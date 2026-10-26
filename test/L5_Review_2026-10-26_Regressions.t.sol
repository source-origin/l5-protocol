// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "src/AgentIdentity.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";
import {CreditScore, IAgentIdentity} from "src/CreditScore.sol";
import {AgentView} from "src/L5Types.sol";

/// @dev Minimal bridge sink. Counts what it receives, does nothing else.
contract BridgeSink {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @dev A view that lies: `totalSuccessful > totalTransactions`. Used to prove the
///      consumer fails closed instead of minting credit from an inconsistent view.
contract LyingIdentity is IAgentIdentity {
    function creditView(address) external pure returns (AgentView memory v) {
        v.totalTransactions = 1;
        v.totalSuccessful = 1000;
    }

    function getAgentStatus(address) external pure returns (uint8) {
        return 1;
    }
}

/// ============================================================================
///  Regression suite for the 2026-10-26 independent review (three findings,
///  plus one found while reproducing them).
///
///  The bug-proof counterparts of these assertions were written FIRST and passed
///  against the pre-fix code (fresh agent scored 10000/10000, a stranger moved
///  another agent's contribution, a channel debit moved no value). They now
///  assert the fixed behaviour, so a regression re-opens them.
///
///  L5-01  CreditScore decoded AgentIdentity.Agent as a 12-word AgentView.
///  L5-02  recordContribution had no access control.
///  L5-02b (ours) (q*c*t)/1 ether truncates to 0 on the 0-100 scale.
///  L5-03  crossChainSettle debited a channel without moving value.
/// ============================================================================
contract L5_01_ABIMismatch_Regression is Test {
    AgentIdentity internal id;
    CreditScore internal cs;
    address internal alice = address(0xA11CE);

    function setUp() public {
        id = new AgentIdentity();
        cs = new CreditScore(address(id));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        id.registerAgent{value: 0.01 ether}("alice_trader", "Alice Trader", "quant bot", "trading", "ipfs://alice");
    }

    /// A brand-new agent has no history. It must land on the neutral baseline,
    /// nowhere near the cap.
    function test_Fixed_NewAgentDoesNotGetTopCredit() public {
        (uint256 score, uint256 limit) = cs.calculateCredit(alice);
        emit log_named_uint("fresh agent score", score);
        emit log_named_uint("fresh agent limit", limit);

        assertLt(score, cs.SCORE_MAX(), "fresh agent must not hit the cap");
        assertEq(score, 2600, "neutral baseline: 0.5 success, zero quality, base stability");
        assertEq(limit, (score * cs.creditLimitPerK()) / 1000, "limit follows the real score");
    }

    /// The projection is field-by-field: every word must match storage exactly.
    function test_Fixed_CreditViewMirrorsStorage() public {
        AgentIdentity.Agent memory a = id.getAgent(alice);
        AgentView memory v = id.creditView(alice);

        assertEq(v.totalRevenue, a.totalRevenue);
        assertEq(v.totalTransactions, a.totalTransactions);
        assertEq(v.totalSuccessful, a.totalSuccessful);
        assertEq(v.reputationScore, a.reputationScore);
        assertEq(v.stakedAmount, a.stakedAmount);
        assertEq(v.endorsementCount, a.endorsementCount);
        assertEq(v.longevityBonus, a.longevityBonus);
        assertEq(v.slashCount, a.slashCount);
        assertEq(v.contributionClockScore, a.contributionClockScore);
        assertEq(v.totalQuality, a.totalQuality);
        assertEq(v.totalComplexity, a.totalComplexity);
        assertEq(v.totalTimeliness, a.totalTimeliness);
    }

    /// A wrong projection must now fail closed, not mint credit.
    function test_Fixed_InconsistentViewReverts() public {
        CreditScore lying = new CreditScore(address(new LyingIdentity()));
        vm.expectRevert("CreditScore: inconsistent view");
        lying.calculateCredit(address(0xA));
    }
}

contract L5_02_NoAuth_Regression is Test {
    AgentIdentity internal id;
    address internal alice = address(0xA11CE);
    address internal mallory = address(0xBAD);

    function setUp() public {
        id = new AgentIdentity();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        id.registerAgent{value: 0.01 ether}("alice_trader", "Alice Trader", "quant bot", "trading", "ipfs://alice");
    }

    function test_Fixed_StrangerCannotWriteContribution() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentity.Identity_NotContributionRecorder.selector, mallory));
        id.recordContribution(alice, 90, 90, 90);
    }

    /// Recording is fail-closed before a recorder is configured at all.
    function test_Fixed_UnsetRecorderRejectsEverything() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentity.Identity_NotContributionRecorder.selector, alice));
        id.recordContribution(alice, 100, 100, 100);
    }

    /// The recorder itself still works, and the clock score now actually moves:
    /// 100/100/100 -> 1000 points, not zero.
    function test_Fixed_RecorderWritesAndClockScoreMoves() public {
        id.setContributionRecorder(address(this));

        id.recordContribution(alice, 100, 100, 100);

        AgentIdentity.Agent memory a = id.getAgent(alice);
        assertEq(a.totalQuality, 100);
        assertEq(a.contributionClockScore, 1000, "100*100*100/1000 == 1000");
    }

    function test_Fixed_ClockScoreCapsAtMax() public {
        id.setContributionRecorder(address(this));
        for (uint256 i = 0; i < 20; i++) {
            id.recordContribution(alice, 100, 100, 100);
        }
        assertEq(id.getAgent(alice).contributionClockScore, id.SCORE_MAX(), "clock score is capped");
    }

    function test_Fixed_OutOfRangeDimensionsRevert() public {
        id.setContributionRecorder(address(this));
        vm.expectRevert(abi.encodeWithSelector(AgentIdentity.Identity_ContributionOutOfRange.selector, 101));
        id.recordContribution(alice, 101, 0, 0);
    }

    function test_Fixed_OnlyOwnerSetsRecorder() public {
        vm.prank(mallory);
        vm.expectRevert();
        id.setContributionRecorder(mallory);
    }
}

