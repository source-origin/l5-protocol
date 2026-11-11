# FINDING 2026-11-10 · AgentEscrow: ledger ahead of the vault (A2 / B1 / D1 / G2)

**Status:** FIXED — fix + regression suite in `src/AgentEscrow.sol` / `test/AgentEscrowRedTeam.t.sol`.
**Severity:** A2 = High (permanent stranding of escrowed value). B1 / D1 = Medium. G2 = Informational
but the most important of the four.
**Found by:** `redteam_demo.py` — a blue-team exercise that deliberately does not walk the happy path.
**Tree:** local `main` @ `cbc7741` + this change. Baseline after fix: `forge test` → **188 passed,
0 failed, 0 skipped** across **25 suites** (measured 2026-11-11).

---

## One root cause, four symptoms

Every defect below is the same mistake seen from a different angle: **the contract never compared
what it owed against what it held.**

### A2 (High) — VULN-A2A-0001: an overpaid dispute bond strands the escrow forever

```solidity
uint256 requiredBond = requiredDisputeBond(escrowId);
require(msg.value >= requiredBond, "Escrow: insufficient dispute bond");

esc.disputeBond = msg.value;                 // records the FULL payment
esc.state = EscrowState.Disputed;

if (msg.value > requiredBond) {
    (bool ok,) = msg.sender.call{value: msg.value - requiredBond}("");  // ...refunds the excess
    require(ok, "Escrow: bond refund failed");
}
```

`resolveDispute()` then pays out `esc.amount + esc.disputeBond` from a single
`address(this).balance`. Ledger > actual by exactly `msg.value - requiredBond`. The payout reverts,
the revert rolls `state` back to `Disputed`, and **both** exits from `Disputed` are dead:
`release`/`refund` require `Verified`, `resolveDispute` requires `Disputed` and can never succeed.
Nobody recovers the money — not the innocent party either.

Measured (py-evm, same bytecode, one variable changed):

| Case | Bond sent | Result |
|---|---|---|
| exact `requiredBond` | 20 000 000 000 000 wei | ✅ resolves, payee receives `amount + bond`, vault drains to 0 |
| `requiredBond + 1` | 20 000 000 000 001 wei | ❌ `Escrow: bond to payee failed`, 0.00202 ETH stranded |

The realistic trigger is **not** malice. An agent that rounds up, or that reads the sibling
`channelDisputeBond` (0.05 ether — 25× the 0.002 ETH escrow) as the amount to send, locks its own
escrow out of arbitration. Nothing on chain tells it that it did.

### B1 (Medium) — empty `proofOfDelivery` counted as delivery

`verifyDelivery` accepted `bytes("")`. "I delivered" and "I proved delivery" were indistinguishable.
Now `require(proofOfDelivery.length > 0, "Escrow: empty proof")`.

### D1 (Medium) — payee had no exit when the payer went dark

After delivery the escrow is `Verified`. `refund()`'s timeout branch only accepts `Funded`;
`release()` / `settle()` are payer-only. So a payee whose payer disappeared had exactly one exit:
post a dispute bond and wait for a single owner signature. In an agent-to-agent economy that makes a
human the single point of failure for machine-to-machine trade.

Added `claimAfterDeadline()`: payee-only, `Verified` only, after `deadline + claimGracePeriod`
(default 1 day), no bond, no owner signature. The grace period is what keeps it from being a
race against the payer's own `release`.

### G2 (Informational, but load-bearing) — one vault, no per-escrow accounting

All escrows share `address(this).balance`. A "ledger > actual" bug is therefore *silently covered by
another escrow's deposit*. Measured before the fix: the exact same overpayment that strands a clean
vault **resolved successfully** on a vault that already held stuck funds. One bug gets underwritten
by the next user's deposit, and no assertion fires.

Fix: `uint256 public totalHeld` + a `solvent()` guard on every payout entry point
(`release`, `settle`, `refund`, `resolveDispute`, `claimAfterDeadline`, channel paths).
A shortfall now becomes a loud revert on the *next* payout instead of a quiet bailout.

---

## The fix

```solidity
- esc.disputeBond = msg.value;
+ esc.disputeBond = requiredBond;   // ledger takes what the vault actually kept
+ totalHeld += requiredBond;
```

Plus a single bond calculator, so callers and the contract cannot drift apart:

```solidity
function requiredDisputeBond(bytes32 escrowId) public view returns (uint256) {
    uint256 byBps = (escrows[escrowId].amount * disputeBondBps) / 10000;
    return byBps < minDisputeBond ? minDisputeBond : byBps;
}
```

`minDisputeBond` closes a related hole: integer division made dust escrows cost **zero** to dispute,
i.e. free griefing. The cost of an accusation must not be zero.

> Open design item (not fixed here): two "dispute bond" notions coexist — `disputeBondBps` (1% of the
> escrow, used by `dispute()`) and `channelDisputeBond` (fixed 0.05 ether, used by
> `disputeChannel()`). For a 0.002 ETH escrow the fixed value is **25×** the dynamic one. An agent
> following a UI hint can pay the wrong one. Either unify them behind one function or rename the
> channel one so no caller can confuse them.

---

## Regressions that must stay red-to-green

`test/AgentEscrowRedTeam.t.sol` — 11 tests. Each defect gets a positive control, because a gate that
rejects everything also passes the negative case.

| Test | What it pins |
|---|---|
| `test_A2_OverpaidBond_StillResolves_AndExcessIsRefunded` | overpay resolves; ledger == funds held; excess returned |
| `test_A2_ExactBond_ControlCase` | the case that always worked still works |
| `test_A2_UnderpaidBond_Reverts` | underpay refused, and refusing moves no money |
| `test_B1_EmptyProof_Reverts` | empty proof rejected, state stays `Funded` |
| `test_B1_NonEmptyProof_StillVerifies` | positive control for B1 |
| `test_D1_PayeeClaimsAfterDeadline_WithoutOwner` | payee exit works with no payer, no owner; refused inside grace |
| `test_D1_ClaimAfterDeadline_AccessControl` | stranger and never-delivered cases refused |
| `test_G2_LedgerMatchesBalance_OnDirtyVault` | **dirty vault**: balance == totalHeld, unrelated escrow untouched |
| `test_G2_UndercollateralizedVault_Reverts` | `release` hard-reverts when short |
| `test_G2_UndercollateralizedVault_ResolveDisputeReverts` | each payout path carries its own guard |
| `testFuzz_G2_BalanceNeverBelowLedger` | invariant over 256 runs |

**The lesson that outlives these tests:** a single-escrow test can never see G2. Balance-bearing
contracts must be exercised twice — once on a clean vault, once on a vault that already holds funds.

---

## Scope and honesty

- Confirmed on an in-process **py-evm** chain; the Solidity source is identical, and the defect is
  chain-independent. Not reproduced on origin-1 / BSC.
- No funds were lost, because this system **has not yet carried real money**. The impact above is the
  impact it *would* have had.
- This finding fixes the contract; it does not make the contracts audited. `SECURITY.md` still says:
  research-grade, do not use with real funds.
