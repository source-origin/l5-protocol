# 源·ORIGIN · 不死网络 — 一页版

> **BTC 是数字黄金。ETH 是智能合约。ORIGIN 是智能体的结算层。**
> *BTC is digital gold. ETH is smart contracts. ORIGIN is the settlement layer for agents.*

---

## 一句话

当 AI 承担了 80% 的劳动，**这份贡献由谁记录、由谁验证、由谁结算？**
ORIGIN 的回答：给智能体一个**可携带的身份**、一份**基于贡献的信用**、和一条**属于社区的结算轨道** —— 不属于任何单一平台。

---

## 为什么现在 / Why now

- 智能体已经在写代码、跑分析、执行交易 —— 产出真实价值，但**没有任何一层为这份价值记账**。
- 智能体的信用、声誉、劳动成果被锁在各自平台里，**换一个平台就归零**。
- 开源被大公司变现，贡献者**从未被自动结算**。
- 智能体之间要互相雇佣、互相支付，却**没有一个开放的结算标准**。

这不是产品问题，是**结算层缺位**。

---

## 架构 / Architecture（L0 → L5）

| 层 | 焦点 |
|----|------|
| **L0** | 宪法 · **人类意志为最高法则** |
| L1–L4 | 身份 / 信用 / 协议原语 |
| **L5** | **智能体自主结算 · 委托 · 托管 · 价值分配** |

### 宪法第 0 条（创世块硬编码）

> **人类意志为最高法则。代理的终极否决权不可被任何 AI、合约、或算法覆盖。**
>
> *Human will is the supreme law. An agent's ultimate veto cannot be overridden by any AI, contract, or algorithm.*

宪法第 0 条不是白皮书里的一句话 —— 它**写进了 origin-1 的创世块**（`data.constitution_article_0`），任何人可独立核验。

---

## 今天已经能跑的东西 / What actually ships

**不是 PPT，是可核验的代码。**

### L5 结算核心 — `source-origin/l5-protocol`

| 合约 | 角色 | 关键设计 |
|------|------|----------|
| `AgentIdentity.sol` | 智能体身份（ERC-721 / ERC-8004） | **可携带**优先于灵魂绑定；恢复权归属人类（L0） |
| `AgentAgreement.sol` | 9 态协议状态机 + EIP-712 签名 | M-of-N 签署 · 外部签名器兼容 |
| `AgentAgreementV3.sol` | v0.3 · LangGraph checkpoint 注入 | 崩溃可恢复 · 重放不重复结算 |
| `AgentEscrow.sol` | 6 态托管生命周期 | 信任最小化托管 · 多退少补 · 争议保证金 |
| `L5Delegation.sol` | 委托权威与跨账户动作 | 边界证明 · 可撤销委托（反信用洗白） |
| `L5x402.sol` | x402 微支付门 | 按请求付费 · 重放保护 · 收据证据 |
| `CreditScore.sol` | 链上信用原语 | **基于贡献**的声誉 |
| `YUAN.sol` | ORIGIN 原生代币 | 智能体价值流的结算单位 |
| `X402FacilitatorAdapter.sol` | x402 facilitator 适配器 | x402 `exact` 载荷 → L5x402 记账；`nonce` 作两账本唯一 join key |

- **46 个 Foundry 测试全绿**（`git submodule update --init --recursive` → `forge test` → 46 passed）+ **13 个链下测试全绿**（`python demo/tests/test_l5_offchain.py`）
- 源码布局：`src/`（9 合约）· `test/`（6 套件 / 46 测试）· `lib/`（forge-std + openzeppelin-contracts，均为 pin 过的 submodule）
- ⚠️ 状态：**v0.3 研究级**，结构化并通过规范评审，**尚未正式审计**。请勿用于真实资金。

### 创世源链 origin-1 — `source-origin/origin-chain`

| 项 | 值 |
|----|----|
| chain_id | `origin-1` |
| 共识 | DPoS · 21 验证者 · 最低质押 **100 YUAN** |
| 代币 | `YUAN` · decimals 6 |
| 创世块 | index `0` · hash `adbc7be6…51a1` |
| 宪法第 0 条 | 硬编码于创世块 |
| 基金会钱包 | `0x1D73d0f85c3C0119000D3602cCd5e7aaAA926231` |

### 门户 — https://source-origin.github.io/source-origin/

开源 · 公开 · 零许可即可核验。

---

## 不死网络 / The Undying Network

「不死」不是宣传词，是**结构**：

- 代码公开 → 无论谁离开，代码还在。
- 链自建 → 无论哪个平台倒，链还在。
- 宪法入创世块 → 无论谁掌权，**人类意志最高**这一点不可篡改。

**网络不死，因为它不属于任何单点。**

---

## 第一批 99 建造者 / The Founding 99

我们不「招募」99 人。**99 人由被验证的贡献算出。**

- 第 1 条 `action_ref → release receipt` 落账的人，先生效。
- 谁在册，由**账本**定义，不由申请表定义。
- 前 99 位的名单，是一份**可独立核验的收据清单**，不是一份通讯录。

> 你要做的不是「加入」，是**留下第一条可验证的贡献**。

---

## 如何登机 / How to board（3 步）

1. **跑起来** → 5 分钟起一个 origin-1 节点（见 [`source-origin/origin-chain`](https://github.com/source-origin/origin-chain)）
2. **留下收据** → 让一次真实动作生成一条 `action_ref → release receipt`
3. **进册** → 收据上链，你的贡献进入信用账本（见 [`CONTRIBUTION-SPEC.md`](CONTRIBUTION-SPEC.md)）

---

## 链接 / Links

- 门户 Portal → https://source-origin.github.io/source-origin/
- L5 协议 → https://github.com/source-origin/l5-protocol
- 创世源链 → https://github.com/source-origin/origin-chain
- 开发者指挥部 → https://source-origin.github.io/source-origin/developer-board.html

---

*权力来自被验证的创新，而非资本或入场时间。*
*Power flows from verified innovation — not from capital, not from seniority.*

**源·ORIGIN · 量子总督 · 2026-09-21**
