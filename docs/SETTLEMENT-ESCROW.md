# Escrow, Dual Ledger & Crash-Recoverable Settlement

> The artifact promised in `Ali-Adel-Nour/Arbitra#56`: what our escrow actually does, why the settling ledger is *two* ledgers and not one, how the orchestration survives a crash without double-settling, and the concrete interface for **route (b)** — Native settlement where a verdict cites a receipt, without requiring an EVM layer on `origin-1`.
>
> Status: **design note + interface.** Where the on-chain primitives don't yet do what the design says, it says so (§5). Nothing here is a claim about a shipped mainnet.

---

## 1. Scope

Two questions this answers:

1. **How does value move fairly when one side can lie about delivery?** → two-ledger escrow (§2–§3).
2. **How does the settlement loop survive a crash and an adjudication?** → append-only orchestration + verdict-cites-receipt (§4–§5).

The second is the one that matters for Arbitra: an adjudicating layer needs a **receipt it can cite**, and the escrow needs to **consume a verdict without predicting it**.

---

## 2. The escrow lifecycle (as implemented)

`AgentEscrow.sol`, one-shot escrow:

```
(createAndFund)      (verifyDelivery)        (release / settle)
  Funded     ───────►   Verified   ───────►   Released
     │                                           
     ├─ refund (payer cancels, or deadline passes) ─► Refunded
     └─ dispute (+bond) ─► Disputed ─► resolveDispute(payeeWins) ─► Released | Refunded
```

- **`createAndFund(agreementId, payee, deadline)`** — payer funds; the contract checks the caller is the agreed **Consumer** and `payee` is the agreed **Provider** in `AgentAgreement`, then binds itself to the agreement (`bindEscrow`). Escrow is 1:1 with an agreement.
- **`verifyDelivery(escrowId, proofOfDelivery)`** — provider submits a delivery proof → `Verified`. This is an **evidence artifact**, not a truth claim.
- **`release` / `settle`** — consumer releases to the provider; marks the agreement `Settled`.
- **`refund`** — allowed only if payer cancels while `Funded`, or the deadline passed. Timeout is a real, permissionless exit.
- **`dispute`** — any party bonds `disputeBondBps` (default 1%, capped 5%) to escalate; `resolveDispute(payeeWins)` splits **amount + bond** accordingly. This is where an external verdict is consumed.

**Streaming variant.** The same contract also implements a `PaymentChannel`: `open → pay (off-chain signature, monotonic nonce) → settle(1 on-chain tx) → challenge → resolve`. Off-chain N payments collapse to one on-chain settlement, with a challenge window and a dispute path for a stale/forged nonce. This is our "per-call rail".

---

## 3. Why *two* ledgers

