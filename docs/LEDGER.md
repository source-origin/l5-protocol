# 开发者账本 / Builder Ledger

> **这是一本追加式（append-only）名册。它的职责只有一个：记住每一个碰过这条边界的人——早期的、现在的、后来的。**
> 记账不靠申请，靠**可独立核验的贡献**（见 [`CONTRIBUTION-SPEC.md`](CONTRIBUTION-SPEC.md)）。

**状态：`v0 — seeded 2026-09-24`。** 机器可读版：[`../ledger.json`](../ledger.json)。校验：`node tools/ledger.cjs check`。

---

## 铁律 / The rules

1. **只增不改。** 条目一旦落账，永不重写；过时用 `superseded_by` 指向新条目，原件保留。`id` 单调递增（`bld-0001`…）。
2. **每条都带得开的证据。** 每个条目必须引用一个第三方能打开的东西（issue / discussion / commit / PR / 链上 tx）。不能只有「我认识他」。**若对方表面已失联（改名/删号），标 `reachable:false` 并在 `note` 说明**——记录保留，不硬认归属。
3. **记住 ≠ 计账。** 被引（convergence）是「记住」；**落了一条可核验的贡献收据**（`counted: true`）才是「计账」。两者分开记。
   - **绑定规则（关键）：** 外部条目的 `counted` **只在该条目自己公布的密钥（`signing_key`）签署的收据上翻真——绝不在账本保管人自己记录的该条目言辞上翻真。** 否则「记住 → 计账」的距离只有一次 push。（此条由 scvd 指认，采纳。）
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
| 6 | `bld-0006` ↻`bld-0041` | **seancrecord** | 同一 Boundary 规则（授权侧）；**读本仓公开树对照其自身文档，检出真实漂移**（契约数 / 无据 CI 声明 / 测试数） | 2026-09-21 | [scvd#874](https://github.com/seancrecord/scvd-general-store-repo/issues/874) |

> ↻ `bld-0041` 覆盖 `bld-0006` 的措辞（追加式：原条目保留、指向覆盖项，不重写）。`bld-0006` 的 `counted` 恒为 `false`——scvd 的 `signing_key` 在 `scvd.store/.well-known/scvd-signing-key`，且声明**不会**向 origin-1 签收据（按构造为 false）。

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
| 42 | `bld-0042` | **cirwel** | `unitares`：长时程 agent 问责基建（identity / claim / evidence / review / outcome / reconstruction）；问「记录者亦裁判」缝隙 | 2026-09-24 | [disc#2420](https://github.com/cirwel/unitares/discussions/2420) |
| 43 | `bld-0043` | **Zoverions** | `AXIOM-MESH`：intent→policy plan→approved effects→加密链接证据；问 intent vs effect 绑定 + 可否反转 | 2026-09-24 | [disc#1819](https://github.com/Zoverions/AXIOM-MESH/discussions/1819) |
| 54 | `bld-0054` | **Mindburn-Labs** | `helm-ai-kernel`：fail-closed 执行防火墙 + signed receipts + EvidencePacks 离线核验；**逐字同频我们的 seam#8**（收据完整性 `integrity_valid` 与签名者信任 `signer_trusted` 分作两裁）；问“权威绑定从哪来” | 2026-09-24 | [disc#978](https://github.com/orgs/Mindburn-Labs/discussions/978) |
| 55 | `bld-0055` | **DanceNitra** | `inspeximus`：agent 记忆“改一次已知、旧值退休”（**逐字同频我们的 append-only + supersede**）+ verifiable erasure；问 supersede 与 erasure 如何在一条日志共存、witness 是谁 | 2026-09-24 | [disc#34](https://github.com/DanceNitra/inspeximus/discussions/34) |
| 66 | `bld-0066` | **Aliipou** | `decision-os-min`：signed action-bound decisions + hosted effect mediation + replay resistance；问 observed effect 如何绑回预签 decision、第三方能否不信任 mediator 独立重算绑定 | 2026-09-24 | [disc#5](https://github.com/Aliipou/decision-os-min/discussions/5) |
| 67 | `bld-0067` | **sunilp** | `aip`（IETF Internet-Draft）：可验证可委托的 agent 身份（MCP/A2A，UCAN 式）；问 invocation 如何绑到 delegation chain、根钥轮换后绑定是否还在 | 2026-09-24 | [disc#6](https://github.com/sunilp/aip/discussions/6) |
| 68 | `bld-0068` | **PerryLink** | `dsh-research-report`：content-addressed 证据账本，claim-snapshot 绑定 + tamper-evident；问源变更时 supersede 还是 invalidate、merkle receipt 证的是 retrieved(effect) 还是 asserted(intent) | 2026-09-24 | [disc#10](https://github.com/PerryLink/dsh-research-report/discussions/10) |

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
| 44 | `bld-0044` | **b7n0de** | `proofbundle`：离线可核验证据包（RFC 6962 透明日志 / merkle / receipts）；"integrity, not truth" | 2026-09-24 |
| 45 | `bld-0045` | **sattyamjjain** | `ferrumdeck`：in-path 执行强制 + hash-chained 审计 + 预算/批准门；自带假阳率与分母 | 2026-09-24 |
| 46 | `bld-0046` | **mishrasanjeev** | `grantex`：agent 身份/授权/审计基建（"OAuth moment"） | 2026-09-24 |
| 47 | `bld-0047` | **YugantM** | `hvtracker`：独立、基于证据的 agent/MCP 信任注册表 | 2026-09-24 |
| 48 | `bld-0048` | **basilisk-labs** | `agentplane`：git-native 批准计划 + 可审证据 | 2026-09-24 |
| 49 | `bld-0049` | **A3S-Lab** | `Power`：可验证执行 + TEE + canonical receipts | 2026-09-24 |
| 50 | `bld-0050` | **HelloVIMS** | `Agent-NFT`：ERC-8004 身份 + EIP-712/EIP-3009 x402 结算 | 2026-09-24 |
| 51 | `bld-0051` | **kychee-com** | `run402`：agent 后端基建，x402/MPP 计费 | 2026-09-24 |
| 52 | `bld-0052` | **Its-fortunatefolly** | `HubVibe`：machine-payable work（HTTP 402），per-job receipt | 2026-09-24 |
| 53 | `bld-0053` | **Dragonmonk111** | `junoclaw`：可验证自治 + 链上真值市场 + 工作史 attestation | 2026-09-24 |
| 56 | `bld-0056` | **ashaveri** | `ashaveri`：OpenAI 兼容推理，每个响应带签名 COSE_Sign1 收据（request/response hash + 权重清单 + 机密硬件度量）；"Change the model. Keep the evidence." | 2026-09-24 |
| 57 | `bld-0057` | **Garl-Protocol** | `garl`：ECDSA-secp256k1+RFC6979 签名的 Action Receipt，绑定到授权 token，Merkle 锚定 Base；能力 token 只能收窄不可放大。⚠️ **已归档（2026-09-24），托管服务下线** | 2026-09-24 |
| 58 | `bld-0058` | **at1c-protocol** | `at1c-protocol-official`：人类控制 AI 的证据层；"Don't trust us. Verify the receipt." + 主权身份/注册表 | 2026-09-24 |
| 59 | `bld-0059` | **tuannguyenvan95** | `AgentSLA`：子 Agent SLA 裁决 + bounty escrow（GenLayer） | 2026-09-24 |
| 60 | `bld-0060` | **chainloop-dev** | `chainloop`：SDLC 证据库 + 策略引擎（in-toto / SLSA / SBOM attestations） | 2026-09-24 |
| 61 | `bld-0061` | **darklordVirtual** | `REMORA-research`：policy-gated 治理（OPA/Rego，pre-execution，负结果记录） | 2026-09-24 |
| 62 | `bld-0062` | **edgepillar** | `zenon-x402-poc`：Zenon 作 HTTP-native agent 支付结算轨 | 2026-09-24 |
| 63 | `bld-0063` | **naulonapp** | `naulon`：agentic web 的按读付费 toll（x402/USDC nanopayment，归因即分成规则） | 2026-09-24 |
| 64 | `bld-0064` | **Vortx-AI** | `emem`：物理世界的机器维护外部记忆（content-addressed + ed25519 + transparency log + 确定性） | 2026-09-24 |
| 65 | `bld-0065` | **Luminous-Dynamics** | `mycelix`：Holochain 上的分形治理 CivOS（身份/governance） | 2026-09-24 |
| 69 | `bld-0069` | **Vadale** | `project-guardian`：本地用户态 agent-agnostic 防火墙，中介 agent 动作（policy/audit/human-in-the-loop） | 2026-09-24 |
| 70 | `bld-0070` | **benseverndev-oss** | `goldenmatch`：实体消解喂给持久身份层（按 identity 去重） | 2026-09-24 |
| 71 | `bld-0071` | **aks129** | `HealthClawGuardrails`：agent 与 FHIR 之间的护栏（PHI 脱敏 / 不可变审计 / step-up 认证） | 2026-09-24 |
| 72 | `bld-0072` | **accensa** | `accensa-contracts`：Soroban 链上收据锚定 + 商户退款金库 | 2026-09-24 |
| 73 | `bld-0073` | **Stellar-VaultLink** | `invofi`：Stellar Soroban 上链发票融资 + escrow | 2026-09-24 |
| 74 | `bld-0074` | **legend-esc** | `carbonchain`：Soroban 问责 / 审批（tokenized carbon 发行-交易-注销） | 2026-09-24 |
| 75 | `bld-0075` | **Zahanturel** | `adtp`：agent 密码学身份 + 委托（UCAN 链、RESTRICT 模式收窄） | 2026-09-24 |
| 76 | `bld-0076` | **giselleevita** | `agent-security-gate`：OPA/Rego 策略门 + 审批，执行前拦截不安全 tool call | 2026-09-24 |
| 77 | `bld-0077` | **LegionForge** | `guardian`：agent 安全层，阻断 prompt injection / tool tampering / 失控 | 2026-09-24 |
| 78 | `bld-0078` | **nohn3043-arch** | `second-perspective`（NOMOS）：可审计决策编排层，确定性基座 | 2026-09-24 |
| 79 | `bld-0079` | **jposluns** | `grc_library`：治理/风险/合规（GRC）文档库 | 2026-09-24 |

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
