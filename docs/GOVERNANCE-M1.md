# M1 · Governance — from single-owner to multisig + timelock

> **Status:** design / recommendation. The **code half is already shipped** (two-step
> ownership); the **operational half is the owner's decision** (which signer set, what delay).
> This file is the shared reference so that decision doesn't have to be re-derived later.

## 1. The finding

Every privileged path in the L5 core is `onlyOwner` / `onlyAdmin`:

| Contract | Privileged surface |
|---|---|
| `AgentEscrow` | `resolveDispute`, `setDisputeBond`, `cancelEscrow`, … |
| `AgentIdentity` | `upgradeVerification`, `recordRevenue`, `suspendAgent`, `slashAgent` |
| `L5x402` | `updateSnapshot`, `disputeReceipt`, `refundReceipt`, `attachVerdict`, `markProvisional`, `setDelegationContract` |
| `L5Delegation` | `suspend`, `unsuspend`, `setIdentityContract`, `setEscrowContract` |
| `YUAN` | `setServiceProvider`, `setAnchorRate` |
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

## 3. What remains (owner's decision, not a code question)

1. **Signer set** — threshold and members. Any 2-of-3 / 3-of-5; a hardware-wallet quorum; or an
   external Safe.
2. **Timelock delay** — how long between "privileged action scheduled" and "executable". Longer for
   the value-bearing paths (`resolveDispute`, `refundReceipt`, `setAnchorRate`); shorter or none for
   purely additive configuration.
3. **Scope** — which functions are timelocked vs. immediate-owner. A reasonable split:
   - **Timelocked (value-bearing):** `AgentEscrow.resolveDispute` / `setDisputeBond`, `L5x402.refundReceipt`,
     `YUAN.setAnchorRate` / `setServiceProvider`, `AgentIdentity.slashAgent`.
   - **Immediate (config-only):** `setIdentityContract`, `setEscrowContract`, `setL5x402`, `setFacilitator`.
4. **Who the multisig is** — human keyholders (Constitution L0: *humans are the highest authority*).
   Automation must not hold a signing key.

## 4. Recommended path (no new contracts required)

Use OpenZeppelin `TimelockController` + `Ownable2Step`:

1. Deploy `TimelockController(minDelay, proposers[], executors[], admin)`.
2. For each L5 contract: current owner calls `transferOwnership(timelock)`.
3. The timelock calls `acceptOwnership()` on each (via a scheduled operation).
4. Privileged calls become: `schedule` → (delay) → `execute`, visible on-chain the whole time.

For the signer set, a 2-of-3 (or better) **Safe** can hold the `PROPOSER_ROLE`, with execution left
to the timelock.

> **Why timelock + multisig, not just multisig:** the multisig stops a single key from acting;
> the timelock gives every other stakeholder time to *see* and *react* to a privileged call before it
> lands. Together they turn "trust the owner" into "trust the process".

## 5. Follow-up that this unblocks

The `onlyOwner` locks added for C1–C4 are a **stopgap** — the functions were always meant to be
driven by a **contribution clock / DAO**, not the deployer. Once the timelock is in place, re-wiring
each stopgap to its intended caller is a scoped, testable change — the lock becomes a *floor* rather
than the final authority model.

## 6. Non-goals

- This does **not** claim audits are done. Contracts remain research-grade until professionally audited.
- This does **not** decide the signer set — that is an operational/legal decision for the owner.
