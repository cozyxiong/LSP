// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IAggregatorRead {

}

interface IAggregatorWrite {
    function processReturns(uint256 rewardAmount, uint256 principalAmount, bool shouldIncludeELRewards) external;
}

interface IAggregator is IAggregatorRead, IAggregatorWrite {

}
