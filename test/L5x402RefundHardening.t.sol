// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/L5x402.sol";
import "../src/L5Delegation.sol";
import "./MockERC20.t.sol";

/// @title L5x402RefundHardening
/// @notice Regression suite for the refund-path hardening (漏洞1+2 修复).
///
///   Invariant under test — "a verdict settles business, never rewrites whether value moved":
///   - settledAmount tracks ONLY value that actually moved (Pending == 0, Settled == amount).
///   - a never-moved receipt can NEVER be refunded (nothing to claw back) — it is voided instead.
///   - a refund is value reflow, NOT a verdict — it never mints terminal Final; finality stays verdict-driven.
///   - dispute does not lie: a never-moved receipt stays Open through dispute (never ProvisionalSubjectToVerdict).
///
///   H1 (design decision, upheld): a Settled receipt cannot be disputed at all ("settlement == finality"),
///   so the "claw back from a payee who received value" path is intentionally unreachable in this version.
///   settledAmount + the refund upper-bound are therefore defensive: they make the invariant hold for
///   any future path (escrow integration) that re-opens dispute on moved value.
contract L5x402RefundHardeningTest is Test {
    L5x402 x402;
    MockERC20 token;

    uint256 payerPk = 1;
    uint256 payeePk = 2;
    address payer;
    address payee;
    address admin = address(this);

    bytes32 reqId = keccak256("req-1");
    bytes32 routeHash = keccak256("route");
    bytes32 payloadHash = keccak256("payload");
    bytes32 permissionHash = keccak256("policy");

    function setUp() public {
        token = new MockERC20();
        x402 = new L5x402();
        payer = vm.addr(payerPk);
        payee = vm.addr(payeePk);
    }

    function _payerAuth(
        bytes32 _reqId,
        address _p,
        address _pay,
        address _tok,
        uint256 _amt,
        bytes32 _route,
        bytes32 _payload,
        bytes32 _perm,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = x402.actionDigest(_reqId, _p, _pay, _tok, _amt, _route, _payload, _perm, _deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Pending: no allowance -> value never moved -> settledAmount == 0.
    function _recordPending() internal returns (bytes32 rid) {
        uint256 deadline = block.timestamp + 1000;
        bytes memory auth = _payerAuth(
            reqId, payer, payee, address(token), 100 ether, routeHash, payloadHash, permissionHash, deadline
        );
        rid = x402.recordReceipt(
            reqId, payer, payee, address(token), 100 ether, routeHash, payloadHash, permissionHash, deadline, auth
        );
        assertEq(uint256(x402.getReceipt(rid).status), uint256(L5x402.ReceiptStatus.Pending));
        assertEq(x402.getReceipt(rid).settledAmount, 0);
    }

    // Settled: allowance + registered policy -> value moved -> settledAmount == amount.
    function _recordSettled(bytes32 _reqId) internal returns (bytes32 rid) {
        uint256 deadline = block.timestamp + 1000;
        bytes memory auth = _payerAuth(
            _reqId, payer, payee, address(token), 100 ether, routeHash, payloadHash, permissionHash, deadline
        );
        token.mint(payer, 100 ether);
        vm.prank(payer);
        token.approve(address(x402), 100 ether);
        x402.updateSnapshot(permissionHash, payer, 0, 200 ether, 1 days);
        rid = x402.recordReceipt(
            _reqId, payer, payee, address(token), 100 ether, routeHash, payloadHash, permissionHash, deadline, auth
        );
        assertEq(uint256(x402.getReceipt(rid).status), uint256(L5x402.ReceiptStatus.Settled));
        assertEq(x402.getReceipt(rid).settledAmount, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════
    // 漏洞 1 · 退款不能从"未收到钱"的收款人扣钱
    // ═══════════════════════════════════════════════════════════

    // T1: a never-moved receipt must not be refundable (nothing was clawed-back-able).
    function test_T1_PendingReceipt_RefundReverts() public {
        bytes32 rid = _recordPending();
        vm.prank(admin);
        x402.disputeReceipt(rid, "dispute");
        vm.prank(admin);
        vm.expectRevert("L5x402: value never moved");
        x402.refundReceipt(rid, 1 ether);
    }

    // T2: a never-moved disputed receipt is voided -> Failed, and stays Open.
    function test_T2_PendingDisputedReceipt_VoidsToFailed_StaysOpen() public {
        bytes32 rid = _recordPending();
        vm.prank(admin);
        x402.disputeReceipt(rid, "dispute");
        vm.prank(admin);
        x402.voidReceipt(rid);
        assertEq(uint256(x402.getReceipt(rid).status), uint256(L5x402.ReceiptStatus.Failed));
        assertEq(uint256(x402.getReceipt(rid).finality), uint256(L5x402.ReceiptFinality.Open));
    }

    // T3: dispute must not LIE — a never-moved receipt stays Open, never claims Provisional.
    function test_T3_Dispute_NeverMoved_StaysOpen() public {
        bytes32 rid = _recordPending();
        vm.prank(admin);
        x402.disputeReceipt(rid, "dispute");
        assertEq(uint256(x402.getReceipt(rid).status), uint256(L5x402.ReceiptStatus.Disputed));
        assertEq(uint256(x402.getReceipt(rid).finality), uint256(L5x402.ReceiptFinality.Open));
    }

    // T4: void only closes a Disputed receipt (not arbitrary states).
    function test_T4_Void_RequiresDisputed() public {
        bytes32 rid = _recordPending();
        vm.prank(admin);
        vm.expectRevert("L5x402: not disputed");
        x402.voidReceipt(rid);
    }

    // ═══════════════════════════════════════════════════════════
    // 漏洞 2 · 判决不能把"未转账"收据标 FINAL
    // ═══════════════════════════════════════════════════════════

    // T5: settledAmount is only written when value actually moved.
    function test_T5_SettledAmount_OnlyOnRealTransfer() public {
        bytes32 pending = _recordPending();
        assertEq(x402.getReceipt(pending).settledAmount, 0);
        bytes32 settled = _recordSettled(keccak256("req-settled"));
        assertEq(x402.getReceipt(settled).settledAmount, 100 ether);
    }

    // T6: H1 upheld — a Settled receipt cannot be disputed (settlement == finality).
    function test_T6_SettledReceipt_CannotBeDisputed() public {
        bytes32 rid = _recordSettled(keccak256("req-h1"));
        vm.prank(admin);
        vm.expectRevert("L5x402: already settled");
        x402.disputeReceipt(rid, "dispute");
    }

    // T7: a never-moved receipt can never be rendered Final by a post-hoc verdict.
    function test_T7_NeverMovedReceipt_CannotBeFinalized() public {
        bytes32 rid = _recordPending();
        vm.prank(admin);
        vm.expectRevert("L5x402: value not moved");
        x402.recordPostHocVerdict(rid, keccak256("verdict"), true);
    }
}
