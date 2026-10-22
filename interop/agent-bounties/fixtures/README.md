# Wallet / escrow conformance fixtures

Synthetic, version-pinned escrow cases, built to answer the review in
`NSPG13/agent-bounties#1478` — the nine-case matrix, with the controls that were
asked for.

Everything here is synthetic. No account, no key, no stake, no wallet, no node,
no live payment is involved or required.

## What is here

| File | Role |
| --- | --- |
| `matrix.json` | Nine cases. Each has a declared escrow identity, an event log, a claim, and an expected verdict. |
| `run_matrix.py` | Reference checker. Replays each log through the escrow state machine and classifies the claim. |

## What a row contains

```
agreement   the agreement the escrow is bound to (consumer, provider, value, state)
escrow      the escrow's public fields (payer, payee, amount, deadline, state)
events      what an outside observer can see, in order, with sequence numbers
claim       the proposition being tested, in machine-readable form
expected    supported | rejected | indistinguishable
controls    wrong-recipient | duplicate-event | interrupted-claim | withheld-claim
pins        Foundry test functions that pin the real contract's behaviour for this row
```

The claim is not prose. It is `{kind, escrowId, recipient, amount}`, so the
checker compares numbers to numbers instead of reading a sentence and agreeing
with it.

## Run it

```
python fixtures/run_matrix.py            # table
python fixtures/run_matrix.py --json     # machine-readable rows
python fixtures/run_matrix.py --verbose  # per-event state trace
```

Exit code is 0 only when every row's computed verdict equals its expected
verdict **and** every pin resolves to a test function that exists.

## The nine cases

| # | Case | Expected | Control |
| --- | --- | --- | --- |
| C1 | funded, no delivery claim, deadline passes, payer refunded | supported | |
| C2 | same, then the payer calls `release()` anyway | rejected | |
| C3 | delivery verified, payer has not released | rejected | |
| C4 | delivered, verified, released once | supported | |
| C5 | release event pays an address that is not the payee | rejected | wrong-recipient |
| C6 | two `EscrowReleased` for one escrow | rejected | duplicate-event |
| C7 | verified delivery, then a refund is attempted | rejected | interrupted-claim |
| C8 | same log as C1, claim is "no delivery claim was made" | indistinguishable | withheld-claim |
| C9 | payer cancels before delivery, then tries to release | rejected | |

## The one row we cannot decide, and did not round up

**C8 is `indistinguishable`, and that is the honest answer, not a pass.**

`EscrowTimeout` proves a contract state: the deadline passed while the escrow was
still `Funded`. It is not a signed statement of non-delivery, and it is not
evidence about anything that happened off-chain. So these two worlds produce an
observationally identical log:

- the provider never claimed delivery;
- the provider claimed delivery and the claim was withheld from us.

Closing this needs signed non-delivery, or a claim-inclusion proof over a log the
payer cannot filter. Neither exists in this repository today. C8 exists to keep
that visible, and it will stay `indistinguishable` until the evidence type
changes — not until we write a better description of it.

## Scope limits, stated rather than implied

1. **This is a reference model, not an on-chain run.** `run_matrix.py` replays
   logs against a hand-written state machine that mirrors `src/AgentEscrow.sol`.
   It does not execute Solidity and it does not talk to a chain. Where a row's
   real behaviour matters, it is pinned to a Foundry test through `pins`, and the
   checker verifies that the named function actually exists. A pin is a pointer
   to executable evidence, not a substitute for it — run `forge test` yourself.
2. **`supported` is about the log, not the operator.** It means the events
   establish the claim. It says nothing about whether the operator is honest.
3. **`rejected` is not an accusation.** It means the claim as stated does not
   follow from what is observable — usually because the claim was written more
   strongly than the evidence allows.
4. **The matrix tests one escrow at a time.** Cross-escrow solvency (one escrow's
   payout being funded by another's deposit) is covered by the C2 regression
   test, not by this matrix.
5. **Nine rows is not a conformance suite.** It is nine falsifiable statements.
   Adding rows is cheap; please send the ones you think we are missing.

## Found while building this

Row C2 was **failing** on `main` before 2026-10-22. The timeout branch of
`refund()` set the escrow to `Verified` — the state `release()` requires — and
left `esc.amount` intact, so a keeper-triggered timeout refund could be followed
by a payer `release()` that paid the provider out of a different escrow's funds.
`settle()` was also unreachable: it called `this.release()`, which makes
`msg.sender == address(this)`, failing the payer-only guard unconditionally.

Both are fixed in the commit that adds this directory. Full write-up:
`docs/FINDING-2026-10-22-escrow-timeout-refund.md`. Regression:
`test/TimeoutReleaseDoubleSpend.t.sol`.

This row is the one your review was pointing at, and you were right that it was
the one most likely to expose us. It was worse than under-evidenced.

## Credit

The case design — nine cases plus wrong-recipient, duplicate-event and
interrupted/withheld-claim controls, and the insistence that a signed receipt is
not proof of payment — is NSPG13's, from
`NSPG13/agent-bounties#1478`. The defects found by running it are ours.
