// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IStakingRead {
    function totalDepositedInValidators() external view returns (uint256);
    function InitiatedValidatorNumber() external view returns (uint256);
}

interface IStakingWrite {
    function receiveSurplus() external payable;
    function receiveReturns() external payable;
}

interface IStaking is IStakingRead, IStakingWrite {

}
