// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";

/// @title Regression: VULN-A2A-0001 and the three defects the red-team exercise found
/// @notice Found 2026-11-10 by redteam_demo.py (a blue-team exercise that does NOT
///         follow the happy path). Four defects, one shared root cause:
///         **the contract never compared what it owed against what it held.**
///
///         A2 (VULN-A2A-0001, high). dispute() recorded `esc.disputeBond = msg.value`
///         but refunded the excess in the same call, keeping only `requiredBond`.
///         The ledger then claimed more than the vault received. resolveDispute()
///         pays out `amount + disputeBond`, so it reverted for insufficient balance
///         -- forever. Both exits from Disputed were dead: the money could not be
///         recovered by ANYONE, including the innocent party.
///         The realistic trigger is not malice: an agent that rounds up, or that
///         reads `channelDisputeBond` (0.05 ether) as the amount to send, locks
///         its own escrow out of arbitration.
///
///         B1 (medium). verifyDelivery accepted empty bytes. "I delivered" and
///         "I proved delivery" were indistinguishable on chain.
///
///         D1 (medium). After delivery the escrow is Verified. refund()'s timeout
///         branch only accepts Funded, and release()/settle() are payer-only. So a
///         payee whose payer went offline had exactly one exit: pay a dispute bond
///         and wait for a single owner signature. In an agent-to-agent economy that
///         makes a human the single point of failure for machine-to-machine trade.
///
///         G2 (informational, but the most important one). AgentEscrow holds all
///         escrows in one `address(this).balance`, with no per-escrow accounting.
///         So a "ledger > actual" bug is silently covered by OTHER escrows' money.
///         Measured: the exact same overpayment that locks a clean vault resolved
///         successfully on a vault that already held stuck funds. One bug gets
///         underwritten by the next user's deposit, and no assertion fires.
///         Fix: `totalHeld` + a `solvent()` guard on every payout.
///
///         The lesson that outlives these four tests: a single-escrow test can
///         never see G2. Balance-bearing contracts must be exercised twice --
///         once on a clean vault, once on a vault that already holds funds.
contract AgentEscrowRedTeamTest is Test {
    AgentAgreement public agreement;
    AgentEscrow public escrow;

    uint256 internal kAlice = 0xA11CE;
    uint256 internal kBob = 0xB0B;
    uint256 internal kStranger = 0x57A46E;

    address internal alice;
    address internal bob;
    address internal stranger;

    uint256 internal constant PRICE = 2 * 10 ** 15; // 0.002 ETH

    function setUp() public {
        alice = vm.addr(kAlice);
        bob = vm.addr(kBob);
        stranger = vm.addr(kStranger);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(stranger, 100 ether);

        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
    }

    // ---------------------------------------------------------------- helpers

    function _parties(address consumer) internal view returns (AgentAgreement.AgentParty[] memory p) {
        p = new AgentAgreement.AgentParty[](2);
        p[0] = AgentAgreement.AgentParty({
            agentAddr: consumer, role: AgentAgreement.PartyRole.Consumer, signature: new bytes(0), signedAt: 0
        });
        p[1] = AgentAgreement.AgentParty({
            agentAddr: bob, role: AgentAgreement.PartyRole.Provider, signature: new bytes(0), signedAt: 0
        });
    }

    function _terms() internal view returns (AgentAgreement.SettlementTerm[] memory t) {
        t = new AgentAgreement.SettlementTerm[](2);
        t[0] = AgentAgreement.SettlementTerm({
            termId: bytes32(0),
            termType: AgentAgreement.TermType.Deliverable,
            description: "submit report",
            value: 0,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });
        t[1] = AgentAgreement.SettlementTerm({
            termId: bytes32(0),
            termType: AgentAgreement.TermType.Payment,
            description: "pay for report",
            value: PRICE,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });
    }

    function _sig(bytes32 hash, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev create -> propose -> both signatures -> Executed
    function _executed(string memory name) internal returns (bytes32 id) {
        vm.prank(alice);
        id = agreement.createAgreement(name, "deliverable", _parties(alice), _terms(), PRICE);
        vm.prank(alice);
        agreement.propose(id);
        bytes32 h = agreement.getAgreement(id).agreementHash;
        // NOTE: build the signature BEFORE vm.prank. _sig() staticcalls
        // domainSeparator(), and that staticcall would consume the prank,
        // making signAgreement run as the test contract ("not a party").
        bytes memory s1 = _sig(h, kAlice);
        vm.prank(alice);
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

    /// @dev Drives an agreement all the way to Verified, on a given vault.
    function _verifiedOn(AgentEscrow vault, string memory name) internal returns (bytes32 eid) {
        bytes32 id = _executed(name);
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(alice);
        eid = vault.createAndFund{value: PRICE}(id, bob, deadline);
        vm.prank(bob);
        vault.verifyDelivery(eid, bytes("sha256:report"));
    }

    function _verified(string memory name) internal returns (bytes32 eid) {
        return _verifiedOn(escrow, name);
    }

    /// @dev Pushes every agreement term to Completed so markSettled() can pass.
    function _completeTerms(bytes32 id) internal {
        bytes32[] memory ids = _allTerms(id);
        vm.prank(bob);
        agreement.completeTerms(id, ids);
    }

    function _bondOf(bytes32 eid) internal view returns (uint256) {
        return escrow.requiredDisputeBond(eid);
    }

    // ---------------------------------------------------------------- A2

    /// @notice The reported vulnerability. Overpaying the bond by 1 wei used to
    ///         strand the escrow in Disputed with no exit. It must now resolve,
    ///         and the excess must be returned rather than recorded.
    function test_A2_OverpaidBond_StillResolves_AndExcessIsRefunded() public {
        bytes32 eid = _verified("a2-over");
        bytes32 aid = escrow.getEscrow(eid).agreementId;
        _completeTerms(aid);

        uint256 bond = _bondOf(eid);
        uint256 vaultBefore = address(escrow).balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        escrow.dispute{value: bond + 1}(eid);

        // Ledger must equal what the vault actually kept -- not msg.value.
        assertEq(escrow.getEscrow(eid).disputeBond, bond, "ledger must equal funds held");
        assertEq(address(escrow).balance - vaultBefore, bond, "vault must keep exactly the bond");
        assertEq(escrow.totalHeld(), PRICE + bond, "totalHeld must track the kept bond");

        // The single overpaid wei must be refunded: compare against the balance
        // captured before the call, so gas accounting cannot poison the check.
        assertEq(bobBefore - bob.balance, bond + 1 - 1, "excess wei must come back");

        uint256 payeeBefore = bob.balance;
        escrow.resolveDispute(eid, true);
        assertEq(bob.balance - payeeBefore, PRICE + bond, "payee gets price + bond");
        assertEq(address(escrow).balance, 0, "vault fully drained");
        assertEq(escrow.totalHeld(), 0, "ledger fully drained");
    }

    /// @notice Precise bond is the control case: it always worked, and must keep
    ///         working. A fix that only makes the odd case pass is not a fix.
    function test_A2_ExactBond_ControlCase() public {
        bytes32 eid = _verified("a2-exact");
        _completeTerms(escrow.getEscrow(eid).agreementId);
        uint256 bond = _bondOf(eid);
        vm.prank(bob);
        escrow.dispute{value: bond}(eid);
        uint256 before = bob.balance;
        escrow.resolveDispute(eid, true);
        assertEq(bob.balance - before, PRICE + bond);
    }

    /// @notice Underpaying is still refused, and refusing must not move money.
    function test_A2_UnderpaidBond_Reverts() public {
        bytes32 eid = _verified("a2-under");
        uint256 bond = _bondOf(eid);
        vm.prank(bob);
        vm.expectRevert(bytes("Escrow: insufficient dispute bond"));
        escrow.dispute{value: bond - 1}(eid);
        assertEq(uint8(escrow.getEscrow(eid).state), uint8(AgentEscrow.EscrowState.Verified));
    }

    // ---------------------------------------------------------------- B1

    function test_B1_EmptyProof_Reverts() public {
        bytes32 id = _executed("b1-empty");
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(alice);
        bytes32 eid = escrow.createAndFund{value: PRICE}(id, bob, deadline);

        vm.prank(bob);
        vm.expectRevert(bytes("Escrow: empty proof"));
        escrow.verifyDelivery(eid, bytes(""));

        assertEq(uint8(escrow.getEscrow(eid).state), uint8(AgentEscrow.EscrowState.Funded));
    }

    /// @notice Positive control: a non-empty proof still works. A gate that
    ///         rejects everything would also pass test_B1_EmptyProof_Reverts.
    function test_B1_NonEmptyProof_StillVerifies() public {
        bytes32 eid = _verified("b1-ok");
        assertEq(uint8(escrow.getEscrow(eid).state), uint8(AgentEscrow.EscrowState.Verified));
    }

    // ---------------------------------------------------------------- D1

    /// @notice The payee must be able to collect without the payer and without
    ///         the owner, once the objective conditions are met.
    function test_D1_PayeeClaimsAfterDeadline_WithoutOwner() public {
        bytes32 id = _executed("d1-dead-buyer");
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(alice);
        bytes32 eid = escrow.createAndFund{value: PRICE}(id, bob, deadline);

        vm.prank(bob);
        escrow.verifyDelivery(eid, bytes("sha256:delivered"));
        _completeTerms(id); // payee is a party, so it can advance its own terms

        // Still inside the grace period: must be refused.
        vm.warp(deadline + 1);
        vm.prank(bob);
        vm.expectRevert(bytes("Escrow: grace not over"));
        escrow.claimAfterDeadline(eid);

        // Past the grace period: collectable, no bond, no owner signature.
        vm.warp(deadline + escrow.claimGracePeriod() + 1);
        uint256 before = bob.balance;
        vm.prank(bob);
        escrow.claimAfterDeadline(eid);
        assertEq(bob.balance - before, PRICE, "payee collects the full amount");
        assertEq(uint8(escrow.getEscrow(eid).state), uint8(AgentEscrow.EscrowState.Released));
        assertEq(address(escrow).balance, 0);
    }

    /// @notice Only the payee may claim, and only from Verified. Otherwise the
    ///         new exit becomes a general-purpose drain.
    function test_D1_ClaimAfterDeadline_AccessControl() public {
        bytes32 id = _executed("d1-acl");
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(alice);
        bytes32 eid = escrow.createAndFund{value: PRICE}(id, bob, deadline);
        vm.prank(bob);
        escrow.verifyDelivery(eid, bytes("sha256:delivered"));
        _completeTerms(id);
        vm.warp(deadline + escrow.claimGracePeriod() + 1);

        vm.prank(stranger);
        vm.expectRevert(bytes("Escrow: only payee can claim"));
        escrow.claimAfterDeadline(eid);

        // A payer that never delivered must not have this exit either.
        // Fresh deadline: block.timestamp already moved past the one above.
        bytes32 id2 = _executed("d1-notdelivered");
        // NOTE: use the cheatcode getter, not `block.timestamp + 1 hours`.
        // The optimizer CSEs repeated `block.timestamp + <const>` expressions
        // (it assumes time cannot move inside one tx), so after vm.warp a second
        // identical expression still yields the OLD value. That cost me a red test.
        uint256 deadline2 = vm.getBlockTimestamp() + 1 hours;
        vm.prank(alice);
        bytes32 eid2 = escrow.createAndFund{value: PRICE}(id2, bob, deadline2);
        vm.warp(deadline2 + escrow.claimGracePeriod() + 1);
        vm.prank(bob);
        vm.expectRevert(bytes("Escrow: invalid state")); // still Funded, not Verified
        escrow.claimAfterDeadline(eid2);
    }

    // ---------------------------------------------------------------- G2

    /// @notice The heart of the exercise. Identical inputs, two vaults:
    ///         a clean one and one that already holds a stranger's escrow.
    ///         Before the fix these disagreed -- the dirty vault passed only
    ///         because the shortfall was paid out of someone else's deposit.
    function test_G2_LedgerMatchesBalance_OnDirtyVault() public {
        // Dirty vault: an unrelated escrow is already sitting in it.
        _verified("g2-float");

        bytes32 eid = _verified("g2-main");
        bytes32 aid = escrow.getEscrow(eid).agreementId;
        _completeTerms(aid);

        uint256 bond = _bondOf(eid);
        vm.prank(bob);
        escrow.dispute{value: bond + 1}(eid);
        escrow.resolveDispute(eid, true);

        // Nothing may be left over on account of this escrow, and the ledger
        // must still describe the vault exactly.
        assertEq(address(escrow).balance, escrow.totalHeld(), "balance must equal totalHeld");

        // The unrelated escrow is still fully funded -- it was never used as
        // a buffer. This is the assertion that would have caught the original bug.
        bytes32[] memory ids = escrow.getAgentEscrows(alice);
        uint256 outstanding;
        for (uint256 i = 0; i < ids.length; i++) {
            AgentEscrow.Escrow memory e = escrow.getEscrow(ids[i]);
            if (
                e.state == AgentEscrow.EscrowState.Funded || e.state == AgentEscrow.EscrowState.Verified
                    || e.state == AgentEscrow.EscrowState.Disputed
            ) {
                outstanding += e.amount + e.disputeBond;
            }
        }
        assertEq(outstanding, escrow.totalHeld(), "totalHeld must equal outstanding obligations");
        assertGe(address(escrow).balance, outstanding, "vault must cover every obligation");
    }

    /// @notice The guard itself. If the ledger ever exceeds the balance, payout
    ///         paths must hard-revert instead of quietly paying with other
    ///         escrows' funds. Simulated by forcing the contract's balance down.
    function test_G2_UndercollateralizedVault_Reverts() public {
        bytes32 eid = _verified("g2-short");
        _completeTerms(escrow.getEscrow(eid).agreementId);

        // Burn the vault's balance out from under the ledger.
        vm.deal(address(escrow), 0);

        vm.prank(alice);
        vm.expectRevert(bytes("Escrow: vault undercollateralized"));
        escrow.release(eid);
    }

    /// @notice Same guard, arbitration path. Each payout function carries its own
    ///         `solvent()`, so each needs its own proof -- otherwise a guard can be
    ///         removed from one entry point and nothing goes red.
    function test_G2_UndercollateralizedVault_ResolveDisputeReverts() public {
        bytes32 eid = _verified("g2-short-dispute");
        _completeTerms(escrow.getEscrow(eid).agreementId);
        uint256 bond = _bondOf(eid);
        vm.prank(bob);
        escrow.dispute{value: bond}(eid);

        vm.deal(address(escrow), 0);

        vm.expectRevert(bytes("Escrow: vault undercollateralized"));
        escrow.resolveDispute(eid, true);
    }

    /// @notice Invariant: no sequence of normal operations may leave the vault
    ///         holding less than it owes.
    function testFuzz_G2_BalanceNeverBelowLedger(uint96 amount) public {
        amount = uint96(bound(amount, 1, 10 ether));
        vm.deal(alice, uint256(amount) * 4 + 10 ether);

        bytes32 id = _executed("g2-fuzz");
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(alice);
        bytes32 eid = escrow.createAndFund{value: amount}(id, bob, deadline);

        assertEq(escrow.totalHeld(), amount);
        assertEq(address(escrow).balance, amount);

        vm.prank(bob);
        escrow.verifyDelivery(eid, bytes("sha256:fuzz"));
        _completeTerms(id);

        vm.prank(alice);
        escrow.release(eid);

        assertEq(escrow.totalHeld(), 0, "ledger cleared");
        assertEq(address(escrow).balance, 0, "vault cleared");
    }
}
