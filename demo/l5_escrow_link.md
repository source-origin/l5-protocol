# l5_escrow_link.md — 托管联动映射总表（C 路线 · 双账本真闭环）

> 配套实现：`l5_escrow_link.py`（链桥抽象 + 模拟链 + 双账本联动）
> 上游：`AgentAgreementV3.sol`（协议状态）+ `AgentEscrow.sol`（资金托管）
> 诚实标注：本文件为链桥抽象层，不真发链上交易；真连链时把内存实现换成对上两合约的实际 provider 调用。

## 一、编排器 node → escrow 动作 → EscrowState → 该步 AgreementState（合拍表）

| 编排器 node | escrow 动作 | escrow EscrowState | 该步 AgreementState（合拍） | 资金/落点 |
|---|---|---|---|---|
| SUBMIT | —（create agreement） | Empty | Draft | 无资金移动 |
| VALIDATE | —（propose） | Empty | Proposed | 无资金移动 |
| SIGN | —（sign） | Empty | Signed | 无资金移动 |
| FUND | `createAndFund()` | Empty → **Funded** | Signed（已签才能托管） | 资金**锁定**入 escrow |
| EXECUTE | off-chain 真劳务 | Funded | **Executed** | 编排器仅记录完成（不可链上） |
| VERIFY | `verifyDelivery()` | Funded → **Verified** | terms 完成 → **Completed** | 验工作，**资金未动** |
| SETTLE | escrow `release()/settle()` 驱动 agreement `markSettled()` | Verified → **Released** | Completed → **Settled**（握手终态） | 资金**释放给 Provider** |
| REFUND | escrow `refund()` | → **Cancelled** | Cancelled | 资金**退回 Consumer**，Provider 无所得 |
| DISPUTE | escrow `dispute()`（交 bond） | Verified → **Disputed** | Disputed | 争议锁定 |
| ARBITRATE | `resolveDispute(payeeWins)` | Disputed → Released / Cancelled | Settled / Cancelled | payee_wins→付 Provider；否则退回 |

## 二、诚实边界（哪些步调谁）

- **调 escrow**：FUND / VERIFY / SETTLE / REFUND / DISPUTE / ARBITRATE —— 资金三态生命周期全在 `AgentEscrow.sol`，不在 `AgentAgreementV3.sol`。
- **escrow 驱动 agreement 握手**：SETTLE 时 escrow `release()` 内部会驱动 agreement `markSettled()`（Completed→Settled），两账本同到终态才一致。若 agreement 尚未 Completed，release 抛错并提示先 completeTerms。
- **off-chain 真劳务**：EXECUTE 是不可链上化的真实工作，编排器/联动层只记录"已完成"，escrow 无资金动作。
- **SUBMIT→VALIDATE→SIGN** 属协议前置，不碰 escrow（Empty 态），仅推进 AgreementState。

## 三、双账本 invariant（一句话）

> 资金在 escrow 里被锁定或被释放，必须与 agreement 的状态同步成立：
> FUND→escrow.Funded 且资金锁；VERIFY→escrow.Verified 且 agreement 向 Completed 推进；
> SETTLE→escrow.Released（钱已付 Provider）且 agreement.Settled 同到终态；
> REFUND→钱回 Consumer 且 Provider 无所得；DISPUTE/ARBITRATE→escrow.Disputed→resolve。

实现为 `cross_check(node, escrow_state, agreement_state) -> (ok, msg)`，违约态返回 ok=False 并给"哪侧落后/该先推哪步"的中文提示。

## 四、附件域（后续可做，本 C 暂不覆盖）

- **state channel**：`openChannel` / `topUpChannel` / `settleChannel` / `finalizeSettlement` / `disputeChannel` —— 高频微结算通道。
- **crossChainSettle**：跨链结算到目标链 payee。
- 均已在上游 `AgentEscrow.sol` 存在，L5 需要时可扩。

## 五、验证状态

- `l5_escrow_link.py`：18,143B / `python -m py_compile` exit=0 / demo 双账本到终态一致。
- demo(a) 成功路径到 SETTLED / Released（钱已付 Provider）。
- demo(b) 违约（未 VERIFY 想 SETTLE）被双保险拦：escrow 门禁抛错 + `cross_check` ok=False。
