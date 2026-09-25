// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {X402FacilitatorAdapter} from "src/X402FacilitatorAdapter.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title X402FacilitatorAdapter fuzz-verified invariants
/// @notice Sweeps the pass-through surface: only a registered facilitator can settle, malformed
///         payloads are refused, an external-rail payload records evidence but never moves funds
///         (stays Pending), an on-chain payload moves exactly the signed value, and the adapter
///         never custodies anything. No `src/` change -- purely additive.
contract X402AdapterFuzzTest is Test {
    L5x402 internal x402;
    MockERC20 internal yuan;
    X402FacilitatorAdapter internal adapter;

    address internal facilitator = address(0xFAC);
    uint256 internal payerPk = 1;
    address internal payer;
    address internal payee;

    bytes32 internal policyId = keccak256("policy-1");
    bytes32 internal routeHash = keccak256("route:/v1/agent/infer");
    bytes32 internal payloadHash = keccak256("payload:request-params");
    bytes32 internal nonce = keccak256("x402-nonce-1");

    function setUp() public {
        payer = vm.addr(payerPk);
        payee = vm.addr(2);
        x402 = new L5x402();
        yuan = new MockERC20();
        adapter = new X402FacilitatorAdapter(address(x402));
        adapter.setFacilitator(facilitator, true);

        yuan.mint(payer, 1_000_000 ether);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
        // H2: register the spend policy so on-chain settlement is gated by a cap.
        x402.updateSnapshot(policyId, payer, 0, 100 ether, 7 days);
    }

    /// Build a payload for `value`, signed by the payer over the canonical action. The token
    /// recorded by L5x402 is the external marker when asset == 0, else the asset itself.
    function _payload(address asset, uint256 value, bytes32 reqNonce)
        internal
        view
        returns (X402FacilitatorAdapter.ExactPayload memory)
    {
        uint256 deadline = block.timestamp + 1 days;
        address token = asset == address(0) ? adapter.externalAsset() : asset;
        bytes32 d = x402.actionDigest(reqNonce, payer, payee, token, value, routeHash, payloadHash, policyId, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, d);
        return X402FacilitatorAdapter.ExactPayload({
            from: payer,
            to: payee,
            asset: asset,
            value: value,
            nonce: reqNonce,
            deadline: deadline,
            authorization: abi.encodePacked(r, s, v)
        });
    }

    /// Only a registered facilitator may settle -- anyone else is refused.
    function testFuzz_OnlyFacilitatorCanSettle(address caller) public {
        vm.assume(caller != facilitator);
        X402FacilitatorAdapter.ExactPayload memory p = _payload(address(yuan), 5 ether, nonce);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(X402FacilitatorAdapter.NotFacilitator.selector, caller));
        adapter.settleExact(p, routeHash, payloadHash, policyId);
    }

    /// A malformed payload (zero from / to / value / nonce) is refused before anything is stored.
    function testFuzz_BadPayloadReverts(address from, address to, uint256 value, bytes32 reqNonce) public {
        vm.assume(from == address(0) || to == address(0) || value == 0 || reqNonce == bytes32(0));
        X402FacilitatorAdapter.ExactPayload memory p = X402FacilitatorAdapter.ExactPayload({
            from: from,
            to: to,
            asset: address(yuan),
            value: value,
            nonce: reqNonce,
            deadline: block.timestamp + 1 days,
            authorization: ""
        });
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(X402FacilitatorAdapter.BadPayload.selector));
        adapter.settleExact(p, routeHash, payloadHash, policyId);
    }

    /// External rail (asset == 0): the receipt is recorded as evidence but stays Pending and
    /// nothing moves on-chain -- the value lives on the other ledger.
    function testFuzz_ExternalRailNeverSettles(uint256 value) public {
        value = bound(value, 1, 100 ether);
        uint256 payeeBefore = yuan.balanceOf(payee);
        X402FacilitatorAdapter.ExactPayload memory p = _payload(address(0), value, nonce);

        vm.prank(facilitator);
        bytes32 rid = adapter.settleExact(p, routeHash, payloadHash, policyId);

        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Pending), "external rail stays pending");
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Open), "no finality without value move");
        assertEq(yuan.balanceOf(payee), payeeBefore, "no funds moved");
        assertEq(yuan.balanceOf(address(adapter)), 0, "adapter custodies nothing");
    }

    /// On-chain rail: the receipt settles and moves exactly the signed value, preserving the join key.
    function testFuzz_OnchainRailMovesExactValue(uint256 value) public {
        value = bound(value, 1, 100 ether); // within the registered policy cap
        uint256 payerBefore = yuan.balanceOf(payer);
        uint256 payeeBefore = yuan.balanceOf(payee);
        X402FacilitatorAdapter.ExactPayload memory p = _payload(address(yuan), value, nonce);

        vm.prank(facilitator);
        bytes32 rid = adapter.settleExact(p, routeHash, payloadHash, policyId);

        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Settled), "settled");
        assertEq(uint8(r.finality), uint8(L5x402.ReceiptFinality.Final), "final");
        assertEq(yuan.balanceOf(payee), payeeBefore + value, "payee credited exactly");
        assertEq(yuan.balanceOf(payer), payerBefore - value, "payer debited exactly");
        assertEq(yuan.balanceOf(address(adapter)), 0, "adapter custodies nothing");
        assertEq(r.requestId, nonce, "x402 nonce preserved as join key");
    }

    /// The adapter is a pure pass-through: it never holds the underlying token.
    function testFuzz_AdapterNeverHoldsFunds(uint256 value) public {
        value = bound(value, 1, 100 ether);
        X402FacilitatorAdapter.ExactPayload memory p = _payload(address(yuan), value, nonce);
        vm.prank(facilitator);
        adapter.settleExact(p, routeHash, payloadHash, policyId);
        assertEq(yuan.balanceOf(address(adapter)), 0, "adapter token balance always zero");
    }
}
