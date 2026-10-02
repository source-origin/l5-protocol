// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/L5x402.sol";

/// @notice Reproduces the JCS<->EIP-712 bridge fixture emitted for EMILIA
///   (workspace/_bridge/bridge_fixture.json) against the real L5x402 contract.
///
///   The address-free part of the EIP-712 digest is the struct hash; that is the
///   piece comparable to Python byte-for-byte. We assert:
///     (1) struct hash computed here == struct hash computed in Python,
///     (2) the contract's actionDigest == keccak("\x19\x01" || its domain || structHash).
contract BridgeFixtureTest is Test {
    L5x402 x402;

    // ---- published field set (identical to _bridge/bridge_fixture.json) ----
    bytes32 constant REQ = 0x1111111111111111111111111111111111111111111111111111111111111111;
    address constant PAYER = 0x1111111111111111111111111111111111111111;
    address constant PAYEE = 0x2222222222222222222222222222222222222222;
    address constant TOKEN = 0x3333333333333333333333333333333333333333;
    uint256 constant AMOUNT = 1000000;
    bytes32 constant ROUTE_HASH = 0x9b5215b2f5a871587ede9f445b7fcb0cd711917bd25ae426960bb280e5092550;
    bytes32 constant PAYLOAD_HASH = 0x46286e2ec0c2f8823daec9bbcce80d03dd88231e9217fb8fb597814795192233;
    bytes32 constant PERM_HASH = 0x5555555555555555555555555555555555555555555555555555555555555555;
    uint256 constant DEADLINE = 1799999999;

    // ---- Python-computed expectation (address-independent) ----
    bytes32 constant PY_STRUCT_HASH = 0x17af7f2655d8faf85f5d31d2a0cfaa22e93e6a8ad4a805226683b6f3c9b71493;

    function setUp() public {
        vm.chainId(1);
        x402 = new L5x402();
    }

    /// (1) Solidity-recomputed struct hash == Python struct hash.
    function test_StructHash_PythonSolidity_Match() public pure {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PaymentAction(bytes32 requestId,address payer,address payee,address token,uint256 amount,bytes32 routeHash,bytes32 payloadHash,bytes32 permissionHash,uint256 deadline)"
                ),
                REQ,
                PAYER,
                PAYEE,
                TOKEN,
                AMOUNT,
                ROUTE_HASH,
                PAYLOAD_HASH,
                PERM_HASH,
                DEADLINE
            )
        );
        assertEq(structHash, PY_STRUCT_HASH, "struct hash must match Python fixture");
    }

    /// (2) Contract actionDigest == EIP-712 over (its domain, that struct hash).
    function test_ActionDigest_Wraps_StructHash() public view {
        bytes32 structHash = keccak256(
            abi.encode(
                x402.PAYMENT_ACTION_TYPEHASH(),
                REQ,
                PAYER,
                PAYEE,
                TOKEN,
                AMOUNT,
                ROUTE_HASH,
                PAYLOAD_HASH,
                PERM_HASH,
                DEADLINE
            )
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", x402.DOMAIN_SEPARATOR(), structHash));
        bytes32 actual =
            x402.actionDigest(REQ, PAYER, PAYEE, TOKEN, AMOUNT, ROUTE_HASH, PAYLOAD_HASH, PERM_HASH, DEADLINE);
        assertEq(actual, expected, "actionDigest must be EIP-712 over enumerated fields");
    }

    /// (3) The full enumeration is load-bearing: mutating any single field changes
    ///     the digest (mirrors the off-chain mutation probe).
    function test_AnyFieldMutation_Changes_Digest() public view {
        bytes32 baseD =
            x402.actionDigest(REQ, PAYER, PAYEE, TOKEN, AMOUNT, ROUTE_HASH, PAYLOAD_HASH, PERM_HASH, DEADLINE);
        assertTrue(
            baseD
                != x402.actionDigest(
                    REQ, PAYER, PAYEE, TOKEN, AMOUNT + 1, ROUTE_HASH, PAYLOAD_HASH, PERM_HASH, DEADLINE
                ),
            "amount"
        );
        assertTrue(
            baseD
                != x402.actionDigest(
                    REQ, PAYER, PAYEE, TOKEN, AMOUNT, ROUTE_HASH, PAYLOAD_HASH, PERM_HASH, DEADLINE + 1
                ),
            "deadline"
        );
        assertTrue(
            baseD
                != x402.actionDigest(
                    REQ,
                    PAYER,
                    PAYEE,
                    TOKEN,
                    AMOUNT,
                    ROUTE_HASH,
                    bytes32(uint256(PAYLOAD_HASH) ^ 1),
                    PERM_HASH,
                    DEADLINE
                ),
            "payloadHash"
        );
        assertTrue(
            baseD
                != x402.actionDigest(
                    REQ,
                    PAYER,
                    PAYEE,
                    TOKEN,
                    AMOUNT,
                    ROUTE_HASH,
                    PAYLOAD_HASH,
                    bytes32(uint256(PERM_HASH) ^ 1),
                    DEADLINE
                ),
            "permissionHash"
        );
    }
}
