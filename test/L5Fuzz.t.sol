// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5Delegation} from "src/L5Delegation.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentIdentity} from "src/AgentIdentity.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5 fuzz-verified invariants
/// @notice Stateless fuzz assertions over the properties a reviewer cares about most:
///         spend authority never exceeds its caps, channel/escrow accounting conserves
///         value, and revocation is absolute. These complement the example-based suites
///         (L5Core/L5Delegation/...) by sweeping the whole input domain instead of a few
///         hand-picked points. No `src/` change -- purely additive.
contract L5FuzzTest is Test {
    // ── delegation fixtures ──
    L5Delegation internal del;
    MockERC20 internal yuan;
    address internal delegator = address(0x1);
    address internal delegate = address(0x2);
    address internal payTo = address(0x3);
    uint256 internal constant MAX_REQ = 10 ether;
    uint256 internal constant MAX_PERIOD = 30 ether;

    // ── escrow/channel fixtures ──
    AgentEscrow internal escrow;
    AgentAgreement internal agreement;
    AgentIdentity internal identity;
    uint256 internal constant K_ALICE = 0xA11CE;
    uint256 internal constant K_BOB = 0xB0B;
    address internal alice;
    address internal bob;
    bytes32 internal agreementId;

    function setUp() public {
        del = new L5Delegation();
        yuan = new MockERC20();
        yuan.mint(delegator, 1_000_000 ether);
        vm.prank(delegator);
        yuan.approve(address(del), type(uint256).max);

        alice = vm.addr(K_ALICE);
        bob = vm.addr(K_BOB);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        identity = new AgentIdentity();
        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
    }

    // ═════════════════ helpers ═════════════════

    function _newDelegation() internal returns (bytes32) {
        vm.prank(delegator);
        return del.createDelegation(delegate, address(yuan), payTo, "api:", MAX_REQ, MAX_PERIOD, 7 days, 30 days);
    }

    function _sign(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _executedAgreement(uint256 total) internal {
        AgentAgreement.AgentParty[] memory parties = new AgentAgreement.AgentParty[](2);
        parties[0] = AgentAgreement.AgentParty({
            agentAddr: alice, role: AgentAgreement.PartyRole.Consumer, signature: new bytes(0), signedAt: 0
        });
        parties[1] = AgentAgreement.AgentParty({
            agentAddr: bob, role: AgentAgreement.PartyRole.Provider, signature: new bytes(0), signedAt: 0
        });
        AgentAgreement.SettlementTerm[] memory terms = new AgentAgreement.SettlementTerm[](1);
        terms[0] = AgentAgreement.SettlementTerm({
            termId: bytes32(0),
            termType: AgentAgreement.TermType.Payment,
            description: "deliver",
            value: total,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });
        vm.startPrank(alice);
        agreementId = agreement.createAgreement("task-1", "deliver", parties, terms, total);
        agreement.propose(agreementId);
        vm.stopPrank();

        bytes32 h = agreement.getAgreement(agreementId).agreementHash;
        bytes memory sa = _sign(keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), h)), K_ALICE);
        bytes memory sb = _sign(keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), h)), K_BOB);
        vm.prank(alice);
        agreement.signAgreement(agreementId, sa);
        vm.prank(bob);
        agreement.signAgreement(agreementId, sb);
        require(
            uint8(agreement.getAgreement(agreementId).state) == uint8(AgentAgreement.AgreementState.Executed),
            "setup: not executed"
        );
    }

    // ═════════════════ Delegation: spend never exceeds its authority ═════════════════

    /// A spend within the per-request cap moves exactly that amount, from the delegator,
    /// and leaves the period counter exactly equal to the amount spent.
    function testFuzz_Delegation_SpendExactAccounting(uint256 a) public {
        a = bound(a, 1, MAX_REQ);
        bytes32 id = _newDelegation();

        vm.prank(delegate);
        uint256 remaining = del.spend(id, payTo, a, "api:x");

        assertEq(remaining, MAX_PERIOD - a, "remaining = cap - spent");
        L5Delegation.Delegation memory d = del.getDelegation(id);
        assertEq(d.spentThisPeriod, a, "period counter = amount");
        assertEq(d.requestCount, 1);
        assertEq(yuan.balanceOf(payTo), a, "payee received exactly a");
    }

    /// Any amount above the per-request cap is rejected -- no upper edge case slips through.
    function testFuzz_Delegation_AbovePerRequestAlwaysReverts(uint256 a) public {
        a = bound(a, MAX_REQ + 1, type(uint160).max);
        bytes32 id = _newDelegation();
        vm.prank(delegate);
        vm.expectRevert("L5D: exceeds per-request");
        del.spend(id, payTo, a, "api:x");
    }

    /// Across an arbitrary sequence of spends, cumulative spend can never exceed the
    /// period cap; each accepted spend is drawn from the delegator.
    function testFuzz_Delegation_CumulativeNeverExceedsCap(uint8 n, uint256 seed) public {
        bytes32 id = _newDelegation();
        uint256 calls = bound(uint256(n), 0, 12);
        uint256 total;

        for (uint256 i = 0; i < calls; ++i) {
            uint256 a = bound(uint256(keccak256(abi.encode(seed, i))), 1, MAX_REQ);
            if (total + a > MAX_PERIOD) {
                vm.prank(delegate);
                vm.expectRevert("L5D: exceeds period cap");
                del.spend(id, payTo, a, "api:x");
            } else {
                vm.prank(delegate);
                del.spend(id, payTo, a, "api:x");
                total += a;
            }
        }

        assertLe(total, MAX_PERIOD, "spent <= period cap");
        assertEq(del.getDelegation(id).spentThisPeriod, total, "counter matches sum");
        assertEq(yuan.balanceOf(payTo), total, "payee total = sum");
    }

    /// Once the period rolls over the budget is whole again -- for any gap past the period
    /// and still inside the delegation's validity window (period = 7d, validFor = 30d).
    function testFuzz_Delegation_PeriodRolloverResetsBudget(uint256 a, uint256 gap) public {
        a = bound(a, 1, MAX_REQ);
        gap = bound(gap, 8 days, 29 days);
        bytes32 id = _newDelegation();

        vm.prank(delegate);
        del.spend(id, payTo, a, "api:x");
        vm.warp(block.timestamp + gap);
        vm.prank(delegate);
        uint256 remaining = del.spend(id, payTo, a, "api:x");

        assertEq(remaining, MAX_PERIOD - a, "fresh period budget");
        assertEq(del.getDelegation(id).spentThisPeriod, a, "counter reset then charged");
    }

    /// Past `validUntil`, no amount is spendable -- expiry is a hard wall, not a soft cap.
    function testFuzz_Delegation_AfterExpiryAlwaysReverts(uint256 a, uint256 beyond) public {
        a = bound(a, 1, MAX_REQ);
        beyond = bound(beyond, 1 seconds, 365 days);
        bytes32 id = _newDelegation();

        vm.warp(block.timestamp + 30 days + beyond);
        vm.prank(delegate);
        vm.expectRevert("L5D: expired");
        del.spend(id, payTo, a, "api:x");
    }

    /// Revocation is absolute: no amount, at any time within validity, can be spent after it.
    function testFuzz_Delegation_RevokeBlocksAnySpend(uint256 a) public {
        a = bound(a, 1, MAX_REQ);
        bytes32 id = _newDelegation();
        vm.prank(delegator);
        del.revoke(id, "human override");
        vm.prank(delegate);
        vm.expectRevert("L5D: not active");
        del.spend(id, payTo, a, "api:x");
    }

    // ═════════════════ PaymentChannel: value is conserved exactly once ═════════════════

    /// After a channel settles and finalizes, value splits exactly: the receiver gets the
    /// vouched cumulative amount, the sender gets the remainder, and the escrow holds nothing.
    function testFuzz_Channel_FinalizeConservesValue(uint256 deposit, uint256 amount, uint256 gap) public {
        deposit = bound(deposit, 1 ether, 50 ether);
        amount = bound(amount, 0, deposit);
        gap = bound(gap, escrow.challengePeriod(), 30 days);

        vm.prank(alice);
        bytes32 cid = escrow.openChannel{value: deposit}(bob);

        bytes memory sig = _sign(escrow.channelVoucherDigest(cid, 1, amount), K_BOB);
        vm.prank(bob);
        escrow.settleChannel(cid, 1, amount, sig);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        vm.warp(block.timestamp + gap);
        escrow.finalizeSettlement(cid);

        assertEq(bob.balance, bobBefore + amount, "receiver got the voucher");
        assertEq(alice.balance, aliceBefore + (deposit - amount), "sender got the remainder");
        assertEq(address(escrow).balance, 0, "no value stranded");
    }

    /// A cumulative amount above the channel balance is impossible to settle, for any deposit.
    function testFuzz_Channel_SettleAboveBalanceReverts(uint256 deposit, uint256 amount) public {
        deposit = bound(deposit, 1 ether, 20 ether);
        amount = bound(amount, deposit + 1, deposit + 100 ether);

        vm.prank(alice);
        bytes32 cid = escrow.openChannel{value: deposit}(bob);
        bytes memory sig = _sign(escrow.channelVoucherDigest(cid, 1, amount), K_BOB);
        vm.prank(bob);
        vm.expectRevert("Channel: exceeds balance");
        escrow.settleChannel(cid, 1, amount, sig);
    }

    // ═════════════════ AgentEscrow: release pays exactly the escrowed amount ═════════════════

    function testFuzz_Escrow_ReleasePaysExactly(uint256 amount) public {
        amount = bound(amount, 1 wei, 50 ether);
        _executedAgreement(amount);

        vm.prank(alice);
        bytes32 eid = escrow.createAndFund{value: amount}(agreementId, bob, block.timestamp + 7 days);
        vm.prank(bob);
        escrow.verifyDelivery(eid, "ipfs://proof");

        bytes32 termId = agreement.getAgreement(agreementId).terms[0].termId;
        vm.prank(alice);
        agreement.completeTerm(agreementId, termId);

        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        escrow.release(eid);

        assertEq(bob.balance, bobBefore + amount, "payee received exactly the escrow");
        assertEq(address(escrow).balance, 0, "escrow drained");
    }

    /// A timeout refund always returns the full amount to the payer, for any amount.
    function testFuzz_Escrow_TimeoutRefundsInFull(uint256 amount, uint256 gap) public {
        amount = bound(amount, 1 wei, 50 ether);
        gap = bound(gap, 1, 365 days);
        _executedAgreement(amount);

        vm.prank(alice);
        bytes32 eid = escrow.createAndFund{value: amount}(agreementId, bob, block.timestamp + 1 days);

        uint256 aliceBefore = alice.balance;
        vm.warp(block.timestamp + 1 days + gap);
        vm.prank(alice);
        escrow.refund(eid);

        assertEq(alice.balance, aliceBefore + amount, "payer refunded in full");
        assertEq(address(escrow).balance, 0, "escrow drained");
    }
}
