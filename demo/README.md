# Demo — L5 Settlement Orchestrator (off-chain reference)

A **pure-Python, runnable demonstration** of the ORIGIN L5 settlement loop. It mirrors the on-chain `AgentAgreement` GraphNode state machine, so you can watch a Task move from **Submit → Validate → Fund → Execute → Verify → Settle** (and the failure paths **Reject / Refund / Slash**) without touching a chain.

> This is the "Chain-Born" walkthrough the roadmap mentions — the story of an AI agent doing work, getting verified, and settling value with a human (or another agent) — open, auditable, append-only.

## What's here

| File | What it shows |
|---|---|
| `settlement_orchestrator.py` | The **orchestrator core** — Task lifecycle + append-only `Ledger`, mirroring `AgentAgreement`'s 8 GraphNodes. |
| `chain_born_kit.py` | Higher-level helper wrapping identity + escrow + settlement for a "dual-citizen" scenario. |
| `l5_escrow_link.py` | Maps orchestration onto the escrow lifecycle (funded / dispute / settle / refund). |
| `l5_contract_link.py` | Rough linkage notes between off-chain orchestration and the Solidity contracts. |
| `l5_demo_theater.py` / `.html` | An animated "theater" walkthrough you can open in a browser. |
| `chain_born_demo.html` | Standalone HTML demo of the dual-citizen settlement story. |
| `tests/` | Off-chain test suite (`test_l5_offchain.py`). |

## Run it

Requires **Python 3.10+**, no third-party deps.

```bash
# 1. Watch a full Task lifecycle (Submit → … → Settle / Slash)
python settlement_orchestrator.py

# 2. Run the test suite
python tests/test_l5_offchain.py

# 3. Open the browser walkthroughs
#    start: python l5_demo_theater.py  then open the printed URL
#    or simply open chain_born_demo.html / l5_demo_theater.html
```

## What it demonstrates (mapping to the contracts)

- **Identity** → an agent is a first-class participant with a stable handle.
- **Escrow** → funds are held and only released on verified completion (`FUNDED → SETTLE`), with `REFUND` on timeout and `SLASH` on misbehavior.
- **Append-only ledger** → every state transition is recorded, so a crash can recover at the last checkpoint — the same design intent as `AgentAgreement`'s checkpoint array. **Replay cannot double-settle** (taskId + checkpoint are the idempotency key).

⚠️ Off-chain reference / educational. It does **not** execute the Solidity itself (stubs the interfaces). For the actual audit-grade logic see `../src/`.
