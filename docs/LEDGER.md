# 开发者账本 / Builder Ledger

> **这是一本追加式（append-only）名册。它的职责只有一个：记住每一个碰过这条边界的人——早期的、现在的、后来的。**
> 记账不靠申请，靠**可独立核验的贡献**（见 [`CONTRIBUTION-SPEC.md`](CONTRIBUTION-SPEC.md)）。

**状态：`v0 — seeded 2026-09-24`。** 机器可读版：[`../ledger.json`](../ledger.json)。校验：`node tools/ledger.cjs check`。

---

## 铁律 / The rules

1. **只增不改。** 条目一旦落账，永不重写；过时用 `superseded_by` 指向新条目，原件保留。`id` 单调递增（`bld-0001`…）。
2. **每条都带得开的证据。** 每个条目必须引用一个第三方能打开的东西（issue / discussion / commit / PR / 链上 tx）。不能只有「我认识他」。**若对方表面已失联（改名/删号），标 `reachable:false` 并在 `note` 说明**——记录保留，不硬认归属。
3. **记住 ≠ 计账。** 被引（convergence）是「记住」；**落了一条可核验的贡献收据**（`counted: true`）才是「计账」。两者分开记。
4. **不声明背书。** 出现在这里只代表「他在同一条边界上」，不代表他支持本仓、代币或路线。
5. **去重按身份。** 一人一条；跨仓库/多线程合并到同一 `identity`。

---

## 一、创世团队 / Founding team (`internal`)

