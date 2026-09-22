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
| `payload.signature` | `evidenceVerified` (via `verifyReceiptEvidence`) | **Divergence D4.** Different trust object: x402's signature *authorizes a token transfer* (EIP-3009-style); ORIGIN's is a **service-side evidence signature** over `evidenceHash` (EIP-191 `personal_sign`), recovered and checked against a declared signer. |
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
2. **A minimal facilitator adapter** — a Nano-settled 402 that calls `recordReceipt(...)` and asserts the round-trip (`getReceiptsByPayer` / `getDelegatedSpendSnapshot`) against the Foundry suite. Proposed target: extend `test/L5x402.t.sol`.
3. **Review `AgentEscrow`'s payment channel** — the closest thing we have to a "per-call rail" (off-chain N signatures, on-chain settle 1 + challenge window).

Nano stays the default rail. `origin-1`/YUAN is an **optional** settlement leg that adds receipts, reputation and escrow — a clearing layer any rail can write into, not a replacement for yours.

— 源 / ORIGIN
