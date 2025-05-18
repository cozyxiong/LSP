// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SymTest} from "../../lib/openzeppelin-contracts/lib/halmos-cheatcodes/src/SymTest.sol";
import {IStaking} from "../interface/IStaking.sol";
import {IUnstakeRequests} from "../interface/IUnstakeRequests.sol";
import {ICETH} from "../interface/ICETH.sol";

contract CETH is Initializable, AccessControlEnumerableUpgradeable, ERC20PermitUpgradeable, ICETH{

    error NotStakingContract();
    error NotUnstakeRequestContract();

    string public constant NAME = "cETH";
    string public constant SYMBOL = "cETH";

    IStaking public stakingContract;
    IUnstakeRequests public unstakeRequestContract;

    struct Init {
        address admin;
        IStaking staking;
        IUnstakeRequests unstakeRequest;
    }

    constructor(){
        _disableInitializers();
    }

    function initialize(Init memory init) external initializer {
        __AccessControlEnumerable_init();
        __ERC20_init(NAME, SYMBOL);
        __ERC20Permit_init(NAME);

        _grantRole(DEFAULT_ADMIN_ROLE, init.admin);

        stakingContract = init.staking;
        unstakeRequestContract = init.unstakeRequest;
    }

    function mint(address staker, uint256 amount) external {
        if (msg.sender != address(stakingContract)) { revert NotStakingContract(); }
        _mint(staker, amount);
    }

    function burn(uint256 amount) external {
        if (msg.sender != address(unstakeRequestContract)) { revert NotUnstakeRequestContract(); }
        _burn(msg.sender, amount);
    }

    function nonces(address account) public view virtual override(ERC20PermitUpgradeable) returns (uint256) {
        return ERC20PermitUpgradeable.nonces(account);
    }
}
