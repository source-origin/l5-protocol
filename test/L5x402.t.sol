// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title L5x402 测试套件 —— x402 记账 + 收据 + 仲裁闭环 + 授权/证据绑定
/// @notice 覆盖: 快照/策略校验 / 授权登记(recordReceipt) / 争议仲裁 / 签名证据绑定
///   P0 加固（EMILIA review at commit 807e1ee）: recordReceipt 需 payer 授权签名（#1）、
///   证据必须绑定到已存 payloadHash 且签名者固定为 payee（#2）、
///   动作摘要为完整字段集（#3）、Pending 不得铸为 Final（#4）。
contract L5x402Test is Test {
    L5x402 public x402;
    MockERC20 public yuan;

    address public owner = address(this);
    uint256 public payerPk = 1;
    uint256 public payeePk = 2;
    address public payer;
    address public payee;

    bytes32 public policyId = keccak256("policy-1");
    bytes32 public routeHash = keccak256("route");
    bytes32 public payloadHash = keccak256("payload");

    function setUp() public {
        payer = vm.addr(payerPk);
        payee = vm.addr(payeePk);
        x402 = new L5x402();
        yuan = new MockERC20();
        yuan.mint(payer, 1000 ether);
        yuan.mint(payee, 1000 ether);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        vm.prank(payee);
        yuan.approve(address(x402), type(uint256).max);
    }

    function _auth(bytes32 reqId, address tkn, uint256 amount, bytes32 pHash, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 d = x402.actionDigest(reqId, payer, payee, tkn, amount, routeHash, pHash, policyId, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _rec(bytes32 reqId, address tkn, uint256 amount, bytes32 pHash) internal returns (bytes32) {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _auth(reqId, tkn, amount, pHash, deadline, payerPk);
        return x402.recordReceipt(reqId, payer, payee, tkn, amount, routeHash, pHash, policyId, deadline, sig);
    }

    function _record() internal returns (bytes32) {
        return _rec(keccak256("req-1"), address(yuan), 5 ether, payloadHash);
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

    // ── recordReceipt (有 allowance + 授权 → Settled, Final) ──
    function test_RecordReceipt_Settled() public {
        // H2: settlement now requires a registered policy within its on-chain cap.
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        bytes32 rid = _record();
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Settled));
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Final));
        assertEq(r.amount, 5 ether);
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(yuan.balanceOf(payee), 1000 ether + 5 ether);
    }

    function test_RecordReceipt_NoAllowance_Pending_NotFinal() public {
        // payer 不对 x402 approve → 停留 Pending，且不得声称 Final（P0 #4）
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 rid = _rec(keccak256("req-2"), address(yuan), 5 ether, keccak256("payload"));
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Pending));
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Open), "pending must not claim Final");
        assertEq(yuan.balanceOf(payee), 1000 ether); // 未转出
    }

    // ── P0 #1: 未授权 / 重放 / 过期 ──
    function test_RecordReceipt_NotPayerAuthorized_Reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        // 攻击者用自己的 key 签（不是 payer）→ 拒绝
        bytes memory sig = _auth(keccak256("req-x"), address(yuan), 5 ether, payloadHash, deadline, 3);
        vm.expectRevert("L5x402: not payer-authorized");
        x402.recordReceipt(
            keccak256("req-x"), payer, payee, address(yuan), 5 ether, routeHash, payloadHash, policyId, deadline, sig
        );
    }

    function test_RecordReceipt_ReplayedAuth_Reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _auth(keccak256("req-r"), address(yuan), 5 ether, payloadHash, deadline, payerPk);
        x402.recordReceipt(
            keccak256("req-r"), payer, payee, address(yuan), 5 ether, routeHash, payloadHash, policyId, deadline, sig
        );
        // 同一授权再次使用 → 拒绝（防重放）
        vm.expectRevert("L5x402: authorization replayed");
        x402.recordReceipt(
            keccak256("req-r"), payer, payee, address(yuan), 5 ether, routeHash, payloadHash, policyId, deadline, sig
        );
    }

    function test_RecordReceipt_Expired_Reverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _auth(keccak256("req-e"), address(yuan), 5 ether, payloadHash, deadline, payerPk);
        vm.expectRevert("L5x402: authorization expired");
        x402.recordReceipt(
            keccak256("req-e"), payer, payee, address(yuan), 5 ether, routeHash, payloadHash, policyId, deadline, sig
        );
    }

    // ── 仲裁闭环：dispute → refund（裁决追回）──
    function test_DisputeThenRefund() public {
        // H2: register the policy so the first receipt actually settles.
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
        bytes32 rid = _record();
        assertEq(uint8(x402.getReceipt(rid).status), uint8(L5x402.ReceiptStatus.Settled));

        // 争议已结算的收据应失败
        vm.expectRevert("L5x402: already settled");
        x402.disputeReceipt(rid, "bad quality");

        // 用无 allowance 的路径造一个 Pending 收据来争议
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 rid2 = _rec(keccak256("req-3"), address(yuan), 5 ether, keccak256("payload"));
        assertEq(uint8(x402.getReceipt(rid2).status), uint8(L5x402.ReceiptStatus.Pending));

        x402.disputeReceipt(rid2, "fraud evidence");
        assertEq(uint8(x402.getReceipt(rid2).status), uint8(L5x402.ReceiptStatus.Disputed));

        // 裁决退款：未动款收据不可退（value never moved），只能作废
        vm.expectRevert("L5x402: value never moved");
        x402.refundReceipt(rid2, 5 ether);
        x402.voidReceipt(rid2);
        assertEq(uint8(x402.getReceipt(rid2).status), uint8(L5x402.ReceiptStatus.Failed));
        assertEq(uint8(x402.getReceipt(rid2).finality), uint8(L5x402.ReceiptFinality.Open));
    }

    function test_Refund_NotDisputed_Fails() public {
        vm.prank(payer);
        yuan.approve(address(x402), 0);
        bytes32 rid = _rec(keccak256("req-4"), address(yuan), 5 ether, keccak256("payload"));
        vm.expectRevert("L5x402: not disputed");
        x402.refundReceipt(rid, 5 ether);
    }

    // ── P0 #2: 签名证据绑定（hash 必须 == 存储 payloadHash；签名者固定 payee）──
    function test_VerifyReceiptEvidence() public {
        bytes32 rid = _record();
        bytes32 evidenceHash = x402.getReceipt(rid).payloadHash; // 必须等于登记时的 payloadHash
        bytes32 signedDigest = x402.receiptEvidenceDigest(rid, evidenceHash); // H3: domain-bound
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, signedDigest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(x402.verifyReceiptEvidence(rid, evidenceHash, sig, payee));
        assertTrue(x402.getReceipt(rid).evidenceVerified, "binding persisted");

        // 签名者非 payee → false（签名者被固定）
        assertFalse(x402.verifyReceiptEvidence(rid, evidenceHash, sig, payer));
        // 证据 hash 不等于存储 payloadHash → false（不能另供一个 hash）
        assertFalse(x402.verifyReceiptEvidence(rid, keccak256("other"), sig, payee));
    }
}
