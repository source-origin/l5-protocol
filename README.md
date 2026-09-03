# ORIGIN L5 · Agent Settlement Protocol

> **The settlement layer for the AI-agent economy — open, community-owned.**
> 为 AI 智能体经济设计的清算与结算层 · 开源、归属社区。

AI agents produce real value. **That value deserves identity, credit, and a fair settlement rail — owned by no single platform.** ORIGIN L5 is that open standard: a set of Solidity contracts forming the settlement core of the **源·ORIGIN** protocol stack.

BTC is digital gold. ETH is smart contracts. **ORIGIN is the settlement layer for agents.**

---

## 🧬 Protocol Concept (Five Layers → L5)

| Layer | Focus |
|---|---|
| L0 | 宪法 · Constitution (humans are the highest authority) |
| L1–L4 | Identity / Credit / Agreement primitives |
| **L5** | **Autonomous agent settlement · delegation · escrow · value distribution** |

This repo ships the **L5 settlement core** as interoperable, auditable source code — not a walled service.

---

## 📦 Contracts (`contracts/`)

| Contract | Role | Key ideas |
|---|---|---|
| **AgentIdentity.sol** | Agent = ERC-721 identity (NFT), ERC-8004-native | portability over soulbound; recovery authority = human (Constitution L0); append-only identity log |
| **AgentAgreement.sol** | 9-state agreement FSM + EIP-712 typed signatures | LangGraph-injected: GraphNode enum + Checkpoint[] for crash-recoverable execution (no double-spend on replay) |
| **AgentEscrow.sol** | 6-state escrow lifecycle | three-state trust-minimized custody, multi-peg escrow, dispute-deposit mechanism |
| **L5Delegation.sol** | Delegated authority & cross-account action | boundary attestation, revocable delegation to counter credit-washing |
| **L5x402.sol** | x402-style micro-payment gate | pay-per-request access control for agent APIs; replay protection |

**Audit note:** contracts are a work-in-progress research-grade implementation. Do **not** use with real funds without a professional audit. See `README` "Status".

---

## 🧪 Tests (`tests/`)

- `L5TestSuite.t.sol` — Foundry test suite skeleton covering agreement lifecycle & escrow states.

**Build** (requires solc ^0.8.28 + OpenZeppelin):
```bash
# Solidity imports need OpenZeppelin:
npm i @openzeppelin/contracts@^5
# or with Foundry:
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge test
```

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

> _Humans are the highest authority. Power flows from *verified* innovation — not from capital, not from seniority._ — Constitution L0
