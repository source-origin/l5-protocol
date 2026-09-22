// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5x402 测试套件 —— x402 记账 + 收据 + 仲裁闭环
/// @notice 覆盖: 快照/策略校验 / recordReceipt / 争议仲裁 / 签名证据
contract L5x402Test is Test {
    L5x402 public x402;
    MockERC20 public yuan;

    address public owner = address(this);
    address public payer = address(0x1);
    address public payee = address(0x2);

    bytes32 public policyId = keccak256("policy-1");

    function setUp() public {
        x402 = new L5x402();
        yuan = new MockERC20();
        yuan.mint(payer, 1000 ether);
        yuan.mint(payee, 1000 ether);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        vm.prank(payee);
        yuan.approve(address(x402), type(uint256).max);
    }

    function _record() internal returns (bytes32 receiptId) {
        receiptId = x402.recordReceipt(
            keccak256("req-1"), payer, payee, address(yuan), 5 ether, keccak256("route"), keccak256("payload"), policyId
        );
    }

    // ── 快照 + 策略校验 ──
    function test_VerifyRequirement_OK() public {
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        (bool allowed, string memory reason) =
            x402.verifyRequirement(policyId, payer, payee, address(yuan), 5 ether, keccak256("res"));
        assertTrue(allowed);
        assertEq(reason, "ok");
    }

    function test_VerifyRequirement_Unregistered() public {
        (bool allowed,) = x402.verifyRequirement(policyId, payer, payee, address(yuan), 5 ether, keccak256("res"));
        assertFalse(allowed);
    }

    function test_VerifyRequirement_ExceedsCap() public {
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        (bool allowed,) = x402.verifyRequirement(policyId, payer, payee, address(yuan), 200 ether, keccak256("res"));
        assertFalse(allowed);
    }

    // ── recordReceipt (有 allowance → Settled) ──
    function test_RecordReceipt_Settled() public {
        bytes32 rid = _record();
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Settled));
        assertEq(r.amount, 5 ether);
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(yuan.balanceOf(payee), 1000 ether + 5 ether);
    }

    function test_RecordReceipt_NoAllowance_Pending() public {
        // payer 不对 x402 approve → 停留 Pending
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 rid = x402.recordReceipt(
            keccak256("req-2"), payer, payee, address(yuan), 5 ether, keccak256("route"), keccak256("payload"), policyId
        );
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Pending));
        assertEq(yuan.balanceOf(payee), 1000 ether); // 未转出
    }

    // ── 仲裁闭环：dispute → refund（裁决追回）──
    function test_DisputeThenRefund() public {
        bytes32 rid = _record();
        assertEq(uint8(x402.getReceipt(rid).status), uint8(L5x402.ReceiptStatus.Settled));

        // 争议已结算的收据应失败
        vm.expectRevert("L5x402: already settled");
        x402.disputeReceipt(rid, "bad quality");

        // 用无 allowance 的路径造一个 Pending 收据来争议
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 rid2 = x402.recordReceipt(
            keccak256("req-3"), payer, payee, address(yuan), 5 ether, keccak256("route"), keccak256("payload"), policyId
        );
        assertEq(uint8(x402.getReceipt(rid2).status), uint8(L5x402.ReceiptStatus.Pending));

        x402.disputeReceipt(rid2, "fraud evidence");
        assertEq(uint8(x402.getReceipt(rid2).status), uint8(L5x402.ReceiptStatus.Disputed));

        // 裁决退款：payee → payer
        uint256 payerBefore = yuan.balanceOf(payer);
        x402.refundReceipt(rid2, 5 ether);
        assertEq(uint8(x402.getReceipt(rid2).status), uint8(L5x402.ReceiptStatus.Refunded));
        assertEq(yuan.balanceOf(payer), payerBefore + 5 ether);
    }

    function test_Refund_NotDisputed_Fails() public {
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 rid = x402.recordReceipt(
            keccak256("req-4"), payer, payee, address(yuan), 5 ether, keccak256("route"), keccak256("payload"), policyId
        );
        vm.expectRevert("L5x402: not disputed");
        x402.refundReceipt(rid, 5 ether);
    }

    // ── 签名证据 (Signed Evidence Pattern) ──
    function test_VerifyReceiptEvidence() public {
        bytes32 rid = _record();
        bytes32 evidenceHash = keccak256("evidence-1");
        // 合约 recover: EIP-191 前缀包裹 evidenceHash
        bytes32 signedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", evidenceHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, signedDigest);
        bytes memory sig = abi.encodePacked(r, s, v);
        address signer = vm.addr(1);

        assertTrue(x402.verifyReceiptEvidence(rid, evidenceHash, sig, signer));
        assertFalse(x402.verifyReceiptEvidence(rid, evidenceHash, sig, address(0x9)));
    }
}
