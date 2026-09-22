// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5Delegation} from "src/L5Delegation.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5Delegation 测试套件 —— ERC-7710 委托 + AgentSpendPolicy
/// @notice 覆盖: 创建/校验 / spend结算 / 周期与上限 / revoke(宪法第0条)
contract L5DelegationTest is Test {
    L5Delegation public del;
    MockERC20 public yuan;

    address public owner = address(this);
    address public delegator = address(0x1);
    address public delegate = address(0x2);
    address public payTo = address(0x3);

    bytes32 public delId;

    function setUp() public {
        del = new L5Delegation();
        yuan = new MockERC20();
        // mint 给 delegate（spend 从 msg.sender=delegate 转出）
        yuan.mint(delegate, 1000 ether);
        // approve
        vm.prank(delegate);
        yuan.approve(address(del), type(uint256).max);
    }

    function _createDelegation() internal returns (bytes32) {
        vm.prank(delegator);
        return del.createDelegation(
            delegate, // _delegate
            address(yuan), // _token
            payTo, // _allowedPayTo
            "api:", // _resourcePattern (前缀匹配: 以冒号结尾)
            10 ether, // _maxPerRequest
            30 ether, // _maxPerPeriod
            7 days, // _period
            30 days // _validFor
        );
    }

    // ── 创建 ──
    function test_CreateDelegation() public {
        delId = _createDelegation();
        L5Delegation.Delegation memory d = del.getDelegation(delId);
        assertEq(d.delegator, delegator);
        assertEq(d.delegate, delegate);
        assertEq(d.token, address(yuan));
        assertEq(d.allowedPayTo, payTo);
        assertTrue(d.revocable); // 宪法第0条：默认可撤销
        assertEq(uint8(d.status), uint8(L5Delegation.DelegationStatus.Active));
        assertEq(d.maxPerRequest, 10 ether);
        assertEq(d.maxPerPeriod, 30 ether);
    }

    function test_CreateRejectBadDelegate() public {
        vm.prank(delegator);
        vm.expectRevert("L5D: bad delegate");
        del.createDelegation(address(0), address(yuan), payTo, "api:", 1 ether, 2 ether, 7 days, 1 days);
    }

    function test_CreateRejectReqGtPeriod() public {
        vm.prank(delegator);
        vm.expectRevert("L5D: req>period");
        del.createDelegation(delegate, address(yuan), payTo, "api:", 20 ether, 10 ether, 7 days, 1 days);
    }

    // ── spend 结算 ──
    function test_SpendHappyPath() public {
        delId = _createDelegation();
        uint256 balBefore = yuan.balanceOf(payTo);

        // delegate 调用 spend（token 从 delegate 转给 payTo）
        vm.prank(delegate);
        uint256 remaining = del.spend(delId, payTo, 5 ether, "api:get-price");

        assertEq(remaining, 25 ether); // 30 - 5
        assertEq(yuan.balanceOf(payTo), balBefore + 5 ether);
        L5Delegation.Delegation memory d = del.getDelegation(delId);
        assertEq(d.spentThisPeriod, 5 ether);
        assertEq(d.requestCount, 1);
    }

    function test_SpendExceedsPerRequest() public {
        delId = _createDelegation();
        vm.prank(delegate);
        vm.expectRevert("L5D: exceeds per-request");
        del.spend(delId, payTo, 11 ether, "api:get-price");
    }

    function test_SpendExceedsPeriodCap() public {
        delId = _createDelegation();
        // 每次最多 10 (per-request)，打满 30 周期上限
        vm.prank(delegate);
        del.spend(delId, payTo, 10 ether, "api:get-price");
        vm.prank(delegate);
        del.spend(delId, payTo, 10 ether, "api:get-price");
        vm.prank(delegate);
        del.spend(delId, payTo, 10 ether, "api:get-price"); // 累计 30 == cap
        // 下一笔 10 将超出 30 周期上限
        vm.prank(delegate);
        vm.expectRevert("L5D: exceeds period cap");
        del.spend(delId, payTo, 10 ether, "api:get-price");
    }

    function test_SpendWrongPayTo() public {
        delId = _createDelegation();
        vm.prank(delegate);
        vm.expectRevert("L5D: payTo mismatch");
        del.spend(delId, address(0x9), 1 ether, "api:get-price");
    }

    function test_SpendResourceMismatch() public {
        delId = _createDelegation();
        vm.prank(delegate);
        vm.expectRevert("L5D: resource mismatch");
        del.spend(delId, payTo, 1 ether, "file:///etc/passwd");
    }

    function test_SpendNotDelegate() public {
        delId = _createDelegation();
        vm.prank(address(0x9)); // 非 delegate
        vm.expectRevert("L5D: not delegate");
        del.spend(delId, payTo, 1 ether, "api:get-price");
    }

    function test_PeriodRolloverResetsBudget() public {
        delId = _createDelegation();
        vm.prank(delegate);
        del.spend(delId, payTo, 10 ether, "api:get-price");

        vm.warp(block.timestamp + 8 days); // 越过7天周期
        vm.prank(delegate);
        uint256 remaining = del.spend(delId, payTo, 10 ether, "api:get-price");
        assertEq(remaining, 20 ether); // 新周期又满额了
    }

    // ── revoke（宪法第0条 · 人类最高权威）──
    function test_Revoke_SpendFailsThenCanRecreate() public {
        delId = _createDelegation();

        vm.prank(delegator);
        bool revoked = del.revoke(delId, "human override");
        assertTrue(revoked);

        // spend 立即失败
        vm.prank(delegate);
        vm.expectRevert("L5D: not active");
        del.spend(delId, payTo, 1 ether, "api:get-price");
    }

    function test_SuspendThenUnsuspend() public {
        delId = _createDelegation();

        vm.prank(owner);
        del.suspend(delId, "audit");
        vm.prank(delegate);
        vm.expectRevert("L5D: not active");
        del.spend(delId, payTo, 1 ether, "api:get-price");

        vm.prank(owner);
        del.unsuspend(delId);
        vm.prank(delegate);
        uint256 remaining = del.spend(delId, payTo, 1 ether, "api:get-price");
        assertEq(remaining, 29 ether);
    }

    function test_ExpiredDelegation() public {
        delId = _createDelegation();
        vm.warp(block.timestamp + 31 days); // 超过30天 validFor
        vm.prank(delegate);
        vm.expectRevert("L5D: expired");
        del.spend(delId, payTo, 1 ether, "api:get-price");
    }
}
