# Delegation · whose budget does a delegated spend draw? (M2)

> **Decision (2026-09-25, by the maintainer):** a delegated spend draws the
> **delegator's** budget. The delegate is the *trigger*, not the *funder*.
> This file records why, so the semantics are not re-litigated later.

## 1. The finding (M2, pre-decision)

`L5Delegation.spend` performed:

```solidity
IERC20(d.token).safeTransferFrom(msg.sender, _payTo, _amount); // msg.sender == delegate
```

So the money came out of the **delegate's own** wallet. But the contract hands the
**delegator** every lever — `maxPerRequest` / `maxPerPeriod` / `period` /
`validUntil` / `allowedPayTo` / `resourcePattern` / `revoke`. If the delegate spends its own
funds, the delegator's "authority" over assets is empty: the whole `delegator` / `revoke`
apparatus controls nothing but a self-imposed limit on someone else's money.

## 2. The decision

```solidity
IERC20(d.token).safeTransferFrom(d.delegator, _payTo, _amount); // delegator funds; delegate triggers
```

The delegator must `approve` the `L5Delegation` contract for the token. The effective
authority to move funds is then the **intersection of two gates**:

1. the delegator's on-chain **allowance** (delegator-controlled, revocable at any time), **and**
2. the delegation's **caps** (`maxPerRequest`, `maxPerPeriod`, `allowedPayTo`, `resourcePattern`, validity).

This is the same shape as `L5x402` after H2 ("allowance **AND** policy"). The two layers now
model the same thing: *the principal pays, within a policy the principal set.*

## 3. Why this is the right answer

- **ERC-7710 semantics.** A delegation is authority over the *delegator's* assets; the delegate
  acts *on the delegator's behalf*. Spending the delegate's own funds is not a delegation at all.
- **Constitution L0 (human will is the highest law).** `revocable` is described as the on-chain
  mapping of L0. It is only meaningful if what is revoked is the human's own budget.
- **`allowedPayTo` ("防转付" — anti-diversion).** A delegator cares *where* the money goes only if
  it is the delegator's money that moves.
- **Consistency.** H2 already made the x402 gate "allowance AND policy". Making `spend` draw the
  delegator's allowance puts the delegation layer and the x402 gate on the same model — which also
  dissolves the M7 "two ledgers" ambiguity: both now mean *the delegator pays, within the policy*.

## 4. What changed vs. what did not

- **Changed:** `spend` debits `d.delegator` (was `msg.sender`). Tests mint to / approve from the
  delegator. New regressions: `test_SpendDebitsDelegatorBudgetNotDelegate`,
  `test_SpendRequiresDelegatorAllowance`.
- **Unchanged:** the caps, `revoke`, `suspend` / `unsuspend`, period rollover, resource matching,
  and `onlyDelegate` (the delegate still *triggers* the spend). No interface signature changed.

## 5. Non-goals

- Not a custody contract — it does not hold funds; it moves the delegator's tokens directly to
  `allowedPayTo`. Contestable funds belong in `AgentEscrow`, not here.
- No off-chain signer added. Authority is the delegator's on-chain approval + the caps.
