# L5 结算编排器 ↔ AgentAgreementV3.sol 链上联动 · 权威映射

> 源·ORIGIN · L5 打磨 A 路线 ｜ 链桥 / 集成系 ｜ 文件同目录：`offchain\`
> 作用对象：
> - off-chain 结算编排器 `settlement_orchestrator.py`（只读对齐，**不改源**）
> - 链上基座 `src\AgentAgreementV3.sol`（全绿编译，**绝不动**）
> 本文件是**权威联络对接图**：编排器 GraphNode → 链上函数 → 链上合拍 AgreementState → 落点。
> 配套代码：`l5_contract_link.py`（ChainBridge 抽象 + SimulatedChain 模拟链 + LINK_TABLE + assert_state_consistent）。

---

## 0. 从哪核实来的（不是猜的）

链上权威语义直接从 `AgentAgreementV3.sol` 函数体核实：

| 链上函数 | onlyState 门禁 | 跳变 | 自动 checkpoint |
|---|---|---|---|
| `createAgreement(...)` | 非 onlyState | 无 → **Draft** | 无 |
| `propose()` | onlyState(Draft) | Draft→**Proposed** | `_autoCheckpoint(Validate)` |
| `signAgreement()` | onlyState(Proposed) | Proposed→**Signed**（EIP-712） | 无 |
| `completeTerm(s)` | onlyState(Executed) | Executed 内逐 term | 无 |
| `bindEscrow()` | external（参与方/escrow 可 bind） | 绑托管地址 | 无 |
| `markSettled()` | only escrow + onlyState(Completed) | Completed→**Settled** | `_autoCheckpoint(Settle)` |
| `cancelAgreement()` | onlyState(Draft/Proposed) | → **Cancelled** | 无 |
| `disputeAgreement()` | — | → **Disputed** | 无 |

链上 `enum AgreementState`：`Draft → Proposed → Signed → Executed → Completed → Settled`
（旁支 Cancelled / Disputed / Slashed）。
链上 `enum GraphNode(合约侧 camelCase)`：Submit/Validate/Fund/Execute/Verify/Settle/Arbitrate/Slash。

---

## 1. 权威总表：编排器 GraphNode → 链上函数 → 合拍 AgreementState → 落点

| 编排器 GraphNode | 链上函数 | 成功后合拍 AgreementState | 落点 | 备注 |
|---|---|---|---|---|
| **SUBMIT** | `createAgreement(...)` | **Draft** | 本合约 | 起点；Draft |
| **VALIDATE** | `propose()` | **Proposed** | 本合约 | 自动落 cp **Validate** |
| *SIGN*（中间带）| `signAgreement()` | **Signed** | 本合约 | EIP-712 钱包签名，非私钥裸传 |
| **FUND** | — (*)| Signed | **AgentEscrow** | 资金/质押在托管合约 |
| **EXECUTE** | — | Signed | **off-chain 劳务** | 真的工作不在链上，不可链上化 |
| **VERIFY** | `completeTerm(s)` | **Executed** | 本合约 | Executed 态内逐 term 完成 |
| **SETTLE**(①) | `bindEscrow()` | Completed | 本合约 | 绑托管（放款前置；Completable） |
| **SETTLE**(②) | `markSettled()` | **Settled** | escrow-calls | 仅 escrow 能调；自动落 cp **Settle** |
| **ARBITRATE** | `disputeAgreement()` | Disputed | 本合约→Court | 裁决（本合约无终裁） |
| **SLASH** | — | Slashed | **AgentEscrow/Court** | 罚没在托管/法庭侧 |
| *CANCEL*（中间带）| `cancelAgreement()` | Cancelled | 本合约 | onlyState(Draft|Proposed) |
| RETRY | — | — | off-chain（回炉） | 不直接打链 |
| REJECT | `cancelAgreement()` | Cancelled | 本合约 | 编排器驳回≈取消(谨慎语义) |
| REFUND | — | Cancelled | **AgentEscrow** | 资金走 escrow 退回 |
| DONE | — | Settled | 本合约(收口) | 编排器收口：应已 Settled |

(*) FUND 不调 AgentAgreementV3 的资金函数——资金的托管与放款在 AgentEscrow.sol。

### 谁跨了合约 / 落点在别处（3–5 句重点）

1. **FUND → AgentEscrow**：编排器到 FUND 时链上本合约并不真正"收钱"，真资金质押/托管在
   `AgentEscrow.sol`；本合约此时的联动只是"读状态仍在 Signed"，真正的资金动作不经过
   AgentAgreementV3 的函数。
2. **EXECUTE → off-chain**：真正执行者跑任务、产出结果是线下真实劳务/计算，链上无对应
   交易——所以这个 node 对链只有"记账/等待"，绝不可能把工作内容写进本合约。
3. **SETTLE 是两跳**：先是本合约 `bindEscrow`（绑托管、前置条件，推到 Completed 的可 bind
   区间），再是本合约的 `markSettled`——但 **caller 必须是 escrow 合约**（onlyEscrow），
   编排器/参与方没有直接调用权，只能靠 escrow 放款后由 escrow 触发，因而这条归入
   "escrow-calls" 落点。
4. **ARBITRATE / SLASH 只有入口态**：本合约只有 `disputeAgreement()`(→Disputed)；真正的
   仲裁裁决、罚没(stake/slashing)执行在 AgentEscrow / Court 等外部组件，编排器不能指望
   本合约单点完成终裁。
5. **end-to-end 关键点**：唯一真正会"一路推着链上跳到 Settled"的是这条——SUBMIT→VALIDATE
   →SIGN→(FUND/EXECUTE 离线)→VERIFY(Executed)→SETTLE(bindEscrow,Completed)→escrow
   `markSettled`(Settled)。其余 REJECT/REFUND/CANCEL/DISPUTE/SLASH 都是此链上的分流或
   旁支。

---

## 2. assert_state_consistent 的对齐判据

对"会改本合约主 AgreementState"的节点（落点 this-contract / escrow-calls），编排器当前
node 必须与链上 AgreementState 相同；若不符合，给出"哪个先/后错"提示：

- 链上落后的文案：`链上落后：编排器想动 {expect}，链上还在 {cur}——先把链推上 {expect} 再放编排器`
- 链上超前/偏离的文案：`链上超前/偏离：链上已 {cur}，编排器仍想动 {expect}——编排器应回退/等链先对账`
- 对落点在 AgentEscrow / off-chain / Court 或不改变本合约主状态的节点，不强求某一
  AgreementState（合拍视为成立）——因为那本来就是别的舱位的事，本合约不背锅。

> 演示可见：某 agreement 停在 **Signed**(编排器误以为已走完 VERIFY、链应为 Completed)时，
> 对 SETTLE 做 assert → `ok=False`，给出"应先推上 Completed 再放编排器"的定向提示，
> 由此编排器不会对链上违约态误调 `markSettled`。同时 `SimulatedChain.mark_settled` 自带
> onlyState(Completed) 门禁，即使 assert 被跳过，链侧也会抛 `OnChainStateError` —— 双保险。

---

## 3. 给 settlement_orchestrator.py 的建议改动点（**不改源，仅标注**）

- 编排器目前 `GraphNode` 没有显式 `SIGN`/`CANCEL` 中间带成员（SIGN 隐含在 VALIDATE→FUND
  之间、CANCEL 不存在于主路径）。接线时若想在 node-runner 上挂链桥调用，建议在编排器
  的 DECISION 链上把签名/取消作为显式停留点或桥的私有 hook，而不是塞进现有 node 名。
- 编排器 `EscrowStatus`（CREATED/FUNDED/SETTLED/REFUNDED/SLASHED) 与链上归位的对齐：
  建议 `_set_terminal` 里 REJECT→REFUNDED 的措辞与 agent 实际 escrow 退款语义复核。
  SETTLE 前编排器对"链上 Completed/bindEscrow"的前置观测，建议在 node-runner 里先在
  桥上调 `assert_state_consistent` 再过闸，避免编排器凌驾于链状态。
- 上面仅是建议点；`settlement_orchestrator.py` 本体保持不动。

---

## 4. 真连链方向

本套件是**链桥抽象 + 模拟链**，不真发交易。真连链时把 `SimulatedChain` 换成真实 provider：

- `propose/completeTerms/bindEscrow/cancel/dispute` → `web3`/privy 的 `contract.functions.<fn>()`
  `.transact({from: signer})`
- `signAgreement` → EIP-712 签名由参与方离线/钱包生成后以 `bytes signature` 传入，不是私钥裸传
- `markSettled` → 记住 caller 必须为 escrow 合约地址（onlyEscrow），编排器无直接调用权

这样编排器状态机（crontab / checkpoint 恢复）与链上 AgreementState 由
`l5_contract_link.py` 里的 `LINK_TABLE` + `assert_state_consistent()` 协同保证合拍。
