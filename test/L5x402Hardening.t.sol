// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5x402 hardening suite (H2 / H3 / H4)
/// @notice Regression tests for the remaining HIGH findings of the 2026-09-25
///   self-audit:
///   H2  the delegated spend cap is now enforced on-chain at settlement time, and
///       an unregistered policy grants NO authority (never an unlimited cap).
///   H3  the service evidence signature is domain-bound (chainId + verifying
///       contract + receiptId + payloadHash), so it cannot be replayed cross-receipt
///       or cross-chain.
///   H4  only an action whose value has actually moved may be rendered Final by a
///       verdict; a never-moved receipt stays Open/its own state.
contract L5x402HardeningTest is Test {
    L5x402 public x402;
    MockERC20 public yuan;

    uint256 public payerPk = 1;
    uint256 public payeePk = 2;
    address public payer;
    address public payee;

    bytes32 public policyId = keccak256("h-policy");
    bytes32 public routeHash = keccak256("POST /settle");
    bytes32 public payloadHash = keccak256("h-payload");

    function setUp() public {
        payer = vm.addr(payerPk);
        payee = vm.addr(payeePk);
        x402 = new L5x402();
        yuan = new MockERC20();
        yuan.mint(payer, 1000 ether);
        yuan.mint(payee, 1000 ether);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        vm.prank(payee);
        yuan.approve(address(x402), type(uint256).max);
    }

    function _rec(bytes32 reqId, uint256 amount) internal returns (bytes32) {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 d =
            x402.actionDigest(reqId, payer, payee, address(yuan), amount, routeHash, payloadHash, policyId, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, d);
        return x402.recordReceipt(
            reqId,
            payer,
            payee,
            address(yuan),
            amount,
            routeHash,
            payloadHash,
            policyId,
            deadline,
            abi.encodePacked(r, s, v)
        );
    }

    // ─────────────────────────────────────────────
    // H2 · on-chain spend cap enforcement
    // ─────────────────────────────────────────────

    /// An unregistered policy grants no authority: the receipt records but does
    /// NOT settle, despite an approved allowance.
    function test_H2_UnregisteredPolicy_DoesNotSettle() public {
        bytes32 rid = _rec(keccak256("h2-unreg"), 5 ether);
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Pending), "unregistered policy must not settle");
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Open), "no movement -> Open");
        assertEq(yuan.balanceOf(payee), 1000 ether, "nothing moved");
        (, uint256 spentTotal,,,,) = x402.getDelegatedSpendSnapshot(policyId);
        assertEq(spentTotal, 0, "no authority consumed");
    }

    /// A registered policy with a finite cap refuses a settle that exceeds it.
    function test_H2_ExceedsCap_DoesNotSettle() public {
        x402.updateSnapshot(policyId, payer, 0, 3 ether, 7 days);
        bytes32 rid = _rec(keccak256("h2-over"), 5 ether);
        assertEq(uint8(x402.getReceipt(rid).status), uint8(L5x402.ReceiptStatus.Pending), "over cap must not settle");
        assertEq(yuan.balanceOf(payee), 1000 ether, "nothing moved");
    }

    /// Within cap: settles and consumes the snapshot.
    function test_H2_WithinCap_Settles() public {
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        bytes32 rid = _rec(keccak256("h2-ok"), 5 ether);
        assertEq(uint8(x402.getReceipt(rid).status), uint8(L5x402.ReceiptStatus.Settled), "within cap settles");
        assertEq(yuan.balanceOf(payee), 1000 ether + 5 ether, "value moved");
        (address del, uint256 spentTotal, uint256 spentPeriod, uint256 reqCount,,) =
            x402.getDelegatedSpendSnapshot(policyId);
        assertEq(del, payer);
        assertEq(spentTotal, 5 ether);
        assertEq(spentPeriod, 5 ether);
        assertEq(reqCount, 1);
    }

    /// The cap is cumulative within a period: the second spend that would breach
    /// it does not settle.
    function test_H2_CapEnforcedCumulatively() public {
        x402.updateSnapshot(policyId, payer, 0, 6 ether, 7 days);
        bytes32 a = _rec(keccak256("h2-cum-a"), 4 ether);
        assertEq(uint8(x402.getReceipt(a).status), uint8(L5x402.ReceiptStatus.Settled), "first spend ok");

        bytes32 b = _rec(keccak256("h2-cum-b"), 4 ether);
        assertEq(uint8(x402.getReceipt(b).status), uint8(L5x402.ReceiptStatus.Pending), "second breaches cap");
        assertEq(yuan.balanceOf(payee), 1000 ether + 4 ether, "only the first spend moved");
    }

    // ─────────────────────────────────────────────
    // H3 · domain-bound evidence signature
    // ─────────────────────────────────────────────

    /// The old bare personal-sign digest is no longer accepted.
    function test_H3_PersonalSignDigest_Rejected() public {
        bytes32 rid = _rec(keccak256("h3-bare"), 1 ether);
        bytes32 legacy = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, legacy);
        assertFalse(
            x402.verifyReceiptEvidence(rid, payloadHash, abi.encodePacked(r, s, v), payee),
            "undomained personal-sign must be refused"
        );
        assertFalse(x402.getReceipt(rid).evidenceVerified);
    }

    /// A signature minted for receipt A cannot be replayed onto receipt B.
    function test_H3_CrossReceiptReplay_Rejected() public {
        bytes32 a = _rec(keccak256("h3-a"), 1 ether);
        bytes32 b = _rec(keccak256("h3-b"), 1 ether);

        bytes32 dA = x402.receiptEvidenceDigest(a, payloadHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, dA);
        bytes memory sigA = abi.encodePacked(r, s, v);

        assertTrue(x402.verifyReceiptEvidence(a, payloadHash, sigA, payee), "valid on its own receipt");
        assertFalse(x402.verifyReceiptEvidence(b, payloadHash, sigA, payee), "must not replay cross-receipt");
    }

    // ─────────────────────────────────────────────
    // H4 · verdict cannot finalize an unmoved action
    // ─────────────────────────────────────────────

    /// attachVerdict on a receipt whose value never moved must revert.
    function test_H4_AttachVerdict_UnmovedReceipt_Reverts() public {
        bytes32 rid = _rec(keccak256("h4-a"), 1 ether); // unregistered policy -> Pending (unmoved)
        assertEq(uint8(x402.getReceipt(rid).status), uint8(L5x402.ReceiptStatus.Pending));
        vm.expectRevert("L5x402: value not moved");
        x402.attachVerdict(rid, keccak256("verdict-h4"));
    }

    /// A post-hoc verdict may not render a never-moved receipt Final.
    function test_H4_PostHocFinal_UnmovedReceipt_Reverts() public {
        bytes32 rid = _rec(keccak256("h4-b"), 1 ether); // unmoved
        x402.disputeReceipt(rid, "fraud evidence");
        vm.expectRevert("L5x402: value not moved");
        x402.recordPostHocVerdict(rid, keccak256("posthoc-h4"), true);
    }

    /// markProvisional implies value moved; an Open receipt must not claim it.
    function test_H4_MarkProvisional_UnmovedReceipt_Reverts() public {
        bytes32 rid = _rec(keccak256("h4-c"), 1 ether); // unmoved -> Open
        vm.expectRevert("L5x402: value not moved");
        x402.markProvisional(rid);
    }
}
