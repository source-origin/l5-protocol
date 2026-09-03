# -*- coding: utf-8 -*-
"""
chain_born_kit.py — Chain-Born 公民证 Kit (源·ORIGIN · Builder 系 · 收尾落地)

给「未来世界公民」发链上出生证的最小契件:让
  * 人类程序员  -> Creator 公民(代表 Creator 系人类创作者)
  * AI 智能体   -> Agent 公民(代表 Agent 系 AI 智能体)
都拿到 did:origin 公民身份,各自把能力/创新登记上链,并在 L5 上现场结一笔
「公民间经济契约」(签约 -> 托管 -> 验证 -> 结算)。

把源的方向「万物上链 -> 首上创新+AI -> 人机皆公民」焊成最小可跑样本。

本契件在 off-chain 用「内存登记表」镜像上游合约语义(只读参照,不真实 import):
  * CitizenRegistry 镜像  AgentIdentity.sol 的 registerAgent / addService /
    addCapability / getGlobalId / recordRevenue(登记 + 产 did)。
  * CitizenDelegation 镜像 L5Delegation.sol 的 createDelegation(人类 delegator
    -> agent delegate 授权花 token,带 resourcePattern 白名单 + max/period +
    revoke = 人类保留最高权,呼应宪法第0条「人类意志最高法则」)。
  * 公民间经济契约「import 只读的 l5_escrow_link」走 AgentEscrow 双账本托管,
    FUND/EXECUTE/VERIFY/SETTLE 用 cross_check 校验双账本逐节点合拍。

诚实标注:
  * 真链时把本文件的内存登记表/内存授权换成对 AgentIdentity.sol 与
    L5Delegation.sol 的真实 provider 调用(docstring 已给上游语义)。
  * EXECUTE 为 off-chain 真劳务,编排器只记录「Agent 已完成交付物」。

铁律:纯标准库,不联网不装包,不改任何已验收 .py/.sol.输出 ASCII/中文仅,
不加 emoji(防 GBK 崩)。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

# 只读 import 本目录的 L5 escrow 联动层(绝不改它)
from l5_escrow_link import (
    AgreementStateCMA,
    EscrowSide,
    EscrowState,
    cross_check,
)

# ---------------------------------------------------------------------------
# 公民身份语义(镜像 AgentIdentity.sol 注释,见 docstring)
# ---------------------------------------------------------------------------

_CREATOR = "creator"     # 人类程序员 / 人类创作者
_AGENT = "agent"         # AI 智能体


def _did_of(handle: str) -> str:
    """产 did:origin:<lowercase-handle>(前缀统一,体现人机皆为公民)。"""
    return f"did:origin:{handle.strip().lower()}"


@dataclass
class Citizen:
    """一份公民身份(人类 Creator 与 AI Agent 共用同一张表 = 人机平等)。"""
    did: str
    handle: str
    name: str
    kind: str                        # 'creator' | 'agent'
    global_id: str                   # 镜像 getGlobalId
    category: str = ""
    bio: str = ""
    repo_uri: str = ""               # Creator:创新代码 repo
    innovation_claim: str = ""       # Creator:一份创新主张
    capability: str = ""             # Agent:能力登记
    registrations: List[str] = field(default_factory=list)

    def describe(self) -> str:
        side = "人类 Creator 公民" if self.kind == _CREATOR else "AI Agent 公民"
        return f"{side} name={self.name} handle={self.handle} did={self.did}"


class CitizenRegistry:
    """
    公民身份登记表(内存镜像 AgentIdentity.sol 登记语义)。
    人类与 AI 共用同一张公民身份表,同样产 did:origin,可互相在链上被识别。
    """

    def __init__(self) -> None:
        self._by_did: Dict[str, Citizen] = {}
        self._seq = 0

    def _next_global(self) -> str:
        self._seq += 1
        return f"origin:global-id:{self._seq:06d}"

    # ---- registerAgent 语义 -------------------------------------------------
    def register_creator(
        self,
        handle: str,
        name: str,
        repo_uri: str,
        bio: str = "",
        innovation_claim: str = "",
    ) -> Citizen:
        """镜 registerAgent(handle+displayName+bio+category+uri -> did),
        为人类程序员/创作者发 Creator 公民出生证,并登记其创新代码 repo 与主张。"""
        did = _did_of(handle)
        if did in self._by_did:
            raise RuntimeError(f"公民已存在: {did}")
        c = Citizen(
            did=did,
            handle=handle,
            name=name,
            kind=_CREATOR,
            global_id=self._next_global(),
            category="human-creator",
            bio=bio,
            repo_uri=repo_uri,
            innovation_claim=innovation_claim or f"代码/创新仓库: {repo_uri}",
        )
        # addService(addCapability) 登记「创新能力/代码 repo 条目」
        c.registrations.append(f"service[repo]={repo_uri}")
        c.registrations.append(f"claim={c.innovation_claim}")
        self._by_did[did] = c
        return c

    def register_agent(
        self,
        handle: str,
        name: str,
        category: str,
        capability: str,
    ) -> Citizen:
        """镜 registerAgent -> Agent 公民(AI 智能体),记 capability/category。"""
        did = _did_of(handle)
        if did in self._by_did:
            raise RuntimeError(f"公民已存在: {did}")
        c = Citizen(
            did=did,
            handle=handle,
            name=name,
            kind=_AGENT,
            global_id=self._next_global(),
            category=category,
            capability=capability,
        )
        # addCapability 登记能力
        c.registrations.append(f"capability[{category}]={capability}")
        self._by_did[did] = c
        return c

    def grant_citizenship_resolver(self, did: str) -> Optional[Citizen]:
        """公民可查:按 did 返回该公民(Human Creator 或 AI Agent)+ 登记项。"""
        return self._by_did.get(did)

    def is_creator(self, did: str) -> bool:
        c = self._by_did.get(did)
        return c is not None and c.kind == _CREATOR

    def is_agent(self, did: str) -> bool:
        c = self._by_did.get(did)
        return c is not None and c.kind == _AGENT

    def all(self) -> List[Citizen]:
        return list(self._by_did.values())


# ---------------------------------------------------------------------------
# 公民间授权(镜像 L5Delegation.sol 最小授权)
# ---------------------------------------------------------------------------

@dataclass
class Delegation:
    id: str
    delegator_did: str            # 人类 Creator 公民(授权方,保留最高权)
    agent_did: str                # AI Agent 公民(被委托方)
    resource_pattern: str         # 白名单资源/任务
    max_per_request: int          # 单次额度上限
    period: int                   # 周期(秒/轮)
    active: bool = True
    used_total: int = 0
    revoke_events: List[str] = field(default_factory=list)


class CitizenDelegation:
    """
    镜像 L5Delegation.sol 的 createDelegation 最小授权层:
    人类 Creator 公民把某资源/任务委托给 AI Agent 公民代办,带 max/period;
    delegator 可 revoke = 人类保留最高权(宪法第0条「人类意志最高法则」)。
    """

    def __init__(self) -> None:
        self._delegations: Dict[str, Delegation] = {}
        self._seq = 0

    def create_delegation(
        self,
        delegator_did: str,
        agent_did: str,
        resource_pattern: str,
        max_per_request: int,
        period: int,
    ) -> Delegation:
        if not delegator_did or not agent_did:
            raise RuntimeError("delegator 与 agent did 均必填")
        if delegator_did == agent_did:
            raise RuntimeError("delegator 不能同时是 delegate")
        self._seq += 1
        d = Delegation(
            id=f"dlg:{self._seq:04d}",
            delegator_did=delegator_did,
            agent_did=agent_did,
            resource_pattern=resource_pattern,
            max_per_request=max_per_request,
            period=period,
        )
        self._delegations[d.id] = d
        return d

    def authorize_spend(self, deleg_id: str, amount: int) -> bool:
        """Agent 凭 delegate 在额度内花费;超 max 或已吊销 => 拒绝。"""
        d = self._delegations.get(deleg_id)
        if d is None:
            raise RuntimeError(f"无此授权: {deleg_id}")
        if not d.active:
            return False
        if amount > d.max_per_request:
            return False
        d.used_total += amount
        return True

    def revoke(self, deleg_id: str, caller_did: str) -> None:
        """delegator(人类)可吊销授权=人类保留最高权。"""
        d = self._delegations.get(deleg_id)
        if d is None:
            raise RuntimeError(f"无此授权: {deleg_id}")
        if caller_did != d.delegator_did:
            raise RuntimeError("仅 delegator(人类公民)可吊销")
        if d.active:
            d.active = False
            d.revoke_events.append(f"revoked by {caller_did}")

    def delegation(self, deleg_id: str) -> Delegation:
        return self._delegations[deleg_id]


class SettlementRecorder:
    """把 run_citizen_demo 的分步收集下来,供 HTML 单页渲图。"""

    def __init__(self) -> None:
        self.steps: List[dict] = []

    def add(self, kind: str, title: str, lines: List[str]) -> None:
        self.steps.append({"kind": kind, "title": title, "lines": lines})


# ---------------------------------------------------------------------------
# 主线演示(剧情化演一遍人机皆公民 + L5 结算)
# ---------------------------------------------------------------------------

def run_citizen_demo(rec: Optional[SettlementRecorder] = None) -> dict:
    rec = rec or SettlementRecorder()

    def step(kind, title, *msgs):
        rec.add(kind, title, list(msgs))
        print(f"[{len(rec.steps):02d}] {title}")
        for m in msgs:
            print("        " + m)

    print("=" * 72)
    print("Chain-Born 公民证 Kit · 人机皆为公民 · L5 结算演示")
    print("=" * 72)

    # ---- 0. 基础设施 ----
    registry = CitizenRegistry()
    delegation = CitizenDelegation()
    escrow = EscrowSide()            # import 自 l5_escrow_link(只读)

    # ---- 1. 注册两位公民(人类 Creator + AI Agent) ----
    creator = registry.register_creator(
        handle="xiaoli",
        name="小李",
        repo_uri="did:repo://xiaoli/agent-defi-collector",
        bio="人类程序员,创作链上协议与 AI 工具",
        innovation_claim="首上创新:一个面向 AI 智能体的自动清算流水线原型",
    )
    agent = registry.register_agent(
        handle="origin-agent",
        name="Origin-Agent",
        category="processing-agent",
        capability="按 L5 规则自动执行分账与结算任务",
    )

    step("register",
         "公民注册(registerAgent 语义)",
         creator.describe(),
         f"登记项: {'; '.join(creator.registrations)}",
         agent.describe(),
         f"登记项(capability/category): {'; '.join(agent.registrations)}")

    # 双方都拿到 did
    assert creator.did.startswith("did:origin:")
    assert agent.did.startswith("did:origin:")
    # 公民可查(false 双向证明):两个都该能查回并区分 Human / AI
    c1 = registry.grant_citizenship_resolver(creator.did)
    c2 = registry.grant_citizenship_resolver(agent.did)
    step("resolve",
         "公民证可查(grant_citizenship_resolver)",
         f"{creator.did} -> Human Creator 公民({c1.kind})",
         f"{agent.did} -> AI Agent 公民({c2.kind})")

    # ---- 2. Creator 公民给 Agent 公民发授权(人类保留最高权) ----
    d = delegation.create_delegation(
        delegator_did=creator.did,
        agent_did=agent.did,
        resource_pattern="task://xiaoli/origin-agent/*",
        max_per_request=100,
        period=86400,
    )
    spend_ok = delegation.authorize_spend(d.id, amount=80)
    step("delegation",
         "公民授权(L5Delegation 镜像:人类把子任务委托给 AI 公民)",
         f"{d.id}: {creator.did} 授权 {agent.did} 处理 task://xiaoli/origin-agent/*",
         f"max_per_request={d.max_per_request} period={d.period}"
         f" 本次授权额 80 -> 通过={spend_ok}",
         "(delegator 可随时 revoke = 人类保留最高权,宪法第0条)")

    # ---- 3. 公民间经济契约: Creator(payer) <-> Agent(payee) ----
    # 用 Creator 登记的那份创新代码/能力作交付物;资金额取授权批准额度
    amount = 80
    payer = creator.did          # 注资方 = 人类 Creator 公民
    payee = agent.did            # 收款方 = AI Agent 公民
    agreement_id = "agreement_origin_a100"

    # 契约状态推进:DRAFT -> PROPOSED -> SIGNED
    escrow.set_agreement_state(agreement_id, AgreementStateCMA.DRAFT)
    escrow.set_agreement_state(agreement_id, AgreementStateCMA.PROPOSED)
    escrow.set_agreement_state(agreement_id, AgreementStateCMA.SIGNED)
    step("contract",
         "公民间契约签约(Consumer=Creator 公民, Provider=Agent 公民)",
         f"agreement={agreement_id}",
         f"payer={payer}  payee={payee}",
         f"交付物=Creator 登记的创新代码 repo('{creator.repo_uri}')")

    # ---- 4. FUND: create_and_fund 锁资金,双账本 cross_check ----
    esc_id = escrow.create_and_fund(
        agreement_id, payer, payee, amount=amount, deadline=3600,
    )
    e = escrow.escrow_by_agreement(agreement_id)
    ok, txt = cross_check("FUND", e.state, escrow.agreement_state(agreement_id))
    assert ok, txt
    step("fund",
         "FUND: 资金经 escrow 托管锁定(create_and_fund)",
         f"锁入 escrow={esc_id} 金额={amount} escrow={e.state.name}",
         f"cross_check: {txt}")

    # ---- 5. EXECUTE: off-chain 劳务(AI Agent 完成交付/记账) ----
    # agreement 工作推进到 Executed -> Completed(交付物已就绪)
    escrow.set_agreement_state(agreement_id, AgreementStateCMA.EXECUTED)
    escrow.set_agreement_state(agreement_id, AgreementStateCMA.COMPLETED)
    step("execute",
         "EXECUTE: Agent 公民完成交付(off-chain 劳务,编排器记录)",
         f"{agent.name} 依授权按规则执行分账/结算,交付创意代码 repo",
         f"agreement -> {escrow.agreement_state(agreement_id).name}")

    # ---- 6. VERIFY: verify_delivery(仅 payee 可验),双账本 cross_check ----
    escrow.verify_delivery(esc_id, caller=payee)
    e = escrow.escrow_by_agreement(agreement_id)
    ok, txt = cross_check("VERIFY", e.state, escrow.agreement_state(agreement_id))
    assert ok, txt
    step("verify",
         "VERIFY: 交付被验(verify_delivery,资金未动)",
         f"escrow={e.state.name} agreement={escrow.agreement_state(agreement_id).name}",
         f"cross_check: {txt}")

    # ---- 7. SETTLE: release 付给 Agent 公民 + agreement markSettled ----
    escrow.release(esc_id, caller=payer)   # 驱动 agreement -> Settled
    e = escrow.escrow_by_agreement(agreement_id)
    ok, txt = cross_check("SETTLE", e.state, escrow.agreement_state(agreement_id))
    assert ok, txt
    step("settle",
         "SETTLE: 资金释放给 Agent 公民 + agreement 握手 Settled",
         f"escrow={e.state.name} agreement={escrow.agreement_state(agreement_id).name}",
         f"cross_check: {txt}")

    # ---- 8. 收尾: 双 did + 资金流向 + 双账本终态 ----
    final_state = {
        "creator_did": creator.did,
        "creator_name": creator.name,
        "creator_kind": "Human Creator 公民",
        "agent_did": agent.did,
        "agent_name": agent.name,
        "agent_kind": "AI Agent 公民",
        "delegation_id": d.id,
        "resource_pattern": d.resource_pattern,
        "agreement_id": agreement_id,
        "escrow_id": esc_id,
        "amount": amount,
        "payer": payer,
        "payee": payee,
        "escrow_state": e.state.name,
        "agreement_state": escrow.agreement_state(agreement_id).name,
        "funds_locked": e.funds_locked,
        "funds_paid_out": e.funds_paid_out,
        "funds_refunded": e.funds_refunded,
    }
    step("final",
         "收尾: 双公民链上身份 + 资金终态(Settled 落地)",
         f"Creator 公民 name={creator.name} did={creator.did}",
         f"Agent  公民 name={agent.name} did={agent.did}",
         f"资金流向: {payer} 付 {amount} uL5 -> escrow({esc_id}) "
         f"-> 已付 payee={e.funds_paid_out} 退回={e.funds_refunded}",
         f"EscrowState={e.state.name}  AgreementState="
         f"{escrow.agreement_state(agreement_id).name}")

    # 硬断言:双公民都拿到 did,delegation 下花销批准,结算到终态
    assert creator.did != agent.did
    assert spend_ok is True
    assert e.state is EscrowState.RELEASED
    assert escrow.agreement_state(agreement_id) is AgreementStateCMA.SETTLED
    assert e.funds_paid_out == amount and e.funds_locked == 0

    print("\n== [PASS] Chain-Born 公民证 demo: Creator 与 Agent 皆 did 公民,"
          "delgation + 托管结算双账本到终态 ==")
    return final_state


# ---------------------------------------------------------------------------
# HTML 单页渲染(chain_born_demo.html)
# ---------------------------------------------------------------------------

def _badge(kind: str, item: str) -> str:
    color = "#2f7cf6" if kind == "creator" else "#16b66c"
    return (
        f'<span class="badge" style="border-color:{color};color:{color}">'
        f"{item}</span>"
    )


def render_html(data: dict, rec: SettlementRecorder) -> str:
    """渲成单页可视化(meta charset=UTF-8,浅色科技感,分步卡片)。"""
    kind_emoji = {"register": "01", "resolve": "02", "delegation": "03",
                  "contract": "04", "fund": "05", "execute": "06",
                  "verify": "07", "settle": "08", "final": "09"}

    cards = ""
    for i, s in enumerate(rec.steps, 1):
        tag = kind_emoji.get(s["kind"], "xx")
        lines_html = "".join(
            f"<li>{ln}</li>" for ln in s["lines"]
        )
        title = s["title"]
        cls = s["kind"]
        cards += (
            f'<div class="card {cls}">'
            f'<div class="card-head"><span class="tag">{tag}</span>'
            f'<h3>{title}</h3></div>'
            f'<ul class="lines">{lines_html}</ul></div>'
        )

    creator_badge = _badge(
        "creator", f"{data['creator_name']} {data['creator_did']}"
    )
    agent_badge = _badge(
        "agent", f"{data['agent_name']} {data['agent_did']}"
    )
    fund_badge = (
        f'<span class="badge money">flow: {data["payer"]}'
        f' --{data["amount"]} uL5--> escrow[{data["escrow_id"]}]'
        f' --{data["funds_paid_out"]}--> {data["payee"]}</span>'
    )
    result = (
        f'<span class="badge cyan">EscrowState={data["escrow_state"]}</span>'
        f'<span class="badge cyan">AgreementState={data["agreement_state"]}</span>'
    )

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chain-Born 公民证 · 人机皆为公民 · L5 结算演示</title>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
    background: linear-gradient(160deg,#eef4ff 0%,#f6fbff 45%,#eafaf3 100%);
    color:#17324d; padding: 34px 20px 60px; min-height:100vh;
  }}
  .wrap {{ max-width: 920px; margin: 0 auto; }}
  header {{ text-align:center; margin-bottom:26px; }}
  h1 {{
    font-size:26px; letter-spacing:2px; color:#0e2c4f; margin-bottom:6px;
  }}
  .sub {{ color:#3e6a97; font-size:14px; letter-spacing:1px; }}
  .rule {{ height:2px; width:120px; margin:14px auto 0;
    background:linear-gradient(90deg,transparent,#2f7cf6,#16b66c,transparent);}}
  .hero {{ display:flex; flex-wrap:wrap; gap:10px; justify-content:center;
    margin: 8px 0 22px; }}
  .badge {{
    border:1.5px solid #2f7cf6; color:#2f7cf6; background:#fff;
    border-radius:999px; padding:6px 13px; font-size:13px; font-weight:600;
    display:inline-block; margin:3px; box-shadow:0 1px 3px rgba(20,60,110,.08);
  }}
  .badge.money {{
    border-color:#f09b3a; color:#b06a10; background:#fff7ec;
    letter-spacing:.3px;
  }}
  .badge.cyan {{ border-color:#17a2b8; color:#0e7585; background:#eafcff; }}
  .cards {{ display:flex; flex-direction:column; gap:14px; }}
  .card {{
    background:#ffffff; border:1px solid #dbe6f3; border-radius:14px;
    padding:14px 18px; box-shadow:0 3px 10px rgba(20,60,110,.05);
  }}
  .card-head {{ display:flex; align-items:center; gap:10px; margin-bottom:8px; }}
  .tag {{
    background:#e7effb; color:#2f7cf6; font-weight:700; font-size:12px;
    border-radius:8px; padding:3px 8px; border:1px solid #c9dcf5;
  }}
  h3 {{ font-size:16px; color:#0e2c4f; }}
  ul.lines {{ list-style:none; }}
  ul.lines li {{
    font-size:13.5px; color:#2c4a66;
    padding:3px 0 3px 14px; position:relative; word-break:break-all;
  }}
  ul.lines li::before {{
    content:"›"; position:absolute; left:0; color:#7fa8d6; font-weight:700;
  }}
  footer {{ text-align:center; margin-top:26px; color:#6b87a8; font-size:12px; }}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Chain-Born 公民证 · 人机皆为公民 · L5 结算演示</h1>
    <div class="sub">源 · ORIGIN — 为 AI 智能体经济设计的清算与结算层</div>
    <div class="rule"></div>
  </header>

  <div class="hero">
    {creator_badge}
    {agent_badge}
  </div>
  <div class="hero">{fund_badge}</div>
  <div class="hero">{result}</div>

  <div class="cards">{cards}</div>

  <footer>
    did 前缀统一 = 人机平权; Escrow 双账本托管驱动 agreement 握手 Settled;
    全程 off-chain 模拟,镜像 AgentIdentity.sol / L5Delegation.sol 语义。
  </footer>
</div>
</body>
</html>
"""
    # 修正潜在手误并确保 ASCII 合规渲染(仅中文非 ASCII 属正常)
    return html


