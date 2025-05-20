// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ReturnsReceiver is Initializable, AccessControlEnumerableUpgradeable {

    bytes32 public constant RECEIVER_MANAGER_ROLE = keccak256("RECEIVER_MANAGER_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");


    struct Init {
        address admin;
        address manager;
        address withdrawer;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
        _grantRole(RECEIVER_MANAGER_ROLE, init.manager);
        _setRoleAdmin(WITHDRAWER_ROLE, RECEIVER_MANAGER_ROLE);
        _grantRole(WITHDRAWER_ROLE, init.withdrawer);
    }

    receive() external payable {}

    function transfer(address payable to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        Address.sendValue(to, amount);
    }

    function transfer(IERC20 token,address to, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        SafeERC20.safeTransfer(token, to, amount);
    }
}
