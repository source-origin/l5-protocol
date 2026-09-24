// SPDX-License-Identifier: ORIGIN-1.0
// ===========================================================
// ORIGIN L5 - X402FacilitatorAdapter.sol
// x402 -> L5x402 facilitator adapter (minimal)
// Author: 量子总督 (Quantum Governor) - 2026-09-22
// Version: v0.1-x402-facilitator-adapter
// Spec: docs/INTEROP-x402.md section 6.2 (minimal facilitator adapter)
// ===========================================================
//
// Purpose: take an x402 `exact`-scheme payment payload and land it as an
// L5x402 PaymentReceipt, WITHOUT requiring the rail to be EVM-native.
//
// The join key is the x402 `nonce`: the adapter writes it as the L5x402
// `requestId`, so the two ledgers (rail A: the settlement ledger; rail B:
// origin-1) share exactly one key a third party can join on.
//
// Two asset shapes are handled:
//   * asset != address(0): an on-chain token (e.g. a bridged representation).
//     If the payer has approved this adapter's L5x402, the receipt settles.
//   * asset == address(0): an EXTERNAL rail (e.g. Nano/XNO settled off-chain).
//     The receipt is recorded against an `ExternalAssetMarker` whose
//     allowance() is always 0, so nothing moves on-chain and the receipt stays
//     Pending. The value movement lives on the other ledger; origin-1 records
//     the evidence and the join key. This is the dual-ledger case.
//
// This adapter is intentionally thin: it maps fields and delegates storage to
// L5x402. It does not custody funds, and it does not verify the rail's tx.

pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal surface of L5x402 this adapter needs.
interface IL5x402Record {
    function recordReceipt(
        bytes32 _requestId,
        address _payer,
        address _payee,
        address _token,
        uint256 _amount,
        bytes32 _routeHash,
        bytes32 _payloadHash,
        bytes32 _permissionHash
    ) external returns (bytes32 receiptId);
}

/// @notice Marker "asset" whose allowance() is always zero.
/// @dev Used for rails settled off-chain (e.g. Nano). Because allowance < amount,
///      L5x402.recordReceipt will NOT attempt a transfer and the receipt stays
///      Pending - which is the honest state: value moved on another ledger.
contract ExternalAssetMarker {
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @title X402FacilitatorAdapter
/// @notice Maps an x402 `exact` payload to an L5x402 receipt.
contract X402FacilitatorAdapter is Ownable {
    /// @notice The subset of the x402 `exact` payload this adapter consumes.
    /// @dev Field names mirror the x402 authorization object so the mapping in
    ///      docs/INTEROP-x402.md can be followed line by line.
    struct ExactPayload {
        address from; // x402 authorization.from  -> L5x402 payer
        address to; // x402 authorization.to    -> L5x402 payee
        address asset; // on-chain token address; address(0) = external rail (Nano)
        uint256 value; // x402 authorization.value -> L5x402 amount
        bytes32 nonce; // x402 authorization.nonce -> L5x402 requestId (the join key)
    }

    /// @notice The L5x402 receipt/accounting layer this adapter writes into.
    address public l5x402;

    /// @notice Marker asset used when the rail is external (asset == address(0)).
    address public immutable externalAsset;

    /// @notice Registered facilitators allowed to settle. In x402 the facilitator
    ///         is the trusted settlement caller; we make that explicit.
    mapping(address => bool) public facilitators;

    event ExactRecorded(
        bytes32 indexed receiptId, bytes32 indexed nonce, address indexed from, address to, address asset, uint256 value
    );
    event FacilitatorSet(address indexed facilitator, bool allowed);
    event L5x402Set(address indexed l5x402);

    error NotFacilitator(address caller);
    error BadPayload();

    constructor(address _l5x402) Ownable(msg.sender) {
        l5x402 = _l5x402;
        externalAsset = address(new ExternalAssetMarker());
    }

    // ---- admin ----

    function setFacilitator(address f, bool allowed) external onlyOwner {
        facilitators[f] = allowed;
        emit FacilitatorSet(f, allowed);
    }

    function setL5x402(address a) external onlyOwner {
        l5x402 = a;
        emit L5x402Set(a);
    }

    // ---- core ----

    /// @notice Map an x402 `exact` payload to an L5x402 receipt.
    /// @param p              the x402 exact payload subset
    /// @param routeHash      resource/route hash (-> L5x402 route)
    /// @param payloadHash    hash of the request params the 402 was issued for
    /// @param permissionHash L5Delegation policy hash (spend authority)
    /// @return receiptId     deterministic id derived by L5x402
    function settleExact(ExactPayload calldata p, bytes32 routeHash, bytes32 payloadHash, bytes32 permissionHash)
        external
        returns (bytes32 receiptId)
    {
        if (!facilitators[msg.sender]) revert NotFacilitator(msg.sender);
        if (p.from == address(0) || p.to == address(0) || p.value == 0 || p.nonce == bytes32(0)) revert BadPayload();

        address token = p.asset == address(0) ? externalAsset : p.asset;

        receiptId = IL5x402Record(l5x402)
            .recordReceipt(p.nonce, p.from, p.to, token, p.value, routeHash, payloadHash, permissionHash);

        emit ExactRecorded(receiptId, p.nonce, p.from, p.to, token, p.value);
    }
}
