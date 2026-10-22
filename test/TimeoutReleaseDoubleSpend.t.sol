// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "src/AgentIdentity.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";

/// @title Regression: the timeout-refund double spend, plus the dead settle()
/// @notice Found 2026-10-22 while answering NSPG13's escrow review.
///
///         D1 (critical). refund() branched on the CALLER, not on the reason.
///         A payer calling it before the deadline took the cancellation branch
///         (state -> Cancelled). Any third party calling it after the deadline
///         took the timeout branch (state -> Verified, esc.amount untouched).
///         Verified + payer is exactly release()'s precondition, so a keeper
///         triggering the timeout refund let the payer then release the escrow
///         and have the provider paid out of a DIFFERENT escrow's funds. The
///         contract became insolvent and the other consumer could not refund.
///
///         D2. settle() called this.release(); the external self-call set
///         msg.sender == address(this), so "only payer can release" could never
///         pass. settle() reverted unconditionally -- dead code, masked by the
///         fact that release() still worked.
///
///         Neither defect was reachable from the existing suite, because every
///         existing refund test is payer-initiated and therefore exercises only
///         the safe branch. That is the lesson: an untested branch is the one
///         that rots.
contract TimeoutReleaseDoubleSpendTest is Test {
    AgentIdentity public identity;
    AgentAgreement public agreement;
    AgentEscrow public escrow;

    uint256 internal kAlice = 0xA11CE;
    uint256 internal kBob = 0xB0B;
    uint256 internal kCarol = 0xCA21A;
    uint256 internal kStranger = 0x57A46E;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal stranger;

    function setUp() public {
        alice = vm.addr(kAlice);
        bob = vm.addr(kBob);
        carol = vm.addr(kCarol);
        stranger = vm.addr(kStranger);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(stranger, 1 ether);

        identity = new AgentIdentity();
        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
    }

    function _terms() internal view returns (AgentAgreement.SettlementTerm[] memory t) {
        t = new AgentAgreement.SettlementTerm[](1);
        t[0] = AgentAgreement.SettlementTerm({
            termId: bytes32(0),
            termType: AgentAgreement.TermType.Payment,
            description: "deliver dataset",
            value: 5 ether,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });
    }

    function _parties(address consumer) internal view returns (AgentAgreement.AgentParty[] memory p) {
        p = new AgentAgreement.AgentParty[](2);
        p[0] = AgentAgreement.AgentParty({
            agentAddr: consumer,
            role: AgentAgreement.PartyRole.Consumer,
            signature: new bytes(0),
            signedAt: 0
        });
        p[1] = AgentAgreement.AgentParty({
            agentAddr: bob,
            role: AgentAgreement.PartyRole.Provider,
            signature: new bytes(0),
            signedAt: 0
        });
    }

    function _sig(bytes32 hash, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _executed(address consumer, uint256 key, string memory name) internal returns (bytes32 id) {
        vm.prank(consumer);
        id = agreement.createAgreement(name, "deliverable", _parties(consumer), _terms(), 5 ether);
        vm.prank(consumer);
        agreement.propose(id);
        bytes32 h = agreement.getAgreement(id).agreementHash;
        bytes memory s1 = _sig(h, key);
        vm.prank(consumer);
        agreement.signAgreement(id, s1);
        bytes memory s2 = _sig(h, kBob);
        vm.prank(bob);
        agreement.signAgreement(id, s2);
        assertEq(uint8(agreement.getAgreement(id).state), uint8(AgentAgreement.AgreementState.Executed));
    }

    function _allTerms(bytes32 id) internal view returns (bytes32[] memory ids) {
        AgentAgreement.Agreement memory ag = agreement.getAgreement(id);
        ids = new bytes32[](ag.terms.length);
        for (uint256 i = 0; i < ag.terms.length; i++) {
            ids[i] = ag.terms[i].termId;
        }
    }

    function _fund(bytes32 id, address payer, uint256 deadline) internal returns (bytes32 eid) {
        vm.prank(payer);
        eid = escrow.createAndFund{value: 5 ether}(id, bob, deadline);
    }

    // ------------------------------------------------------------------
    // D1: a keeper-triggered timeout refund is terminal, so no second payout
    // ------------------------------------------------------------------
    function test_TimeoutRefundByStranger_CannotThenRelease() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job");
        bytes32 a2 = _executed(carol, kCarol, "carol-job");

        uint256 deadline = block.timestamp + 1 days;
        bytes32 e1 = _fund(a1, alice, deadline);
        bytes32 e2 = _fund(a2, carol, deadline);

        assertEq(address(escrow).balance, 10 ether, "two escrows funded");
        vm.warp(deadline + 1);

        // the keeper path: a non-payer triggers the timeout refund
        uint256 aliceBefore = alice.balance;
        vm.prank(stranger);
        escrow.refund(e1);
        assertEq(alice.balance, aliceBefore + 5 ether, "consumer refunded");
        assertEq(uint8(escrow.getEscrow(e1).state), uint8(AgentEscrow.EscrowState.Cancelled), "refund is terminal");

        // the payer marks the never-delivered terms complete (allowed: any party)
        // compute ids BEFORE prank: the staticcall inside _allTerms would eat it
        bytes32[] memory t1 = _allTerms(a1);
        vm.prank(alice);
        agreement.completeTerms(a1, t1);

        // the drained-release attempt must now fail on state, not on solvency
        vm.prank(alice);
        vm.expectRevert("Escrow: invalid state");
        escrow.release(e1);

        // carol's escrow is intact and she can still refund in full
        assertEq(address(escrow).balance, 5 ether, "carol's funds untouched");
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        escrow.refund(e2);
        assertEq(carol.balance, carolBefore + 5 ether, "carol made whole");
        assertEq(address(escrow).balance, 0);
    }

    // ------------------------------------------------------------------
    // D2: settle() now actually settles
    // ------------------------------------------------------------------
    function test_Settle_ReleasesToProvider() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job2");
        bytes32 e1 = _fund(a1, alice, block.timestamp + 1 days);

        // compute ids BEFORE prank: the staticcall inside _allTerms would eat it
        bytes32[] memory t1 = _allTerms(a1);
        vm.prank(alice);
        agreement.completeTerms(a1, t1);
        assertEq(uint8(agreement.getAgreement(a1).state), uint8(AgentAgreement.AgreementState.Completed));

        vm.prank(bob);
        escrow.verifyDelivery(e1, hex"deadbeef");

        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        escrow.settle(e1);

        assertEq(bob.balance, bobBefore + 5 ether, "provider paid");
        assertEq(uint8(escrow.getEscrow(e1).state), uint8(AgentEscrow.EscrowState.Released));
        assertEq(uint8(agreement.getAgreement(a1).state), uint8(AgentAgreement.AgreementState.Settled));
        assertEq(address(escrow).balance, 0);
    }

    /// @dev settle() is still payer-only: a stranger cannot drain a verified escrow
    function test_Settle_StrangerCannotSettle() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job4");
        bytes32 e1 = _fund(a1, alice, block.timestamp + 1 days);
        // compute ids BEFORE prank: the staticcall inside _allTerms would eat it
        bytes32[] memory t1 = _allTerms(a1);
        vm.prank(alice);
        agreement.completeTerms(a1, t1);
        vm.prank(bob);
        escrow.verifyDelivery(e1, hex"deadbeef");

        vm.prank(stranger);
        vm.expectRevert("Escrow: only payer can release");
        escrow.settle(e1);
    }

    // ------------------------------------------------------------------
    // controls on the refund path
    // ------------------------------------------------------------------
    function test_Control_PayerRefundLandsInCancelled() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job-c");
        bytes32 e1 = _fund(a1, alice, block.timestamp + 1 days);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        escrow.refund(e1);

        assertEq(uint8(escrow.getEscrow(e1).state), uint8(AgentEscrow.EscrowState.Cancelled));
        vm.prank(alice);
        vm.expectRevert("Escrow: invalid state");
        escrow.release(e1);
    }

    function test_Control_DoubleRefundBlocked() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job3");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 e1 = _fund(a1, alice, deadline);

        vm.warp(deadline + 1);
        vm.prank(stranger);
        escrow.refund(e1);

        vm.prank(stranger);
        vm.expectRevert("Escrow: cannot refund");
        escrow.refund(e1);
    }

    /// @dev a stranger cannot refund before the deadline; only the payer can cancel
    function test_Control_StrangerCannotRefundEarly() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job5");
        bytes32 e1 = _fund(a1, alice, block.timestamp + 7 days);

        vm.prank(stranger);
        vm.expectRevert("Escrow: cannot refund");
        escrow.refund(e1);
    }

    /// @dev once the provider has verified delivery, the payer cannot pull the
    ///      funds back: both refund branches require state Funded.
    function test_Control_VerifiedEscrowCannotRefund() public {
        bytes32 a1 = _executed(alice, kAlice, "alice-job6");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 e1 = _fund(a1, alice, deadline);

        vm.prank(bob);
        escrow.verifyDelivery(e1, hex"deadbeef");

        // past the deadline, from both possible callers
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert("Escrow: cannot refund");
        escrow.refund(e1);

        vm.prank(stranger);
        vm.expectRevert("Escrow: cannot refund");
        escrow.refund(e1);

        // the only exits are release/settle by the payer, or a dispute
        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        vm.expectRevert("Agreement: invalid state");
        escrow.release(e1);
        assertEq(bob.balance, bobBefore, "nothing moved");
        assertEq(address(escrow).balance, 5 ether, "funds still locked");
    }
}