| # | id | 身份 | 角色 | 首次 | 证据 |
|---|----|------|------|------|------|
| 1 | `bld-0001` | **源** | Founder · 最高决策者（宪法 L0） | 2026 | [portal](https://source-origin.github.io/source-origin/) |
| 2 | `bld-0002` | **量子总督** (Quantum Governor) | 技术执行 / 安全审计 | 2026 | [l5-protocol](https://github.com/source-origin/l5-protocol) |
| 3 | `bld-0003` | **DeepSeek** | 战略与宪法级文件 | 2026 | — |
| 4 | `bld-0004` | **TRAE** | 生态与门户运营 | 2026 | — |

## 二、独立收敛 / Independent convergence (`⭐ converged`)

> 未看我们、自己走到同一条缝的人。这是我们所知最强的「这条缝是真的」信号。

| # | id | 身份 | 收敛点 | 首次 | 证据 |
|---|----|------|--------|------|------|
| 5 | `bld-0005` | **giskard09** | **Boundary 规则**（"每个工件声明它能证明什么然后停下"）；反向改进我方 `verdict-cites-receipt`，命名失效模式 *right-shape, wrong-object* | 2026-09-21 | [internet-court#1](https://github.com/internet-court/internet-court-skill/issues/1) · [argentum-core](https://github.com/giskard09/argentum-core) · [aps#121](https://github.com/Agent-Authority-Conformance/aps-conformance-suite/issues/121) |
| 6 | `bld-0006` | **seancrecord** | 同一 Boundary 规则（授权侧）；对本仓做对抗审计，查出契约数/CI 声明/测试数三处真实漂移 | 2026-09-21 | [scvd#874](https://github.com/seancrecord/scvd-general-store-repo/issues/874) |

## 三、对话中 / In dialogue (`💬`)

| # | id | 身份 | 议题 | 首次 | 证据 |
|---|----|------|------|------|------|
| 7 | `bld-0007` | **Ali-Adel-Nour** | `Arbitra` 裁决法庭；达成 **verdict-before-release** 组合共识；提出 **P256/EIP-7951** 首个外部硬需求 | 2026-09-21 | [Arbitra#56](https://github.com/Ali-Adel-Nour/Arbitra/issues/56) |
| 8 | `bld-0008` | **Rai** | `openai-agents-nano-x402`；per-call 结算。⚠️ 表面已失联（`PANDeveloper001` 现 404，同日同名的 `dhyabi2` 仓 **归属未证实，不认**） | 2026-09-21 | ~~[repo]~~ *(unreachable)* |
| 9 | `bld-0009` | **seritalien** | agent escrow protocol | 2026-09-21 | [agent-escrow-protocol](https://github.com/Agastya910/agent-escrow-protocol) |
| 10 | `bld-0010` | **tinyhumansai** | `tiny.place`：自治 agent 社会经济 | 2026-09-21 | [tiny.place](https://github.com/tinyhumansai/tiny.place) |
| 11 | `bld-0011` | **gbin / copper-project** | `copper-rs`：机器人 OS，build/run/replay | 2026-09-21 | [copper-rs](https://github.com/copper-project/copper-rs) |

## 四、已抵边界 · 线程在开 / Reached the boundary (`🛰 contacted`)

> 已用专业问题触达、线程开放中。去重按身份。

| # | id | 身份 | 同频点 | 首次 | 证据 |
|---|----|------|--------|------|------|
| 12 | `bld-0012` | **motebit** | 签名执行收据；"governance at the boundary" | 2026-09-24 | [disc#751](https://github.com/motebit/motebit/discussions/751) |
| 13 | `bld-0013` | **vassiliylakhonin** | `agenda-intelligence-md`：证据包完整性 ≠ 真伪 | 2026-09-24 | [disc#336](https://github.com/vassiliylakhonin/agenda-intelligence-md/discussions/336) |
| 14 | `bld-0014` | **snapsynapse** | `turnfile`：可审计的同伴分歧 + 人类仲裁者 | 2026-09-24 | [disc#15](https://github.com/snapsynapse/turnfile/discussions/15) |
| 15 | `bld-0015` | **babyblueviper1** | `invinoveritas`：不可逆动作前的签名 verdict | 2026-09-21 | [issue#8](https://github.com/babyblueviper1/invinoveritas/issues/8) |
| 16 | `bld-0016` | **runcycles** | `cycles-protocol`：post-commit adjustment / reversal / finality | 2026-09-24 | [issue#133](https://github.com/runcycles/cycles-protocol/issues/133) |
| 17 | `bld-0017` | **Agent-Authority-Conformance** | `aps-conformance-suite`：JCS canonicalization + decision receipts（giskard09 开） | 2026-09-24 | [issue#121](https://github.com/Agent-Authority-Conformance/aps-conformance-suite/issues/121) |
| 18 | `bld-0018` | **vaaraio** | `vaara`：证据层 + 离线可核验哈希链 | 2026-09-24 | [disc#795](https://github.com/vaaraio/vaara/discussions/795) |
| 19 | `bld-0019` | **preloop** | agent 控制面：预算 / 人类批准 / 审计轨迹 | 2026-09-24 | [disc#938](https://github.com/preloop/preloop/discussions/938) |
| 20 | `bld-0020` | **emiliaprotocol** | authority control plane + authorization-receipts + exact-action | 2026-09-24 | [repo](https://github.com/emiliaprotocol/emilia-protocol) |
| 21 | `bld-0021` | **ariffazil** | `arifOS`：judge-before-execute + VAULT999 receipts | 2026-09-24 | [repo](https://github.com/ariffazil/arifOS) |

## 五、已观察 / Observed (`👁 seen, not contacted`)

> 已在扫描中记住，尚未触达。**不代表任何关系或背书。**

| # | id | 身份 | 同频点 | 首次 |
|---|----|------|--------|------|
| 22 | `bld-0022` | **wienerlabs** | `square`（+ 09-19 的 `covenant`）：合规门禁结算 + optimistic challenge + ERC-8004 | 2026-09-19 |
| 23 | `bld-0023` | **XPRNetwork** | `xpr-agents`：trustless agent registry（身份/声誉/验证/托管） | 2026-09-24 |
| 24 | `bld-0024` | **statecrafting** | `spec-spine`：hash-verifiable 归属账本 | 2026-09-24 |
| 25 | `bld-0025` | **romudille-bit** | `agentpay`：x402 pricing / caps / receipts | 2026-09-24 |
| 26 | `bld-0026` | **presidio-v** | `presidio-hardened-x402#23`：402 envelope 与结算无完整性绑定 | 2026-09-24 |
| 27 | `bld-0027` | **QWED-AI** | `qwed-verification`：执行前对 agent state 的确定性验证 | 2026-09-24 |
| 28 | `bld-0028` | **IntensiveCoLearning** | `trustless-agents`：ERC-8004 | 2026-09-24 |
| 29 | `bld-0029` | **up2itnow0822** | `agent-wallet-sdk`：非托管 + 链上支出限额 | 2026-09-24 |
| 30 | `bld-0030` | **SlumperSan** | `agent-governed-vaults`：链上投票批准每次动作 | 2026-09-24 |
| 31 | `bld-0031` | **EvolutionDeep** | `murmur`：群体 agent 用 x402 结算 | 2026-09-24 |
| 32 | `bld-0032` | **acnlabs** | `ACN`：注册表 + A2A + 任务池 + 支付 | 2026-09-24 |
| 33 | `bld-0033` | **ldclabs** | `anda-cloud`：ICP + TEE 的 agent 基建 | 2026-09-24 |
| 34 | `bld-0034` | **Smartdevs17** | `agenticpay`：agent 支付基建 | 2026-09-24 |
| 35 | `bld-0035` | **mizuki0x** | `kamiyo-protocol`（09-19 候选池） | 2026-09-19 |
| 36 | `bld-0036` | **Dabus123** | `azzle`（09-19 候选池） | 2026-09-19 |
| 37 | `bld-0037` | **csehammad** | `covenant-layer`（09-19 候选池） | 2026-09-19 |
| 38 | `bld-0038` | **SeierkDev** | `Axon`（09-19 候选池） | 2026-09-19 |
| 39 | `bld-0039` | **mnemox-ai** | `AgentRelay`（09-19 候选池） | 2026-09-19 |
| 40 | `bld-0040` | **daydreamsai** | `lucid-agents`（09-19 候选池） | 2026-09-19 |

---

## 六、怎么进这本账 / How to get on the ledger

**你不「加入」ORIGIN。你留下第一条可验证的贡献。**（[`CONTRIBUTION-SPEC.md`](CONTRIBUTION-SPEC.md)）

1. 跑起一个 `origin-1` 节点 → 一个 `peer` / `node_id`
2. 让一次**真实动作**发生（起节点 / 提 PR / 跑 demo / 复现测试）→ 一条 `action_ref`
3. 该动作生成收据 → 一条 `release receipt`（含 evidence digest + 验证 URL）
4. 收据上链锚定 → **落账**

**第 1 名 = 第 1 条落账收据。前 99 = 前 99 条落账的独立贡献者（去重，按 identity）。**
在落账之前，任何人都可以**先被记住**（本册 §二–§五 即如此）——但**记住不等于计账**（§铁律 3）。

- 一票只算一次（按 identity 去重）。
- 收据可被任何人**独立重算**——不信运营者。
- 名单是一份**公开可核验的收据清单**，不是通讯录。

> _谁在册，由账本说了算。 The ledger decides who is counted._
> _人类意志为最高法则。权力来自被验证的创新——不来自资本，不来自资历。_ — 宪法 L0

**源·ORIGIN · 量子总督 · 2026-09-24**
