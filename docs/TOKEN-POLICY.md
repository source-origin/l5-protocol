# YUAN · Issuance / Monetary Policy (M5)

> **Decision (2026-09-25, owner = 源基金会):** the right to mint belongs to the
> **源 Foundation**; the amount issued is **adjusted in response to the market**.
> This file records the on-chain mechanism that encodes that decision, so the
> semantics are not re-litigated later.

## 1. The finding (M5, pre-decision)

`YUAN.issueService` let **any** whitelisted service provider mint
`serviceUnits * yuanPerServiceUnit`, bounded only by `MAX_SUPPLY`. So a single
provider — with only `setServiceProvider(p, true)` — could mint up to the hard
cap. Supply was therefore *effectively* controlled by whoever was whitelisted,
not by the Foundation. A reviewer would read that as "the deployer hands out
money-printing rights".

## 2. The mechanism now in code

| Lever | Function | Who | Meaning |
|---|---|---|---|
| Provider eligibility | `setServiceProvider(addr, bool)` | Foundation (owner) | May this address issue at all? |
| **Issuance ceiling** | `setProviderMintCap(addr, uint256)` | Foundation (owner) | **How much** this provider may ever mint |
| Anchor rate | `setAnchorRate(uint256)` | Foundation (owner) | 1 服务单元 = N YUAN |
| Hard ceiling | `MAX_SUPPLY = 1e9 * 1e18` | constant | Absolute limit, on top of the above |

`issueService` now requires **all three**:

```solidity
serviceProviders[msg.sender]                                   // eligible
providerMinted[msg.sender] + amount <= providerMintCap[msg.sender]  // within Foundation cap
totalSupply() + amount <= MAX_SUPPLY                           // hard ceiling
```

Two properties follow:

- **Fail-closed:** enabling a provider grants **no** issuance right on its own.
  Until the Foundation sets a cap, that provider mints nothing. There is no
  "unlimited by default".
- **Foundation is the monetary authority:** the market-responsive lever is the
  cap. Lowering a provider's cap immediately blocks any further issuance
  (`test_FoundationLoweringCap_BlocksFurtherMint`); raising it re-opens room.
  Supply can never grow beyond what the Foundation has authorised, per provider.

Regression: `test/L5MintPolicy.t.sol` (9 tests).

## 3. Why keep the service-backed model

Issuance still happens **only through `issueService`**, i.e. a provider mints
against *delivered service units* (the "proof of service" property). We did
**not** add a raw `owner.mint(to, amount)`: the Foundation controls the
*ceiling* and the *rate*, and service delivery remains the trigger. This keeps
the anti-inflation property ("no YUAN without a service") while moving the
supply decision to the Foundation.

> If the Foundation ever needs direct discretionary issuance, that is a distinct
> decision with its own review — it is deliberately **not** included here.

## 4. Governance wiring (ties to M1)

All three levers are `onlyOwner`. Per [`GOVERNANCE-M1.md`](GOVERNANCE-M1.md):

- **`setAnchorRate`** (value-bearing — changes what every service costs) → route
  through the **timelock**: schedule → delay → execute.
- **`setServiceProvider` / `setProviderMintCap`** (supply ceilings) → at minimum
  behind the **multisig**; timelock recommended since they are supply-bearing.

The owner should be the Foundation's **multisig + `TimelockController`**, never a
single EOA. Constitution L0: the signers are humans; automation holds no key.

## 5. Non-goals

- No claim the token is audited or that its legal classification is settled.
- No on-chain price oracle / automatic feedback loop — "market-responsive" is a
  **human policy decision** executed through the caps, not an algorithm.
