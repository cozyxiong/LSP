// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ICETH is IERC20 {
    function mint(address staker, uint256 amount) external;
    function burn(uint256 amount) external;
}
