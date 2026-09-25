// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "src/AgentIdentity.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";

/// @title L5 访问控制止血包 · 回归测试
/// @notice 锁定 2026-09-25 自查审计发现的 C 级问题：
///   C1 resolveDispute 未授权、C2 finalizeSettlement 重入、
///   C3 AgentIdentity 特权函数未授权、C4 setDisputeBond 未授权。
/// @dev 测试合约即部署者 = owner；alice/bob/carol/mallory 为非 owner。
contract L5AccessControlTest is Test {
    AgentIdentity public identity;
    AgentAgreement public agreement;
    AgentEscrow public escrow;

    uint256 public kAlice = 0xA11CE;
    uint256 public kBob = 0xB0B;
    uint256 public kMallory = uint256(keccak256("mallory"));

    address public alice;
    address public bob;
    address public mallory;

    bytes32 public agreementId;

    function setUp() public {
        alice = vm.addr(kAlice);
        bob = vm.addr(kBob);
        mallory = vm.addr(kMallory);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(mallory, 100 ether);

        identity = new AgentIdentity();
        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
    }

    // ─────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────

    function _registerAlice() internal {
        vm.prank(alice);
        identity.registerAgent{value: 0.01 ether}("alice_trader", "Alice Trader", "quant bot", "trading", "ipfs://a");
    }

    function _sign(bytes32 _agreementHash, uint256 _key) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), _agreementHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _executedAgreement() internal {
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
            description: "execute trade",
            value: 5 ether,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });

        vm.prank(alice);
        agreementId = agreement.createAgreement("trade-1", "BTC trade", parties, terms, 5 ether);
        vm.prank(alice);
        agreement.propose(agreementId);

        bytes32 hash = agreement.getAgreement(agreementId).agreementHash;
        bytes memory sigAlice = _sign(hash, kAlice);
        bytes memory sigBob = _sign(hash, kBob);
        vm.prank(alice);
        agreement.signAgreement(agreementId, sigAlice);
        vm.prank(bob);
        agreement.signAgreement(agreementId, sigBob);
    }

    /// @notice 走到 Disputed 状态：Funded → Verified → Disputed
    function _disputedEscrow() internal returns (bytes32 escrowId) {
        _executedAgreement();
        vm.prank(alice);
        escrowId = escrow.createAndFund{value: 5 ether}(agreementId, bob, block.timestamp + 7 days);

        vm.prank(bob);
        escrow.verifyDelivery(escrowId, "ipfs://proof");

        uint256 bond = (5 ether * escrow.disputeBondBps()) / 10000;
        vm.prank(alice);
        escrow.dispute{value: bond}(escrowId);
        require(uint8(escrow.getEscrow(escrowId).state) == uint8(AgentEscrow.EscrowState.Disputed), "not disputed");
    }

    // ─────────────────────────────────────────────
    // C1 · resolveDispute 仅 owner
    // ─────────────────────────────────────────────

    function test_C1_ResolveDispute_NonOwner_Reverts() public {
        bytes32 escrowId = _disputedEscrow();
        vm.prank(mallory);
        vm.expectRevert();
        escrow.resolveDispute(escrowId, true);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(AgentEscrow.EscrowState.Disputed));
    }

    function test_C1_ResolveDispute_Owner_Succeeds() public {
        bytes32 escrowId = _disputedEscrow();
        uint256 bobBefore = bob.balance;
        escrow.resolveDispute(escrowId, true); // 测试合约 = owner
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(AgentEscrow.EscrowState.Released));
        assertEq(bob.balance, bobBefore + 5 ether + 0.05 ether); // 托管 + 押金
    }

    // ─────────────────────────────────────────────
    // C4 · setDisputeBond 仅 owner
    // ─────────────────────────────────────────────

    function test_C4_SetDisputeBond_NonOwner_Reverts() public {
        vm.prank(mallory);
        vm.expectRevert();
        escrow.setDisputeBond(500);
        assertEq(escrow.disputeBondBps(), 100);
    }

    // ─────────────────────────────────────────────
    // C3 · AgentIdentity 特权函数仅 owner
    // ─────────────────────────────────────────────

    function test_C3_SlashAgent_NonOwner_Reverts() public {
        _registerAlice();
        vm.prank(mallory);
        vm.expectRevert();
        identity.slashAgent(alice, "malicious");
        assertEq(uint8(identity.getAgentStatus(alice)), uint8(AgentIdentity.AgentStatus.Active));
    }

    function test_C3_SuspendAgent_NonOwner_Reverts() public {
        _registerAlice();
        vm.prank(mallory);
        vm.expectRevert();
        identity.suspendAgent(alice, "malicious", 7);
        assertEq(uint8(identity.getAgentStatus(alice)), uint8(AgentIdentity.AgentStatus.Active));
    }

    function test_C3_UpgradeVerification_NonOwner_Reverts() public {
        _registerAlice();
        vm.prank(mallory);
        vm.expectRevert();
        identity.upgradeVerification(alice, AgentIdentity.VerificationLevel.Trusted);
        assertEq(uint8(identity.getAgent(alice).verification), uint8(AgentIdentity.VerificationLevel.Basic));
    }

    function test_C3_RecordRevenue_NonOwner_Reverts() public {
        _registerAlice();
        uint256 before = identity.getAgent(alice).totalRevenue;
        vm.prank(mallory);
        vm.expectRevert();
        identity.recordRevenue(alice, 1000 ether);
        assertEq(identity.getAgent(alice).totalRevenue, before);
    }

    // ─────────────────────────────────────────────
    // C2 · finalizeSettlement 重入被阻断
    // ─────────────────────────────────────────────

    function test_C2_FinalizeSettlement_ReentrancyBlocked() public {
        ReentrantReceiver rr = new ReentrantReceiver(escrow);

        vm.prank(alice);
        bytes32 cid = escrow.openChannel{value: 5 ether}(address(rr));
        rr.arm(cid);

        // sender(alice) 签名，结算 1 ether（M3：凭证改绑域 EIP-712）
        bytes32 digest = escrow.channelVoucherDigest(cid, 1, 1 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kAlice, digest);
        escrow.settleChannel(cid, 1, 1 ether, abi.encodePacked(r, s, v));

        vm.warp(block.timestamp + 8 days); // 越过挑战期
        escrow.finalizeSettlement(cid);

        // 只付一次：receiver 收 1 ether，sender 退回 4 ether
        assertEq(address(rr).balance, 1 ether);
        assertEq(alice.balance, 100 ether - 5 ether + 4 ether);
        assertEq(rr.hits(), 1, "receiver must be paid exactly once");
    }
}

/// @dev 恶意收款方：收到款时尝试重入 finalizeSettlement
contract ReentrantReceiver {
    AgentEscrow public escrow;
    bytes32 public cid;
    uint256 public hits;

    constructor(AgentEscrow _escrow) {
        escrow = _escrow;
    }

    function arm(bytes32 _cid) external {
        cid = _cid;
    }

    receive() external payable {
        hits++;
        if (hits == 1) {
            try escrow.finalizeSettlement(cid) {} catch {}
        }
    }
}
