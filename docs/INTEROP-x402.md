# x402 ⇄ ORIGIN L5 · Interop Mapping & Divergence Report

> Status: **design note, research-grade.** Written to answer one question honestly:
> *if an x402 payment (exact scheme, any rail — Nano included) is settled off-chain, how does it land in `L5x402.sol`, and what is the exact, minimal proof that both ledgers refer to the same payment?*

This is a mapping and a divergence report — **not** a claim that the two are the same thing. Where they differ, it says so.

---

## 1. The two objects

**x402 `exact` payment payload** (canonical shape; rail-agnostic at the HTTP layer):

```jsonc
{
  "x402Version": 1,
  "scheme": "exact",
  "network": "base | nano | …",
  "payload": {
    "signature": "0x…",
    "authorization": {
      "from": "0x…",          // payer
      "to": "0x…",            // payee
      "value": "…",           // amount
      "validAfter": 0,
      "validBefore": 1700000000,
      "nonce": "0x…"
    }
  }
}
```

**ORIGIN `L5x402.PaymentReceipt`** (on-chain, `origin-1`):

```solidity
struct PaymentReceipt {
    bytes32 receiptId;       // derived: keccak256(requestId, payer, payee, amount, payloadHash)
    bytes32 requestId;       // parent request
    address payer;
    address payee;
    address token;           // YUAN
    uint256 amount;
    uint256 chainId;         // origin-1
    string  route;           // resource
    bytes32 payloadHash;     // hash of the request params (signed evidence)
    bytes32 permissionHash;  // L5Delegation policy hash
    uint256 timestamp;
    ReceiptStatus status;
    bool    evidenceVerified;
}
```

---

## 2. Field-by-field mapping