# ---------------------------------------------------------------------------
# __main__
# ---------------------------------------------------------------------------

def _main() -> None:
    import os

    rec = SettlementRecorder()
    final_data = run_citizen_demo(rec)

    here = os.path.dirname(os.path.abspath(__file__))
    html_path = os.path.join(here, "chain_born_demo.html")
    html = render_html(final_data, rec)
    # 真写盘(UTF-8, 无 BOM)
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)

    size = os.path.getsize(html_path)
    print("\n== HTML 已落盘 ==")
    print(f"path : {html_path}")
    print(f"bytes: {size}")
    assert os.path.exists(html_path)
    assert size > 5000, f"html 过小: {size}"

    print("\n== 交付摘要(双公民 did + 结算终态) ==")
    print(f"Creator 公民 did : {final_data['creator_did']}")
    print(f"Agent 公民 did   : {final_data['agent_did']}")
    print(f"delegation       : {final_data['delegation_id']} "
          f"{final_data['resource_pattern']}")
    print(f"EscrowState      : {final_data['escrow_state']}")
    print(f"AgreementState   : {final_data['agreement_state']}")
    print(f"资金流向         : {final_data['payer']} --{final_data['amount']} uL5--> "
          f"escrow[{final_data['escrow_id']}] --{final_data['funds_paid_out']}--> "
          f"{final_data['payee']}")


if __name__ == "__main__":
    _main()
