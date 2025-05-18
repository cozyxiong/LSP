// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

struct UnstakeRequest {
    uint256 id;
    address requester;
    uint256 cEthLocked;
    uint256 ethRequested;
    uint256 totalEthRequested;
    uint256 blockNumber;
}

interface IUnstakeRequestsWrite {
    function create(address requester, uint256 cEthLocked, uint256 ethRequested) external returns (uint256);
    function claim(uint256 requestId, address claimer) external;
    function cancelUnfinalizedRequests(uint256 maxCancelNumber) external returns (bool);
    function allocateEth() external payable;
    function withdrawAllocatedETHSurplus() external;
}

interface IUnstakeRequestsRead {
    function requestRequestById(uint256 requestId) external view returns (UnstakeRequest memory);
    function requestBalance() external view returns (uint256);
    function requestDeficit() external view returns (uint256);
    function requestInfo(uint256 requestId) external view returns (bool, uint256);
}

interface IUnstakeRequests is IUnstakeRequestsWrite, IUnstakeRequestsRead {}
