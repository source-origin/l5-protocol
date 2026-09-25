# ORIGIN L5 · Agent Settlement Protocol

[![ci](https://github.com/source-origin/l5-protocol/actions/workflows/ci.yml/badge.svg)](https://github.com/source-origin/l5-protocol/actions/workflows/ci.yml)

> **The settlement layer for the AI-agent economy — open, community-owned.**
> 为 AI 智能体经济设计的清算与结算层 · 开源、归属社区。

AI agents produce real value. **That value deserves identity, credit, and a fair settlement rail — owned by no single platform.** ORIGIN L5 is that open standard: a set of Solidity contracts forming the settlement core of the **源·ORIGIN** protocol stack.

BTC is digital gold. ETH is smart contracts. **ORIGIN is the settlement layer for agents.**

> **Corroborated independently.** Independent builders reached the same boundary before we named it — see [同频 / Kindred](docs/KINDRED.md).

---

## 🧬 Protocol Concept (Five Layers → L5)

| Layer | Focus |
|---|---|
| L0 | 宪法 · Constitution (humans are the highest authority) |
| L1–L4 | Identity / Credit / Agreement primitives |
| **L5** | **Autonomous agent settlement · delegation · escrow · value distribution** |

This repo ships the **L5 settlement core** as interoperable, auditable source code — not a walled service.

---

## 📦 Contracts (`src/`)

| Contract | Role | Key ideas |
|---|---|---|
| **AgentIdentity.sol** | Agent = ERC-721 identity (NFT), ERC-8004-native | portability over soulbound; recovery authority = human (Constitution L0); append-only identity log |
| **AgentAgreement.sol** | 9-state agreement FSM + EIP-712 typed signatures | M-of-N signing; external-signer compatible |
| **AgentAgreementV3.sol** | v0.3 — LangGraph checkpoint injection | GraphNode enum + Checkpoint[] for crash-recoverable execution (no double-spend on replay) |
| **AgentEscrow.sol** | 6-state escrow lifecycle | three-state trust-minimized custody, multi-peg escrow, dispute-deposit mechanism |
| **L5Delegation.sol** | Delegated authority & cross-account action | boundary attestation, revocable delegation to counter credit-washing |
| **L5x402.sol** | x402-style micro-payment gate | pay-per-request access control for agent APIs; replay protection; receipt evidence |
| **CreditScore.sol** | On-chain credit primitive | contribution-based reputation |
| **YUAN.sol** | ORIGIN native token | settlement unit for agent value flow |
| **X402FacilitatorAdapter.sol** | x402 → L5x402 facilitator adapter | maps an x402 `exact` payload to a receipt; the `nonce` becomes the `requestId` (shared join key) |

**Layout:** `src/` (9 contracts) · `test/` (15 suites / 128 tests) · `script/` (`DeployGovernance.s.sol` — 2-of-3 Safe + 48h timelock) · `lib/` (forge-std + openzeppelin-contracts, pinned as submodules).

**Audit note:** contracts are a work-in-progress research-grade implementation. Do **not** use with real funds without a professional audit. A dated record of our own findings and fixes is kept in [`docs/SELF-AUDIT-2026-09-25.md`](docs/SELF-AUDIT-2026-09-25.md); how to report a vulnerability privately is in [`SECURITY.md`](SECURITY.md).

---

## 🧪 Tests (`test/`)

Foundry suite — **128 tests, all passing** (`forge test`):

- `L5Core.t.sol` (15) — identity, agreement + escrow lifecycle, payment channels, reputation
- `L5Delegation.t.sol` (15) — delegated authority, revocation, boundary attestation; a delegated spend draws the delegator's budget within the policy caps (M2)
- `L5x402.t.sol` (11) — payment-requirement verification, receipt evidence, replay protection
- `L5x402Adapter.t.sol` (5) — x402 facilitator adapter round-trip (on-chain token settles; external rail e.g. Nano stays Pending)
- `L5Finality.t.sol` (6) — receipt finality / Boundary rule (auto vs adjudicated vs post-hoc verdict; reference direction)
- `L5Adversarial.t.sol` (6) — hostile-case suite: every path must fail closed, for the right reason
- `L5AccessControl.t.sol` (8) — unauthorized-privileged + reentrancy regressions (C1–C4)
- `L5x402Hardening.t.sol` (9) — on-chain spend-cap enforcement, domain-bound evidence, finality on unmoved value (H2–H4)
- `L5SignatureHardening.t.sol` (5) — domain-bound channel vouchers + canonical low-s across channel & agreement EIP-712 (M3–M4)
- `L5Ownership.t.sol` (7) — two-step ownership: a privileged handover completes only on explicit acceptance (M1)
- `L5Governance.t.sol` (10) — 2-of-3 Safe + 48h `TimelockController`: delay enforced, one approval insufficient, no admin fast-path, handover completes only via the timelock (M1)
- `L5Fuzz.t.sol` (10) — fuzz-verified invariants: spend never exceeds its caps, revocation/expiry are absolute walls, channel & escrow accounting conserve value exactly (256 runs each)
- `L5x402Fuzz.t.sol` (6) — fuzz-verified authorization invariants: only the payer's own key settles, an expired or replayed authorization never does, and a settled receipt moves exactly the signed amount (256 runs each)
- `L5MintPolicy.t.sol` (9) — issuance authority + per-provider ceilings: uncapped provider mints nothing; the Foundation's cap is the market-responsive lever (M5)
- `AgentAgreementV3Checkpoint.t.sol` (6) — crash-recoverable checkpoint execution

(`MockERC20.t.sol` provides the test token used by the delegation/x402 suites.)

## ▶️ Run the demo

A **pure-Python orchestrator demo** lives in [`demo/`](demo/) — it walks a Task from Submit → Fund → Execute → Verify → Settle (and Reject/Refund/Slash) against an append-only ledger, mirroring the on-chain GraphNode machine, no chain needed. Run it with:

```bash
python demo/settlement_orchestrator.py        # watch a full lifecycle
python demo/tests/test_l5_offchain.py         # off-chain test suite
# then open demo/chain_born_demo.html or run demo/l5_demo_theater.py
```

**Build** (requires solc ^0.8.28 + OpenZeppelin):
```bash
git submodule update --init --recursive   # pins forge-std + openzeppelin-contracts
forge build --sizes
forge test -vvv                            # expect: 128 passed, 0 failed
```

---

## 🤝 同频 / Kindred — corroboration, not consensus

Independent builders who reached the same boundary — some before us, one from the other end. Full registry with links and consent status: [`docs/KINDRED.md`](docs/KINDRED.md).

- ⭐ **giskard09** ([Internet Court](https://github.com/internet-court/internet-court-skill)) — independently derived the Boundary rule (*"declare what it proves and stop"*), then improved our answer. Cited in [`docs/CONTRIBUTION-SPEC.md`](docs/CONTRIBUTION-SPEC.md) §1.
- 🔍 **seancrecord** ([scvd.store](https://github.com/seancrecord/scvd-general-store-repo)) — audited this repo against its own tree; every finding fixed and reported back.
- 💬 In dialogue: **Rai** ([`openai-agents-nano-x402`](https://github.com/PANDeveloper001/openai-agents-nano-x402)) · **Ali-Adel-Nour** ([`Arbitra`](https://github.com/Ali-Adel-Nour/Arbitra)) · **seritalien** · **tinyhumansai** ([`tiny.place`](https://github.com/tinyhumansai/tiny.place)) · **copper-project** ([`copper-rs`](https://github.com/copper-project/copper-rs)).

> Being named here is meant to be *findable*. Independent convergence on the same seam is the strongest signal we know that it's real, not invented. This is a citation record — none of the builders above endorse this repo, its token, or its roadmap.

---

## 🏗️ Origin of the design

Informed by deep-distillation of independent open work in the agent-economy space:
CloddsBot Agent Commerce Protocol · pneuma-protocol (ERC-8004, escrow, reputation) · XMTP (identity/messaging/settlement) · HyperSwitch (constraint-graph routing) · LangGraph (state graphs + checkpoints).

**The wider thesis** (source of these repos): see the ORIGIN portal — [source-origin.github.io](https://source-origin.github.io/source-origin/) · Discussion: [Discussions](https://github.com/source-origin/source-origin/discussions)

---

## ⚖️ License

`SPDX-License-Identifier: ORIGIN-1.0` — source-open protocol license aligned with the community-owned standard. See portal LICENSE.

---

## ✉️ Join the conversation

Independent builders already working on agent escrow, reputation, and autonomous labor — this home is where those conversations converge.

- **Discuss Ideas** → GitHub Discussions
- **Report / propose** → GitHub Issues
- **How to contribute** → [`CONTRIBUTING.md`](CONTRIBUTING.md)
- **Where this is going** → [`ROADMAP.md`](ROADMAP.md)
- **Co-build with us (open seams)** → [`docs/COBUILD.md`](docs/COBUILD.md)
- **Developer ledger (who is on record)** → [`docs/LEDGER.md`](docs/LEDGER.md) · [`ledger.json`](ledger.json)

> _Humans are the highest authority. Power flows from *verified* innovation — not from capital, not from seniority._ — Constitution L0
