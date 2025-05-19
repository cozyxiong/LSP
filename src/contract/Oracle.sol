// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import "../interface/IOracle.sol";
import {IAggregatorWrite} from "../interface/IAggregator.sol";
import {IPauser} from "../interface/IPauser.sol";
import {IStakingRead} from "../interface/IStaking.sol";

interface OracleEvents {
    event OracleRecordAdded(uint256 indexed index, Record newRecord);
    event OracleRecordModified(uint256 indexed index, Record replaceRecord);
    event OraclePendingUpdateRejected(Record pendingRecord);
    event OracleConfigChanged(bytes4 indexed setterSelector, string setterSignature, bytes value);
    event RecordFailedSanityCheck(bytes32 reasonHash, string reason, Record record, uint256 value, uint256 bound);
}

contract Oracle is Initializable, AccessControlEnumerableUpgradeable, OracleEvents, IOracle {

    error Paused();
    error NotOracleUpdater();
    error UpdatePending();
    error InvalidUpdateEndBlock();
    error InvalidUpdateStartBlock();
    error InvalidTotalProcessedDeposit(uint256 processed, uint256 sent);
    error InvalidValidators(uint256 record, uint256 actual);
    error NotFinalized();
    error CannotModifyInitialRecord();
    error InvalidRecordIndex();
    error InvalidReplaceRecord();
    error NoUpdatePending();
    error AboveMaxNumberOfBlocksToFinalize();
    error ZeroAddress();
    error AboveDenominator();

    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant ORACLE_MODIFIER_ROLE = keccak256("ORACLE_MODIFIER_ROLE");
    bytes32 public constant ORACLE_PENDING_UPDATE_RESOLVER_ROLE = keccak256("ORACLE_PENDING_UPDATE_RESOLVER_ROLE");

    bool public hasPendingUpdate;
    Record public pendingUpdateRecord;
    address public oracleUpdater;
    Record[] internal records;
    uint256 public numberOfBlocksToFinalize;
    uint256 public minRecordInterval;
    uint256 public minDepositPerValidator;
    uint256 public maxDepositPerValidator;
    uint256 public maxConsensusLayerLossPPM;
    uint256 public minConsensusLayerGainPerBlockPPT;
    uint256 public maxConsensusLayerGainPerBlockPPT;
    uint256 internal constant PPM_DENOMINATOR = 1e6;
    uint256 internal constant PPT_DENOMINATOR = 1e12;
    uint256 internal constant MAX_NUMBER_OF_BLOCKS_TO_FINALIZE = 2048;

    IPauser public pauser;
    IStakingRead public staking;
    IAggregatorWrite public aggregator;

    struct Init {
        address admin;
        address manager;
        address pendingResolver;
        address oracleUpdater;
        address pauser;
        address staking;
        address aggregator;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        // We intentionally do not assign an address to the ORACLE_MODIFIER_ROLE.
        // This is to prevent unintentional oracle modifications outside of exceptional circumstances.
        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(ORACLE_MANAGER_ROLE, init.manager);
        _grantRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE, init.pendingResolver);

        oracleUpdater = init.oracleUpdater;
        pauser = IPauser(init.pauser);
        staking = IStakingRead(init.staking);
        aggregator = IAggregatorWrite(aggregator);

        numberOfBlocksToFinalize = 64;
        minRecordInterval = 100;
        minDepositPerValidator = 32 ether;
        maxDepositPerValidator = 32 ether;
        // 7200 slots per day * 365 days per year = 2628000 slots per year
        // assuming 5% yield per year
        // 5% / 2628000 = 1.9025e-8
        // 1.9025e-8 per slot = 19025 PPT
        maxConsensusLayerGainPerBlockPPT = 190250; // 10x approximate rate
        minConsensusLayerGainPerBlockPPT = 1903; // 0.1x approximate rate
        // We chose a lower bound of a 0.1% loss for the protocol based on several factors:
        // - Sanity check should not fail for normal operations where we define normal operations as attestation
        // penalties due to offline validators. Supposing all our validators go offline, the protocol is expected
        // to have a 0.03% missed attestation penalty on mainnet for all validators' balance for a single day.
        // - For a major slashing event, (i.e. 1 ETH slashed for half of our validators), we should expect a drop of
        // 1.56% of the entire protocol. This *must* trigger the consensus layer loss lower bound.
        maxConsensusLayerLossPPM = 1000;
    }

    function receiveRecord(Record calldata newRecord) external {
        if (pauser.isReceiveOracleRecordPaused()) { revert Paused(); }
        if (msg.sender != oracleUpdater) { revert NotOracleUpdater(); }
        if (hasPendingUpdate) { revert UpdatePending(); }
        _validationCheckUpdate(records.length - 1, newRecord);
        if (block.number < newRecord.updateEndBlock + numberOfBlocksToFinalize) { revert NotFinalized(); }
        (string memory rejectionReason, uint256 value, uint256 bound) = _sanityCheckUpdate(records.length - 1, newRecord);
        if (bytes(rejectionReason).length > 0) {
            pendingUpdateRecord = newRecord;
            hasPendingUpdate = true;
            emit RecordFailedSanityCheck(keccak256(bytes(rejectionReason)), rejectionReason, newRecord, value, bound);
            pauser.pauseAll();
            return;
        }
        _pushRecord(newRecord);
    }

    function acceptPendingUpdate() external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        if (!hasPendingUpdate) { revert NoUpdatePending(); }
        _pushRecord(pendingUpdateRecord);
        _resetPending();
    }

    function rejectPendingUpdate() external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        if (!hasPendingUpdate) { revert NoUpdatePending(); }
        emit OraclePendingUpdateRejected(pendingUpdateRecord);
        _resetPending();
    }

    function modifyExistingRecord(uint256 index, Record calldata replaceRecord) external onlyRole(ORACLE_MODIFIER_ROLE) {
        Record storage existingRecord = records[index];
        if (index == 0) { revert CannotModifyInitialRecord(); }
        if (index >= records.length) { revert InvalidRecordIndex(); }
        if (replaceRecord.updateStartBlock != existingRecord.updateStartBlock
            || replaceRecord.updateEndBlock != existingRecord.updateEndBlock) { revert InvalidReplaceRecord(); }
        _validationCheckUpdate(index - 1, replaceRecord);

        uint256 missingRewards = 0;
        uint256 missingPrincipals = 0;
        if (replaceRecord.windowWithdrawnRewardAmount > existingRecord.windowWithdrawnRewardAmount) {
            missingRewards = replaceRecord.windowWithdrawnRewardAmount - existingRecord.windowWithdrawnRewardAmount;
        }
        if (replaceRecord.windowWithdrawnPrincipalAmount > existingRecord.windowWithdrawnPrincipalAmount) {
            missingPrincipals = replaceRecord.windowWithdrawnPrincipalAmount - existingRecord.windowWithdrawnPrincipalAmount;
        }
        if (missingRewards > 0 || missingPrincipals > 0) {
            aggregator;
        }

        aggregator.processReturns({
            rewardAmount: missingRewards,
            principalAmount: missingPrincipals,
            shouldIncludeELRewards: false
        });

        records[index] = replaceRecord;
        emit OracleRecordModified(index, replaceRecord);
    }

    function _validationCheckUpdate(uint256 prevRecordIndex, Record calldata newRecord) internal view {
        Record storage prevRecord = records[prevRecordIndex];
        if (newRecord.updateStartBlock >= newRecord.updateEndBlock) { revert InvalidUpdateEndBlock(); }
        if (newRecord.updateStartBlock != prevRecord.updateEndBlock + 1) { revert InvalidUpdateStartBlock(); }
        if (newRecord.totalProcessedDeposit > staking.totalDepositedInValidators()) {
            revert InvalidTotalProcessedDeposit(newRecord.totalProcessedDeposit, staking.totalDepositedInValidators());
        }
        if (newRecord.totalValidatorsNotWithdrawable + newRecord.totalValidatorsWithdrawable > staking.InitiatedValidatorNumber()) {
            revert InvalidValidators(newRecord.totalValidatorsNotWithdrawable + newRecord.totalValidatorsWithdrawable, staking.InitiatedValidatorNumber());
        }
    }

    function _sanityCheckUpdate(uint256 prevRecordIndex, Record calldata newRecord) internal view returns (string memory, uint256, uint256) {
        Record storage prevRecord = records[prevRecordIndex];

        uint256 recordInterval = newRecord.updateEndBlock - newRecord.updateStartBlock + 1;
        if (recordInterval < minRecordInterval) { return ("new record's interval below minimum", recordInterval, minRecordInterval); }

        if (newRecord.totalValidatorsWithdrawable < prevRecord.totalValidatorsWithdrawable) { return ("new record's withdrawable validators decreased", newRecord.totalValidatorsWithdrawable, prevRecord.totalValidatorsWithdrawable); }
        uint256 newTotalValidators = newRecord.totalValidatorsWithdrawable + newRecord.totalValidatorsNotWithdrawable;
        uint256 prevTotalValidators = prevRecord.totalValidatorsWithdrawable + prevRecord.totalValidatorsNotWithdrawable;
        if (newTotalValidators < prevTotalValidators) { return ("new record's total validators decreased", newTotalValidators, prevTotalValidators); }

        if (newRecord.totalProcessedDeposit < prevRecord.totalProcessedDeposit) { return ("new record's total processed deposit decreased", newRecord.totalProcessedDeposit, prevRecord.totalProcessedDeposit); }
        uint256 increasedValidators = newTotalValidators - prevTotalValidators;
        uint256 increasedDeposits = newRecord.totalProcessedDeposit - prevRecord.totalProcessedDeposit;
        if (increasedDeposits < increasedValidators * minDepositPerValidator) { return ("new record's increased deposits below minimum deposit per validator", increasedDeposits, increasedValidators * minDepositPerValidator); }
        if (increasedDeposits > increasedValidators * maxDepositPerValidator) { return ("new record's increased deposits above maximum deposit per validator", increasedDeposits, increasedValidators * maxDepositPerValidator); }

        uint256 baselineTotalConsensusLayerBalance = prevRecord.totalValidatorBalance + (newRecord.totalProcessedDeposit - prevRecord.totalProcessedDeposit);
        uint256 newTotalConsensusLayerBalance = newRecord.totalValidatorBalance + newRecord.windowWithdrawnPrincipalAmount + newRecord.windowWithdrawnRewardAmount;
        // Preventing excessive slashing losses
        uint256 lowerBound = baselineTotalConsensusLayerBalance
            - Math.mulDiv(maxConsensusLayerLossPPM, baselineTotalConsensusLayerBalance, PPM_DENOMINATOR)
            + Math.mulDiv(minConsensusLayerGainPerBlockPPT * recordInterval, baselineTotalConsensusLayerBalance, PPT_DENOMINATOR);
        if (newTotalConsensusLayerBalance < lowerBound) { return ("new record's consensus layer balance below lowerBound", newTotalConsensusLayerBalance, lowerBound); }
        // Preventing falsified high yield
        uint256 upperBound = baselineTotalConsensusLayerBalance
            + Math.mulDiv(maxConsensusLayerGainPerBlockPPT * recordInterval, baselineTotalConsensusLayerBalance, PPT_DENOMINATOR);
        if (newTotalConsensusLayerBalance > upperBound) { return ("new record's consensus layer balance above upperBound", newTotalConsensusLayerBalance, upperBound); }

        return ("", 0 ,0);
    }

    function _pushRecord(Record memory record) internal {
        emit OracleRecordAdded(records.length, record);
        records.push(record);

        aggregator.processReturns({
            rewardAmount: record.windowWithdrawnRewardAmount,
            principalAmount: record.windowWithdrawnPrincipalAmount,
            shouldIncludeELRewards: true
        });
    }

    function _resetPending() internal {
        delete pendingUpdateRecord;
        hasPendingUpdate = false;
    }

    function setNumberOfBlocksToFinalize(uint256 _numberOfBlocksToFinalize) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (_numberOfBlocksToFinalize == 0 || _numberOfBlocksToFinalize > MAX_NUMBER_OF_BLOCKS_TO_FINALIZE) {
            revert AboveMaxNumberOfBlocksToFinalize();
        }
        numberOfBlocksToFinalize = _numberOfBlocksToFinalize;
        emit OracleConfigChanged(this.setNumberOfBlocksToFinalize.selector, "setNumberOfBlocksToFinalize(uint256)", abi.encode(numberOfBlocksToFinalize));
    }

    function setOracleUpdater(address _oracleUpdater) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (_oracleUpdater == address(0)) { revert ZeroAddress(); }
        oracleUpdater = _oracleUpdater;
        emit OracleConfigChanged(this.setOracleUpdater.selector, "setOracleUpdater(address)", abi.encode(oracleUpdater));
    }

    function setMinRecordInterval(uint256 _minRecordInterval) external onlyRole(ORACLE_MANAGER_ROLE) {
        minRecordInterval = _minRecordInterval;
        emit OracleConfigChanged(this.setMinRecordInterval.selector, "setMinRecordInterval(address)", abi.encode(minRecordInterval));
    }

    function setMaxDepositPerValidator(uint256 _maxDepositPerValidator) external onlyRole(ORACLE_MANAGER_ROLE) {
        maxDepositPerValidator = _maxDepositPerValidator;
        emit OracleConfigChanged(this.setMaxDepositPerValidator.selector, "setMaxDepositPerValidator(uint256)", abi.encode(maxDepositPerValidator));
    }

    function setMinConsensusLayerGainPerBlockPPT(uint256 _minConsensusLayerGainBlockPPT) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (_minConsensusLayerGainBlockPPT > PPT_DENOMINATOR) { revert AboveDenominator(); }
        minConsensusLayerGainPerBlockPPT = _minConsensusLayerGainBlockPPT;
        emit OracleConfigChanged(this.setMinConsensusLayerGainPerBlockPPT.selector, "setMinConsensusLayerGainPerBlockPPT(uint256)", abi.encode(minConsensusLayerGainPerBlockPPT));
    }

    function setMaxConsensusLayerGainPerBlockPPT(uint256 _maxConsensusLayerGainPerBlockPPT) external  onlyRole(ORACLE_MANAGER_ROLE) {
        if (_maxConsensusLayerGainPerBlockPPT > PPT_DENOMINATOR) { revert AboveDenominator();}
        maxConsensusLayerGainPerBlockPPT = _maxConsensusLayerGainPerBlockPPT;
        emit OracleConfigChanged(this.setMaxConsensusLayerGainPerBlockPPT.selector, "setMaxConsensusLayerGainPerBlockPPT(uint256)", abi.encode(maxConsensusLayerGainPerBlockPPT));
    }

    function setMaxConsensusLayerLossPPM(uint256 _maxConsensusLayerLossPPM) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (_maxConsensusLayerLossPPM > PPM_DENOMINATOR) { revert AboveDenominator(); }
        maxConsensusLayerLossPPM = _maxConsensusLayerLossPPM;
        emit OracleConfigChanged(this.setMaxConsensusLayerLossPPM.selector, "setMaxConsensusLayerLossPPM(uint256)", abi.encode(maxConsensusLayerLossPPM));
    }

    function getLatestRecord() external view returns (Record memory) {
        return records[records.length - 1];
    }

    function getPendingUpdateRecord() external view returns (Record memory) {
        return pendingUpdateRecord;
    }

    function getRecordsNumber() external view returns (uint256) {
        return records.length;
    }
}























