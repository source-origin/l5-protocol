// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5x402 fuzz-verified invariants
/// @notice Sweeps the authorization surface a reviewer scrutinizes most: a receipt can only
///         settle under the payer's own signature, over a fresh (unexpired, non-replayed)
///         digest, and always moves exactly the signed amount. Without the payer's allowance
///         it stays Pending and never claims Final. No `src/` change -- purely additive.
contract L5x402FuzzTest is Test {
    L5x402 internal x402;
    MockERC20 internal yuan;

    uint256 internal payerPk = 1;
    uint256 internal payeePk = 2;
    address internal payer;
    address internal payee;

    bytes32 internal policyId = keccak256("policy-1");
    bytes32 internal routeHash = keccak256("route");

    function setUp() public {
        payer = vm.addr(payerPk);
        payee = vm.addr(payeePk);
        x402 = new L5x402();
        yuan = new MockERC20();
        yuan.mint(payer, 1_000_000 ether);
        yuan.mint(payee, 1_000_000 ether);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        vm.prank(payee);
        yuan.approve(address(x402), type(uint256).max);
    }

    function _auth(bytes32 reqId, uint256 amount, bytes32 pHash, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 d = x402.actionDigest(reqId, payer, payee, address(yuan), amount, routeHash, pHash, policyId, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    /// A settled receipt moves exactly the signed amount payer -> payee, and is Final.
    function testFuzz_Settle_MovesExactAmount(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        bytes32 reqId = keccak256("req");
        bytes32 pHash = keccak256("payload");
        uint256 deadline = block.timestamp + 1 days;

        uint256 payerBefore = yuan.balanceOf(payer);
        uint256 payeeBefore = yuan.balanceOf(payee);
        bytes32 rid = x402.recordReceipt(
            reqId,
            payer,
            payee,
            address(yuan),
            amount,
            routeHash,
            pHash,
            policyId,
            deadline,
            _auth(reqId, amount, pHash, deadline, payerPk)
        );

        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Settled), "settled");
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Final), "final");
        assertEq(yuan.balanceOf(payer), payerBefore - amount, "payer debited exactly");
        assertEq(yuan.balanceOf(payee), payeeBefore + amount, "payee credited exactly");
    }

    /// Only the payer's own key can authorize -- any other signer is rejected.
    function testFuzz_OnlyPayerSignatureAuthorizes(uint256 badPk) public {
        badPk = bound(badPk, 3, type(uint32).max);
        vm.assume(vm.addr(badPk) != payer && vm.addr(badPk) != payee);
        bytes32 reqId = keccak256("req");
        bytes32 pHash = keccak256("payload");
        uint256 deadline = block.timestamp + 1 days;
        // Compute the signature BEFORE expectRevert: _auth makes a staticcall, which would otherwise
        // consume the pending expectRevert cheatcode.
        bytes memory sig = _auth(reqId, 5 ether, pHash, deadline, badPk);
        vm.expectRevert("L5x402: not payer-authorized");
        x402.recordReceipt(reqId, payer, payee, address(yuan), 5 ether, routeHash, pHash, policyId, deadline, sig);
    }

    /// An expired authorization can never settle. Note: under via_ir the optimizer may assume
    /// `block.timestamp` is constant within a call frame (true on a real EVM), so we derive the
    /// past deadline arithmetically from the post-warp clock rather than relying on a read taken
    /// before `vm.warp`.
    function testFuzz_ExpiredAuthAlwaysReverts(uint256 amount, uint256 past) public {
        amount = bound(amount, 1, 100 ether);
        past = bound(past, 1, 3650 days);
        vm.warp(block.timestamp + past + 1);
        uint256 deadline = block.timestamp - 1; // strictly in the past
        bytes32 reqId = keccak256("req");
        bytes32 pHash = keccak256("payload");
        bytes memory sig = _auth(reqId, amount, pHash, deadline, payerPk);
        vm.expectRevert("L5x402: authorization expired");
        x402.recordReceipt(reqId, payer, payee, address(yuan), amount, routeHash, pHash, policyId, deadline, sig);
    }

    /// A zero-amount receipt is refused outright.
    function test_ZeroAmountReverts() public {
        bytes32 reqId = keccak256("req");
        bytes32 pHash = keccak256("payload");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _auth(reqId, 0, pHash, deadline, payerPk);
        vm.expectRevert("L5x402: zero amount");
        x402.recordReceipt(reqId, payer, payee, address(yuan), 0, routeHash, pHash, policyId, deadline, sig);
    }

    /// The same authorization can never be spent twice.
    function testFuzz_AuthorizationNeverReplays(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        bytes32 reqId = keccak256("req");
        bytes32 pHash = keccak256("payload");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _auth(reqId, amount, pHash, deadline, payerPk);
        x402.recordReceipt(reqId, payer, payee, address(yuan), amount, routeHash, pHash, policyId, deadline, sig);
        vm.expectRevert("L5x402: authorization replayed");
        x402.recordReceipt(reqId, payer, payee, address(yuan), amount, routeHash, pHash, policyId, deadline, sig);
    }

    /// Without the payer's allowance the receipt stays Pending, never claims Final, moves nothing.
    function testFuzz_NoAllowance_NeverFinal_NoFundsMove(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 reqId = keccak256("req");
        bytes32 pHash = keccak256("payload");
        uint256 deadline = block.timestamp + 1 days;
        uint256 payeeBefore = yuan.balanceOf(payee);
        bytes32 rid = x402.recordReceipt(
            reqId,
            payer,
            payee,
            address(yuan),
            amount,
            routeHash,
            pHash,
            policyId,
            deadline,
            _auth(reqId, amount, pHash, deadline, payerPk)
        );
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Pending), "pending");
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Open), "open, not final");
        assertEq(yuan.balanceOf(payee), payeeBefore, "no funds moved");
    }
}
