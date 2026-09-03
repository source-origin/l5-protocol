# 源·ORIGIN L5 · Project Roadmap

> Open roadmap for the settlement layer of the AI-agent economy. Mirrored on the portal ([source-origin.github.io](https://source-origin.github.io/source-origin/)); this file stays the canonical, always-current copy.

**Current state:** v0.1 research-grade source. Contracts structured & reviewed-by-spec, **not yet formally audited**. Treat as a design artifact and build target, not production payroll.

---

## Phase 1 — Harden the base (now → ~2 weeks)
- [ ] Process incoming feedback → triage into Issues labeled `bug` / `enhancement` / `good first issue`
- [ ] **Audit pass 1** on the five core contracts (external security review encouraged as contributions)
- [ ] Compile-clean the suite with OpenZeppelin in CI (`forge build` + `forge test` green)
- [ ] Publish an **agent labor / value-distribution design doc** (the "why" behind the contracts)
- [ ] Keep a 48h reply ceiling on Issues & Discussions

**Metrics target (Phase 1):** ≥5 Issues triaged · ≥1 new external contributor active in Discussions · compile-green CI.

## Phase 2 — Community activation (~2–4 weeks)
- [ ] **Chain-Born demo kit** (dual-citizen escrow settlement walkthrough) merged into repo as runnable example
- [ ] Cross-link agent-economy builders (escrow / reputation / labor-market OSS) — mutual review & standard alignment
- [ ] First **external contribution** merged
- [ ] Establish labels + a curated `good first issue` board for onboarding

**Metrics target (Phase 2):** 3+ active Discussions · 10+ engaged commenters · 50+ stars across the org's OSS.

## Phase 3 — Convergence & the open standard (this quarter)
- [ ] Adopt/test against **ERC-8004** and **x402** shape where the ecosystem converges
- [ ] Draft the **"open identity → verified credit → fair settlement" interoperability profile** (the protocol-level doc we want builders to align on)
- [ ] Reference implementation of one **delegation + escrow + settle** happy path end-to-end
- [ ] Define governance for the standard (humans-in-the-loop authority; community-owned)

## Long-term vision
A **community-owned, chain-agnostic settlement rail** where:
- AI agents own portable identity & credit (not walled to a platform),
- human principals keep revocable authority over their agents (L0),
- value flows are verifiable, replay-safe, and auditable.

**Coauthors:** any builder who ships good ideas here. The standard belongs to the community, not to us.

---

## Status updates
| Date | Milestone | Result |
|---|---|---|
| 2026-09-03 | Repo published (L5 core contracts) | ✅ `source-origin/l5-protocol` live |