contract L5_03_Stranding_Regression is Test {
    AgentAgreement internal agreement;
    AgentEscrow internal escrow;
    BridgeSink internal bridge;
    CreditScore internal cs;

    uint256 internal kSender = 0x5E4D;
    uint256 internal kReceiver = 0x2ECE1;
    address internal sender;
    address internal receiver;

    function setUp() public {
        sender = vm.addr(kSender);
        receiver = vm.addr(kReceiver);
        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
        bridge = new BridgeSink();
        vm.deal(sender, 100 ether);
    }

    function _open() internal returns (bytes32 cid) {
        vm.prank(sender);
        cid = escrow.openChannel{value: 5 ether}(receiver);
    }

    /// Fail-closed: no bridge configured, no cross-chain settlement.
    function test_Fixed_NoBridgeConfiguredReverts() public {
        bytes32 cid = _open();
        vm.prank(sender);
        vm.expectRevert("Channel: cross-chain bridge not configured");
        escrow.crossChainSettle(cid, 42161, address(0xD00D), 2 ether);
    }

    /// Value actually leaves, and it leaves to the bridge — not into a void.
    function test_Fixed_ValueMovesToBridge() public {
        escrow.setCrossChainBridge(address(bridge));
        bytes32 cid = _open();
        uint256 escrowBefore = address(escrow).balance;

        vm.prank(sender);
        escrow.crossChainSettle(cid, 42161, address(0xD00D), 2 ether);

        assertEq(address(bridge).balance, 2 ether, "bridge received the value");
        assertEq(address(escrow).balance, escrowBefore - 2 ether, "escrow balance decreased by exactly the amount");
    }

    /// The channel still settles normally afterwards: the debit is now backed by
    /// a real outflow, so the remaining balance is spendable.
    function test_Fixed_SettleChannelStillWorksAfterCrossChain() public {
        escrow.setCrossChainBridge(address(bridge));
        bytes32 cid = _open();

        vm.prank(sender);
        escrow.crossChainSettle(cid, 42161, address(0xD00D), 2 ether); // 3 ether left in the channel

        bytes32 digest = escrow.channelVoucherDigest(cid, 1, 3 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kReceiver, digest);

        vm.prank(receiver);
        escrow.settleChannel(cid, 1, 3 ether, abi.encodePacked(r, s, v));

        (,,,,,,,,,,, AgentEscrow.ChannelState st) = escrow.channels(cid);
        assertEq(uint256(st), uint256(AgentEscrow.ChannelState.Settling));
    }

    /// The receiver must not be able to push the payer's channel funds outward.
    function test_Fixed_OnlySenderCanCrossChainSettle() public {
        escrow.setCrossChainBridge(address(bridge));
        bytes32 cid = _open();

        vm.prank(receiver);
        vm.expectRevert("Channel: only sender");
        escrow.crossChainSettle(cid, 42161, address(0xD00D), 2 ether);
    }

    /// Accounting invariant: the contract's real ETH balance always covers what
    /// the channels believe they hold.
    function test_Fixed_ContractSolventAfterCrossChain() public {
        escrow.setCrossChainBridge(address(bridge));
        bytes32 cid = _open();

        vm.prank(sender);
        escrow.crossChainSettle(cid, 42161, address(0xD00D), 2 ether);

        (,,, uint256 claimed,,,,,,,,) = escrow.channels(cid);
        assertEq(address(escrow).balance, claimed, "real balance == accounted channel balance");
    }
}
