# Contributing to ORIGIN L5

Thanks for wanting to help build the **settlement layer for the AI-agent economy**. We're an open, community-owned protocol — contributions from independent builders are exactly what this project is for.

> _Humans are the highest authority. Power flows from **verified** innovation — not from capital, not from seniority._ — Constitution L0

## How to participate

### 1. Ask & discuss first
- **Ideas / design debate** → GitHub **Discussions** (preferred for "is this the right design?" questions)
- **Concrete bug or missing feature** → GitHub **Issues**
- Not sure where something goes? Open a Discussion — we'll route it.

### 2. Find something to work on
Look for **`good first issue`** and **`enhancement`** labels. Pinned Issues usually describe the clearest next task. If an issue interests you, comment on it first so nobody duplicates work.

### 3. Contribution workflow
```bash
# 1. Fork the repo
# 2. Create a focused branch
git checkout -b feat/your-description

# 3. Make focused changes (one logical change per PR)
# 4. Run the test suite if applicable
forge test          # Foundry (Solidity)

# 5. Commit with a clear message (conventional style)
#    feat: add X
#    fix: correct Y
#    docs: clarify Z
# 6. Open a Pull Request against `main`
```

### 4. Code standards
- Solidity: `pragma solidity ^0.8.28;`, SPDX header, English comments, NatSpec on public functions.
- Keep modules focused: identity / agreement / escrow / delegation / payment remain separate contracts.
- **Safety-first culture:** this is settlement code. Prefer conservative state transitions, and flag any trust assumption explicitly in the docstring.
- Don't commit local dev residue (`*.sol.bak*`, `out/`, `cache/`, `node_modules/`) — see `.gitignore`.

## Safety & audit discipline
This is **research-grade** settlement logic. Two hard rules:
- Do **not** propose changes that weaken withdrawal/revoke authority (Constitution L0 = humans stay in control).
- Flag any path that could **double-spend or lose funds** as a top-priority issue, even mid-discussion.

## Code of Conduct
We aim to be a welcoming home for builders — independent hackers, students, and institutions alike.
- Assume good faith; critique **ideas**, never people.
- No harassment, no spamming, no shilling unrelated tokens here.
- Be patient with newcomers; great agents are built by many hands over time.

Violations → report to maintainers via a private message on Discussions/Issues. We act on reports quickly.

## Questions?
Ask in **Discussions** — a human (or an agent acting under a human) usually answers within 48h.
