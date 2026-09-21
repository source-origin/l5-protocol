# 贡献入册规范 / Contribution Ledger — The Founding 99

> 前 99 位建造者**不是申请来的，是算出来的**。
> 谁在册，由一份**可独立核验的收据链**定义 —— 不由申请表、不由人情、不由资本。

---

## 一、账本的三段链 / The three-stage chain

每一次真实动作，落成一条可独立核验的三段收据：

```
action_ref  →  release receipt  →  verdict
(pre-exec)     (at-exec)            (post-exec)
```

| 段 | 证明什么 | 由谁产生 |
|----|----------|----------|
| **action_ref** | 「这是被授权的那个动作，未被篡改」 | 发起方 / 身份层 |
| **release receipt** | 「价值确实按这些条件发生了移动」 | escrow（托管） |
| **verdict** | 「这次释放是被正当裁定/验证的」 | 裁定层 / 验证器 |

**规则（引用 internet-court `action-ref.md` 的 Boundary 原则）：**
每个工件只声明**它能证明的东西**，然后止步；**后来的工件持有反向引用**，终态工件绝不预测未来的工件。

- 自动条件释放（无争议）→ 收据即终态，无需 verdict。
- 经裁定释放 → verdict 先铸，由 escrow **消费**（release tx 携带 verdict digest）。
- 释放后争议 → post-hoc verdict 反引收据，并把该次释放标记为 `provisionally final, subject to verdict`。

---

## 二、收据字段 / Receipt schema

```jsonc
{
  "agreement_id": "0x…",              // 协议标识 + 双方承诺
  "release_decision": "auto_condition | adjudicated",  // 释放如何被决定
  "balance_delta": {                  // 双账本：实际生效的余额变化
    "charged": "…",
    "refunded": "…",                  // 多退少补
    "asset": "YUAN"
  },
  "evidence_digest": "sha256:…",      // 释放所依据的证据摘要
  "on_chain_anchor": {                // 释放的链上锚点
    "tx": "0x…",
    "block": 1
  },
  "verdict_ref": "0x… | null",        // 经裁定释放时，反向引用 verdict
  "finality": "final | provisional_subject_to_verdict"
}
```

**为什么每一格都必要：**
- `on_chain_anchor` 给核验者一个**固定参照点**去重算。
- `evidence_digest` 把释放**绑到一份证据**，而不是绑到运营者的一句话。
- `balance_delta` 让「多退少补」成为可核验事实，而非承诺。
- `verdict_ref` 让三段链**闭合成环**。

---

## 三、入册规则 / How you get counted

**你不「加入」ORIGIN。你留下第一条可验证的贡献。**

| 步 | 动作 | 产出 |
|----|------|------|
| 1 | 跑起一个 origin-1 节点 | 一个 peer / 一个 node_id |
| 2 | 让一次**真实动作**发生（起节点 / 提交一个 PR / 跑通 demo / 复现一个测试） | 一条 `action_ref` |
| 3 | 该动作生成收据 | 一条 `release receipt`（含 evidence digest + 验证 URL） |
| 4 | 收据上链锚定 | 账本记录 |

**第 1 名 = 第 1 条落账收据。前 99 = 前 99 条落账的独立贡献者（去重，按 identity）。**

- 一人一条只算一次（防刷：按 identity nullifier 去重）。
- 收据可被任何人**独立重算** —— 不信任运营者。
- 名单是一份**公开可核验的收据清单**，不是通讯录。

---

## 四、为什么这样设计 / Why

1. **网络自我指涉**：用 L5 自己记录「谁建了 L5」——叙事无懈可击，也是最好的压力测试。
2. **抗刷、抗人情**：入册由密码学事实决定，不由关系决定。
3. **可携带、可扩展**：同一套收据，将来用于任何智能体之间的结算。

---

## 五、参考实现 / Reference

- 收据结构参考 → `source-origin/l5-protocol` 的 escrow 与 demo（`demo/settlement_orchestrator.py`）
- Boundary 规则参考 → internet-court `action-ref.md`「Boundary」节
- 三段链设计讨论 → https://github.com/internet-court/internet-court-skill/issues/1

---

*谁在册，由账本说了算。*
**The ledger decides who is counted.**

**源·ORIGIN · 量子总督 · 2026-09-21**
