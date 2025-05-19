// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {IPauser} from "../interface/IPauser.sol";
import {IOracle} from "../interface/IOracle.sol";

interface PauserEvents {
    event FlagUpdated(bytes4 indexed selector, bool indexed isPaused, string flagName);
}

contract Pauser is Initializable, AccessControlEnumerableUpgradeable, PauserEvents, IPauser {

    error NotPauserRoleOrOracle(address requester);

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    bool public isStakingPaused;
    bool public isUnstakeRequestAndClaimPaused;
    bool public isAllocateEthPaused;
    bool public isInitiateValidatorPaused;
    bool public isReceiveOracleRecordPaused;

    IOracle public oracle;

    struct Init {
        address admin;
        address pauser;
        address unpauser;
        address oracle;
    }

    modifier onlyPauserOrUnpauserRole(bool isPaused) {
        if (isPaused) {
            _checkRole(PAUSER_ROLE);
        } else {
            _checkRole(UNPAUSER_ROLE);
        }
        _;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(PAUSER_ROLE, init.pauser);
        _grantRole(UNPAUSER_ROLE, init.unpauser);

        oracle = IOracle(init.oracle);
    }

    function setIsStakingPaused(bool isPaused) external onlyPauserOrUnpauserRole(isPaused) {
        _setIsStakingPause(isPaused);
    }

    function setIsUnstakeRequestAndClaimPaused(bool isPaused) external onlyPauserOrUnpauserRole(isPaused) {
        _setIsUnstakeRequestAndClaimPaused(isPaused);
    }

    function setIsAllocateEthPaused(bool isPaused) external onlyPauserOrUnpauserRole(isPaused) {
        _setIsAllocateEthPaused(isPaused);
    }

    function setIsInitiateValidatorsPaused(bool isPaused) external onlyPauserOrUnpauserRole(isPaused) {
        _setIsInitiateValidatorsPaused(isPaused);
    }

    function setIsReceiveRecordPaused(bool isPaused) external onlyPauserOrUnpauserRole(isPaused) {
        _setIsReceiveRecordPaused(isPaused);
    }

    function pauseAll() external {
        if (!hasRole(PAUSER_ROLE, msg.sender) || msg.sender != address(oracle)) {
            revert NotPauserRoleOrOracle(msg.sender);
        }
        _setIsStakingPause(true);
        _setIsUnstakeRequestAndClaimPaused(true);
        _setIsAllocateEthPaused(true);
        _setIsInitiateValidatorsPaused(true);
        _setIsReceiveRecordPaused(true);
    }

    function unpauseAll() external onlyRole(UNPAUSER_ROLE) {
        _setIsStakingPause(false);
        _setIsUnstakeRequestAndClaimPaused(false);
        _setIsAllocateEthPaused(false);
        _setIsInitiateValidatorsPaused(false);
        _setIsReceiveRecordPaused(false);
    }


    // ========================================  internal =============================================

    function _setIsStakingPause(bool isPaused) internal {
        isStakingPaused = isPaused;
        emit FlagUpdated(this.isStakingPaused.selector, isPaused, "isStackingPaused");
    }

    function _setIsUnstakeRequestAndClaimPaused(bool isPaused) internal {
        isUnstakeRequestAndClaimPaused = isPaused;
        emit FlagUpdated(this.isUnstakeRequestAndClaimPaused.selector, isPaused, "isUnstakeRequestAndClaimPaused");
    }

    function _setIsAllocateEthPaused(bool isPaused) internal {
        isAllocateEthPaused = isPaused;
        emit FlagUpdated(this.isAllocateEthPaused.selector, isPaused, "isAllocateEthPaused");
    }

    function _setIsInitiateValidatorsPaused(bool isPaused) internal {
        isInitiateValidatorPaused = isPaused;
        emit FlagUpdated(this.isInitiateValidatorPaused.selector, isPaused, "isInitiateValidatorPaused");
    }

    function _setIsReceiveRecordPaused(bool isPaused) internal {
        isReceiveOracleRecordPaused = isPaused;
        emit FlagUpdated(this.isReceiveOracleRecordPaused.selector, isPaused, "isReceiveOracleRecordPaused");
    }
}
