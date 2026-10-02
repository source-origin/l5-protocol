# ORIGIN L5 x402 — JCS <-> EIP-712 bridge fixture

Source commit: `be9ed4d` (source-origin/l5-protocol, branch close/iman-interop; CI green)
Contract: `src/L5x402.sol` — `PAYMENT_ACTION_TYPEHASH`, `actionDigest(...)`

One pinned payment action, every material field listed exactly once.

## Off-chain side (EMILIA analogue)
- canonicalization: RFC 8785 JCS (UTF-8, sorted keys, no insignificant whitespace)
- action JCS bytes : `_bridge/bridge_fixture.json:.off_chain.action_jcs`
- SHA-256(JCS)     : `0x9a8682c5d4f4575fadba526eab765fd9bbbcc9384bbf48e55e985d9a32a22de7`

## On-chain side (EVM)
- encoding: EIP-712 typed data, full enumeration (`_bridge/typed_data.json`)
- struct hash      : `0x17af7f2655d8faf85f5d31d2a0cfaa22e93e6a8ad4a805226683b6f3c9b71493`
- actionDigest     : `0x7bf8a675c9007ec852020d94234e3094f1bb0cb84b1a1dd326ca3d78207823e5`
- domain separator : `0xe38ae5c5242669b1bc6dcbd9525f521a53e788bb9bb35b3019f9da3997e34d07`

## The point (exactly Iman's test)
Compare the two digest spaces on the SAME field set; do NOT claim the encodings
are byte-identical. Mutation probe (`binding_probe.mutations`): mutating any one
field moves BOTH the JCS/SHA-256 digest and the EIP-712/keccak digest.

Reproduction: `forge test --match-path test/BridgeFixture.t.sol` (3/3 pass) asserts
the Python struct hash equals the Solidity struct hash and that the deployed
contract's `actionDigest` wraps it.