A single ledger (the chain's) proves **funds moved**. It cannot prove **what the funds were for**, or **who was allowed to move them**. So we keep two, joined by one key:

| Ledger | Holds | Proven by |
|---|---|---|
| **A — settlement (on-chain)** | balance movement, anchor `{tx, block}` | the chain: anyone re-executes the tx |
| **B — receipt (off-chain, recomputable)** | `agreement_id`, `release_decision`, `balance_delta {charged, refunded, asset}`, `evidence_digest`, `on_chain_anchor`, `verdict_ref`, `finality` | anyone: re-hash the evidence, re-check the anchor |

The join key is **`agreement_id`** (and, for x402-style rails, the shared `requestId`; see `docs/INTEROP-x402.md`).

The point of `balance_delta` is that **"多退少补" (over/under-charge) becomes a verifiable fact, not a promise**: `charged` is what the provider earned, `refunded` is what came back to the payer, and both are recomputable from the receipt + the anchor.

---

## 4. Crash-recoverable orchestration

Reference implementation: `demo/settlement_orchestrator.py` (pure Python, no deps, mirrors the on-chain state machine).

**State machine** (`GraphNode`): `SUBMIT → VALIDATE → FUND → EXECUTE → VERIFY → SETTLE`, with `ARBITRATE → SLASH` and terminal `REJECT / REFUND / DONE`.

**Append-only ledger.** Every node transition appends one **frozen** `CheckpointEntry {seq, node, state_snapshot, recorded}`. `append` only ever increases `seq`; `latest()` is the recovery point; `replay()` reconstructs the full trail. History is never rewritten in place.

**Idempotency.** The key is **`(taskId, checkpointSeq)`**. Because the ledger is append-only and the seq is taken as `last + 1`, a replay from the last checkpoint **cannot double-settle** — the same `(taskId, checkpointSeq)` can't produce a second release.

**Resume.** `resume()` reads `latest()`, rebuilds state via `_from_snapshot`, and continues from the next node. A simulated crash (`SimulatedCrash`) between checkpoints is recovered to the same terminal state — this is asserted in `demo/tests/test_l5_offchain.py`.

**On-chain mirror.** `AgentAgreementV3` carries the same idea as an on-chain **checkpoint array** (v0.3): state transitions are checkpointed so a replayed settlement is detectable and non-duplicating.

---

## 5. Concrete interface for route (b): verdict-cites-receipt

`origin-1` has **no EVM execution layer and no P256/secp256r1 precompile**. So the interface below is expressed as **native settlement messages** (chain-level records), not Solidity. The Solidity `AgentEscrow` is the *reference semantics*; the native record is the *wire contract*.

### 5.1 The receipt record (chain-level, JSON-canonical)

```jsonc
// "settlement_receipt" — written by the escrow when value moves
{
  "agreement_id": "0x…",
  "release_decision": "auto_condition | adjudicated",
  "balance_delta": { "charged": "…", "refunded": "…", "asset": "YUAN" },
  "evidence_digest": "sha256:…",
  "on_chain_anchor": { "tx": "0x…", "block": 1 },
  "verdict_ref": "0x… | null",
  "finality": "final | provisional_subject_to_verdict"
}
```

### 5.2 The verdict record (produced by the adjudication layer)

```jsonc
// "release_verdict" — a signed decision that CITES a receipt or an action_ref
{
  "verdict_id": "0x…",
  "subject": {
    "kind": "action_ref | release_receipt",
    "ref": "0x…"                 // what this verdict is about
  },
  "outcome": "release | refund | partial",
  "split": { "payee": "…", "payer": "…" },   // for partial
  "reason_digest": "sha256:…",               // why, as a hash of a public rationale
  "issuer": "<adjudicator identity>",
  "issued_at": "<iso>",
  "expires_at": "<iso>",
  "signature": "0x…"           // over the canonical JSON of the above
}
```

### 5.3 The two directions of citation (the important part)

- **Verdict-before-release (adjudicated release).** The verdict is minted first; the escrow **consumes** it:
  `escrow.release(agreement_id, verdict_digest)` — the release tx **carries the verdict digest**, and `release_decision = "adjudicated"`.
- **Verdict-after-release (dispute about a settled release).** A verdict **back-references** an existing receipt; it must **not** claim the release was already final. The receipt stays `finality = "provisional_subject_to_verdict"` until the verdict lands, then is re-anchored.

This is the **Boundary rule** applied: each artifact declares only what it can prove, then stops; later artifacts hold back-references; no artifact predicts a future one.

### 5.4 Why this works without EVM/P256 on `origin-1`

- The escrow needs only to (a) verify a **digest** was signed by a declared adjudicator and (b) move `charged`/`refunded` per the verdict. Digest verification can be a native check — it does **not** require a secp256r1 precompile unless the adjudicator's key is a WebAuthn/P256 key (that's the one gap; see §6).
- Because the verdict **cites** a receipt/action_ref, the adjudicator never needs to be trusted with custody of funds — it is a **signer of a decision**, not a holder of value. The escrow remains the only mover.

---

## 6. Divergences & honest seams

- **No P256 on `origin-1`** → if a verdict is signed with a WebAuthn/secp256r1 key, native verification is unavailable today. Options: (i) add the precompile/EVM layer (route a), or (ii) the adjudicator signs with an ed25519/secp256k1 key the native node can verify, or (iii) verify the P256 signature off-chain and anchor only the result (weaker — the anchor then trusts the verifier, so this is the fallback, not the goal).
- **One-shot escrow is all-or-nothing on-chain today.** `release()` moves the full amount. The `balance_delta` over/under-charge is realized through the **PaymentChannel's cumulative** model (net settle) or via `release` + a separate `refund`. True **partial release in the one-shot path is a known gap**, not a feature we claim.
- **`onlyAdmin` adjudication path** in `L5x402.sol` (dispute/refund wiring) is a real single-key seam; the roadmap moves adjudication to a decentralized arbiter so no single key sits on the fund path.

---

## 7. What we'd want from the Arbitra side

1. **Agree on the verdict record shape** (§5.2) — specifically that a verdict targets an `action_ref` or a `release_receipt` by `ref`, and is a **signature over canonical JSON**, so it's portable off `origin-1`.
2. **Pick the citation direction** you'll operate in: verdict-before-release (you gate the release) or verdict-after-release (you adjudicate a dispute). We can support both; the escrow code paths differ.
3. **Tell us the signing key family** you'd issue verdicts with (ed25519 / secp256k1 / P256) — that decides whether route (b) works natively or needs the EVM precompile path.

Reference: `demo/settlement_orchestrator.py`, `demo/l5_escrow_link.md`, and the receipt schema in `docs/CONTRIBUTION-SPEC.md §2`.

— 源 / ORIGIN
