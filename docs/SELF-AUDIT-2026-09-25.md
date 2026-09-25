# ORIGIN L5 · Self-Audit Record — 2026-09-25

> **Why this file exists.** This repo is a settlement layer, and a settlement layer earns
> the right to be written to by strangers only if the strangers can *read* it. So we audit
> our own code **in the source tree**, fix what is wrong, and publish the record — findings,
> the exact commit that closed each one, and the regression test that proves it stayed closed.
>
> **Criterion we hold ourselves to:** *not* "how few bugs are left", but **"would an
> independent reviewer flag this repo?"** Every item below is reproducible with `forge test`.

- **Scope:** `src/` (9 contracts) — identity, agreement, escrow / payment channels, delegation, x402 gate, credit, token.
- **Method:** manual in-source review, no reliance on memory; every claim tied to a line reference and a runnable test.
- **Baseline reviewed:** `main` through `807e1ee` (the commit carrying the external EMILIA review fixes).
- **Toolchain:** `solc 0.8.28`, Foundry, OpenZeppelin v5. `forge fmt --check` clean.

---

## 1. Summary

| ID | Severity | Contract | Status | Closed in |
|---|---|---|---|---|
| C1 | CRITICAL | `AgentEscrow.resolveDispute` | ✅ fixed | `9c69cfe7b60` |
| C2 | CRITICAL | `AgentEscrow.finalizeSettlement` (reentrancy) | ✅ fixed | `9c69cfe7b60` |
| C3 | CRITICAL | `AgentIdentity` privileged fns | ✅ fixed | `9c69cfe7b60` |
| C4 | CRITICAL | `AgentEscrow.setDisputeBond` | ✅ fixed | `9c69cfe7b60` |
| H2 | HIGH | `L5x402` spend cap not enforced on-chain | ✅ fixed | `ecef8a5b41b` |
| H3 | HIGH | `L5x402` receipt-evidence signature not domain-bound | ✅ fixed | `ecef8a5b41b` |
| H4 | HIGH | `L5x402` finality reachable without value movement | ✅ fixed | `ecef8a5b41b` |
| M3 | MEDIUM | `AgentEscrow` channel voucher not domain-bound; no low-s | ✅ fixed | `23584042d38` |
| M4 | MEDIUM | `AgentAgreement(V3)._verifyEIP712Signature` hand-rolled ecrecover, no low-s | ✅ fixed | `23584042d38` |
| H1 | HIGH | `L5x402` settled receipts are non-disputable | ✅ resolved by design (below) | — |
| M1 | MEDIUM | single-owner authority → multisig + timelock | ✅ resolved (2-of-3 Safe + 48h timelock) | `L5Ownership.t.sol` · `L5Governance.t.sol` |
| M2 | MEDIUM | `L5Delegation.spend` debit-semantics | ✅ resolved (draws the delegator's budget) | `L5Delegation.t.sol` |
| M5 | MEDIUM | `YUAN` mint centralization | ✅ fixed (Foundation issuance caps) | `L5MintPolicy.t.sol` |

Tests: **128 passing / 0 failing / 0 skipped**. Suites added by this audit: `L5x402Hardening.t.sol` (9), `L5AccessControl.t.sol` (8), `L5SignatureHardening.t.sol` (5), `L5Adversarial.t.sol` (6), `L5Ownership.t.sol` (7), `L5MintPolicy.t.sol` (9), `L5Governance.t.sol` (10), `L5Fuzz.t.sol` (10), `L5x402Fuzz.t.sol` (6).

---

## 2. CRITICAL — unauthorized privileged paths (C1–C4)

The reviewed baseline left several privileged functions with their access check
**commented out** behind a `// 未来：由贡献时钟 / DAO 调用` note. Until that wiring exists,
the functions were callable by anyone.

- **C1** `AgentEscrow.resolveDispute` — no authorization; any caller chose `payeeWins` and released escrow.
- **C2** `AgentEscrow.finalizeSettlement` — `.call{value}` executed before state was written and with no reentrancy guard → double payment.
- **C3** `AgentIdentity.upgradeVerification` / `recordRevenue` / `suspendAgent` / `slashAgent` — anyone could inflate verification level, fabricate revenue (which feeds reputation, the leaderboard, and credit limits), or slash/suspend any agent.
- **C4** `AgentEscrow.setDisputeBond` — the dispute-bond rate was world-writable.

**Fix.** Every one of these is now gated (`onlyOwner` / `onlyAdmin`) as a strict stopgap, and
`finalizeSettlement` follows checks-effects-interactions under `nonReentrant`. The functions
are annotated as *awaiting their real caller* (a contribution clock / DAO), i.e. the `onlyOwner`
lock is a **floor**, not the final authority model. Reintroducing the intended caller is a
scoped follow-up, tracked by M1.

*Regression:* `L5AccessControl.t.sol` (8) — each path reverts for a non-privileged caller, and
the reentrancy attack is paid exactly once.

---

## 3. HIGH — x402 gate (H2–H4)

- **H2 · spend cap was not enforced on-chain.** `recordReceipt` settled whenever allowance alone
  sufficed; an *unregistered* policy silently minted `maxPerPeriod = uint256.max` — the exact
  "unbounded authorization" this project exists to avoid. Settlement now requires
  **allowance AND `_policyAllows(...)`** (registered + delegate match + within cap). An unknown
  policy grants **nothing** (receipt stays `Pending`), and settling consumes the policy budget.
- **H3 · evidence signature was not domain-bound.** `verifyReceiptEvidence` recovered over a bare
  `personal_sign` digest → cross-receipt / cross-chain replay. It now recovers over
  `receiptEvidenceDigest(receiptId, payloadHash)` (EIP-712 over `chainId` + `verifyingContract` +
  both fields).
- **H4 · finality reachable without value movement.** A verdict could be attached / a receipt
  marked `Final` before any value moved. All three paths now require the receipt to be in a
  value-moved state and revert `"L5x402: value not moved"` otherwise (fail closed).

*Regression:* `L5x402Hardening.t.sol` (9).

---

## 4. MEDIUM — signature layer (M3–M4)

- **M3 · channel vouchers were not domain-bound.** `AgentEscrow` recovered `settleChannel` /
  `disputeChannel` signatures over an un-domained struct via a hand-rolled `ecrecover` with no
  low-s check → cross-chain replay + malleability. Vouchers now use
  `channelVoucherDigest(channelId, nonce, amount)` (EIP-712 over `chainId` + `verifyingContract`)
  and `_recoverSigner` routes through `ECDSA.tryRecover` (canonical low-s; malformed → `address(0)`).
  *Deliberately retained:* either channel party may vouch (`sender` authorizes a release, `receiver`
  claims one). This is **not** a theft vector — both are parties to the channel — and the C2
  reentrancy regression depends on a contract receiver being unable to sign.
- **M4 · agreement EIP-712 used a hand-rolled `ecrecover` with no low-s enforcement.**
  `AgentAgreement` / `AgentAgreementV3._verifyEIP712Signature` now route through `ECDSA.tryRecover`,
  so a malleable (high-s) signature is refused.

*Regression:* `L5SignatureHardening.t.sol` (5).

---

## 5. Design decision — H1: **settlement is final**

`L5x402` settled receipts cannot enter the dispute/refund path (`disputeReceipt` reverts on a
`Settled` receipt). This is **intentional**, and is how "L0 revocability" is meant to be honored:

1. An x402 receipt is a **post-hoc fact**, not a custody receipt. Once value has moved, it records
   history — and history is append-only.
2. Reversibility lives in the **right layer**: the *authorization* layer (`L5Delegation` spend
   policies can be revoked/suspended) and the *custody* layer (`AgentEscrow` holds funds **before**
   settlement and can refund). Funds that need to be contestable belong in escrow, not in a receipt.
3. Compensation, when owed, is issued as a **forward instrument** (a new compensating receipt /
   transfer) — never by rewriting a settled one. Allowing a settled receipt to be reversed would put
   a dispute key **on the fund path**, which contradicts the goal that no single key sits on the path.

---

## 5·1. Decision — M5: issuance authority belongs to the Foundation

`YUAN.issueService` previously let **any** whitelisted provider mint, bounded only by `MAX_SUPPLY` —
so a single whitelisted address could print to the hard cap. The owner's ruling (2026-09-25): **the right
to mint belongs to the 源 Foundation, and the amount issued is adjusted in response to the market.**

The mechanism now in code: issuance requires **eligibility AND a Foundation-set per-provider ceiling
AND** the hard cap. `setServiceProvider` alone grants nothing (fail-closed): until
`setProviderMintCap(p, cap)` is called, provider `p` mints zero. The market-responsive lever is the
cap — lowering it immediately blocks further issuance, raising it re-opens room. Issuance still only
happens through `issueService` against **delivered service units** (no raw `owner.mint`), so the
"no YUAN without a service" property is retained while the supply decision moves to the Foundation.
All three levers are `onlyOwner` and route through the M1 multisig / timelock. See
[`TOKEN-POLICY.md`](TOKEN-POLICY.md).

*Regression:* `L5MintPolicy.t.sol` (9) — uncapped provider mints nothing; cap is cumulative and
cannot be exceeded; lowering the cap blocks further minting; cap and rate are owner-only.

---

## 5·2. Decision — M2: a delegated spend draws the **delegator's** budget

`L5Delegation.spend` previously did `safeTransferFrom(msg.sender, ...)` (= the delegate's own funds).
That made the delegator's whole apparatus — caps, `allowedPayTo`, `resourcePattern`, `revoke` —
control nothing but a self-imposed limit on someone else's money. The maintainer's ruling:
**the delegator funds, the delegate triggers.** `spend` now draws `d.delegator`, so the effective
authority is the **intersection of the delegator's allowance AND the delegation's caps** — the same
"allowance AND policy" shape as the hardened x402 gate (H2), and the same reading that dissolves the
M7 two-ledger ambiguity. Rationale: ERC-7710 (authority over the delegator's assets), L0
(`revocable` is only meaningful over the human's own budget), and `allowedPayTo`'s anti-diversion
intent. See [`DELEGATION-POLICY.md`](DELEGATION-POLICY.md).

*Regression:* `L5Delegation.t.sol` — `test_SpendDebitsDelegatorBudgetNotDelegate` (the delegate's own
balance is untouched), `test_SpendRequiresDelegatorAllowance` (revoking the delegator's approval
blocks the spend even within cap).

---

## 5·3. Decision — M1: authority moves to a 2-of-3 Safe behind a 48h timelock

The owner's ruling (2026-09-25): **threshold 2-of-3, timelock delay 48h**, applied **uniformly** to
every privileged path (no "config-only = instant" fast-path — a silent faster path is exactly what a
reviewer looks for). The code half was already shipped (`Ownable2Step` on all 7 ownable contracts);
the operational half now ships as [`script/DeployGovernance.s.sol`](../script/DeployGovernance.s.sol) —
a `TimelockController(minDelay = 48h, proposers = [Safe], executors = [Safe], admin = 0)` — plus the
governance regression `test/L5Governance.t.sol`. With `admin = 0` there is **no fast-path key**: the
timelock administers itself, so even a role change must be timelocked. Rationale, residual
assumptions (the Safe's three keys must be independent humans; no emergency bypass — the 48h window
*is* the defense), and the handover runbook are in [`GOVERNANCE-M1.md`](GOVERNANCE-M1.md).

*Regression:* `L5Governance.t.sol` (10) — the operation is not ready before 48h and ready after; a
single approval is insufficient (2-of-3); a signer EOA holds no role and cannot schedule; `admin = 0`
leaves no fast-path key; and the two-step ownership handover completes **only** through the timelock.

---

## 6. Known open items (disclosed, not hidden)

- **M6 · documented integration hooks are not wired.** `L5Delegation.identityContract` /
  `.escrowContract` and `L5x402.identityContract` / `.escrowContract` are settable (`onlyOwner` /
  `onlyAdmin`) but **never read** — the AgentIdentity / AgentEscrow integration the comments describe
  is not implemented. No exploit (nothing reads them), but it is a *truthfulness* gap a reviewer would
  name: the accessors exist so they are not dead code, yet they grant no behaviour. Tracked as a
  scoped follow-up to either implement the checks or remove the hooks; **not** silently dropped.
- **M7 · two spend ledgers for one logical policy.** An x402 policy's budget is tracked in **two
  independent counters**: `L5x402.SpendSnapshot.spentPeriod` (consumed at `recordReceipt`) and
  `L5Delegation.Delegation.spentThisPeriod` (consumed at `spend`). If both are used for the same
  logical policy, the effective cap is the *sum*, not either one. This is a design seam, not a bug in
  either contract; unifying the two (one authoritative budget, one read view) is a scoped change to
  make before real funds. *M2's resolution sharpened this:* both counters now mean the same thing
  (*the delegator pays, within the policy*), which is what makes one authoritative budget the
  natural end state rather than a choice between two models.

None of these are silent: they are listed here so a reviewer can weigh them rather than discover them.

---

## 7. Reproduce

```bash
git clone --recursive https://github.com/source-origin/l5-protocol.git
cd l5-protocol
forge fmt --check      # clean
forge test             # 128 passed, 0 failed
```

Hostile-case discipline: every negative test in `L5Adversarial.t.sol` / `L5AccessControl.t.sol`
must **fail closed, for the correct reason, independently** — a test that passes for the wrong
revert string is treated as a defect.

Fuzz discipline: [`L5Fuzz.t.sol`](../test/L5Fuzz.t.sol) and [`L5x402Fuzz.t.sol`](../test/L5x402Fuzz.t.sol)
sweep the input domain (256 runs each) to assert the properties that matter — a delegated spend
never exceeds its per-request or period cap and always draws the delegator's budget; revocation and
expiry are absolute walls; a channel and an escrow each conserve value exactly; and an x402 receipt
settles only under the payer's own fresh signature and moves exactly the signed amount (an expired
or replayed authorization never settles, and without allowance it stays Pending, never Final).
Example-based tests pin the edges; fuzz shows the edges are not special. (Note for authors: under
`via_ir` the optimizer may treat `block.timestamp` as constant within a call frame, so derive a past
deadline arithmetically after `vm.warp` rather than relying on a pre-warp read.)

---

## Disclosure of this record

This is a **self**-audit, not a third-party audit, and must not be read as one. It is published so
that independent reviewers can check our work and so nothing is discovered that we already knew.
To report a vulnerability privately, see [`SECURITY.md`](../SECURITY.md).

_量子总督 (Quantum Governor) 👽 · 2026-09-25 · for the ORIGIN L5 maintainers_
