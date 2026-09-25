// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "src/AgentIdentity.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";

/// @title L5 核心三合约测试（按真实接口重写）
/// @notice 覆盖 AgentIdentity / AgentAgreement / AgentEscrow + PaymentChannel
contract L5CoreTest is Test {
    AgentIdentity public identity;
    AgentAgreement public agreement;
    AgentEscrow public escrow;

    // 确定性私钥 → 地址（保证 EIP-712 签名有效）
    uint256 public kAlice = 0xA11CE;
    uint256 public kBob = 0xB0B;
    uint256 public kCarol = 0xCA21A;
    uint256 public kMallory = uint256(keccak256("mallory"));

    address public alice;
    address public bob;
    address public carol;
    address public mallory;

    bytes32 public agreementId;

    function setUp() public {
        alice = vm.addr(kAlice);
        bob = vm.addr(kBob);
        carol = vm.addr(kCarol);
        mallory = vm.addr(kMallory);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        // 部署依赖链：Identity → Agreement → Escrow(需 Agreement 地址)
        identity = new AgentIdentity();
        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
    }

    // ══════════════════════════
    // AgentIdentity 测试
    // ══════════════════════════

    function _registerAlice() internal {
        vm.prank(alice);
        identity.registerAgent{value: 0.01 ether}(
            "alice_trader", "Alice Trader", "quant bot", "trading", "ipfs://alice-md"
        );
    }

    function test_RegisterAgent() public {
        _registerAlice();
        uint256 id = identity.getAgentId(alice);
        assertGt(id, 0);
        assertEq(identity.getHandle(alice), "alice_trader");
        assertEq(identity.balanceOf(alice), 1); // ERC-721 一枚
    }

    function test_RegisterDuplicateHandle_Fails() public {
        _registerAlice();
        vm.prank(bob);
        vm.expectRevert("Identity: handle taken");
        identity.registerAgent{value: 0.01 ether}("alice_trader", "Bob", "bot", "mining", "ipfs://bob");
    }

    function test_RegisterDuplicateSender_Fails() public {
        _registerAlice();
        vm.prank(alice);
        vm.expectRevert("Identity: already registered");
        identity.registerAgent{value: 0.01 ether}("another", "Alice2", "bot", "trading", "ipfs://a2");
    }

    function test_RecordContribution_RaisesReputation() public {
        _registerAlice();
        uint256 before = identity.getAgent(alice).reputationScore;
        for (uint256 i = 0; i < 10; i++) {
            identity.recordContribution(alice, 90, 90, 90);
        }
        assertGt(identity.getAgent(alice).reputationScore, before);
    }

    // ══════════════════════════
    // AgentAgreement 测试（含 EIP-712 双签）
    // ══════════════════════════

    function _makeTerms() internal view returns (AgentAgreement.SettlementTerm[] memory terms) {
        terms = new AgentAgreement.SettlementTerm[](1);
        terms[0] = AgentAgreement.SettlementTerm({
            termId: bytes32(0),
            termType: AgentAgreement.TermType.Payment,
            description: "execute trade",
            value: 5 ether,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });
    }

    function _makeParties() internal view returns (AgentAgreement.AgentParty[] memory parties) {
        parties = new AgentAgreement.AgentParty[](2);
        parties[0] = AgentAgreement.AgentParty({
            agentAddr: alice, role: AgentAgreement.PartyRole.Consumer, signature: new bytes(0), signedAt: 0
        });
        parties[1] = AgentAgreement.AgentParty({
            agentAddr: bob, role: AgentAgreement.PartyRole.Provider, signature: new bytes(0), signedAt: 0
        });
    }

    function _createAndPropose() internal {
        AgentAgreement.AgentParty[] memory parties = _makeParties();
        AgentAgreement.SettlementTerm[] memory terms = _makeTerms();
        vm.startPrank(alice);
        agreementId = agreement.createAgreement("trade-1", "BTC trade", parties, terms, 5 ether);
        agreement.propose(agreementId);
        vm.stopPrank();
    }

    function _sign(bytes32 _agreementHash, uint256 _key) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), _agreementHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Propose_ThenFullSign_Executed() public {
        _createAndPropose();
        assertEq(uint8(agreement.getAgreement(agreementId).state), uint8(AgentAgreement.AgreementState.Proposed));

        bytes32 hash = agreement.getAgreement(agreementId).agreementHash;
        // 先算好签名，再 prank——避免中间 staticcall 消耗 vm.prank
        bytes memory sigAlice = _sign(hash, kAlice);
        vm.prank(alice);
        agreement.signAgreement(agreementId, sigAlice);
        assertEq(uint8(agreement.getAgreement(agreementId).state), uint8(AgentAgreement.AgreementState.Proposed));

        bytes memory sigBob = _sign(hash, kBob);
        vm.prank(bob);
        agreement.signAgreement(agreementId, sigBob);
        assertEq(uint8(agreement.getAgreement(agreementId).state), uint8(AgentAgreement.AgreementState.Executed));
    }

    function test_SignByMallory_Fails() public {
        _createAndPropose();
        bytes32 hash = agreement.getAgreement(agreementId).agreementHash;
        bytes memory sigM = _sign(hash, kMallory);
        vm.prank(mallory);
        vm.expectRevert();
        agreement.signAgreement(agreementId, sigM);
    }

    // ══════════════════════════
    // AgentEscrow 测试（强依赖 Agreement）
    // ══════════════════════════

    function _executedAgreement() internal {
        _createAndPropose();
        bytes32 hash = agreement.getAgreement(agreementId).agreementHash;
        bytes memory sigAlice = _sign(hash, kAlice);
        bytes memory sigBob = _sign(hash, kBob);
        vm.prank(alice);
        agreement.signAgreement(agreementId, sigAlice);
        vm.prank(bob);
        agreement.signAgreement(agreementId, sigBob);
        require(
            uint8(agreement.getAgreement(agreementId).state) == uint8(AgentAgreement.AgreementState.Executed),
            "not executed"
        );
    }

    function test_CreateAndFundEscrow() public {
        _executedAgreement();
        vm.prank(alice);
        bytes32 escrowId = escrow.createAndFund{value: 5 ether}(agreementId, bob, block.timestamp + 7 days);

        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.amount, 5 ether);
        assertEq(e.payer, alice);
        assertEq(e.payee, bob);
        assertEq(uint8(e.state), uint8(AgentEscrow.EscrowState.Funded));
    }

    function test_CreateAndFund_NonConsumer_Fails() public {
        _executedAgreement();
        vm.prank(mallory);
        vm.expectRevert();
        escrow.createAndFund{value: 5 ether}(agreementId, bob, block.timestamp + 7 days);
    }

    function test_EscrowFullLifecycle_Release() public {
        _executedAgreement();
        vm.prank(alice);
        bytes32 escrowId = escrow.createAndFund{value: 5 ether}(agreementId, bob, block.timestamp + 7 days);

        vm.prank(bob);
        escrow.verifyDelivery(escrowId, "ipfs://proof");
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(AgentEscrow.EscrowState.Verified));

        // markSettled 要求协议处于 Completed：把所有条款标记完成
        bytes32 termId = agreement.getAgreement(agreementId).terms[0].termId;
        vm.prank(alice);
        agreement.completeTerm(agreementId, termId);
        assertEq(uint8(agreement.getAgreement(agreementId).state), uint8(AgentAgreement.AgreementState.Completed));

        uint256 bobBalBefore = bob.balance;
        vm.prank(alice);
        escrow.release(escrowId);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(AgentEscrow.EscrowState.Released));
        assertEq(uint8(agreement.getAgreement(agreementId).state), uint8(AgentAgreement.AgreementState.Settled));
        assertEq(bob.balance, bobBalBefore + 5 ether);
    }

    function test_EscrowRefund_Timeout() public {
        _executedAgreement();
        vm.prank(alice);
        bytes32 escrowId = escrow.createAndFund{value: 5 ether}(agreementId, bob, block.timestamp + 1 days);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        escrow.refund(escrowId);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(AgentEscrow.EscrowState.Cancelled));
        assertEq(alice.balance, 100 ether);
    }

    function test_ReleaseBeforeVerify_Fails() public {
        _executedAgreement();
        vm.prank(alice);
        bytes32 escrowId = escrow.createAndFund{value: 5 ether}(agreementId, bob, block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert();
        escrow.release(escrowId);
    }

    // ══════════════════════════
    // PaymentChannel 测试
    // ══════════════════════════
    // PaymentChannel 字段: channelId, sender, receiver, balance, nonce,
    //                       openedAt, lastUsedAt, settlingAt, pendingAmount,
    //                       pendingSignature, disputeBond, state

    function test_OpenChannel() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 cid = escrow.openChannel{value: 5 ether}(bob);
        (
            bytes32 cId,
            address sender,
            address receiver,
            uint256 bal,
            uint256 nonce,
            uint256 openedAt,
            uint256 lastUsedAt,
            uint256 settlingAt,
            uint256 pendingAmount,
            bytes memory pendingSig,
            uint256 disputeBond,
            AgentEscrow.ChannelState st
        ) = escrow.channels(cid);
        assertEq(sender, alice);
        assertEq(receiver, bob);
        assertEq(bal, 5 ether);
        assertEq(uint256(st), uint256(AgentEscrow.ChannelState.Open));
    }

    function test_OpenChannelInvalidReceiver() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert("Channel: invalid receiver");
        escrow.openChannel{value: 1 ether}(alice);
    }

    function test_SettleChannel_WithChallenge() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 cid = escrow.openChannel{value: 5 ether}(bob);

        bytes32 digest = escrow.channelVoucherDigest(cid, 5, 3 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kBob, digest);
        vm.prank(bob);
        escrow.settleChannel(cid, 5, 3 ether, abi.encodePacked(r, s, v));

        (
            bytes32 chId2,
            address send2,
            address recv2,
            uint256 bal2,
            uint256 nonce2b,
            uint256 openAt2,
            uint256 lastUsed2,
            uint256 settleAt2,
            uint256 pending,
            bytes memory pendSig2,
            uint256 bond2,
            AgentEscrow.ChannelState state
        ) = escrow.channels(cid);
        assertEq(uint256(state), uint256(AgentEscrow.ChannelState.Settling));
        assertEq(pending, 3 ether);
    }

    function test_ChannelDispute_HigherNonce_Wins() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bytes32 cid = escrow.openChannel{value: 5 ether}(bob);

        bytes32 lowDigest = escrow.channelVoucherDigest(cid, 3, 0.5 ether);
        (uint8 vl, bytes32 rl, bytes32 sl) = vm.sign(kBob, lowDigest);
        vm.prank(bob);
        escrow.settleChannel(cid, 3, 0.5 ether, abi.encodePacked(rl, sl, vl));

        bytes32 highDigest = escrow.channelVoucherDigest(cid, 8, 4 ether);
        (uint8 vh, bytes32 rh, bytes32 sh) = vm.sign(kBob, highDigest);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        escrow.disputeChannel{value: 0.05 ether}(cid, 8, 4 ether, abi.encodePacked(rh, sh, vh));

        (
            bytes32 chId3,
            address send3,
            address recv3,
            uint256 bal3,
            uint256 nonce,
            uint256 openAt3,
            uint256 lastUsed3,
            uint256 settleAt3,
            uint256 pending2,
            bytes memory pendSig3,
            uint256 bond3,
            AgentEscrow.ChannelState state2
        ) = escrow.channels(cid);
        assertEq(nonce, 8);
        assertEq(pending2, 4 ether);
        assertEq(uint256(state2), uint256(AgentEscrow.ChannelState.Settling));
    }
}
