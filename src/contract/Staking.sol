// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interface/IOracle.sol";
import {IPauserRead} from "../interface/IPauser.sol";
import {ICETH} from "../interface/ICETH.sol";
import {IOracleRead} from "../interface/IOracle.sol";
import {IUnstakeRequests} from "../interface/IUnstakeRequests.sol";
import {ERC20PermitUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IDepositContract} from "../interface/IDepositContract.sol";

interface stakingEvents {
    event Staked(address indexed staker, uint256 stakeAmount, uint256 cETHAmount);
    event AllocatedEthForClaim(uint256 allocateAmount);
    event AllocatedEthForDeposit(uint256 allocateAmount);
    event SurplusReceived(uint256 SurplusAmount);
    event ReturnsReceived(uint256 ReturnsAmount);
    event ValidatorInitiated(bytes32 indexed id, uint256 indexed operatorId, bytes publicKey, uint256 amountDeposited);
    event UnstackRequested(uint256 indexed requestId, address indexed requester, uint256 cEthAmount, uint256 ethAmount);
    event UnstakeRequestClaimed(uint256 indexed requestId, address indexed claimer);
    event StakeConfigChanged(bytes4 indexed setterSelector, string setterSignature, bytes value);
}

contract Staking is Initializable, AccessControlEnumerableUpgradeable, stakingEvents {
    error Paused();
    error MinimumStakeAmountNotSatisfied();
    error MaximumCETHSupplyExceeded();
    error MinimumUnstakeAmountNotSatisfied();
    error NotEnoughUnallocatedETH();
    error InvalidDepositRoot(bytes32 actualRoot);
    error PreviouslyUsedValidator();
    error MinimumDepositAmountNotSatisfied();
    error MaximumDepositAmountNotSatisfied();
    error InvalidWithdrawalCredentialsWrongLength(uint256);
    error InvalidWithdrawalCredentialsNotETH1(bytes12);
    error InvalidWithdrawalCredentialsWrongAddress(address);
    error NotEnoughDepositETH();
    error ZeroAddress();

    bytes32 public constant STAKING_MANAGER_ROLE = keccak256("STAKING_MANAGER_ROLE");
    bytes32 public constant STAKING_ALLOWLIST_MANAGER_ROLE = keccak256("STAKING_ALLOWLIST_MANAGER_ROLE");
    bytes32 public constant STAKING_ALLOWLIST_ROLE = keccak256("STAKING_ALLOWLIST_ROLE");
    bytes32 public constant ALLOCATOR_SERVICE_ROLE = keccak256("ALLOCATOR_SERVICE_ROLE");
    bytes32 public constant INITIATOR_SERVICE_ROLE = keccak256("INITIATOR_SERVICE_ROLE");

    uint16 public exchangeAdjustmentRate;
    uint16 internal constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_EXCHANGE_ADJUSTMENT_RATE = BASIS_POINTS_DENOMINATOR / 10;

    using SafeERC20 for ICETH;
    IUnstakeRequests public unstakeRequests;
    IPauserRead public pauser;
    ICETH public cEth;
    IOracleRead public oracle;
    IDepositContract public depositContract;

    bool public isStakingAllowed;
    uint256 public unallocatedETH;
    uint256 public allocatedEthForDeposit;
    uint256 public totalDepositedInValidators;
    uint256 public minimumStakeAmount;
    uint256 public minimumUnstakeAmount;
    uint256 public maximumCETHSupply;
    uint256 public minimumDepositAmount;
    uint256 public maximumDepositAmount;
    uint256 public InitiatedValidatorNumber;
    address public withdrawalWallet;
    mapping(bytes publicKey => bool exists) public usedValidators;

    struct Validator {
        uint256 operatorId;
        bytes publicKey;
        uint256 depositAmount;
        bytes withdrawalCredentials;
        bytes signature;
        bytes32 depositDataRoot;
    }

    struct Init {
        address admin;
        address manager;
        address allocatorService;
        address withdrawalWallet;
        address pauser;
        address oracle;
        address cEth;
        address unstakeRequests;
        address depositContract;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(STAKING_MANAGER_ROLE, init.manager);
        _grantRole(ALLOCATOR_SERVICE_ROLE, init.allocatorService);

        _setRoleAdmin(STAKING_ALLOWLIST_MANAGER_ROLE, STAKING_MANAGER_ROLE);
        _setRoleAdmin(STAKING_ALLOWLIST_ROLE, STAKING_ALLOWLIST_MANAGER_ROLE);

        pauser = IPauserRead(init.pauser);
        oracle = IOracleRead(init.oracle);
        cEth = ICETH(init.cEth);
        unstakeRequests = IUnstakeRequests(init.unstakeRequests);
        depositContract = IDepositContract(depositContract);
        withdrawalWallet = init.withdrawalWallet;

        isStakingAllowed = true;
        minimumStakeAmount = 0.1 ether;
        minimumUnstakeAmount = 0.01 ether;
        maximumCETHSupply = 1024 ether;
        minimumDepositAmount = 32 ether;
        maximumDepositAmount = 32 ether;
    }

    function stake() external payable {
        if (pauser.isStakingPaused()) { revert Paused(); }
        if (isStakingAllowed) { _checkRole(STAKING_ALLOWLIST_ROLE); }
        if (msg.value < minimumStakeAmount) { revert MinimumStakeAmountNotSatisfied(); }

        uint256 cETHAmount = ethTocEth(msg.value);
        if (cETHAmount + cEth.totalSupply() > maximumCETHSupply) { revert MaximumCETHSupplyExceeded(); }
        unallocatedETH += msg.value;
        emit Staked(msg.sender, msg.value, cETHAmount);

        cEth.mint(msg.sender, cETHAmount);
    }

    function allocateEth(uint256 allocateEthForClaim, uint256 allocateEthForDeposit) external onlyRole(ALLOCATOR_SERVICE_ROLE) {
        if (pauser.isAllocateEthPaused()) { revert Paused(); }
        if (allocateEthForClaim + allocateEthForDeposit > unallocatedETH) { revert NotEnoughUnallocatedETH(); }
        unallocatedETH -= allocateEthForClaim + allocateEthForDeposit;
        if (allocateEthForClaim > 0) {
            unstakeRequests.allocateEth{value: allocateEthForClaim}();
            emit AllocatedEthForClaim(allocateEthForClaim);
        }
        if (allocateEthForDeposit > 0) {
            allocatedEthForDeposit += allocateEthForDeposit;
            emit AllocatedEthForDeposit(allocateEthForDeposit);
        }
    }

    function reclaimAllocatedEthSurplus() external onlyRole(STAKING_MANAGER_ROLE) {
        unstakeRequests.withdrawAllocatedETHSurplus();
    }

    function receiveSurplus() external payable {
        unallocatedETH += msg.value;
        emit SurplusReceived(msg.value);
    }

    function receiveReturns() external payable{
        unallocatedETH += msg.value;
        emit ReturnsReceived(msg.value);
    }

    function recharge() external payable {
        unallocatedETH += msg.value;
    }

    function initiateValidatorsWithDeposit(Validator[] calldata validators, bytes32 expectedDepositRoot) external onlyRole(INITIATOR_SERVICE_ROLE) {
        if (pauser.isInitiateValidatorPaused()) { revert Paused(); }
        if (validators.length == 0) { return; }

        bytes32 actualRoot = depositContract.get_deposit_root();
        if (expectedDepositRoot != actualRoot) {
            revert InvalidDepositRoot(actualRoot);
        }

        uint256 amountDeposited = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            Validator calldata validator = validators[i];
            if (usedValidators[validator.publicKey]) { revert PreviouslyUsedValidator(); }
            if (validator.depositAmount < minimumDepositAmount) { revert MinimumDepositAmountNotSatisfied(); }
            if (validator.depositAmount > maximumDepositAmount) { revert MaximumDepositAmountNotSatisfied(); }
            _requireProtocolWithdrawalAccount(validator.withdrawalCredentials);

            usedValidators[validator.publicKey] = true;
            amountDeposited += validator.depositAmount;

            emit ValidatorInitiated(keccak256(validator.publicKey), validator.operatorId, validator.publicKey, validator.depositAmount);
        }

        if (amountDeposited > allocatedEthForDeposit) { revert NotEnoughDepositETH(); }
        allocatedEthForDeposit -= amountDeposited;
        totalDepositedInValidators += amountDeposited;
        InitiatedValidatorNumber += validators.length;

        for (uint256 i = 0; i < validators.length; i++) {
            Validator calldata validator = validators[i];
            depositContract.deposit{value: validator.depositAmount}({
                pubkey: validator.publicKey,
                withdrawal_credentials: validator.withdrawalCredentials,
                signature: validator.signature,
                deposit_data_root: validator.depositDataRoot
            });
        }
    }

    function unstakeRequest(uint256 cEthAmount) external returns (uint256) {
        return _unstakeRequest(cEthAmount);
    }

    function unstakeRequestWithPermit(uint256 cEthAmount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (uint256) {
        IERC20Permit(address(cEth)).permit(msg.sender, address(this), cEthAmount, deadline, v, r, s);
        return _unstakeRequest(cEthAmount);
    }

    function _unstakeRequest(uint256 cEthAmount) internal returns (uint256) {
        if (pauser.isUnstakeRequestAndClaimPaused()) { revert Paused(); }
        if (cEthAmount < minimumUnstakeAmount) { revert MinimumUnstakeAmountNotSatisfied(); }

        uint256 ethAmount = cEthToEth(cEthAmount);
        cEth.safeTransferFrom(msg.sender, address(this), cEthAmount);
        uint256 requestId = unstakeRequests.create(msg.sender, cEthAmount, ethAmount);

        emit UnstackRequested(requestId, msg.sender, cEthAmount, ethAmount);

        return requestId;
    }

    function claimUnstakeRequest(uint256 requestId) external {
        if (pauser.isUnstakeRequestAndClaimPaused()) { revert Paused(); }
        emit UnstakeRequestClaimed(requestId, msg.sender);
        unstakeRequests.claim(requestId, msg.sender);
    }





    function ethTocEth(uint256 ethAmount) public view returns (uint256) {
        if (cEth.totalSupply() == 0) { return ethAmount; }
        return Math.mulDiv(
            ethAmount,
            cEth.totalSupply() * uint256(BASIS_POINTS_DENOMINATOR - exchangeAdjustmentRate),
            totalControlled() * uint256(BASIS_POINTS_DENOMINATOR)
        );
    }

    function cEthToEth(uint256 cETHAmount) public view returns (uint256) {
        if (cEth.totalSupply() == 0) { return cETHAmount; }
        return Math.mulDiv(
            cETHAmount,
            totalControlled(),
            cEth.totalSupply());
    }

    function totalControlled() public view returns (uint256) {
        Record memory record = oracle.getLatestRecord();

        uint256 total = 0;
        total += unallocatedETH;
        total += allocatedEthForDeposit;
        total += totalDepositedInValidators - record.totalProcessedDeposit;
        total += record.totalValidatorBalance;
        total += unstakeRequests.requestBalance();

        return total;
    }

    /// @notice Checks if the given withdrawal credentials are a valid 0x01 prefixed withdrawal address.
    /// @dev See also
    /// https://github.com/ethereum/consensus-specs/blob/master/specs/phase0/validator.md#eth1_address_withdrawal_prefix
    function _requireProtocolWithdrawalAccount(bytes calldata withdrawalCredentials) internal view {
        if (withdrawalCredentials.length != 32) {
            revert InvalidWithdrawalCredentialsWrongLength(withdrawalCredentials.length);
        }

        // Check the ETH1_ADDRESS_WITHDRAWAL_PREFIX and that all other bytes are zero.
        bytes12 prefixAndPadding = bytes12(withdrawalCredentials[:12]);
        if (prefixAndPadding != 0x010000000000000000000000) {
            revert InvalidWithdrawalCredentialsNotETH1(prefixAndPadding);
        }

        address addr = address(bytes20(withdrawalCredentials[12:32]));
        if (addr != withdrawalWallet) {
            revert InvalidWithdrawalCredentialsWrongAddress(addr);
        }
    }

    function setMinimumStakeAmount(uint256 _minimumStakeAmount) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumStakeAmount = _minimumStakeAmount;
        emit StakeConfigChanged(this.setMinimumStakeAmount.selector, "setMinimumStakeAmount(uint256)", abi.encode(minimumStakeAmount));
    }

    function setMinimumUnstakeAmount(uint256 _minimumUnstakeAmount) external onlyRole(STAKING_MANAGER_ROLE) {
        minimumUnstakeAmount = _minimumUnstakeAmount;
        emit StakeConfigChanged(this.setMinimumUnstakeAmount.selector, "setMinimumUnstakeAmount(uint256)", abi.encode(minimumUnstakeAmount));
    }

    function setMaximumDepositAmount(uint256 _maximumDepositAmount) external onlyRole(STAKING_MANAGER_ROLE) {
        maximumDepositAmount = _maximumDepositAmount;
        emit StakeConfigChanged(this.setMaximumDepositAmount.selector, "setMaximumDepositAmount(uint256)", abi.encode(maximumDepositAmount));
    }

    function setExchangeAdjustmentRate(uint16 _exchangeAdjustmentRate) external onlyRole(STAKING_MANAGER_ROLE) {
        exchangeAdjustmentRate = _exchangeAdjustmentRate;
        emit StakeConfigChanged(this.setExchangeAdjustmentRate.selector, "setExchangeAdjustmentRate(uint16)", abi.encode(exchangeAdjustmentRate));
    }

    function setMaximumCETHSupply(uint256 _maximumCETHSupply) external onlyRole(STAKING_MANAGER_ROLE) {
        maximumCETHSupply = _maximumCETHSupply;
        emit StakeConfigChanged(this.setMaximumCETHSupply.selector, "setMaximumCETHSupply(uint256)", abi.encode(maximumCETHSupply));
    }

    function setWithdrawalWallet(address _withdrawalWallet) external onlyRole(STAKING_MANAGER_ROLE) {
        if (_withdrawalWallet == address(0)) { revert ZeroAddress(); }
        withdrawalWallet = _withdrawalWallet;
        emit StakeConfigChanged(this.setWithdrawalWallet.selector, "setWithdrawalWallet(uint256)", abi.encode(withdrawalWallet));
    }

    function setIsStakingAllowed(bool _isStakingAllowed) external onlyRole(STAKING_MANAGER_ROLE) {
        isStakingAllowed = _isStakingAllowed;
        emit StakeConfigChanged(this.setIsStakingAllowed.selector, "setIsStakingAllowed(uint256)", abi.encode(isStakingAllowed));
    }

    function getUnstakeRequestInfo(uint256 requestId) external view returns (bool, uint256) {
        return unstakeRequests.requestInfo(requestId);
    }
}