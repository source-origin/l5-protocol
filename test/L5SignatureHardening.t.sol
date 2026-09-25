// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentAgreement} from "src/AgentAgreement.sol";
import {AgentEscrow} from "src/AgentEscrow.sol";

/// @title L5 signature hardening (M3 / M4) — 2026-09-25 self-audit
/// @notice M3  payment-channel vouchers are now domain-bound (chainId + verifying
///       contract) and low-s enforced, so neither a cross-chain replay nor a
///       malleable (high-s) signature can move a channel. Either channel party may
///       vouch (payer authorizes, payee claims).
///     M4  AgentAgreement / AgentAgreementV3 EIP-712 verification now goes through
///       OZ ECDSA (canonical low-s), so a malleable (high-s) agreement signature is
///       refused instead of silently accepted.
contract L5SignatureHardeningTest is Test {
    AgentAgreement public agreement;
    AgentEscrow public escrow;

    uint256 public constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256 public kSender = 0x11;
    uint256 public kPayee = 0x22;
    uint256 public kAlice = 0xA11CE;
    uint256 public kBob = 0xB0B;

    address public sender;
    address public payee;
    address public alice;
    address public bob;

    function setUp() public {
        sender = vm.addr(kSender);
        payee = vm.addr(kPayee);
        alice = vm.addr(kAlice);
        bob = vm.addr(kBob);
        agreement = new AgentAgreement();
        escrow = new AgentEscrow(address(agreement));
        vm.deal(sender, 100 ether);
        vm.deal(alice, 100 ether);
    }

    // ── helpers ──

    function _openChannel() internal returns (bytes32 cid) {
        vm.prank(sender);
        cid = escrow.openChannel{value: 5 ether}(payee);
    }

    function _sign(uint256 pk, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Flip a canonical low-s signature into its malleable high-s twin (s' = n - s, v flips).
    function _toHighS(bytes memory sig) internal pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        s = bytes32(SECP256K1N - uint256(s));
        v = v == 27 ? 28 : 27;
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────────────────────────────
    // M3 · payment-channel voucher
    // ─────────────────────────────────────────────

    function test_M3_ValidReceiverVoucher_Settles() public {
        bytes32 cid = _openChannel();
        bytes memory sig = _sign(kPayee, escrow.channelVoucherDigest(cid, 5, 3 ether));
        escrow.settleChannel(cid, 5, 3 ether, sig);
        (,,,,,,,, uint256 pending,,, AgentEscrow.ChannelState st) = escrow.channels(cid);
        assertEq(pending, 3 ether);
        assertEq(uint256(st), uint256(AgentEscrow.ChannelState.Settling));
    }

    /// The pre-hardening digest (bare personal_sign over the un-domained struct) is rejected.
    function test_M3_PersonalSignDigest_Rejected() public {
        bytes32 cid = _openChannel();
        bytes32 legacy = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(abi.encode(cid, uint256(5), 3 ether)))
        );
        bytes memory sig = _sign(kPayee, legacy);
        vm.expectRevert("Channel: invalid signer");
        escrow.settleChannel(cid, 5, 3 ether, sig);
    }

    /// A valid voucher re-encoded with high-s must not be accepted (malleability).
    function test_M3_MalleableHighS_Rejected() public {
        bytes32 cid = _openChannel();
        bytes memory sig = _toHighS(_sign(kPayee, escrow.channelVoucherDigest(cid, 5, 3 ether)));
        vm.expectRevert("Channel: invalid signer");
        escrow.settleChannel(cid, 5, 3 ether, sig);
    }

    /// Either party may vouch: a sender-signed voucher is still a valid settlement.
    function test_M3_SenderSignedVoucher_Settles() public {
        bytes32 cid = _openChannel();
        bytes memory sig = _sign(kSender, escrow.channelVoucherDigest(cid, 5, 3 ether));
        escrow.settleChannel(cid, 5, 3 ether, sig);
        (,,,,,,,, uint256 pending,,, AgentEscrow.ChannelState st) = escrow.channels(cid);
        assertEq(pending, 3 ether);
        assertEq(uint256(st), uint256(AgentEscrow.ChannelState.Settling));
    }

    // ─────────────────────────────────────────────
    // M4 · agreement EIP-712 signature
    // ─────────────────────────────────────────────

    function test_M4_HighS_AgreementSignature_Rejected() public {
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
            description: "x",
            value: 5 ether,
            dueDate: block.timestamp + 7 days,
            completed: false,
            completedAt: 0
        });

        vm.startPrank(alice);
        bytes32 aid = agreement.createAgreement("t", "d", parties, terms, 5 ether);
        agreement.propose(aid);
        vm.stopPrank();

        bytes32 ahash = agreement.getAgreement(aid).agreementHash;
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", agreement.domainSeparator(), ahash));
        bytes memory sig = _toHighS(_sign(kAlice, digest));

        vm.prank(alice);
        vm.expectRevert("Agreement: invalid EIP-712 signature");
        agreement.signAgreement(aid, sig);
    }
}
