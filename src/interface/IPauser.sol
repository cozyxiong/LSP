// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IPauserRead {
    function isStakingPaused() external view returns (bool);
    function isUnstakeRequestAndClaimPaused() external view returns (bool);
    function isAllocateEthPaused() external view returns (bool);
    function isInitiateValidatorPaused() external view returns (bool);
    function isReceiveOracleRecordPaused() external view returns (bool);
}

interface IPauserWrite {
    function pauseAll() external;
}

interface IPauser is IPauserRead, IPauserWrite {}
