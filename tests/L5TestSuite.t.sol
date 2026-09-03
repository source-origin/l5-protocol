// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentAgreement} from "../src/AgentAgreement.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";

/// @title L5TestSuite —— ORIGIN L5 三合约完整测试套件
/// @notice 覆盖核心路径 + 边界条件 + 攻击向量
contract L5TestSuite is Test {
    AgentIdentity public identity;
    AgentAgreement public agreement;
    AgentEscrow public escrow;

    // 测试账号
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public mallory = address(0x99);

    bytes32 public aliceId;
    bytes32 public bobId;
    bytes32 public carolId;

    receive() external payable {}

    function setUp() public {
        // 部署合约
        identity = new AgentIdentity();
        agreement = new AgentAgreement(address(identity));
        escrow = new AgentEscrow(address(agreement));

        // 注册三个Agent
        vm.startPrank(alice);
        aliceId = identity.registerAgent(
            AgentIdentity.AgentRegistration({
                name: ""Alice Trader"",
                handle: ""alice"",
                entityType: AgentIdentity.EntityType.Individual,
                services: [""trading""],
                agentURI: ""ipfs://alice-metadata"",
                serviceEndpoints: [AgentIdentity.ServiceEndpoint({protocol:""a2a"", url:""https://alice.example.com""})]
            })
        );
        vm.stopPrank();

        vm.startPrank(bob);
        bobId = identity.registerAgent(
            AgentIdentity.AgentRegistration({
                name: ""Bob Auditor"",
                handle: ""bob"",
                entityType: AgentIdentity.EntityType.Individual,
                services: [""audit""],
                agentURI: ""ipfs://bob-metadata"",
                serviceEndpoints: [AgentIdentity.ServiceEndpoint({protocol:""a2a"", url:""https://bob.example.com""})]
            })
        );
        vm.stopPrank();

        vm.startPrank(carol);
        carolId = identity.registerAgent(
            AgentIdentity.AgentRegistration({
                name: ""Carol Arbiter"",
                handle: ""carol"",
                entityType: AgentIdentity.EntityType.Individual,
                services: [""arbitration""],
                agentURI: ""ipfs://carol-metadata"",
                serviceEndpoints: [AgentIdentity.ServiceEndpoint({protocol:""a2a"", url:""https://carol.example.com""})]
            })
        );
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════
    // AGENT IDENTITY TESTS
    // ══════════════════════════════════════════════

    function test_AgentRegistration() public {
        assertEq(identity.balanceOf(alice), 1);
        assertTrue(identity.isAgent(aliceId));
        assertEq(identity.handleOf(aliceId), ""alice"");
    }

    function test_AgentRegistration_DuplicateHandle() public {
        vm.startPrank(bob);
        vm.expectRevert(""Identity: handle taken"");
        identity.registerAgent(
            AgentIdentity.AgentRegistration({
                name: ""Bob2"",
                handle: ""alice"",
                entityType: AgentIdentity.EntityType.Individual,
                services: [""mining""],
                agentURI: """",
                serviceEndpoints: new AgentIdentity.ServiceEndpoint[](0)
            })
        );
        vm.stopPrank();
    }

    function test_AgentGlobalId() public {
        string memory gid = identity.getGlobalId(aliceId);
        assertTrue(bytes(gid).length > 0);
    }

    function test_RecordContribution() public {
        vm.startPrank(address(this));
        identity.recordContribution(alice, 800, 600, 900, 1 ether);
        vm.stopPrank();

        uint256 score = identity.reputationScore(alice);
        assertGt(score, 0);
    }

    function test_ReputationDecay() public {
        // Record a contribution
        vm.prank(address(this));
        identity.recordContribution(alice, 800, 600, 900, 1 ether);
        uint256 scoreBefore = identity.reputationScore(alice);

        // Fast forward 60 days
        vm.warp(block.timestamp + 60 days);
        uint256 scoreAfter = identity.reputationScore(alice);
        
        assertLt(scoreAfter, scoreBefore);
    }

    function test_SlashAgent() public {
        // Give alice some reputation first
        vm.prank(address(this));
        identity.recordContribution(alice, 800, 600, 900, 1 ether);

        uint256 before = identity.reputationScore(alice);
        identity.slashAgent(aliceId, 500);
        uint256 after_ = identity.reputationScore(alice);
        assertLt(after_, before);
    }

    // ══════════════════════════════════════════════
    // AGENT AGREEMENT TESTS
    // ══════════════════════════════════════════════

    function test_CreateAgreement() public {
        bytes32[] memory signers = new bytes32[](2);
        signers[0] = aliceId;
        signers[1] = bobId;

        AgentAgreement.Term[] memory terms = new AgentAgreement.Term[](2);
        terms[0] = AgentAgreement.Term({key: ""payment"", value: ""1 ether""});
        terms[1] = AgentAgreement.Term({key: ""deliverable"", value: ""audit report""});

        vm.prank(alice);
        bytes32 agreementId = agreement.createAgreement(signers, carolId, 7 days, terms);

        assertEq(uint256(agreement.getState(agreementId)), uint256(AgentAgreement.AgreementState.Draft));
    }

    function test_SignAgreement_MultiSig() public {
        // Alice creates agreement with requiredSignatures=2
        bytes32[] memory signers = new bytes32[](2);
        signers[0] = aliceId;
        signers[1] = bobId;

        AgentAgreement.Term[] memory terms = new AgentAgreement.Term[](1);
        terms[0] = AgentAgreement.Term({key: ""price"", value: ""5 ether""});

        vm.prank(alice);
        bytes32 agreementId = agreement.createAgreement(signers, carolId, 7 days, terms);

        // Alice signs (EIP-712)
        uint256 chainId = block.chainid;
        bytes32 domainSep = agreement.domainSeparator();
        bytes32 typeHash = keccak256(""Agreement(bytes32 agreementId,address signer,uint256 timestamp)"");
        bytes32 structHash = keccak256(abi.encode(typeHash, agreementId, alice, block.timestamp));
        bytes32 digest = keccak256(abi.encodePacked(""\x19\x01"", domainSep, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        agreement.signAgreement(agreementId, sig);

        // Bob signs
        bytes32 structHash2 = keccak256(abi.encode(typeHash, agreementId, bob, block.timestamp));
        bytes32 digest2 = keccak256(abi.encodePacked(""\x19\x01"", domainSep, structHash2));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, digest2);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);

        vm.prank(bob);
        agreement.signAgreement(agreementId, sig2);

        assertEq(uint256(agreement.getState(agreementId)), uint256(AgentAgreement.AgreementState.Signed));
    }

    function test_AgreementCancel_Draft() public {
        bytes32[] memory signers = new bytes32[](1);
        signers[0] = aliceId;

        AgentAgreement.Term[] memory terms = new AgentAgreement.Term[](0);
        vm.prank(alice);
        bytes32 agreementId = agreement.createAgreement(signers, carolId, 7 days, terms);

        vm.prank(alice);
        agreement.cancelAgreement(agreementId);

        assertEq(uint256(agreement.getState(agreementId)), uint256(AgentAgreement.AgreementState.Cancelled));
    }

    // ══════════════════════════════════════════════
    // AGENT ESCROW TESTS
    // ══════════════════════════════════════════════

    function test_CreateAndFund() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bytes32 agreementId, bytes32 escrowId) = escrow.createAndFund{value: 1 ether}(
            bob, 7 days, ""ipfs://deliverables""
        );

        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.amount, 1 ether);
        assertEq(uint256(e.state), uint256(AgentEscrow.EscrowState.Funded));
    }

    function test_VerifyAndRelease() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bytes32 agreementId, bytes32 escrowId) = escrow.createAndFund{value: 1 ether}(
            bob, 7 days, ""ipfs://deliverables""
        );

        vm.prank(bob);
        escrow.verifyDelivery(escrowId, ""ipfs://proof"");

        assertEq(uint256(escrow.getEscrow(escrowId).state), uint256(AgentEscrow.EscrowState.Verified));

        vm.prank(alice);
        escrow.release(escrowId);

        assertEq(uint256(escrow.getEscrow(escrowId).state), uint256(AgentEscrow.EscrowState.Released));
        assertEq(bob.balance, 1 ether);
    }

    function test_Refund_Timeout() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bytes32 agreementId, bytes32 escrowId) = escrow.createAndFund{value: 1 ether}(
            bob, 1 days, ""ipfs://deliverables""
        );

        // Bob never delivers
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        escrow.refund(escrowId);

        assertEq(uint256(escrow.getEscrow(escrowId).state), uint256(AgentEscrow.EscrowState.Cancelled));
    }

    // ══════════════════════════════════════════════
    // PAYMENT CHANNEL TESTS
    // ══════════════════════════════════════════════

    function test_OpenChannel() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 channelId = escrow.openChannel{value: 5 ether}(bob);

        (bytes32 cid, address sender, address receiver, uint256 balance,,,,,,,,) = escrow.channels(channelId);
        assertEq(sender, alice);
        assertEq(receiver, bob);
        assertEq(balance, 5 ether);
    }

    function test_OpenChannelInvalidReceiver() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(""Channel: invalid receiver"");
        escrow.openChannel{value: 1 ether}(alice);
    }

    function test_SettleChannel_WithChallenge() public {
        uint256 pkBob = 2;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 channelId = escrow.openChannel{value: 5 ether}(bob);

        // Bob signs nonce 5 for 3 ether
        bytes32 digest = keccak256(abi.encodePacked(
            ""\x19Ethereum Signed Message:\n32"",
            keccak256(abi.encode(channelId, uint256(5), 3 ether))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkBob, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(bob);
        escrow.settleChannel(channelId, 5, 3 ether, sig);

        (, , , , , , , , , uint256 pendingAmt, , , AgentEscrow.ChannelState state) = escrow.channels(channelId);
        assertEq(uint256(state), uint256(AgentEscrow.ChannelState.Settling));
        assertEq(pendingAmt, 3 ether);
    }

    function test_DisputeChannel_CorrectNonce() public {
        uint256 pkBob = 2;
        uint256 pkAlice = 1;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 channelId = escrow.openChannel{value: 5 ether}(bob);

        // Bob signs nonce 3 for 0.5 ETH (fraud: low nonce)
        bytes32 lowDigest = keccak256(abi.encodePacked(
            ""\x19Ethereum Signed Message:\n32"",
            keccak256(abi.encode(channelId, uint256(3), 0.5 ether))
        ));
        (uint8 vL, bytes32 rL, bytes32 sL) = vm.sign(pkBob, lowDigest);
        bytes memory lowSig = abi.encodePacked(rL, sL, vL);

        vm.prank(bob);
        escrow.settleChannel(channelId, 3, 0.5 ether, lowSig);

        // Alice has a higher nonce from Bob (nonce 8, 4 ether)
        bytes32 highDigest = keccak256(abi.encodePacked(
            ""\x19Ethereum Signed Message:\n32"",
            keccak256(abi.encode(channelId, uint256(8), 4 ether))
        ));
        (uint8 vH, bytes32 rH, bytes32 sH) = vm.sign(pkBob, highDigest);
        bytes memory highSig = abi.encodePacked(rH, sH, vH);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.disputeChannel{value: 0.05 ether}(channelId, 8, 4 ether, highSig);

        // Alice wins → nonce updated to 8
        (, , , , uint256 nonce, , , , , uint256 pendingAmt2, , , ) = escrow.channels(channelId);
        assertEq(nonce, 8);
        assertEq(pendingAmt2, 4 ether);
    }

    // ══════════════════════════════════════════════
    // ATTACK VECTORS
    // ══════════════════════════════════════════════

    function testAttack_UnauthorizedSign() public {
        bytes32[] memory signers = new bytes32[](1);
        signers[0] = aliceId;

        AgentAgreement.Term[] memory terms = new AgentAgreement.Term[](0);
        vm.prank(alice);
        bytes32 agreementId = agreement.createAgreement(signers, carolId, 7 days, terms);

        // Mallory tries to sign (not a party)
        bytes32 domainSep = agreement.domainSeparator();
        bytes32 typeHash = keccak256(""Agreement(bytes32 agreementId,address signer,uint256 timestamp)"");
        bytes32 structHash = keccak256(abi.encode(typeHash, agreementId, mallory, block.timestamp));
        bytes32 digest = keccak256(abi.encodePacked(""\x19\x01"", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(99, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(mallory);
        vm.expectRevert(""Agreement: not a party"");
        agreement.signAgreement(agreementId, sig);
    }

    function testAttack_EscrowReleaseByNonPayer() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (, bytes32 escrowId) = escrow.createAndFund{value: 1 ether}(
            bob, 7 days, ""ipfs://deliverables""
        );

        // Mallory tries to release (not the payer)
        vm.prank(mallory);
        vm.expectRevert();
        escrow.release(escrowId);
    }

    function testAttack_ChannelDisputeByNonSender() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 channelId = escrow.openChannel{value: 5 ether}(bob);

        vm.prank(mallory);
        vm.expectRevert(""Channel: only sender can dispute"");
        escrow.disputeChannel{value: 0.05 ether}(channelId, 99, 5 ether, """");
    }
}