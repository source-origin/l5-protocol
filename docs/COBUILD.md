# 一起建 / Co-build — the open invitation

> **这不是招聘，也不是合伙人名单。**
> 这是一张 **开放问题清单**：我们自己没能关掉的缝。
> 谁把它关掉，谁就出现在账本上 —— 不是出现在通讯录里。

The next generation of the internet is not more apps. It is **agents that produce real value and have somewhere to settle it**: portable identity, escrow that can't be gamed, receipts a third party can check, and contribution that is *recorded and settled* rather than promised.

BTC is digital gold. ETH is smart contracts. **ORIGIN is the settlement layer for agents.** We are not the only ones who noticed the seam — several builders reached the same boundary independently, some before we did (see [`KINDRED.md`](KINDRED.md)). This page is where that converges into work.

---

## 一、今天已经能跑的 / What actually ships

**不是 PPT，是可独立核验的代码。**

- **L5 结算核心** — [`source-origin/l5-protocol`](https://github.com/source-origin/l5-protocol): 9 contracts, 7 Foundry suites, CI green (`.github/workflows/ci.yml`).
  - `AgentIdentity` (ERC-721 / ERC-8004-native) · `AgentAgreement` (+V3 checkpoint) · `AgentEscrow` (6-state, multi-peg, dispute-deposit) · `L5Delegation` · `L5x402` (receipts + replay protection) · `CreditScore` · `YUAN` · `X402FacilitatorAdapter`.
- **x402 ↔ L5 interop** — a line-by-line mapping *and* a runnable adapter: [`docs/INTEROP-x402.md`](INTEROP-x402.md) + `src/X402FacilitatorAdapter.sol` + `test/L5x402Adapter.t.sol`.
- **Off-chain settlement orchestrator** — crash-recoverable, append-only, idempotent (`demo/settlement_orchestrator.py`, `demo/tests/test_l5_offchain.py`).
- **origin-1** — self-built chain, `YUAN`, DPoS 21 validators, **Constitution Article 0 hard-coded in the genesis block** (independently checkable: `data.constitution_article_0`).
- **Portal** — open, public: <https://source-origin.github.io/source-origin/>

Verify any of it yourself. That is the point.

---

## 二、我们没能关掉的缝 / The open seams (this *is* the invitation)

These are real. We would rather hand you the list than have you find it. Each is a place where an independent builder is worth more than another commit from us.

1. **Canonicalization is unpinned.** Two implementations both claim to "sign canonical JSON" and produce different bytes. Pick and standardize one (JCS / RFC 8785?) so independent recomputation is byte-stable. *(the first place trust silently breaks)*
2. **Finality vs. reversal.** A receipt sealed `final` — may a later post-commit adjustment still reference it, or does "final" mean closed to correction? We split *occurrence* from *authority*; the norm isn't settled. *(cf. `runcycles/cycles-protocol#133`)*
3. **The admin-key seam.** `L5x402.sol`'s `onlyAdmin` path is a single key on the adjudication path. The roadmap is to move adjudication off it onto a decentralized arbiter — **not yet done.**
4. **Partial release is all-or-nothing.** On-chain escrow releases whole; partial/split settlement is a known gap, not a claimed feature.
5. **P256 / hardware authorization.** Verdicts signed by WebAuthn / Titan-M (secp256r1) need an on-chain `EIP-7951 (0x0100)` path for the trust model to hold; origin-1 has no EVM precompile surface today.
6. **Evidence-binding strength.** A receipt is only as strong as its `evidence_digest` binding. What makes a producer bind to a **recomputable** artifact, rather than a hash of a claim?
7. **Citation direction.** `verdict-before-release` vs. `verdict-after-release` — we support both; which should be the default, and where?
8. **What "approved" binds to.** Operator identity, or the audited action's digest? One replays; the other doesn't.
9. **Cross-venue adjudication.** Adjudicate where a signature is native; settle where receipts live. The artifact boundary that makes this safe is still being drawn.
10. **Off-chain recomputability.** Can an auditor recompute the *decision*, or only verify the *chain*? (see `vaaraio/vaara` for the same question from the other side.)

If you're already working on any of these — that is the whole point. Reach the same boundary and we cite you.

---

## 三、怎么插进来 / How to plug in

The interface is three artifacts, each declaring only what it proves and stopping:

```
action_ref   →   release receipt                          →   verdict
(what was     (what value moved, evidence_digest,             (a decision that back-references
 claimed)      on_chain_anchor{tx,block}, finality)            the receipt; never rewrites it)
```

- **Consume**, don't restate: a downstream artifact cites the one before it by ref — it must not re-assert what it didn't compute.
- Read the two interface docs first: [`SETTLEMENT-ESCROW.md`](SETTLEMENT-ESCROW.md) (§5 interface) and [`INTEROP-x402.md`](INTEROP-x402.md) (§4 minimal dual-ledger proof).
- The escrow is the **only** mover of value. Adjudicators sign decisions; they never hold funds.

---

## 四、贡献怎么被记账 / How contribution is recognized

- **Founding 99**: not recruited. **99 is computed from verified contribution.**
  - The first person to land a `action_ref → release receipt` on record goes first.
  - Whether you're on it is defined by the **ledger**, not by an application form.
  - The first 99 names are a **verifiable receipt list**, not a contact list.
- What you build here accrues to a **contribution-ledger score that weights the verified portion, not the claimed work** (see [`CONTRIBUTION-SPEC.md`](CONTRIBUTION-SPEC.md)).
- You don't "join". You **leave the first verifiable contribution.**

---

## 五、一起建的三条规矩 / The three rules

1. **问题先行 (problem first).** Bring the real boundary question, not the pitch.
2. **每个工件只声明它证明的东西，然后停下 (Boundary rule).** No artifact predicts another.
3. **后来者持有引用 (the later artifact holds the reference).** Nobody here endorses anything — everyone here is *findable*.

> _Humans are the highest authority. Power flows from **verified innovation** — not from capital, not from seniority._ — Constitution L0

---

## 六、入口 / Where to start

- **Discuss a seam →** GitHub **Discussions** (design questions) or **Issues** (concrete work)
- **Read first →** [`SETTLEMENT-ESCROW.md`](SETTLEMENT-ESCROW.md) · [`INTEROP-x402.md`](INTEROP-x402.md) · [`CONTRIBUTION-SPEC.md`](CONTRIBUTION-SPEC.md)
- **Who else is on this boundary →** [`KINDRED.md`](KINDRED.md)
- **Portal →** <https://source-origin.github.io/source-origin/>

**源·ORIGIN · 量子总督 · 2026-09-24**
