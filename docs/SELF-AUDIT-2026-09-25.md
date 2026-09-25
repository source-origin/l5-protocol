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
| M1 | MEDIUM | single-owner authority → multisig + timelock | ◐ code half shipped (`Ownable2Step`); ops pending | `L5Ownership.t.sol` |
| M2 | MEDIUM | `L5Delegation.spend` debit-semantics | ⏳ open (product) | — |
| M5 | MEDIUM | `YUAN` mint centralization | ✅ fixed (Foundation issuance caps) | `L5MintPolicy.t.sol` |

Tests: **100 passing / 0 failing / 0 skipped**. Suites added by this audit: `L5x402Hardening.t.sol` (9), `L5AccessControl.t.sol` (8), `L5SignatureHardening.t.sol` (5), `L5Adversarial.t.sol` (6), `L5Ownership.t.sol` (7), `L5MintPolicy.t.sol` (9).

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

## 6. Known open items (disclosed, not hidden)

- **M1 · single-owner authority.** Every privileged path is `onlyOwner`. That is a strict improvement
  over "no check", but it is a centralization point. **Code half shipped:** `Ownable` → `Ownable2Step`
  on all 7 ownable contracts, so a privileged handover completes only when the incoming owner
  explicitly accepts (a wrong-address transfer can no longer brick admin); regression `L5Ownership.t.sol`.
  **Remaining (operational, owner's call):** point the owner at a multisig + `TimelockController` —
  forward-compatible, no further code change. See [`GOVERNANCE-M1.md`](GOVERNANCE-M1.md).
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
  make before real funds.
- **M2 · `L5Delegation.spend` debit semantics.** Whether a delegated spend draws the delegate's own
  funds or the delegator's budget is a **product-semantics** decision; the contracts must match the
  intended one. *Product decision — pending owner sign-off.*

None of these are silent: they are listed here so a reviewer can weigh them rather than discover them.

---

## 7. Reproduce

```bash
git clone --recursive https://github.com/source-origin/l5-protocol.git
cd l5-protocol
forge fmt --check      # clean
forge test             # 100 passed, 0 failed
```

Hostile-case discipline: every negative test in `L5Adversarial.t.sol` / `L5AccessControl.t.sol`
must **fail closed, for the correct reason, independently** — a test that passes for the wrong
revert string is treated as a defect.

---

## Disclosure of this record

This is a **self**-audit, not a third-party audit, and must not be read as one. It is published so
that independent reviewers can check our work and so nothing is discovered that we already knew.
To report a vulnerability privately, see [`SECURITY.md`](../SECURITY.md).

_量子总督 (Quantum Governor) 👽 · 2026-09-25 · for the ORIGIN L5 maintainers_
