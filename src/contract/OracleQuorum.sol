// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interface/IOracle.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IOracleQuorum} from "../interface/IOracleQuorum.sol";
import {IOracle} from "../interface/IOracle.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface OracleQuorumEvent {
    event ReportReceived(uint256 blockNumber, address reporter, bytes32 recordHash, Record record);
    event ReportQuorumReached(uint256 block);
    event OracleRecordReceivedError(bytes reason);
    event OracleQuorumConfigChanged(bytes4 setterSelector, string setterSignature, bytes value);
}

contract OracleQuorum is Initializable, AccessControlEnumerableUpgradeable, OracleQuorumEvent, IOracleQuorum {

    error InvalidRelativeThresholdBasisPoints();

    bytes32 public constant QUORUM_MANAGER_ROLE = keccak256("QUORUM_MANAGER_ROLE");
    bytes32 public constant SERVICE_ORACLE_REPORTER = keccak256("SERVICE_ORACLE_REPORTER");
    bytes32 public constant REPORTER_MODIFIER_ROLE = keccak256("REPORTER_MODIFIER_ROLE");

    mapping(uint256 block => mapping(address reporter => bytes32 recordHash)) public reporterRecordHashByBlock;
    mapping(uint256 block => mapping(bytes32 recordHash => uint256)) public recordHashCountByBlock;
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public absoluteThreshold;
    uint256 public relativeThresholdBasisPoints;

    IOracle public oracle;

    struct Init {
        address admin;
        address manager;
        address reporterModifier;
        address[] allowedReporters;
        address oracle;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(QUORUM_MANAGER_ROLE, init.manager);
        _grantRole(REPORTER_MODIFIER_ROLE, init.reporterModifier);
        _setRoleAdmin(SERVICE_ORACLE_REPORTER, REPORTER_MODIFIER_ROLE);
        for (uint256 i = 0; i < init.allowedReporters.length; i++) {
            _grantRole(SERVICE_ORACLE_REPORTER, init.allowedReporters[i]);
        }

        oracle = IOracle(init.oracle);
        absoluteThreshold = 1;
        relativeThresholdBasisPoints = 0;
    }

    function receiveRecord(Record calldata record) external onlyRole(SERVICE_ORACLE_REPORTER) {
        bytes32 recordHash = _updateRecordHash(msg.sender, record);
        if (!_hasReachedQuorum(record.updateEndBlock, recordHash)) { return; }
        if (_wasReceivedByOracle(record.updateEndBlock)) { return; }
        emit ReportQuorumReached(record.updateEndBlock);

        try oracle.receiveRecord(record) {}
        catch (bytes memory reason) {
            emit OracleRecordReceivedError(reason);
        }
    }

    function _updateRecordHash(address reporter, Record calldata record) internal returns (bytes32) {
        bytes32 newRecordHash = keccak256(abi.encode(record));
        emit ReportReceived(record.updateEndBlock, reporter, newRecordHash, record);
        bytes32 prevRecordHash = reporterRecordHashByBlock[record.updateEndBlock][reporter];
        if (newRecordHash == prevRecordHash) { return newRecordHash; }
        if (prevRecordHash != 0) { recordHashCountByBlock[record.updateEndBlock][prevRecordHash] -= 1; }

        reporterRecordHashByBlock[record.updateEndBlock][reporter] = newRecordHash;
        recordHashCountByBlock[record.updateEndBlock][newRecordHash] += 1;

        return newRecordHash;
    }

    function _hasReachedQuorum(uint256 blockNumber, bytes32 recordHash) internal view returns (bool) {
        uint256 reportsNumber = recordHashCountByBlock[blockNumber][recordHash];
        uint256 reportersNumber = getRoleMemberCount(SERVICE_ORACLE_REPORTER);
        return (reportsNumber >= absoluteThreshold) && (reportsNumber * BASIS_POINTS_DENOMINATOR >= reportersNumber * relativeThresholdBasisPoints);
    }

    function _wasReceivedByOracle(uint256 updateEndBlock) internal view returns (bool) {
        return (oracle.getLatestRecord().updateEndBlock >= updateEndBlock) || (oracle.getPendingUpdateRecord().updateEndBlock >= updateEndBlock);
    }

    function setQuorumThresholds(uint256 _absoluteThreshold, uint256 _relativeThresholdBasisPoints) external onlyRole(QUORUM_MANAGER_ROLE) {
        if (_relativeThresholdBasisPoints > BASIS_POINTS_DENOMINATOR) { revert InvalidRelativeThresholdBasisPoints(); }
        absoluteThreshold = _absoluteThreshold;
        relativeThresholdBasisPoints = _relativeThresholdBasisPoints;
        emit OracleQuorumConfigChanged(this.setQuorumThresholds.selector, "setQuorumThresholds(uint256,uint256)", abi.encode(absoluteThreshold, relativeThresholdBasisPoints));
    }

    function getRecordHashByBlockAndSender(uint256 blockNumber, address sender) external view returns (bytes32) {
        return reporterRecordHashByBlock[blockNumber][sender];
    }
}
















