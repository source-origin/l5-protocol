// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentAgreement} from "../src/AgentAgreementV3.sol";

// NOTE: v0.3-langgraph-injection specific tests: GraphNode + Checkpoint recoverability.
// Focus on the checkpoint machine (seq increments / auto-checkpoint / dedup / idempotent replay).
// Full escrow fund flows are covered by L5Core.t.sol (v0.2); this file validates the v0.3 delta.
contract AgentAgreementV3CheckpointTest is Test {
    AgentAgreement internal aa;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xC0A); // non-party

    bytes32 internal agreementId;

    function setUp() public {
        aa = new AgentAgreement();
        // two parties alice+bob create -> drive draft -> proposed to test auto Validate checkpoint
        AgentAgreement.AgentParty[] memory parties = new AgentAgreement.AgentParty[](2);
        parties[0] = AgentAgreement.AgentParty({
            agentAddr: alice, role: AgentAgreement.PartyRole.Provider, signature: "", signedAt: 0
        });
        parties[1] = AgentAgreement.AgentParty({
            agentAddr: bob, role: AgentAgreement.PartyRole.Consumer, signature: "", signedAt: 0
        });
        AgentAgreement.SettlementTerm[] memory terms = new AgentAgreement.SettlementTerm[](1);
        terms[0] = AgentAgreement.SettlementTerm({
            termId: bytes32(uint256(1)),
            termType: AgentAgreement.TermType.Payment,
            description: "milestone 1",
            value: 100 ether,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });
        vm.prank(alice);
        agreementId = aa.createAgreement("L5 agent deal", "checkpoint recover test", parties, terms, 100 ether);
    }

    // initial draft: checkpoint count == 0
    function test_InitialNoCheckpoint() public view {
        assertEq(aa.getCheckpointCount(agreementId), 0);
    }

    // propose -> auto record Validate checkpoint (seq=1), advance to Proposed
    function test_Propose_AutoRecordsValidateCheckpoint() public {
        vm.prank(alice);
        aa.propose(agreementId);

        assertEq(aa.getCheckpointCount(agreementId), 1, "propose should auto-record 1 checkpoint");
        (uint256 seq, uint8 node, bytes32 stateHash) = aa.getLatestCheckpoint(agreementId);
        assertEq(seq, 1, "first checkpoint seq should be 1");
        assertEq(node, uint8(AgentAgreement.GraphNode.Validate), "propose auto-records Validate node");
        assertTrue(stateHash != bytes32(0), "should record state hash");
    }

    // record distinct nodes -> seq increments; re-record same node -> HARD reject (anti-replay)
    function test_RecordCheckpoint_SeqIncrementsAndDedup() public {
        vm.prank(alice);
        aa.propose(agreementId); // seq=1 Validate

        // explicit record Execute node -> seq=2
        vm.prank(alice);
        uint256 s2 = aa.recordCheckpoint(agreementId, AgentAgreement.GraphNode.Execute);
        assertEq(s2, 2, "recordCheckpoint should return incrementing seq");

        // re-record same node -> HARD reject (no double checkpoint / anti-replay)
        vm.prank(alice);
        vm.expectRevert(bytes("Agreement: checkpoint already recorded"));
        aa.recordCheckpoint(agreementId, AgentAgreement.GraphNode.Execute);
        assertEq(aa.getCheckpointCount(agreementId), 2, "re-record rejected: total stays 2");
    }

    // replayTo idempotent: replay to already-reached/latest target -> no revert, no double-spend
    function test_ReplayTo_IsIdempotent() public {
        vm.prank(alice);
        aa.propose(agreementId); // seq=1

        vm.prank(alice);
        aa.recordCheckpoint(agreementId, AgentAgreement.GraphNode.Fund); // 2
        vm.prank(alice);
        aa.recordCheckpoint(agreementId, AgentAgreement.GraphNode.Execute); // 3

        // replay to seq=3 (latest) -> idempotent success, reached 3
        vm.prank(alice);
        uint256 reached = aa.replayTo(agreementId, 3);
        assertEq(reached, 3, "replay to latest should idempotently return 3");
        assertEq(aa.getCheckpointCount(agreementId), 3, "replay should neither revert nor add: stays 3");
    }

    // replayTo on minimal lifecycle (only auto Validate) -> to 1 idempotent
    function test_ReplayTo_EmptyLifecycleIdempotent() public {
        vm.prank(alice);
        aa.propose(agreementId); // only seq=1
        vm.prank(alice);
        uint256 reached = aa.replayTo(agreementId, 1);
        assertEq(reached, 1, "replay to 1 with only Validate checkpoint is idempotent");
    }

    // non-party cannot recordCheckpoint / replayTo (permission isolation)
    function test_NonParty_CannotRecordOrReplay() public {
        vm.prank(alice);
        aa.propose(agreementId);
        vm.prank(carol); // carol not a party: record uses its own require
        vm.expectRevert(bytes("Agreement: unauthorized checkpoint"));
        aa.recordCheckpoint(agreementId, AgentAgreement.GraphNode.Fund);

        vm.prank(carol); // replayTo carries onlyParty modifier
        vm.expectRevert(bytes("Agreement: caller is not a party"));
        aa.replayTo(agreementId, 1);
    }
}
