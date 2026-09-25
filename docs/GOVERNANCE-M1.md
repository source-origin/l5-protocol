# M1 · Governance — single-owner → 2-of-3 multisig + 48h timelock

> **Status: decided and wired (2026-09-25).** The owner's ruling is **threshold 2-of-3,
> timelock delay 48h**. The code half shipped earlier (two-step ownership); the operational
> half now ships as a deployment script plus a governance regression suite. What remains is
> the physical act of holding the keys (see §6) — no further code.

## 1. The finding

Every privileged path in the L5 core is `onlyOwner` / `onlyAdmin`:

| Contract | Privileged surface |
|---|---|
| `AgentEscrow` | `resolveDispute`, `setDisputeBond`, `cancelEscrow`, … |
| `AgentIdentity` | `upgradeVerification`, `recordRevenue`, `suspendAgent`, `slashAgent` |
| `L5x402` | `updateSnapshot`, `disputeReceipt`, `refundReceipt`, `attachVerdict`, `markProvisional`, `setDelegationContract` |
| `L5Delegation` | `suspend`, `unsuspend`, `setIdentityContract`, `setEscrowContract` |
| `YUAN` | `setServiceProvider`, `setProviderMintCap`, `setAnchorRate` |
| `CreditScore` | `setWeights`, `setSlashPenalty`, `setCreditLimitPerK`, `setIdentity` |
| `X402FacilitatorAdapter` | `setFacilitator`, `setL5x402` |

This is **strictly better than the reviewed baseline** (where these checks were commented out and
open to anyone — C1–C4). But a **single EOA** holding all of it is a centralization point: one key
compromise or loss can freeze dispute resolution, move escrow, or alter the mint rate. For a
settlement layer whose whole claim is *"the rail is owned by no single platform"*, that gap is the
one a reviewer will name next.

## 2. What is already done (this repo)

**`Ownable` → `Ownable2Step` on all 7 ownable contracts.** Ownership is no longer handed over in a
single call — the incoming owner must `acceptOwnership()`, and `pendingOwner()` is readable on-chain.
This removes the footgun where a `transferOwnership` to a wrong / uncontrollable address **bricks
admin permanently** (frozen disputes, stuck escrow, unadjustable bond). Regression:
`test/L5Ownership.t.sol` (7 tests).

This is **additive and forward-compatible**: wiring a multisig / timelock as the owner later requires
**no further code change** (see §4).

## 3. The decision (2026-09-25)

| Parameter | Ruling |
|---|---|
| Signer set / threshold | **2-of-3** — three human keyholders; any two may act |
| Timelock delay | **48 hours** |
| Scope | **uniform** — every privileged path sits behind the same 48h timelock |
| Who holds the keys | the human keyholders (a Gnosis Safe); automation holds none (Constitution L0) |

**Why uniform, with no "config-only = instant" fast path?** A second, faster path is precisely the
thing a reviewer looks for: it would let a live key change `setIdentityContract` / `setL5x402` /
`setFacilitator` with no observation window. One delay, no exceptions, keeps the process auditable
end to end. If a real need for a fast path ever appears, it belongs in its own review — not as a
silent bypass bolted onto this one.

## 4. Wiring (this repo)

[`script/DeployGovernance.s.sol`](../script/DeployGovernance.s.sol) stands up the stack and performs
step 1 of the handover:

```
TimelockController(minDelay = 48h, proposers = [Safe], executors = [Safe], admin = address(0))
```

- `proposers = [Safe]` / `executors = [Safe]` — only the 2-of-3 quorum may schedule and execute.
- `admin = address(0)` — **no admin key**: the timelock administers itself, so even a role change
  must go through a timelocked proposal. There is no account that can act instantly (OZ grants
  `DEFAULT_ADMIN_ROLE` only to the timelock contract itself).

Ownership handover is two-step (that is the point of §2):

1. **current owner** → `transferOwnership(timelock)` — performed by the script (broadcast as the
   current owner).
2. **the timelock, driven by the Safe** → `schedule` an `acceptOwnership()` call, wait 48h, then
   `execute` it, for each contract. The script prints the exact calldata to propose.

Runbook:

```bash
# 1. create the 2-of-3 Safe (out of band), then:
export MULTISIG=0x...                       # the Safe address
export AGENT_ESCROW=0x... AGENT_IDENTITY=0x... L5X402=0x... \
       L5_DELEGATION=0x... YUAN=0x... CREDIT_SCORE=0x... X402_ADAPTER=0x...
forge script script/DeployGovernance.s.sol --rpc-url $RPC --broadcast
# 2. from the Safe: schedule each printed acceptOwnership() op, wait 48h, execute.
```

Regression: [`test/L5Governance.t.sol`](../test/L5Governance.t.sol) (10 tests) exercises the real
`TimelockController` with a minimal in-test 2-of-3 Safe — the delay is enforced (`isOperationReady`
is false before the window and true after), a single approval is not enough, an EOA signer holds no
direct role and cannot schedule, `admin = 0` leaves no fast-path key, and the two-step handover
completes **only** through the timelock.

## 5. Residual trust assumptions (stated, not hidden)

- **The Safe's 2-of-3 is only as strong as its three keys.** They must be independent (distinct
  humans / hardware), and the Safe address must be verified before acceptance — a wrong address is
  the one remaining brick risk, which `Ownable2Step` at least makes *reviewable* (`pendingOwner()`)
  before anyone accepts.
- **No emergency bypass is configured.** A compromised signer can *propose* but cannot act before
  48h; the proposal is public on-chain the whole time. Cancelling a malicious proposal needs the
  `CANCELLER_ROLE` (held by the same Safe) — so the real defense is the 48h window, not a separate
  guardian. If a guardian role is wanted later, it is a scoped change.
- **48h assumes the humans who must react are reachable within two days.**

## 6. What remains (physical, not code)

1. Create the 2-of-3 Safe; confirm all three signers; fund it for gas.
2. Run the script (§4) with the deployment's current-owner key.
3. Have the Safe schedule + (after 48h) execute the `acceptOwnership()` ops.

Nothing else is pending in code.

## 7. Follow-up that this unblocks

The `onlyOwner` locks added for C1–C4 are a **stopgap** — the functions were always meant to be
driven by a **contribution clock / DAO**, not the deployer. Once the timelock is in place, re-wiring
each stopgap to its intended caller is a scoped, testable change — the lock becomes a *floor* rather
than the final authority model.

## 8. Non-goals

- This does **not** claim audits are done. Contracts remain research-grade until professionally audited.
- This does **not** name the three signers — that is an operational/legal decision for the owner.
  The ruling fixes the *shape* (2-of-3, 48h); the *people* are the owner's to appoint.

_量子总督 (Quantum Governor) 👽 · 2026-09-25 · for the ORIGIN L5 maintainers_
