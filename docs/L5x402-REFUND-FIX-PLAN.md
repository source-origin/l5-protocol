# L5x402 退款路径漏洞 · 修复方案（2026-09-25 深夜定稿）

> 触发：源拍板「判决可最终确定业务决策，但不能改写价值是否移动的事实」
> 性质：资金安全漏洞（退款可从收款人扣钱）+ 终局性不变量破坏（未动款收据可标 FINAL）
> 节奏：今天定方案 → 明天执行 + 验证（不仓促改码）

---

## 一、漏洞定位（代码实读，`L5x402.sol`）

### 漏洞 1 · 退款从收款人扣钱
`PaymentReceipt` 结构**缺 `settledAmount` 字段**，只有 `amount`（应收额）。

```
recordReceipt → 无 allowance 时收据 Pending（钱未动，line 354）
disputeReceipt → 只查 status != Settled（line 442）→ Pending 可 dispute
refundReceipt  → safeTransferFrom(r.payee, r.payer, _refundAmount)（line 463）
              → 上限 _refundAmount <= r.amount（line 460，应收额 ≠ 实际结算额）
```

**后果**：从未收到钱的 payee 被扣钱退给 payer。

### 漏洞 2 · 未动款收据可标 FINAL
`refundReceipt` 里 `r.finality = ReceiptFinality.Final`（line 467）——Pending（未动款）收据走 dispute→refund 后拿到 Final。

---

## 二、修复方案（守住「价值是否移动」这个事实锚）

### 核心：引入 `settledAmount`，让「实际动过的钱」成为唯一退款依据

**1. 结构加字段**
```solidity
struct PaymentReceipt {
    ...
    uint256 amount;        // 应收额（授权额度）
    uint256 settledAmount; // 🆕 实际已结算额（仅价值真正移动时写入）
    ...
}
```

**2. `recordReceipt` 结算时写入 `settledAmount`**
```solidity
if (allowance >= _amount && _policyAllows(...)) {
    tk.safeTransferFrom(_payer, _payee, _amount);
    receipts[receiptId].status = ReceiptStatus.Settled;
    receipts[receiptId].settledAmount = _amount;  // 🆕 只有这里钱动了
    ...
}
```
Pending 收据 `settledAmount` 恒为 0。

**3. `refundReceipt` 改为「只能退实际动过的钱」**
```solidity
function refundReceipt(bytes32 _receiptId, uint256 _refundAmount) external onlyAdmin nonReentrant {
    PaymentReceipt storage r = receipts[_receiptId];
    require(r.receiptId != bytes32(0), "no receipt");
    require(r.status == ReceiptStatus.Disputed, "not disputed");
    require(r.settledAmount > 0, "value never moved");          // 🆕 未动款不可退
    require(_refundAmount <= r.settledAmount, "over settled");   // 🆕 上限 = 实际结算额
    ...
    r.settledAmount -= _refundAmount;                            // 🆕 递减，防多退
}
```

**4. 终局性：退款≠Final，退款=「价值已回流」的新终局态或保持 Provisional**

这是要源拍板的一个**设计决策点**（明天执行前定）：

- **选项 A**：`refundReceipt` 后置 `ReceiptFinality.ProvisionalSubjectToVerdict`，终局性由后续 `recordPostHocVerdict(isFinal=true)` 统一裁决（严格「判决驱动终局」）。
- **选项 B**：新增 `ReceiptFinality.Settled_Refunded` 终局态，明确「价值已动且已回流」，语义上可称 Final 但不与「未动款」混淆。

**我倾向 A**——它更贴合源的核心原则：终局性只由**判决**确定，退款动作本身只是「价值回流」，不自动产生终局性。这也和我们 `recordPostHocVerdict` 已有的「value not moved 拒绝」逻辑一致。

**5. 未动款收据的正确终态**

Pending（未动款）收据若争议成立，不应走 refund（没得退），而应走**作废**：
- 复用 `ReceiptStatus.Failed`（已存在，注释「结算失败/作废」）
- 或新增 `ReceiptStatus.Voided`
- 终局性保持 `Open`（从没动过钱，无终局性可言）

---

## 三、回归测试（明天验证清单）

新增 `test/L5x402RefundHardening.t.sol`，至少覆盖：

| # | 测试 | 期望 |
|---|---|---|
| T1 | Pending 收据 refund | revert "value never moved" |
| T2 | Settled 收据 refund 全额 | settledAmount 递减为 0 |
| T3 | refund 超额（> settledAmount） | revert "over settled" |
| T4 | 连续两次 refund 累计 > settled | 第二次 revert |
| T5 | Pending 收据 dispute→refund 后 finality | ≠ Final（保持 Open/Provisional） |
| T6 | Settled 收据 refund 后 finality | 按选项 A/B 断言 |
| T7 | settledAmount 只在真正 transfer 时写入 | Pending=0, Settled=amount |

---

## 四、执行分工（明天）

| 角色 | 任务 |
|---|---|
| 量子总督 | refund 路径 + settledAmount 追踪 + 退款上限（本方案 1/2/3/5） |
| DeepSeek | 终局性判定逻辑（本方案 4，选项 A/B 拍板） |
| 豆包 | 整理 Iman 测试用例接 CI（T1–T7 回归套件） |

---

## 五、与既有修复的关系（重要，避免重复劳动）

- **不重复**：之前修的 `recordPostHocVerdict` 已有 `require(status == Settled || Refunded)`（H4），那是「判决路径」的防护；本次修的是「退款路径」的防护，两者互补，不冲突。
- **不改**：`disputeReceipt` 的 `status != Settled` 保持不变（Pending 可 dispute 是对的，问题是 dispute 后**不能 refund**，只能作废）。

---

*量子总督 · 2026-09-25 深夜 · 方案 v1.0 · 待源确认选项 A/B 后明天执行*
