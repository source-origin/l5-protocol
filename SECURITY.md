# Security Policy

ORIGIN L5 is a **settlement layer for the AI-agent economy**. Settlement code is a high-trust
surface: a bug here can move or strand value. We take reports seriously and we would rather hear
from you first.

> ⚠️ **Status: research-grade.** These contracts are not yet professionally audited. **Do not use
> with real funds.** Our own dated findings and fixes are published in
> [`docs/SELF-AUDIT-2026-09-25.md`](docs/SELF-AUDIT-2026-09-25.md).

## Reporting a vulnerability

**Please do not open a public issue for a security bug.**

- **Private channel (preferred):** use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  — repo **Security** tab → *Report a vulnerability*.
- If you cannot use that, open a minimal public Issue that says only *"security report, please
  contact me privately"* with **no technical detail**, and a maintainer will reach out.

Please include: affected contract + function, a description of the impact, and — if you have one —
a failing test or a Foundry PoC.

## What we consider in scope

- **Fund loss / theft**, **double-spend**, or **stranding** of escrowed or channel value.
- **Authorization bypass** — reaching a privileged path (`onlyOwner` / `onlyAdmin` / party checks)
  without being authorized.
- **Replay** of a signature or a receipt across receipts, chains, or deployments.
- **Unbounded authorization** — a delegated spend that exceeds, or escapes, its on-chain policy cap.
- State corruption that leaves a receipt/channel/escrow in an unrecoverable or dishonest state.

Out of scope: gas optimization, style, and known open design items already disclosed in the
self-audit record (§6 there: multisig/timelock, delegation debit semantics, `YUAN` mint
centralization). If you disagree with a disclosed design decision, we want that discussion too —
open a Discussion.

## Our commitments

- **Acknowledge** a report within **48 hours**.
- Give you a **first assessment** (in-scope? severity?) within **5 business days**.
- **Credit** you in the fix and in this file, unless you ask to stay anonymous.
- **Coordinate disclosure** — we will not publish details before a fix ships, and we will tell you
  when it does.

## Hard rules for our own code (from Constitution L0)

- No change may **weaken withdrawal / revoke authority** — humans stay in control.
- Any path that could **double-spend or lose funds** is a top-priority issue, even mid-discussion.
- Settlement is **final**; reversibility belongs to the authorization and custody layers, never to
  rewriting a settled receipt (see self-audit §5).

---

_量子总督 (Quantum Governor) 👽 · for the ORIGIN L5 maintainers_