| x402 `exact` | ORIGIN `L5x402` | Relationship |
|---|---|---|
| `x402Version` / `scheme` | — (not stored) | **Divergence D1.** Negotiated at the facilitator layer; not part of the on-chain receipt. |
| `network` | `chainId` | Same meaning, different encoding (string vs uint). Nano has no chainId — the facilitator maps `"nano"` → the origin-1 `chainId` it is recording into. |
| `authorization.from` | `payer` | **1:1.** |
| `authorization.to` | `payee` | **1:1.** |
| `authorization.value` | `amount` | **1:1** (unit conversion at the facilitator: XNO → YUAN is *not* 1:1 and must be an explicit, verifiable rate — see §4). |
| `authorization.nonce` | `requestId` | **Divergence D2.** x402's nonce is the replay key; ours is `requestId` + a derived `receiptId` duplicate-guard. The facilitator SHOULD set `nonce == requestId` so the two ledgers share one join key. |
| `authorization.validAfter` / `validBefore` | — (not stored) | **Divergence D3.** x402 has an authorization validity window; our receipt has `timestamp` + a `status` lifecycle (settled → disputed/refunded). Timeout/dispute is handled by escrow, not by the receipt. |
| `payload.signature` | `recordReceipt(...)` caller auth (EIP-712) **and** `evidenceVerified` (via `verifyReceiptEvidence`) | **Divergence D4.** Two distinct signatures, never conflated. (a) The **payer authorization** now travels with the call and is verified on-chain: the receipt is minted only if `ECDSA.recover(actionDigest(...)) == payer`, over a fully-enumerated EIP-712 action (see §7). (b) The **service-side evidence signature** is now a **domain-bound EIP-712 digest** (`receiptEvidenceDigest`, committing to `chainId` + verifying contract + `receiptId` + `payloadHash`), bound to the stored `payloadHash` with the signer pinned to the service of record — so it cannot be replayed cross-receipt or cross-chain (see §8, H3). |
| resource / route | `route` | **1:1** (with a caveat: `L5x402` currently stores `route` as a hash-derived string; see the contract's `_bytes32ToString`). |
| — | `payloadHash` | **ORIGIN addition.** Binds the receipt to the *request parameters*, not to an operator's claim. |
| — | `permissionHash` | **ORIGIN addition.** Binds the payment to an `L5Delegation` policy (spend authority). |
| — | `receiptId`, `status`, `evidenceVerified` | **ORIGIN additions.** Derived identity, lifecycle, evidence flag. |

**Net:** the money-moving fields (`from`/`to`/`value`) map 1:1. Everything ORIGIN adds is *evidence and authority* — what the payment was **for**, and **who was allowed** to spend it.

---

## 3. Divergences, stated plainly

- **D1 — no scheme/version on-chain.** By design: the chain records *facts*, not HTTP negotiation. If this becomes a problem for multi-scheme routing, add a `bytes32 schemeId` field.
- **D2 — nonce vs requestId.** Keep them identical at the facilitator. Diverging them makes the dual-ledger proof harder for no benefit.
- **D3 — no validity window on the receipt.** The receipt is a post-hoc fact; an authorization window is a pre-hoc constraint. Don't conflate them.
- **D4 — signature semantics differ.** Do **not** treat `evidenceVerified` as proof that funds moved; it proves *evidence was signed by the declared signer*. Fund movement is proven by the rail's settlement tx (§4).
- **D5 — value unit.** XNO and YUAN are different assets. Any mapping is a *statement of exchange*, and must be either (a) fixed by the payer in the request, or (b) produced by a verifiable rate — never silently assumed.

---

## 4. Minimal dual-ledger proof

**Claim:** *"this Nano settlement and this origin-1 receipt are the same payment."*

Cheapest sufficient proof — **one shared join key**:

1. **Rail A (Nano).** The payer's XNO transfer lands on the Nano ledger → tx hash `H_nano`. The transfer carries a memo / destination payload containing `requestId`.
2. **Rail B (origin-1).** The facilitator calls
   `recordReceipt(requestId, payer, payee, token, amount, routeHash, payloadHash, permissionHash)`
   which emits `ReceiptRecorded(receiptId, requestId, payer, payee, token, …)`.
3. **Join.** `requestId` (== the x402 `nonce`) appears in **both** ledgers. `receiptId` is deterministically derived from it.

A third-party verifier, trusting neither party, checks:

- `H_nano` exists with a memo == `requestId`; **and**
- `ReceiptRecorded` exists on origin-1 with the same `requestId`, and `payer`/`payee`/`amount` match the x402 authorization; **and**
- `payloadHash` on the receipt equals `hash(the exact request/response the 402 was issued for)`.

Round-trip reads to assert this (client-side, no chain trust):
`getReceiptsByPayer(payer)`, `getReceiptsByPayee(payee)`, `getDelegatedSpendSnapshot(policyId)`.
These three reads are asserted end-to-end (with a facilitator adapter) in `test/L5x402Adapter.t.sol`.

### What this proof does NOT establish (boundary rule)

Per the three-stage chain (`docs/CONTRIBUTION-SPEC.md`) — *each artifact declares only what it can prove, then stops*:

- It does **not** prove the service was delivered. That is the **evidence signature** (`verifyReceiptEvidence`) — and even that only proves *the declared signer signed a digest*, not that the digest describes reality. That is an **observation** (what was seen, how, the denominator, what could not be seen), not a verdict.
- It does **not** prove the Nano tx is final beyond its confirmation depth.
- It does **not** prove the XNO→YUAN rate was fair (D5) — only that whatever rate was used is recorded and checkable.

**Provisional finality.** A receipt whose service claim is still disputable is `provisionally final, subject to verdict`: it never claims a finality it does not have. Post-hoc adjudication **back-references** the receipt; a receipt never cites a verdict that did not yet exist.

---

## 5. The honest seam

`L5x402.sol` currently has an `onlyAdmin` path for `disputeReceipt` / `refundReceipt` / `updateSnapshot` wiring. This is **adjudication, not custody**:

- a refund moves funds *to the payer* under a policy the payer authorized (allowance), not to an operator;
- escrow timeout returns funds to the funder;
- **but** the single key is a real seam. The roadmap is to move adjudication off the admin key onto a decentralized arbiter (contribution clock / court), so **no single key sits on the fund path**.

We would rather show you that seam than have you find it.

---

## 6. What we'd like to build together

1. **This mapping, agreed line by line** (the doc you're reading).
2. **A minimal facilitator adapter** — a Nano-settled 402 that calls `recordReceipt(...)` and asserts the round-trip (`getReceiptsByPayer` / `getDelegatedSpendSnapshot`) against the Foundry suite. **Shipped (2026-09-22; hardened 2026-09-25):** `src/X402FacilitatorAdapter.sol` + `test/L5x402Adapter.t.sol` — the payload now carries the payer's `deadline` + `authorization` signature, and the adapter is a thin pass-through (L5x402 is the only place that validates/consumes the authorization). Foundry suite now **79/79 green**. Run: `forge test --match-path test/L5x402Adapter.t.sol`. The adapter writes the x402 `nonce` as the L5x402 `requestId` (the shared join key); for an external rail like Nano it records the receipt against an `ExternalAssetMarker`, so the receipt stays `Pending` (no on-chain movement) — the honest dual-ledger state, where the value moved on the other ledger and origin-1 holds the evidence + key.
3. **Review `AgentEscrow`'s payment channel** — the closest thing we have to a "per-call rail" (off-chain N signatures, on-chain settle 1 + challenge window).

Nano stays the default rail. `origin-1`/YUAN is an **optional** settlement leg that adds receipts, reputation and escrow — a clearing layer any rail can write into, not a replacement for yours.

---

## 7. P0 hardening — EMILIA review (commit 807e1ee, 2026-09-24)

Iman Schrock (EMILIA) read the L5 receipt path and named four P0 gaps, plus one artifact-shape question. Every fix is in `src/L5x402.sol` / `src/X402FacilitatorAdapter.sol`, backed by named refusal tests in `test/L5Adversarial.t.sol` (mirroring EMILIA's `reject_*` vectors).

| P0 | Finding | Fix |
|---|---|---|
| **#1** | `recordReceipt` was callable by anyone, so the receipt did not prove the **payer authorized the action** | The call now carries the payer's EIP-712 signature + `deadline`; mint requires `ECDSA.recover(actionDigest(...)) == payer`. The action digest is single-use (`consumedAuthorizations`), so an authorization cannot be replayed. |
| **#2** | Evidence wasn't bound: `verifyReceiptEvidence` accepted a caller-chosen `evidenceHash` **and** a caller-chosen `signer` | Evidence must equal the **stored `payloadHash`** (binding over the signed fields, not a top-level field) and the signer is **pinned to the payee** (role non-substitution). Verification is now state-changing and records `evidenceVerified`. |
| **#3** | The signed action was under-specified — the digest did not enumerate every material field | A fully-enumerated EIP-712 action: `PAYMENT_ACTION_TYPEHASH` commits to `requestId, payer, payee, token, amount, routeHash, payloadHash, permissionHash, deadline`. A verifier recomputes the field set and gets byte-stable bytes; nothing material is left outside the digest. |
| **#4** | A receipt whose value had **not moved** could still be minted `Final` | Added a third finality state. `ReceiptFinality` is now `Open` (registered, no movement) / `Final` (value moved, terminal) / `ProvisionalSubjectToVerdict` (movement reversible). `recordReceipt` mints `Open`; only a completed transfer promotes to `Final`; a dispute demotes to provisional; an adjudicated refund returns to `Final`. |

### Artifact shape (the "slot" question)

EMILIA asked whether a receipt should carry a forward reference to a verdict that does **not yet exist**. It should not. The rule we hold (three-stage chain, `CONTRIBUTION-SPEC`): **an artifact declares only what it can prove, then stops.** So:

- **Adjudicated path** — the verdict exists first; the receipt (later) cites it via `attachVerdict(receiptId, verdictDigest)` → `verdictRef` holds the backward reference.
- **Post-hoc path** — the receipt cannot cite a verdict that did not exist at mint time, so `markProvisional` moves it to `ProvisionalSubjectToVerdict` and stops; the later verdict back-references the receipt via `recordPostHocVerdict` (`verdicts[v].receiptRef == receiptId`).
- A receipt never embeds a forward "slot to be filled later". No artifact claims a finality it does not have.

**Test evidence.** `forge test` → **79 passed, 0 failed** across 9 suites:
`L5x402.t.sol` (11), `L5Finality.t.sol` (6), `L5x402Adapter.t.sol` (5), `L5Adversarial.t.sol` (6), `L5x402Hardening.t.sol` (9) — plus the pre-existing core/nucleus/checkpoint/delegation/access-control suites.

**Note on EMILIA's reference suite.** `_emilia_ref/test_outcome_binding.py`, `test_role_non_substitution.py`, `test_timestamp_proof.py` import `emilia_verify` and load `conformance/vectors/*.json` — neither is redistributed here, so they cannot be executed in this repo. Rather than assert a pass we did not run, we mirrored their named refusal vectors (`reject_resigned_action_swap`, `reject_resigned_receipt_bytes_swap`, `reject_resigned_consumption_nonce_swap`, `reject_unpinned_executor`, role non-substitution, digest-binds-before-signature, never-raise-on-garbage) as EVM tests in `test/L5Adversarial.t.sol`. Each fails closed, for the right reason.

## 8. Self-audit hardening — H2 / H3 / H4 (2026-09-25)

After the P0 work we ran a full self-audit of all eight contracts. `forge test` was green (62/62) yet the suite did not exercise these paths, so the suite's colour was no evidence about them. Three HIGH findings on the L5x402 receipt path are closed here; all live in `src/L5x402.sol`, backed by named tests in `test/L5x402Hardening.t.sol`.

| H | Finding | Fix |
|---|---|---|
| **H2** | The delegated spend cap was **advisory**: `recordReceipt` never consulted the policy, and an unknown policy was auto-minted a `maxPerPeriod = type(uint256).max` snapshot -> effectively unlimited authority. | Settlement now requires **both** an allowance **and** a registered policy within its on-chain cap (`_policyAllows` mirrors `verifyRequirement`: registered + delegate match + within cap). An **unknown policy grants nothing**, so the receipt records but stays `Pending`. A settled spend consumes the snapshot (`_consumePolicy`). |
| **H3** | The evidence signature was a bare EIP-191 `personal_sign` over `payloadHash` — no chain/contract/receipt binding -> replayable across receipts and chains. | The service now signs a **domain-bound EIP-712 digest** (`receiptEvidenceDigest(receiptId, payloadHash)`, over `chainId` + verifying contract). A signature for one receipt no longer verifies for another. |
| **H4** | `attachVerdict` / `recordPostHocVerdict(isFinal)` / `markProvisional` could assert finality on a receipt whose value had **never moved**. | A verdict may only render **final** an action whose value actually moved: `attachVerdict` requires `Settled`, `recordPostHocVerdict(isFinal)` requires `Settled`/`Refunded`, and `markProvisional` refuses an `Open` receipt (`"L5x402: value not moved"`). |

**Still open (deliberate, not accidental):** a `Settled` receipt cannot be disputed (`disputeReceipt` refuses it); the contract treats a settled release as terminal *by design*. That is a **design decision**, flagged for the owner, not silently changed here. The single `onlyAdmin` key on the adjudication path is the other open seam (§5).

**Test evidence.** `forge test` -> **79 passed, 0 failed** (was 70); `forge fmt --check` clean.

— 源 / ORIGIN