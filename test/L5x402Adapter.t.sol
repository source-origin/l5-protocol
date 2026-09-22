// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5x402} from "src/L5x402.sol";
import {X402FacilitatorAdapter} from "src/X402FacilitatorAdapter.sol";
import {MockERC20} from "./MockERC20.t.sol";

/// @title x402 facilitator adapter - round-trip tests
/// @notice Proves the mapping in docs/INTEROP-x402.md section 6.2:
///         an x402 `exact` payload -> recordReceipt(...) -> getReceiptsByPayer /
///         getDelegatedSpendSnapshot round trip.
///         Two rails: (1) on-chain token (settles), (2) external rail (Nano, stays Pending).
contract L5x402AdapterTest is Test {
    L5x402 public x402;
    MockERC20 public yuan;
    X402FacilitatorAdapter public adapter;

    address public owner = address(this);
    address public facilitator = address(0xFAC);
    address public payer = address(0x1);
    address public payee = address(0x2);

    bytes32 public policyId = keccak256("policy-1");
    bytes32 public routeHash = keccak256("route:/v1/agent/infer");
    bytes32 public payloadHash = keccak256("payload:request-params");
    bytes32 public nonce = keccak256("x402-nonce-1");

    function setUp() public {
        x402 = new L5x402();
        yuan = new MockERC20();
        adapter = new X402FacilitatorAdapter(address(x402));
        adapter.setFacilitator(facilitator, true);

        yuan.mint(payer, 1000 ether);
        vm.prank(payer);
        yuan.approve(address(x402), type(uint256).max);
    }

    function _payload(address asset) internal view returns (X402FacilitatorAdapter.ExactPayload memory) {
        return X402FacilitatorAdapter.ExactPayload({
            from: payer, to: payee, asset: asset, value: 5 ether, nonce: nonce
        });
    }

    // ---- 1. on-chain token: full round trip, settles + snapshot bumps ----
    function test_SettleExact_OnchainToken_RoundTrip() public {
        vm.prank(facilitator);
        bytes32 rid = adapter.settleExact(_payload(address(yuan)), routeHash, payloadHash, policyId);

        // receipt fields match the x402 payload
        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(r.requestId, nonce); // JOIN KEY: x402 nonce == requestId
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(r.amount, 5 ether);
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Settled));
        assertEq(yuan.balanceOf(payee), 5 ether);

        // getReceiptsByPayer round trip
        bytes32[] memory rids = x402.getReceiptsByPayer(payer);
        assertEq(rids.length, 1);
        assertEq(rids[0], rid);

        // getDelegatedSpendSnapshot round trip
        (address del, uint256 spentTotal, uint256 spentPeriod, uint256 reqCount,,) =
            x402.getDelegatedSpendSnapshot(policyId);
        assertEq(del, payer);
        assertEq(spentTotal, 5 ether);
        assertEq(spentPeriod, 5 ether);
        assertEq(reqCount, 1);
    }

    // ---- 2. external rail (Nano): receipt recorded, stays Pending, no on-chain move ----
    function test_SettleExact_ExternalRail_Nano_Pending() public {
        vm.prank(facilitator);
        bytes32 rid = adapter.settleExact(_payload(address(0)), routeHash, payloadHash, policyId);

        L5x402.PaymentReceipt memory r = x402.getReceipt(rid);
        assertEq(r.requestId, nonce); // join key still present
        assertEq(uint8(r.status), uint8(L5x402.ReceiptStatus.Pending));
        assertEq(r.token, adapter.externalAsset()); // recorded against the marker
        assertEq(yuan.balanceOf(payee), 0); // nothing moved on-chain

        // receipt is still discoverable by payer/payee
        bytes32[] memory rids = x402.getReceiptsByPayer(payer);
        assertEq(rids.length, 1);
        assertEq(rids[0], rid);
        bytes32[] memory prids = x402.getReceiptsByPayee(payee);
        assertEq(prids.length, 1);
        assertEq(prids[0], rid);

        // honest: off-chain value is NOT counted as on-chain spend
        (, uint256 spentTotal,,,,) = x402.getDelegatedSpendSnapshot(policyId);
        assertEq(spentTotal, 0);
    }

    // ---- 3. only a registered facilitator may settle ----
    function test_SettleExact_OnlyFacilitator() public {
        vm.expectRevert(abi.encodeWithSelector(X402FacilitatorAdapter.NotFacilitator.selector, address(this)));
        adapter.settleExact(_payload(address(yuan)), routeHash, payloadHash, policyId);
    }

    // ---- 4. malformed payload rejected (zero nonce -> no join key) ----
    function test_SettleExact_RejectsBadPayload() public {
        X402FacilitatorAdapter.ExactPayload memory p = _payload(address(yuan));
        p.nonce = bytes32(0);
        vm.prank(facilitator);
        vm.expectRevert(X402FacilitatorAdapter.BadPayload.selector);
        adapter.settleExact(p, routeHash, payloadHash, policyId);
    }
}
