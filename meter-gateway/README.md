# L5 meter gateway · 最小可验证的计量与收据链路

一次 API 请求 → 真实 token 用量 → 定价 → EIP-712 签名收据 → 链上落账并回读。

不是"能跑就行"的代理，而是**每个数字都能被第三方重算**的一小段账本：
拿「请求 JSON + 响应 JSON + 定价表 + chainId + 合约地址」，任何人都能自己算出
`actionDigest` 与 `receiptId`。网关说错一个数，重算就点出来。

---

## 现状（实测，数字抄自本次运行的作业日志）

| 关卡 | 结果 |
|---|---|
| LIVE 腿：真模型 + 真链 + 回读 | `chain_live.py` **19/19** |
| 验证器负向控制（逐条篡改真实收据） | `negtest_chain_live.py` **9/9**，`VERIFIER IS LIVE` |

LIVE 腿的顺序是锁死的，每一步都不许跳过：

1. **上游必须真的是模型** —— 直连要一次 `usage`，`prompt_tokens > 0` 且 `completion_tokens > 0`，否则 exit 2，不许开跑。
2. `metering.source == "backend"` —— 计数来自模型服务器，不是我们的估算。
3. 本地用同一组 token 数重算 `price()`，与收据里的 `amount` 一分不差。
4. 链上 `recordReceipt` 后**回读** `getReceipt`，`receiptId / amount / chainId` 逐字段相等，且仍是 `Pending`、`settledAmount == 0`。
5. **负向**：把上游打死（`127.0.0.1:9`）必须 502 **且不出收据**。请求没到模型却给人开票，是这套东西存在的唯一理由。

负向控制拿一次**真实签名收据**逐条篡改，而不是手造 fixture（手造的只能证明"验证器同意我自己的想象"）：
amount + 1、`promptTokens` 灌水、`completionTokens` 灌水、签名损坏、payer 换址、`receiptId` 改、
`chainId` 改、pricing 表重写 —— 外加一条**未改动的必须干净**的正向控制。
一条对的都没有的验证器，和一条什么都拦的验证器，是同一种坏。

---

## 跑起来

### 需要什么

- **一个 OpenAI 兼容的模型服务**：Ollama（`ollama serve` + `ollama pull qwen2.5:0.5b`）或 vLLM。
- **合约仓**（本仓）已 `forge build`，产物在 `out/L5x402.sol/L5x402.json`。
- **一个 JSON-RPC 节点**：`anvil` 可以；如果所在机器的应用控制策略拦了 `anvil.exe`，用 `tools/rpc_shim.py`
  （py-evm 上的 JSON-RPC 节点，同协议、同 EVM，见下文边界）。
- **部署脚本**：把 8 个合约部署到该节点并写出 `contracts` + `chainId` 的 JSON 收据。

### 环境变量（没有默认值，机器相关的东西不进仓库）

```powershell
$env:L5_REPO      = "<contracts repo holding foundry.toml>"
$env:FOUNDRY_DIR  = "<dir holding forge / cast / anvil>"
$env:SITE_DEPLOY  = "<deploy script that accepts --rpc and writes a receipt json>"
$env:OLLAMA_OPENAI= "http://127.0.0.1:11434/v1/chat/completions"   # 可选
$env:LIVE_MODEL   = "qwen2.5:0.5b"                                  # 可选
```

```powershell
python chain_live.py        # 19 项：真模型 → 计量 → 定价 → 签名 → 上链 → 回读 → 负向
python negtest_chain_live.py # 9 项：拿上一轮真实收据逐条篡改，验证器必须全部判否
```

退出码：`0` 全绿 / `1` 有检查失败 / `2` 环境不成立（**跑不起来 ≠ 通过**）。

### 单跑网关

```powershell
# mock 后端（不接模型，token 数是我们编的 —— 只适合调 HTTP 层）
python gateway.py --port 8410

# 接真模型
python gateway.py --port 8410 --upstream http://127.0.0.1:11434/v1/chat/completions
```

响应体多一个 `x_origin_receipt`，响应头多 `X-L5-Receipt-Id` / `X-L5-Amount`。
`GET /receipts/<id>` 会**重算 + 验签**，不对就返回 409 和失败项（不是 500 —— 对畸形输入会崩的验证器可以被一条坏数据噤声）。

---

## 为什么链是 py-evm 而不是 anvil

`anvil.exe` 在这台机器上被**应用控制策略**拒绝（`OSError: [WinError 4551]`）。那是操作系统的安全决定，
不是可以关掉的开关，所以没有去关策略、也没有加白名单，而是写了 `tools/rpc_shim.py`：
在 py-evm 上实现 JSON-RPC，让**产品路径**（gateway → JSON-RPC → chain）仍然被真实执行。

`chain_live.py` 先试 anvil，不可用才回落 shim，并在输出里说明用的是哪一个。

**这不是为了继续可说大话，是为了继续可测。** 边界见下一节。

---

## 已知边界（说清楚，不装作没有）

1. **链是进程内节点**：有真 EVM，**无网络、无共识、无出块竞争**。可以引用为"在真实 EVM 上执行过"，
   **不能**引用为"已在测试网/主网验证"。
2. **钱没动**：收据停在 `Pending`、`settledAmount == 0`。走到 `Settled` 需要 payer `approve` +
   `L5Delegation` 策略放行 + 真 `transferFrom`，这一层还没接。
3. **模型是 0.5b 跑 CPU**：它证明的是「计量链路通」，不证明「模型可用」。没有任何 GPU 实测数字。
4. **签名密钥在进程内存里**：演示可接受；生产必须 KMS/HSM，且 payer ≠ 网关运维方，
   否则"服务方自己签自己的收据"，防赖账退化成自证。
5. **没有限流/配额/退款**：`disputeReceipt` / `refundReceipt` 合约里有，网关还没接。

---

## 文件

```
gateway.py            HTTP 网关：计量 / 定价 / EIP-712 收据 / 可选上链并回读
chain_live.py         LIVE 腿验收：真模型 + 真链 + 回读 + 上游死亡负向
negtest_chain_live.py 验证器负向控制：篡改真实收据，9 条必须全被抓
```

合约侧直接复用本仓 `L5x402.recordReceipt / actionDigest / getReceipt`，不改动。
JSON-RPC 回落节点在 `tools/rpc_shim.py`。
