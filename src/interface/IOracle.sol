// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

struct Record {
    uint256 updateStartBlock;
    uint256 updateEndBlock;
    uint256 totalValidatorsNotWithdrawable;
    uint256 totalValidatorsWithdrawable;
    uint256 windowWithdrawnPrincipalAmount;
    uint256 windowWithdrawnRewardAmount;
    uint256 totalValidatorBalance;
    uint256 totalProcessedDeposit;
}

interface IOracleRead {
    function getLatestRecord() external view returns (Record memory);
    function getRecordsNumber() external view returns (uint256);
    function getPendingUpdateRecord() external view returns (Record memory);
    function hasPendingUpdate() external view returns (bool);
}

interface IOracleWrite {
    function receiveRecord(Record calldata newRecord) external;
}

interface IOracle is IOracleRead, IOracleWrite {}
