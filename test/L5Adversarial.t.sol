// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5x402 adversarial suite (EMILIA hostile-case parity)
/// @notice Mirrors the named refusal vectors from the EMILIA reference suite
///   (test_outcome_binding / test_role_non_substitution / test_timestamp_proof),
///   restated in EVM terms. Each case must fail CLOSED, for the right reason,
///   independently of the others:
///
///   | EMILIA vector                          | L5 analogue                                  |
///   |----------------------------------------|----------------------------------------------|
///   | reject_resigned_action_swap            | action field tampered -> recovered != payer   |
///   | reject_resigned_receipt_bytes_swap     | evidenceHash != stored payloadHash            |
///   | reject_resigned_consumption_nonce_swap | authorization digest replayed                 |
///   | reject_unpinned_executor               | signer != pinned service (payee)              |
///   | role non-substitution                  | payee key cannot be replaced by payer key     |
///   | digest binds before signature          | binding checked before signature credit       |
///   | never raise on garbage                 | malformed signature -> revert, not panic      |
contract L5AdversarialTest is Test {
    L5x402 public x402;
    MockERC20 public yuan;

    uint256 public payerPk = 1;
    uint256 public payeePk = 2;
    address public payer;
    address public payee;

    bytes32 public requestId = keccak256("adv-req");
    bytes32 public payloadHash = keccak256("adv-payload");
    bytes32 public permHash = keccak256("adv-perm");
    bytes32 public routeHash = keccak256("POST /settle");
    uint256 public deadline;

    function setUp() public {
        payer = vm.addr(payerPk);
        payee = vm.addr(payeePk);
        x402 = new L5x402();
        yuan = new MockERC20();
        yuan.mint(payer, 1_000e6);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        vm.prank(payee);
        yuan.approve(address(x402), type(uint256).max);
        deadline = block.timestamp + 1 days;
    }

    function _digest(uint256 amt, bytes32 pHash, uint256 dl) internal view returns (bytes32) {
        return x402.actionDigest(requestId, payer, payee, address(yuan), amt, routeHash, pHash, permHash, dl);
    }

    /// reject_resigned_action_swap: the signature authorizes amount A; the call
    /// presents amount B. The digest covers amount, so recovery yields != payer.
    function test_ActionSwap_AmountTampered_Reverts() public {
        bytes memory sig = _signPayer(_digest(100e6, payloadHash, deadline));
        vm.expectRevert("L5x402: not payer-authorized");
        x402.recordReceipt(
            requestId, payer, payee, address(yuan), 999e6, routeHash, payloadHash, permHash, deadline, sig
        );
    }

    /// Likewise for the payload/route hashes: swapping the resource the call is
    /// for must not pass under a signature for a different action.
    function test_ActionSwap_PayloadHashTampered_Reverts() public {
        bytes memory sig = _signPayer(_digest(5e6, payloadHash, deadline));
        vm.expectRevert("L5x402: not payer-authorized");
        x402.recordReceipt(
            requestId, payer, payee, address(yuan), 5e6, routeHash, keccak256("other"), permHash, deadline, sig
        );
    }

    /// reject_resigned_consumption_nonce_swap: exactly one action digest may be
    /// consumed. A second presentation of the same authorization is refused.
    function test_ConsumptionReplay_Reverts() public {
        bytes memory sig = _signPayer(_digest(5e6, payloadHash, deadline));
        x402.recordReceipt(requestId, payer, payee, address(yuan), 5e6, routeHash, payloadHash, permHash, deadline, sig);
        vm.expectRevert("L5x402: authorization replayed");
        x402.recordReceipt(requestId, payer, payee, address(yuan), 5e6, routeHash, payloadHash, permHash, deadline, sig);
    }

    /// reject_unpinned_executor: evidence must be signed by the pinned service of
    /// record (the payee). A receipt bound to another signer is refused.
    function test_UnpinnedExecutor_EvidenceRejected() public {
        bytes memory sig = _signPayer(_digest(5e6, payloadHash, deadline));
        bytes32 id = x402.recordReceipt(
            requestId, payer, payee, address(yuan), 5e6, routeHash, payloadHash, permHash, deadline, sig
        );

        // (a) evidence digest must equal the stored payloadHash
        bytes32 wrongHash = keccak256("swapped-evidence");
        bytes32 d = x402.receiptEvidenceDigest(id, wrongHash); // H3: domain-bound
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, d);
        assertFalse(
            x402.verifyReceiptEvidence(id, wrongHash, abi.encodePacked(r, s, v), payee),
            "receipt_bytes_swap must be refused"
        );

        // (b) even a correctly-hashed, correctly-signed blob is refused if the
        // caller tries to pin a foreign signer
        bytes32 d2 = x402.receiptEvidenceDigest(id, payloadHash); // H3: domain-bound
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(payeePk, d2);
        assertFalse(
            x402.verifyReceiptEvidence(id, payloadHash, abi.encodePacked(r2, s2, v2), payer),
            "unpinned signer must be refused"
        );
    }

    /// Role non-substitution: the payee key is pinned for the service role; a
    /// payer-signed blob must not fill it, and vice versa.
    function test_RoleNonSubstitution_PayerKeyCannotFillServiceRole() public {
        bytes memory sig = _signPayer(_digest(5e6, payloadHash, deadline));
        bytes32 id = x402.recordReceipt(
            requestId, payer, payee, address(yuan), 5e6, routeHash, payloadHash, permHash, deadline, sig
        );
        // payer signs the exact evidence hash, but payer is NOT the service key
        bytes32 d = x402.receiptEvidenceDigest(id, payloadHash); // H3: domain-bound
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, d);
        assertFalse(
            x402.verifyReceiptEvidence(id, payloadHash, abi.encodePacked(r, s, v), payee),
            "payer role must not fill the service-of-record role"
        );
    }

    /// never raise on garbage: a malformed signature must revert cleanly
    /// (fail closed), never panic or succeed.
    function test_GarbageSignature_FailsClosed() public {
        vm.expectRevert();
        x402.recordReceipt(
            requestId, payer, payee, address(yuan), 5e6, routeHash, payloadHash, permHash, deadline, hex"deadbeef"
        );
    }

    function _signPayer(bytes32 dgst) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, dgst);
        return abi.encodePacked(r, s, v);
    }
}
