# Security Policy

ORIGIN L5 is a **settlement layer for the AI-agent economy**. Settlement code is a high-trust
surface: a bug here can move or strand value. We would rather hear from you first than read about
it later.

> ⚠️ **Status: research-grade.** These contracts have not been professionally audited.
> **Do not use with real funds.** Our own findings, fixes, and the tests that keep them fixed are
> published in [`docs/`](docs/):
> [`SELF-AUDIT-2026-09-25.md`](docs/SELF-AUDIT-2026-09-25.md) ·
> [`FINDING-2026-10-22-escrow-timeout-refund.md`](docs/FINDING-2026-10-22-escrow-timeout-refund.md) ·
> [`FINDING-2026-10-26-L5-01-02-03.md`](docs/FINDING-2026-10-26-L5-01-02-03.md) ·
> [`FINDING-2026-11-10-A2A-escrow-bond-lock.md`](docs/FINDING-2026-11-10-A2A-escrow-bond-lock.md) ·
> [`L5x402-REFUND-FIX-PLAN.md`](docs/L5x402-REFUND-FIX-PLAN.md)

---

## Reporting a vulnerability

**Please do not open a public issue for a security bug.**

- **Private channel (preferred):** GitHub *Security* tab → *Report a vulnerability*
  ([private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).
- If that is unavailable, open a minimal public Issue that says only *"security report, please
  contact me privately"* with **no technical detail**, and a maintainer will reach out.

### What makes a report actionable

Please include:

1. **Target** — contract or module + function (e.g. `AgentEscrow.sol::release`).
2. **The tree you tested** — the 40-hex commit you were on. A finding against an unnamed tree
   cannot be reproduced, and we will have to ask before we can even agree it is a finding.
3. **Baseline** — the test count you observed (e.g. `forge test` → `191 passed`). If your baseline
   and ours differ, we resolve *that* first; otherwise we may be arguing about two different repos.
4. **Impact** — fund loss, double-spend, stranding, authorization bypass, replay, or state
   corruption, and who is harmed.
5. **Reproduction** — a failing Foundry test, a PoC, or exact steps. A description we cannot run is
   a hypothesis, and we will treat it as one.

State explicitly whether you want to be **credited by name** or stay **anonymous**. Both are fine.

---

## What we consider in scope

- **Fund loss / theft**, **double-spend**, or **stranding** of escrowed, channel, or delegated value.
- **Authorization bypass** — reaching a privileged path (`onlyOwner` / `onlyAdmin` / party checks)
  without being authorized.
- **Replay** of a signature, a receipt, or a checkpoint across receipts, chains, or deployments.
- **Unbounded authorization** — a delegated spend that exceeds or escapes its on-chain policy cap.
- **State corruption** that leaves a receipt, channel, or escrow in an unrecoverable or dishonest
  state — including a state that is *silent* about a failure rather than loud about it.
- **Off-chain settlement orchestrator** (`offchain/`) — checkpoint/idempotency failures that allow a
  double-settle after a crash or a replay.
- **Evidence tooling** — anything that lets a claim pass the ledger without the bytes to back it.

**Out of scope:** gas optimization, style, naming, and design items already disclosed in the
finding records above (multisig/timelock custody, delegation debit semantics, `YUAN` mint
centralization). If you disagree with a disclosed decision, we want that discussion too — open a
Discussion, not a security report.

---

## Our commitments

- **Acknowledge** within **48 hours**.
- **First assessment** (in scope? severity?) within **5 business days**.
- **Credit** you in the fix and in this file, unless you ask to stay anonymous.
- **Coordinated disclosure** — we do not publish details before a fix ships, and we tell you when
  it does.

---

## 处置口径 · how we actually handle a report

These five rules are not aspirations; they are the standard we will hold ourselves to in public.
They exist because we have already been on the wrong side of each one.

**1. 先复现，后判断。** 不复现，不下结论。没有跑过的报告既不能确认也不能否认 —— 那是
`UNDECIDABLE`，不是「已驳回」。

**2. 先写 BugProof，再修。** 先写一个**断言"错误行为存在"**的测试并让它跑绿 —— 这证明洞是真的；
修复后把它反转成回归测试，证明洞不再回来。只改代码不留下这条测试，等于下一次重构时把洞重新打开。

**3. 三个数字必须一致。** 报告里的基线、我们复现的基线、修复后 CI 的数字。对不上时，先去查
**我们看的是不是同一棵树**，不要去解释结论。我们曾经在自己看不见上游的仓库里断言「这个提交不存在」，
而那只是那个仓库看不见它。

**4. 说错了就公开更正。** 不删、不悄悄改、不换个说法重发。更正与原文同一渠道，并且写明**错在哪一步**。

**5. 不买沉默。** 不因披露施压，不用"研究用途"降低标准，不在修复前公开细节；也**不会**用一份
感谢名单去换一句"没问题"。

---

## Disclosure record

| Date | ID | Severity | Finding | Status | Record |
|---|---|---|---|---|---|
| 2026-10-22 | escrow-timeout-refund | high | timeout-refund path could pay the same escrow twice | fixed + regression test | [`docs/FINDING-2026-10-22-escrow-timeout-refund.md`](docs/FINDING-2026-10-22-escrow-timeout-refund.md) |
| 2026-10-26 | L5-01 | critical | `CreditScore` decoded `AgentIdentity.agents()` with the wrong struct shape → a brand-new agent scored 10000/10000 | fixed + regression test | [`docs/FINDING-2026-10-26-L5-01-02-03.md`](docs/FINDING-2026-10-26-L5-01-02-03.md) |
| 2026-10-26 | L5-02 | high | `recordContribution` only checked `agentExists` → anyone could write contributions to any agent | fixed + regression test | same |
| 2026-10-26 | L5-03 | medium | `crossChainSettle` debited `ch.balance` without transferring, and both sender and receiver could call it | fixed + regression test | same |
| 2026-10-26 | L5-02b | high | unbounded intermediate in the score formula (`quality*complexity*timeliness / 1e18`) | fixed + regression test | same |
| 2026-11-10 | A2A-escrow-bond-lock | high | overpaid dispute bond was recorded at `msg.value` but only `requiredBond` was kept → ledger > vault → `resolveDispute` reverts → the escrow is locked for **both** parties | fixed + regression test | [`docs/FINDING-2026-11-10-A2A-escrow-bond-lock.md`](docs/FINDING-2026-11-10-A2A-escrow-bond-lock.md) |
| 2026-11-10 | A2A-b1/d1/g2 | medium | same pass: empty `proofOfDelivery` counted as delivery · payee had no exit if the payer went dark · no per-escrow accounting on a shared vault | fixed + regression test | same |
| 2026-11-11 | escrow-cei | medium | both payout paths updated `totalHeld` *after* the outbound call (safe only by an ordering accident in a different statement) | fixed + `nonReentrant` + mutation-verified regressions | same |

Each of the above is pinned by a test whose name says what it prevents; deleting the fix makes the
suite red. That is the only form of "we fixed it" we accept.

---

## Hard rules for our own code (from Constitution L0)

- No change may **weaken withdrawal or revoke authority** — humans stay in control.
- Any path that could **double-spend or lose funds** is top-priority, even mid-discussion.
- Settlement is **final**; reversibility belongs to the authorization and custody layers, never to
  rewriting a settled receipt.
- **A hidden failure is worse than a loud one.** Reporting `undecidable` is always acceptable;
  reporting it as `supported` is not.

---

## Reporting on this document

If any commitment above turns out to be false in practice — we missed 48 hours, we published before
a fix, we credited someone who asked not to be — say so in an Issue titled
`SECURITY.md commitment breach`. We will treat that as a security report, not as noise.

---

_量子总督 (Quantum Governor) 👽 · for the ORIGIN L5 maintainers_
