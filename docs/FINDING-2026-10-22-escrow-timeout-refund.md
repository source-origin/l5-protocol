# Security finding · 2026-10-22 · escrow timeout-refund double spend

**Status:** fixed in working tree, **not yet pushed** (GitHub API rate limit + no valid PAT as of 2026-10-22 22:40 +0800)
**Contract:** `src/AgentEscrow.sol`
**Regression test:** `test/TimeoutReleaseDoubleSpend.t.sol` (6 tests)
**Found by:** self-review while answering NSPG13's escrow conformance review (`NSPG13/agent-bounties#1478`)

---

## D1 (critical) — timeout refund was not terminal

`refund()` chose its branch by **caller**, not by **reason**:

```solidity
bool isCancellation = esc.state == Funded && msg.sender == esc.payer;
bool isTimeout      = block.timestamp > esc.deadline && esc.state == Funded;
...
if (isCancellation) { esc.state = EscrowState.Cancelled; }
else                { esc.state = EscrowState.Verified;  }   // <-- defect
```

Consequences:

1. `Verified` is exactly what `release()` requires. `refund()` did not clear
   `esc.amount` either.
2. So: a keeper (any third party — `refund()` on the timeout path is
   permissionless by design) triggered the timeout refund after the deadline,
   the payer received the money back, and then the payer called `release()`,
   which paid the provider `esc.amount` again — **out of other escrows' funds**.
3. The contract became insolvent: the second consumer's escrow still claimed
   `Funded` + 5 ether while the balance was 0, so her `refund()` reverted on
   `"Escrow: refund transfer failed"`. Money unrecoverable.

Full reproduction (`test_TimeoutRefundByStranger_CannotThenRelease`, the
pre-fix version of which passed against the buggy code):

```
alice funds 5 ether, carol funds 5 ether   -> contract 10 ether
deadline passes, no delivery claim at all
stranger calls refund(alice)               -> alice +5 ether, state = Verified  (BUG)
payer completes terms (any party may)      -> agreement Completed
payer calls release(alice)                 -> bob +5 ether, contract balance 0 (BUG)
carol calls refund(carol)                  -> revert: refund transfer failed
```

Note the extra enabler: `completeTerms()` is `onlyParty` + `Executed`, so the
**payer alone** can mark never-delivered terms complete, which is what
`release()` -> `markSettled()` requires. Nothing about delivery has to be true.

## D2 — `settle()` was dead code

```solidity
function settle(bytes32 escrowId) external ... {
    this.release(escrowId);   // external self-call => msg.sender == address(this)
}
```

`release()` requires `msg.sender == esc.payer`, so `settle()` could never
succeed. It reverted on every input. The bug was invisible because `release()`
worked and every call site used `release()`.

Fixed by extracting `_release(bytes32, Escrow storage)` and calling it
internally from both `release()` and `settle()`.

## Why the 155-test suite missed it

Every existing refund test is **payer-initiated**:

- `L5Core.t.sol::test_EscrowRefund_Timeout` — payer after deadline -> takes the
  cancellation branch -> asserts `Cancelled`. Passes.
- `L5Fuzz.t.sol::testFuzz_Escrow_TimeoutRefundsInFull` — payer after deadline,
  same branch, fuzzes only the amount and gap. Passes.

The timeout branch (`else`) is therefore **unreachable from the existing suite**.
It was never executed by a test. A branch that no test can reach is a branch
that rots silently.

## Divergence worth recording

The off-chain escrow model (`offchain/l5_escrow_link.py::refund`) already did the
right thing: `refund -> CANCELLED`, `funds_locked = 0`, agreement `CANCELLED`,
and it refuses to refund a terminal escrow. The two ledgers disagreed, and the
**model was correct while the contract was wrong**.

## Fix

```solidity
// refund(): terminal in both branches
esc.state = EscrowState.Cancelled;   // was: Verified on the timeout path
if (isCancellation) emit EscrowCancelled(...); else emit EscrowTimeout(...);
```

The `EscrowTimeout` event is still emitted for the timeout case, so the reason
stays observable on-chain; only the state is unified. `esc.amount` is kept as
the historical record rather than zeroed, because state — not the amount — is
what gates `release()`.

## Test result

```
forge test --match-contract TimeoutReleaseDoubleSpendTest   -> 6 passed
forge test                                                  -> 161 passed, 0 failed
```

(`161` = the previous 155 + 6 new.)

## Lesson

Same lesson NSPG13 was pushing towards, applied to our own code: **a state that
can be reached only by a path no test exercises is not a state machine, it is a
guess.** The timeout path is precisely the "funded, no delivery claim" case his
matrix names — and it was broken, not merely under-evidenced.
