// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20 —— L5测试用YUAN代币
contract MockERC20 is ERC20 {
    constructor() ERC20("ORIGIN YUAN", "YUAN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
