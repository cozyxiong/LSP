// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;


import "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import "../interface/IUnstakeRequests.sol";
import {ICETH} from "../interface/ICETH.sol";
import {IOracleRead} from "../interface/IOracle.sol";
import {IStakingWrite} from "../interface/IStaking.sol";


interface UnstakeRequestsEvent {
    event UnstakeRequestCreated(uint256 requestId, address requester, uint256 cEthLocked, uint256 ethRequested, uint256 totalEthRequested, uint256 blockNumber);
    event UnstakeRequestClaimed(uint256 requestId, address claimer, uint256 cEthLocked, uint256 ethRequested, uint256 totalEthRequested, uint256 blockNumber);
    event UnstakeRequestCancelled(uint256 requestId, address requester, uint256 cEthLocked, uint256 ethRequested, uint256 totalEthRequested, uint256 blockNumber);
    event UnstakeRequestConfigChanged(bytes4 setterSelector, string setterSignature, bytes value);
}

contract UnstakeRequests is Initializable, AccessControlEnumerableUpgradeable, UnstakeRequestsEvent, IUnstakeRequests {

    error NotStakingContract();
    error AlreadyClaimed();
    error NotRequester();
    error NotFinalized();
    error NotEnoughFunds(uint256 needAmount, uint256 totalAmount);

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant REQUEST_CANCELLER_ROLE = keccak256("REQUEST_CANCELLER_ROLE");

    IStakingWrite public stakingContract;
    IOracleRead public oracle;
    ICETH public cEth;

    uint256 public lastTotalEthRequested;
    UnstakeRequest[] public unstakeRequests;
    uint256 public numberOfBlocksToFinalize;
    uint256 public allocatedEthForClaims;
    uint256 public totalEthClaimed;

    struct Init {
        address admin;
        address manager;
        address canceller;
        address staking;
        address oracle;
        address cEth;
        uint256 numberOfBlocksToFinalize;
    }

    modifier onlyStakingContract() {
        if (msg.sender != address(stakingContract)) { revert NotStakingContract(); }
        _;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(MANAGER_ROLE, init.manager);
        _grantRole(REQUEST_CANCELLER_ROLE, init.canceller);

        stakingContract = IStakingWrite(init.staking);
        oracle = IOracleRead(init.oracle);
        cEth = ICETH(init.cEth);
        numberOfBlocksToFinalize = init.numberOfBlocksToFinalize;
    }

    function allocateEth() external payable onlyStakingContract {
        allocatedEthForClaims += msg.value;
    }

    function withdrawAllocatedETHSurplus() external onlyStakingContract {
        uint256 surplus = 0;
        if (allocatedEthForClaims > lastTotalEthRequested) {
            surplus = allocatedEthForClaims - lastTotalEthRequested;
        } else {
            return;
        }
        allocatedEthForClaims -= surplus;
        stakingContract.receiveSurplus{value: surplus}();
    }

    function create(address requester, uint256 cEthLocked, uint256 ethRequested) external onlyStakingContract returns (uint256) {
        uint256 requestId = unstakeRequests.length;
        uint256 currentTotalEthRequested = lastTotalEthRequested + ethRequested;
        UnstakeRequest memory request = UnstakeRequest({
            id: requestId,
            requester: requester,
            cEthLocked: cEthLocked,
            ethRequested: ethRequested,
            totalEthRequested: currentTotalEthRequested,
            blockNumber: block.number
        });
        unstakeRequests.push(request);
        lastTotalEthRequested = currentTotalEthRequested;

        emit UnstakeRequestCreated(requestId, requester, cEthLocked, ethRequested, currentTotalEthRequested, block.number);

        return requestId;
    }

    function claim(uint256 requestId, address claimer) external onlyStakingContract {
        UnstakeRequest memory request = unstakeRequests[requestId];
        if (request.requester == address(0)) { revert AlreadyClaimed(); }
        if (request.requester != claimer) { revert NotRequester(); }
        if (!_isFinalized(request)) { revert NotFinalized(); }
        if (request.totalEthRequested > allocatedEthForClaims) { revert NotEnoughFunds(request.totalEthRequested, allocatedEthForClaims); }

        delete unstakeRequests[requestId];
        totalEthClaimed += request.ethRequested;
        cEth.burn(request.cEthLocked);

        emit UnstakeRequestClaimed({
            requestId: requestId,
            claimer: claimer,
            cEthLocked: request.cEthLocked,
            ethRequested: request.ethRequested,
            totalEthRequested: request.totalEthRequested,
            blockNumber: request.blockNumber
        });

        Address.sendValue(payable(claimer), request.ethRequested);
    }

    function cancelUnfinalizedRequests(uint256 maxCancelNumber) external onlyRole(REQUEST_CANCELLER_ROLE) returns (bool) {
        uint256 requestsNumber = unstakeRequests.length;
        if (requestsNumber == 0) { return false; }
        if (requestsNumber < maxCancelNumber) { maxCancelNumber = requestsNumber; }

        uint256 ethCancelledAmount = 0;
        uint256 requestCancelledNumber = 0;
        UnstakeRequest[] memory cancelledRequests = new UnstakeRequest[](maxCancelNumber);
        while (requestCancelledNumber < maxCancelNumber) {
            UnstakeRequest memory request = unstakeRequests[requestsNumber - 1];
            if (_isFinalized(request)) { break; }
            unstakeRequests.pop();
            cancelledRequests[requestCancelledNumber] = request;
            requestCancelledNumber++;
            ethCancelledAmount += request.ethRequested;

            emit UnstakeRequestCancelled({
                requestId: request.id,
                requester: request.requester,
                cEthLocked: request.cEthLocked,
                ethRequested: request.ethRequested,
                totalEthRequested: request.totalEthRequested,
                blockNumber: request.blockNumber
            });
        }

        if (ethCancelledAmount > 0) {
            lastTotalEthRequested -= ethCancelledAmount;
        }

        bool hasMore;
        uint256 remainingRequestsNumber = unstakeRequests.length;
        if (remainingRequestsNumber == 0) {
            hasMore = false;
        } else {
            hasMore = !_isFinalized(unstakeRequests[remainingRequestsNumber - 1]);
        }

        for (uint256 i = 0; i < requestCancelledNumber; i++) {
            SafeERC20.safeTransferFrom(cEth, address(stakingContract), cancelledRequests[i].requester, cancelledRequests[i].cEthLocked);
        }

        return hasMore;
    }




    function setNumberOfBlocksToFinalize(uint256 _numberOfBlocksToFinalize) external onlyRole(MANAGER_ROLE) {
        numberOfBlocksToFinalize = _numberOfBlocksToFinalize;
        emit UnstakeRequestConfigChanged(this.setNumberOfBlocksToFinalize.selector, "setNumberOfBlocksToFinalize(uint256)", abi.encode(numberOfBlocksToFinalize));
    }


    function requestRequestById(uint256 requestId) external view returns (UnstakeRequest memory) {
        return unstakeRequests[requestId];
    }

    function requestBalance() external view returns (uint256) {
        if (allocatedEthForClaims > totalEthClaimed) {
            return allocatedEthForClaims - totalEthClaimed;
        }
        return 0;
    }

    function requestDeficit() external view returns (uint256) {
        if (lastTotalEthRequested > allocatedEthForClaims) {
            return lastTotalEthRequested - allocatedEthForClaims;
        }
        return 0;
    }

    function requestInfo(uint256 requestId) external view returns (bool, uint256) {
        UnstakeRequest memory request = unstakeRequests[requestId];
        bool isFinalized = _isFinalized(request);
        uint256 claimableAmount = 0;
        uint256 allocatedEthRequired = request.totalEthRequested - request.ethRequested;
        if (allocatedEthRequired < allocatedEthForClaims) {
            claimableAmount = Math.min(allocatedEthForClaims - allocatedEthRequired, request.ethRequested);
        }
        return (isFinalized, claimableAmount);
    }

    function _isFinalized(UnstakeRequest memory request) internal view returns (bool) {
        return (request.blockNumber + numberOfBlocksToFinalize) < oracle.getLatestRecord().updateEndBlock;
    }
}
