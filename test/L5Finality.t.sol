// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5x402 finality / Boundary rule tests
/// @notice Covers the three release paths of the three-stage chain
///   action_ref -> release receipt -> verdict, and the reference direction:
///   the artifact that arrives later holds the backward reference.
contract L5FinalityTest is Test {
    L5x402 public x402;
    MockERC20 public yuan;

    address public payer = address(0x1);
    address public payee = address(0x2);

    bytes32 public requestId = keccak256("req-1");
    bytes32 public payloadHash = keccak256("payload-1");
    bytes32 public permHash = keccak256("perm-1");
    bytes32 public routeHash = keccak256("POST /settle");

    function setUp() public {
        x402 = new L5x402();
        yuan = new MockERC20();
        yuan.mint(payer, 1_000e6);
        yuan.mint(payee, 1_000e6);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        // payee may need to fund a refund after an adjudicated dispute
        vm.prank(payee);
        yuan.approve(address(x402), type(uint256).max);
    }

    function _record(uint256 amt) internal returns (bytes32 id) {
        id = x402.recordReceipt(requestId, payer, payee, address(yuan), amt, routeHash, payloadHash, permHash);
    }

    /// Auto path: no external verdict exists -> the receipt is terminal.
    function test_AutoPath_ReceiptIsFinal_NoVerdictRef() public {
        bytes32 id = _record(100e6);
        L5x402.PaymentReceipt memory r = x402.getReceipt(id);
        assertEq(uint256(r.status), uint256(L5x402.ReceiptStatus.Settled), "should settle");
        assertEq(uint256(r.finality), uint256(L5x402.ReceiptFinality.Final), "auto path is terminal");
        assertEq(r.verdictRef, bytes32(0), "no verdict to cite");
    }

    /// Adjudicated path: verdict minted first; the receipt (later) cites it.
    function test_Adjudicated_ReceiptCitesVerdict() public {
        bytes32 id = _record(100e6);
        bytes32 v = keccak256("verdict-digest-1");

        // a receipt minted first must not embed a forward "slot to be filled later"
        assertEq(x402.getReceipt(id).verdictRef, bytes32(0), "no forward slot at mint time");

        x402.attachVerdict(id, v);
        L5x402.PaymentReceipt memory r = x402.getReceipt(id);
        assertEq(r.verdictRef, v, "receipt holds backward reference to verdict");
        assertEq(uint256(r.finality), uint256(L5x402.ReceiptFinality.Final), "adjudicated -> final");

        // cannot attach twice (no rebinding of the backward reference)
        vm.expectRevert(bytes("L5x402: verdict already set"));
        x402.attachVerdict(id, keccak256("other"));
    }

    /// Post-release dispute: receipt declares provisional and stops;
    /// the post-hoc verdict back-references the receipt.
    function test_PostHoc_ReceiptProvisional_ThenVerdictCitesReceipt() public {
        bytes32 id = _record(100e6);

        x402.markProvisional(id);
        assertEq(
            uint256(x402.getReceipt(id).finality),
            uint256(L5x402.ReceiptFinality.ProvisionalSubjectToVerdict),
            "receipt must not claim finality it lacks"
        );

        bytes32 v = keccak256("post-hoc-verdict");
        x402.recordPostHocVerdict(id, v, true);

        (bytes32 vId, bytes32 vReceiptRef, bool vIsFinal,) = x402.verdicts(v);
        assertEq(vId, v, "verdict id");
        assertEq(vReceiptRef, id, "later verdict holds backward reference");
        assertTrue(vIsFinal, "verdict says final");
        assertEq(x402.verdictOfReceipt(id), v, "receipt -> its post-hoc verdict");
        assertEq(
            uint256(x402.getReceipt(id).finality),
            uint256(L5x402.ReceiptFinality.Final),
            "verdict flips finality"
        );

        // duplicate verdict rejected
        vm.expectRevert(bytes("L5x402: duplicate verdict"));
        x402.recordPostHocVerdict(id, v, true);
    }

    /// Ordering guard: provisional marker cannot be re-applied.
    function test_MarkProvisional_Twice_Reverts() public {
        bytes32 id = _record(100e6);
        x402.markProvisional(id);
        vm.expectRevert(bytes("L5x402: already provisional"));
        x402.markProvisional(id);
    }

    /// Builds a Pending receipt (no allowance) -- the only state a dispute can
    /// enter, since a Settled release is terminal by design.
    function _pending(bytes32 reqId, uint256 amt) internal returns (bytes32 id) {
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        id = x402.recordReceipt(reqId, payer, payee, address(yuan), amt, routeHash, payloadHash, permHash);
    }

    /// Review point (internet-court-skill#1): a receipt cannot be both Disputed
    /// and Final. Entering dispute moves it into the third state explicitly,
    /// rather than leaving a final claim standing over an open dispute window.
    function test_Disputed_ReceiptIsNotFinal() public {
        bytes32 id = _pending(keccak256("d1"), 100e6);
        assertEq(uint256(x402.getReceipt(id).status), uint256(L5x402.ReceiptStatus.Pending), "pending");
        assertEq(
            uint256(x402.getReceipt(id).finality),
            uint256(L5x402.ReceiptFinality.Final),
            "mint default is terminal"
        );

        x402.disputeReceipt(id, "post-release dispute");
        L5x402.PaymentReceipt memory r = x402.getReceipt(id);
        assertEq(uint256(r.status), uint256(L5x402.ReceiptStatus.Disputed), "disputed");
        assertEq(
            uint256(r.finality),
            uint256(L5x402.ReceiptFinality.ProvisionalSubjectToVerdict),
            "disputed must not keep claiming Final"
        );
    }

    /// The adjudicated refund reaches Final: finality is earned at the verdict,
    /// not asserted at mint.
    function test_Refund_ReachesFinal() public {
        bytes32 id = _pending(keccak256("d2"), 100e6);
        x402.disputeReceipt(id, "dispute");
        x402.refundReceipt(id, 40e6);
        L5x402.PaymentReceipt memory r = x402.getReceipt(id);
        assertEq(uint256(r.status), uint256(L5x402.ReceiptStatus.Refunded), "refunded");
        assertEq(uint256(r.finality), uint256(L5x402.ReceiptFinality.Final), "verdict -> final");
    }
}
