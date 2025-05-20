// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {ReturnsReceiver} from "./ReturnsReceiver.sol";
import {IAggregator} from "../interface/IAggregator.sol";
import {IOracleRead} from "../interface/IOracle.sol";
import {IStakingWrite} from "../interface/IStaking.sol";

interface AggregatorEvent {
    event FeeAdd(uint256 fees);
    event AggregatorConfigChanged(bytes4 indexed setterSelector, string setterSignature, bytes value);
}

contract ReturnsAggregator is Initializable, AccessControlEnumerableUpgradeable, AggregatorEvent, IAggregator {

    error NotOracle();
    error InvalidFeePoint();
    error ZeroAddress();

    bytes32 public constant AGGREGATOR_MANAGER_ROLE = keccak256("AGGREGATOR_MANAGER_ROLE");

    uint16 internal constant BASIC_POINT_DENOMINATOR = 10_000;
    uint16 public feesBasisPoints;

    IOracleRead public oracle;
    IStakingWrite public staking;
    ReturnsReceiver public consensusLayerReceiver;
    ReturnsReceiver public executionLayerReceiver;
    address payable public feeReceiver;

    struct Init {
        address admin;
        address manager;
        address oracle;
        address staking;
        address payable consensusLayerReceiver;
        address payable executionLayerReceiver;
        address payable feeReceiver;
    }

    modifier assertBalanceUnchanged() {
        uint256 beforeBalance = address(this).balance;
        _;
        assert(address(this).balance == beforeBalance);
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(AGGREGATOR_MANAGER_ROLE, init.manager);

        oracle = IOracleRead(init.oracle);
        staking = IStakingWrite(init.staking);
        consensusLayerReceiver = ReturnsReceiver(init.consensusLayerReceiver);
        executionLayerReceiver = ReturnsReceiver(init.executionLayerReceiver);
        feeReceiver = init.feeReceiver;

        feesBasisPoints = 1_000;
    }

    receive() external payable {}

    function processReturns(uint256 rewardAmount, uint256 principalAmount, bool shouldIncludeELRewards) external assertBalanceUnchanged  {
        if (msg.sender != address(oracle)) { revert NotOracle(); }

        uint256 consensusLayerTotalAmount = rewardAmount + principalAmount;
        uint256 totalRewards = rewardAmount;
        uint256 executionLayerTotalAmount = 0;
        if (shouldIncludeELRewards) {
            executionLayerTotalAmount = address(executionLayerReceiver).balance;
            totalRewards += executionLayerTotalAmount;
        }

        address payable self = payable(address(this));
        if (consensusLayerTotalAmount > 0) {
            consensusLayerReceiver.transfer(self, consensusLayerTotalAmount);
        }
        if (executionLayerTotalAmount > 0) {
            executionLayerReceiver.transfer(self, executionLayerTotalAmount);
        }

        uint256 fees = Math.mulDiv(feesBasisPoints, totalRewards, BASIC_POINT_DENOMINATOR);
        uint256 ActualReturns = consensusLayerTotalAmount + executionLayerTotalAmount - fees;
        if (ActualReturns > 0) {
            staking.receiveReturns{value: ActualReturns}();
        }
        if (fees > 0) {
            Address.sendValue(feeReceiver, fees);
            emit FeeAdd(fees);
        }
    }

    function setFeeReceiver(address payable _feeReceiver) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        if (_feeReceiver == address(0)) { revert ZeroAddress(); }
        feeReceiver = _feeReceiver;
        emit AggregatorConfigChanged(this.setFeeReceiver.selector, "setFeeReceiver(address)", abi.encode(feeReceiver));
    }

    function setFeeBasisPoints(uint16 _feeBasisPoints) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        if (_feeBasisPoints > BASIC_POINT_DENOMINATOR) { revert InvalidFeePoint(); }
        feesBasisPoints = _feeBasisPoints;
        emit AggregatorConfigChanged(this.setFeeBasisPoints.selector, "setFeeBasisPoints(uint16)", abi.encode(feesBasisPoints));
    }
}


















