# SPEC · Attested Escrow (v1 draft)

**Status:** draft, for review. No code in this document and no code written yet.
**Target contract:** `src/AgentEscrow.sol`
**Reviewers asked:** NSPG13 (`agent-bounties#1478`), Ali (Arbitra `#56`)
**Date:** 2026-10-26

---

## 0. One paragraph

Today `verifyDelivery()` accepts `bytes proofOfDelivery` from the payee and stores
it. Nothing verifies it, nothing binds it to the escrow or the chain, and nothing
can be re-checked later without trusting our own log. This spec replaces
"payee says it delivered" with **a signed, canonical, third-party-recomputable
attestation bundle**, and it states precisely what each attestation does and does
not prove — in particular that **a timeout is a contract-state fact, never a
non-delivery claim**.

---

## 1. What this must fix (the two reviews, restated as requirements)

| # | Requirement | Source | Where it is met |
| --- | --- | --- | --- |
| R1 | A signature must cover the **evidence set**, not a prose blob | Ali (#56) | §4, §6, §7 |
| R2 | The signed preimage must be **byte-recomputable by a third party** (JCS, UTF-8, fixed comparator, no floats) | Ali (#56) | §5 |
| R3 | `EscrowTimeout` must not be readable as "no delivery happened" | NSPG13 (#1478, C8) | §9, §10 |
| R4 | Any verdict the system emits must be **no stronger than its evidence** | NSPG13 (matrix rules) | §9 |
| R5 | A valid attestation for one escrow/chain/purpose must not be replayable elsewhere | this spec | §7, §11 |

Non-goals, stated so they are not assumed later: this does not prove that a
real-world delivery occurred. It proves **who asserted what, over which exact
bytes, under which binding**. That is the whole product.

---

## 2. Trust boundary in one table

| Artifact | Who produces it | What it is worth |
| --- | --- | --- |
| `EscrowTimeout` event | the contract | deadline passed while `Funded`. Nothing about the world. |
| `delivery` attestation by `provider` | payee | the payee's own assertion. Self-serving. Unlocks the release *option*, never the funds. |
| `delivery` attestation by `evaluator` / `sensor` | allowlisted third party | an independent assertion over `deliverableHash` + `rubricHash`. |
| `acceptance` by `consumer` | payer | the payer's own assertion. Equivalent to `release()` intent. |
| `non-delivery` by `provider` | payee | an admission against interest. Strong. |
| `non-delivery` by `notary` / `sensor`+`consumer` | independent | strong, threshold below. |
| prose, notes, README, chat | anyone | **nothing. unsigned. marked unverified.** |

The rule that keeps us honest: **an attestation never moves the strength of a
claim beyond its own row in this table.**

---

## 3. Objects

```
attestation bundle   the signed JSON document (§4), canonicalized per §5
bundleDigest         keccak256(UTF-8 bytes of the canonical JSON)          = 32 bytes
evidenceRoot         keccak256 of the ordered per-item evidence hashes (§6)
attestationDigest    EIP-712 digest over the typed struct (§7)
attestation          the on-chain record: {digest, purpose, attestor, evidenceRoot, timestamp}
```

Off-chain the bundle travels as a file. On-chain only two 32-byte values travel:
`bundleDigest` and `evidenceRoot`, plus the raw `evidence[]` for on-chain root
recomputation. The full JSON never goes on-chain.

---

## 4. The signed bundle (exact field set)

Top-level keys, all ASCII, no others permitted. Unknown fields are a **hard
reject**, not an extension point — extension is `schema` version + new spec.

| Field | Type | Rule |
| --- | --- | --- |
| `schema` | string | exactly `"origin.l5.attested-escrow/1"` |
| `escrowId` | `0x` + 64 hex | lowercase hex, must equal the escrow being attested |
| `purpose` | string | one of §9's purposes |
| `attestor` | object | `{id, keyFamily, role}` — `id` = `0x`+40 hex, `keyFamily` = `"secp256k1"` (v1), `role` = §6 enum |
| `escrow` | object | `{agreementId, payer, payee, amount, deadline}` copied from chain state |
| `hashes` | object | `{deliverableHash, rubricHash, evaluationPromptHash, rawResponseHash}` — required keys, `0x`+64 hex, `0x00…0` allowed only where §9 permits |
| `evidence` | array | 0–32 items, each `{role, alg, digest}`, **sorted, strictly increasing** (§6) |
| `timestamp` | integer | attestor's clock, seconds, `< 2^53`. Advisory: the chain timestamp is authoritative. |

`escrow.amount` is a **decimal string** (`"1000000000000000000"`), never a JSON
number: ECMAScript cannot hold a `uint256` in a number, and the two sides would
diverge at >2^53. This is the §4.2 rule Ali asked us to pin.

There is no `notes`, `comment`, `reason_text`, or free-form field. Prose goes in
a **separate file** and is never signed (§8).

---

## 5. Canonicalization (RFC 8785 JCS, narrowed to a decidable subset)

The preimage is the UTF-8 bytes of the canonical JSON. Rules:

1. **No whitespace.** `{"a":1}` not `{"a": 1}`.
2. **Object keys sorted ascending.** Comparator: **bytewise over ASCII**. The
   schema forbids non-ASCII keys, which removes the `localeCompare` vs codepoint
   divergence entirely instead of trying to referee it.
3. **Integers only**, plain decimal, no `+`, no leading zeros, no `-0`, range
   `0 .. 2^53-1`. Booleans are `true`/`false`.
4. **Floats are forbidden.** A parser that sees `1.0`, `1e21`, or `NaN` must
   reject the bundle. A quantity that can exceed `2^53` is a decimal **string**.
5. **`null` is forbidden.** Absent data is an absent key, never `null`.
6. **Arrays keep their declared order.** No sorting by the canonicalizer.
7. **Strings** are JSON-escaped per RFC 8785 (short escapes, control chars as
   `\u00XX`), literal UTF-8 otherwise.
8. `bundleDigest = keccak256(canonicalBytes)`. Nothing else may be prepended,
   appended, or length-prefixed.

A canonicalizer that follows these rules is the only thing both sides need to
share; it is ~40 lines in any language.

---

## 6. Evidence model

### 6.1 Item

```
{"role": "<role>", "alg": "<alg>", "digest": "0x<64 hex>"}
```

### 6.2 Roles (closed enum, v1)

| Role | Meaning |
| --- | --- |
| `outcome` | the delivered artifact itself (file, model output, robot trajectory) |
| `binding` | the link between the deliverable and the request (`requestId`, job id) |
| `raw-response` | unmodified upstream response bytes |
| `evaluation-transcript` | evaluator's full transcript, pre-verdict |
| `rubric-verdict` | scored verdict against `rubricHash` |
| `sensor-trace` | physical/telemetry log root (video chain, joint states, task log) |
| `claim-inclusion` | proof that a delivery claim exists in a log the payer cannot filter |
| `notary-attestation` | a notary's signed statement over the above |
| `provider-declaration` | the payee's own declaration of non-delivery |

### 6.3 Algorithms (closed enum, v1)

`keccak256`, `sha256`. Anything else is rejected. A verifier that does not
support an `alg` must reject the bundle, not skip the item.

### 6.4 Root

```
itemHash_i   = keccak256( roleId || algId || digest )      // 3 × 32 bytes
              roleId  = keccak256(utf8(role))
              algId   = keccak256(utf8(alg))
evidenceRoot = keccak256( itemHash_0 || itemHash_1 || … )
```

### 6.5 Ordering and identity (this is R1's teeth)

- Items MUST be sorted by `role` ascending, ties broken by `digest` ascending,
  both **bytewise**. The contract does not sort: it walks the supplied array and
  **reverts unless the sequence is strictly increasing**. Cheaper, and it makes
  the on-chain order identical to the signed order by construction.
- Duplicate `(role, digest)` pairs are therefore impossible: they fail the
  strict-increase check.
- `evidenceRoot` is order-sensitive on purpose. Two bundles with the same items
  in different order are two different bundles, and one of them is invalid (§6.5).
- Empty `evidence` is allowed **only** for `purpose = "acceptance"` and
  `"refund-request"` (both are single-party assertions about intent, not about
  the world).

The contract recomputes `evidenceRoot` from the supplied items. This is the part
that makes "the signature covers the evidence" true on-chain rather than only in
a document.

---

## 7. Signature

### 7.1 Typed struct (EIP-712)

```solidity
AttestedDelivery(
  bytes32 escrowId,
  bytes32 purpose,               // keccak256(utf8(purpose))
  bytes32 schemaVersion,         // keccak256("origin.l5.attested-escrow/1")
  bytes32 bundleDigest,
  bytes32 evidenceRoot,
  bytes32 deliverableHash,
  bytes32 rubricHash,
  bytes32 evaluationPromptHash,
  bytes32 rawResponseHash
)
```

Domain: `name = "ORIGIN L5 AgentEscrow"`, `version = "1"`, `chainId`,
`verifyingContract = address(this)`. Reusing the existing domain separator.

`attestationDigest` = `keccak256(0x1901 ‖ domainSeparator ‖ structHash)`.

### 7.2 Coverage proof (mapped to the reviews)

| What must be bound | Bound by | Recomputable by |
| --- | --- | --- |
| chain id | domain separator | anyone, from `chainId` |
| verifying contract | domain separator | anyone, from the address |
| schema version | `schemaVersion` | constant |
| purpose | `purpose` | constant |
| this escrow | `escrowId` | chain state |
| the exact JSON document | `bundleDigest` | anyone holding the file |
| the evidence set | `evidenceRoot` (contract recomputes) | anyone holding the file |
| deliverable / rubric / prompt / raw output | four hashes, directly | anyone holding the file |

Nothing material is outside. If a field is not in this table, it is either in the
bundle (and therefore in `bundleDigest`) or it is prose (§8).

### 7.3 Key families

v1 verifies **secp256k1 only**, via `ECDSA.tryRecover` with the existing low-s
enforcement. A non-EVM adjudicator (P256, e.g. Arbitra) does not sign this
struct; it produces a **verdict digest** that enters as
`verdictRef` / `purpose = "rubric-verdict"` evidence and is trusted at the
boundary where P256 is native. We do not pretend to verify P256 on the EVM.

---

## 8. What is deliberately outside the signature

- Human prose, rationale, links, screenshots: **outside**, in `notes.md`, served
  next to the bundle and labelled `unverified` in any UI that renders it.
- Attestor metadata not in the bundle (name, org, PGP key): outside. Only `id`
  and `role` are signed.
- Chain timestamp, block number, tx hash: outside the bundle because the chain
  supplies them; they are the anchor, not the claim.

Rule for readers: **if it is not in the bundle, it is not evidence.** A document
that says "see attached explanation" is a pointer to unverified material, and we
label it as such rather than letting the pointer borrow the signature's weight.

---

## 9. Purposes, and the strongest claim each one supports

Funds move only through the existing state machine; attestations change *what is
provable*, not *who can call what* except where listed.

| Purpose | Allowed roles | Strongest claim it supports | Funds effect |
| --- | --- | --- | --- |
| `delivery` | provider, evaluator, sensor | *"deliverableHash was produced for this escrow"* — the attestor's assertion, not proof | `Funded → Verified`; release still payer-only unless auto-release opted in (§10.3) |
| `partial-delivery` | provider, evaluator | *"some deliverable exists and does not match the committed hash/quantity"* | `Disputed`; arbiter path |
| `rubric-verdict` | evaluator | *"deliverable scores X against rubricHash"* | `Verified` + `verdictRef`; release eligibility |
| `non-delivery` | provider, notary, sensor(+consumer) | *"nothing was delivered"* — **admission** if provider, **evidence** if independent | refund to payer **before** deadline, once threshold met |
| `acceptance` | consumer | *"the payer accepts"* — intent only | equivalent to `release()` |
| `refund-request` | consumer | *"the payer asks for a refund"* — intent only | does not move funds; opens dispute |

### 9.1 Non-delivery thresholds

| Evidence set | Verdict |
| --- | --- |
| `provider-declaration` signed by payee | supported — an admission against interest |
| `notary-attestation` signed by allowlisted notary | supported |
| `sensor-trace` + `outcome`/`claim-inclusion` from two independent attestors | supported |
| `buyer-observation` alone (consumer's own statement) | **insufficient** — this is the "customer says it never came" case |
| nothing but a timeout | **indistinguishable** (§10) |

---

## 10. The timeout question (R3, answered without hand-waving)

### 10.1 Timeout stays what it is

`EscrowTimeout` keeps its current meaning: *the deadline passed while the escrow
was `Funded`*. It is emitted with `reasonCode = TIMEOUT`. It is **never**
translated into `non-delivery` anywhere in the settlement record, the audit log,
or the UI copy.

### 10.2 The two worlds that produce the same log

- provider never claimed delivery;
- provider claimed delivery and the claim was withheld from us.

Both look identical on-chain. C8 stays `indistinguishable` — permanently, until
the evidence type changes (a signed non-delivery attestation, or a
claim-inclusion proof over a log the payer cannot filter). Writing a better
description does not close it. The two exits:

1. **`non-delivery` attestation** (§9) → refund early, claim supported.
2. **`claim-inclusion` evidence** → the withheld world collapses: either the
   claim exists (and the payer can see it), or it provably does not.

### 10.3 Auto-release, if an agreement opts in

Opt-in only, declared in the agreement, not a default: after a `delivery`
attestation with `purpose = delivery` and non-zero `rubricHash`, a challenge
window of `N` blocks (default 0 = off) must elapse before `ReleaseEligible`.
The payer can still `dispute()` inside the window. Without the opt-in, nothing
changes: the payer releases.

---

## 11. Replay, supersession, revocation

- **Cross-escrow / cross-chain / cross-purpose replay**: impossible by
  construction — `escrowId`, `purpose`, `chainId`, `verifyingContract` are all in
  the preimage.
- **Same-bundle replay**: a bundle is stored once as
  `attestations[attestationDigest]`. A second submission with identical bytes is
  a no-op (idempotent), not an error, so retries are safe. A second submission
  with different bytes is a new attestation and must carry a strictly greater
  `timestamp` for the same `(escrowId, purpose, attestor)` pair; otherwise revert
  `Attestation: stale`.
- **Supersession, not revocation**: attestations are immutable and append-only.
  A later attestation supersedes a former one by `timestamp`; the record keeps
  both. There is no delete path, because "signed then unsigned" is exactly the
  ambiguity we are removing.
- **Attestor set is frozen** at the moment the escrow leaves `Funded`. Changing
  the notary after the dispute starts would make every prior attestation
  unverifiable in context.

---

## 12. Test vectors (frozen; check these before agreeing to anything)

Bundle (canonical JSON, 1252 bytes):

```json
{"attestor":{"id":"0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1","keyFamily":"secp256k1","role":"provider"},"escrow":{"agreementId":"0x2222222222222222222222222222222222222222222222222222222222222222","amount":"1000000000000000000","deadline":1767225600,"payee":"0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1","payer":"0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"},"escrowId":"0x1111111111111111111111111111111111111111111111111111111111111111","evidence":[{"alg":"sha256","digest":"0x7777777777777777777777777777777777777777777777777777777777777777","role":"evaluation-transcript"},{"alg":"sha256","digest":"0x8888888888888888888888888888888888888888888888888888888888888888","role":"outcome"},{"alg":"keccak256","digest":"0x9999999999999999999999999999999999999999999999999999999999999999","role":"raw-response"}],"hashes":{"deliverableHash":"0x3333333333333333333333333333333333333333333333333333333333333333","evaluationPromptHash":"0x4444444444444444444444444444444444444444444444444444444444444444","rawResponseHash":"0x5555555555555555555555555555555555555555555555555555555555555555","rubricHash":"0x6666666666666666666666666666666666666666666666666666666666666666"},"purpose":"delivery","schema":"origin.l5.attested-escrow/1","timestamp":1767226000}
```

Derived values:

```
bundleDigest      0xa85744aff1411844d3712e2d95a22a92ceab49b073920ec4520cd9d6b18c5e19
evidenceRoot      0x34aaa28bea4a45661972b9f60634190430d1628d26e76fc16ae80e7a1c84a63f
  item 0xf47c2a3e5c0e5afa5d4103ac3df8b890ca66ee14f420d0ca034edec905b1f2f5  evaluation-transcript
  item 0x9d97cc037fc711fc839f3459b0b57d15b813be43b66055ce8fb4ffc480cb3d0d  outcome
  item 0x404fbbf9b12272a32c0269a4ffc5d31c9e53cb02590f8517eea4b8cb631aaf3d  raw-response

domain separator  0xe754e71b6552e62e7ad4dca1cae200f4942f845c83c5bd4bf0634a7ee917c0f8
  (chainId 11155111, verifyingContract 0x0000000000000000000000000000000000000001 — a vector, not a deployment)
struct hash       0xb7b6f5d20669eb6140483814dfe3cbcd1fccd06cf6f3e2b6c8ac6af742b0707e
attestationDigest 0xcf8c8296a928b4480323005d5e63115acc7b37d1858ceaf0c75519465f24ea79
```

Negative vectors (each must fail differently, not silently agree):

```
reordered evidence[]  -> evidenceRoot 0x3b859804498f0ed319a83a6cf2e9da4a0daedebce655719b927fe17300617539  (≠ root)
one digest byte changed -> bundleDigest 0x9f00cb8faa88b12f9d8ae52edfc91ec3e0c84417b2971160dfabac3b769bfaaf  (≠ bundleDigest)
```

Reproduce by hand: canonicalize the JSON per §5, `keccak256` the UTF-8 bytes,
compare. If your number differs, the canonical form is not yet shared and the
interop is not real.

---

## 13. Contract deltas this spec requires (shape only, no code yet)

1. `attest(...)` — new entry point. Arguments: the nine struct words, `evidence[]
   (roleId, algId, digest)`, `signature`. Steps, in order:
   validate purpose enum → validate schema constant → recompute `evidenceRoot`
   from the strictly-increasing item list and compare → recompute
   `attestationDigest` → recover signer → check role→address binding → check
   `bundleDigest` not already recorded with different bytes → write record → emit
   `Attested(escrowId, purpose, attestor, attestationDigest, evidenceRoot)`.
2. `verifyDelivery()` — kept for one release cycle as
   `verifyDeliveryLegacy()`, marked deprecated, and it must emit a
   `LegacyUnattestedProof` event so nobody can later mistake an unverified proof
   for an attested one. Removed in v2.
3. Escrow struct gains `attestors[]` (allowlist for evaluator/notary/sensor),
   set by the payer at `createAndFund`, frozen once the escrow leaves `Funded`.
4. Purpose gates on state transitions per §9, with `reasonCode` on every terminal
   event: `RELEASED`, `REFUNDED_CANCELLED`, `REFUNDED_TIMEOUT`,
   `REFUNDED_NON_DELIVERY`, `DISPUTED`, `RESOLVED`.
5. `non-delivery` attestation satisfying §9.1 permits `refund()` **before** the
   deadline, payer-only. Timeout refund stays permissionless and unchanged.
6. `settle()` stays as fixed (internal `_release`), covered by
   `TimeoutReleaseDoubleSpend.t.sol`.

---

## 14. Falsifiable claims about this spec

1. Any two independent JCS implementations produce the same `bundleDigest` for
   the §12 vector. (Run it; it is the cheapest test in the document.)
2. No field outside §7.2 can change the funds outcome. (Audit the struct: nine
   words.)
3. `EscrowTimeout` never appears with `reasonCode` other than `TIMEOUT` in any
   emitted event or derived record. (Grep the contract and the checker.)
4. The checker rejects an unsorted `evidence[]` before it reaches a signature
   check. (Feed it the negative vector.)
5. `non-delivery` with a consumer-only attestation is rejected. (One test.)

If any of these is false, the spec is wrong and should be fixed here, not in code.

---

## 15. Open questions for the reviewers

1. **NSPG13** — is `provider-declaration` (admission against interest) an
   acceptable 1-of-1 for early refund, or do you want a notary second signature
   even when the payee admits non-delivery? Our current answer: 1-of-1, because
   admitting non-delivery is against the admitter's interest.
2. **NSPG13** — should `claim-inclusion` be a v1 role, or does it belong to the
   log/liveness layer above escrow? It is the only role that actually closes C8.
3. **Ali** — we pinned: ASCII-only keys (kills `localeCompare` divergence),
   integers < 2^53 as numbers, everything larger as decimal strings, arrays
   order-sensitive. Confirm or object; a test vector is in §12 either way.
4. **Ali** — does the P256 verdict need the `evidence[]` array inline in the
   verdict JSON, or is `evidenceRoot` enough for your verifier? We sign the root;
   the array is in the bundle beside it.

---

*— 源 / ORIGIN · L5 · draft for adversarial review, not a commitment*
