# -*- coding: utf-8 -*-
"""
l5_demo_theater.py — L5 结算托管双账本 · 可视化演示剧场 (收尾落地)

本职
----
让已验收的 L5 结算能被"看到":import l5_escrow_link 的双账本联动层
(EscrowSide / AgreementStateCMA / EscrowState / cross_check),
驱动一条"看得见每一步"的成功结算轨迹:
    SUBMIT -> VALIDATE -> SIGN -> FUND(资金锁 escrow) -> EXECUTE(off-chain 记录完成)
    -> COMPLETE -> VERIFY(escrow 验证)-> SETTLE(escrow release 付 Provider,
      并驱动 agreement markSettled 到 Settled)。
每一步收集:步骤名 / 当前 escrow 状态(资金锁/已付/退回)/ 当前 agreement 状态 / 一笔中文说明,
存成结构化列表(每项 dict)。

渲染
----
纯标准库把该轨迹渲染成自包含单页 HTML(所有 CSS/JS 内嵌,零外部依赖),
写到同目录 l5_demo_theater.html。浅色科技感:分步卡片纵排、每卡
步骤名 + 双账本状态徽章(escrow 状态 / agreement 状态 / 资金字段)、
顶部标题一句"L5 结算托管双账本 · 可视化演示(off-chain)"、底部诚实标注。
内嵌一段 JS:播放(逐步骤进高亮)+ 重置(高亮第一张)。

铁律
----
只 import 已验收文件(只读),不修改它们。纯标准库,不联网不装包。
全部文件路径/文件名 ASCII。HTML 请求体 UTF-8 落盘。
"""

from __future__ import annotations

import os

# 只读 import 已验收的 escrow 托管双账本联动层
from l5_escrow_link import (
    EscrowSide,
    AgreementStateCMA as AgSt,
    EscrowState as EscSt,
    cross_check,
)

# ---------------------------------------------------------------------------
# 1) 驱动轨迹
# ---------------------------------------------------------------------------
def run_success_trajectory() -> list:
    """
    跑一条完整成功结算轨迹,返回每步结构 dict:
      {step, node, escrow_state, escrow_funds_locked, escrow_funds_paid,
       escrow_funds_refunded, agreement_state, note, ok, goal}
    """
    trace: list = []

    def cap(text, ok=True):
        return ("OK" if ok else "GATE")  # GATE=已达标通过

    side = EscrowSide()
    ag_id = "agreement_0xA1A2"
    payer = "consumer_0xC"
    payee = "provider_0xP"
    amount = 1000
    deadline = 3600

    esc_entry = None  # type: ignore

    def snap(node, text, goal, ok=True, gate=True):
        """截取当前 escrow/agreement 双账本照。"""
        e = esc_entry
        return {
            "step": len(trace) + 1,
            "node": node,
            "goal": goal,
            "escrow_state": (e.state.name if e is not None else EscSt.EMPTY.name),
            "escrow_locked": e.funds_locked if e is not None else 0,
            "escrow_paid": e.funds_paid_out if e is not None else 0,
            "escrow_refunded": e.funds_refunded if e is not None else 0,
            "agreement_state": side.agreement_state(ag_id).name,
            "note": text,
            "gate": gate,
            "credit": cap(text, ok),
        }

    # ---- SUBMIT:开 agreement(DRAFT),还没托管 ----
    side.set_agreement_state(ag_id, AgSt.DRAFT)
    trace.append(snap(
        "SUBMIT",
        "发起人把劳务协议内容提交上链/入编排器,协议先落在 DRAFT(草稿)态,双方随时可改。",
        "agreement 从空进入 DRAFT",
    ))

    # ---- VALIDATE:合法与资金核算 ----
    side.set_agreement_state(ag_id, AgSt.PROPOSED)
    trace.append(snap(
        "VALIDATE",
        f"校验协议条款合法达标,核算应收资金 {amount} 与 截止期限 {deadline}s,协议推进到 PROPOSED,等待双方接受。",
        "agreement PROPOSED,待签署",
    ))

    # ---- SIGN:双方签署 ----
    side.set_agreement_state(ag_id, AgSt.SIGNED)
    trace.append(snap(
        "SIGN",
        "Consumer 结算方与 Provider 履约方双方签名锁约,agreement 到 SIGNED,SETTLE 时的 escrow 托管前提已备齐。",
        "agreement SIGNED,可注资托管",
    ))

    # ---- FUND:资金锁入 escrow(双账本第一握手) ----
    esc_id = side.create_and_fund(ag_id, payer, payee, amount, deadline)
    esc_entry = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("FUND", esc_entry.state, side.agreement_state(ag_id))
    trace.append(snap(
        "FUND",
        f"escrow.create_and_fund:Consumer 把 {amount} 锁定进 escrow,资金进入托管锁(funds_locked={esc_entry.funds_locked}),"
        f"双账本握手校验: {txt}",
        "escrow FUNDED(资金锁) + agreement 已签名",
        ok=True, gate=True,
    ))

    # ---- EXECUTE:off-chain 真劳务,只记录完成(不可链上) ----
    side.set_agreement_state(ag_id, AgSt.EXECUTED)
    trace.append(snap(
        "EXECUTE",
        "EXECUTE 是 off-chain 真实劳务,无法在链上执行;编排器在此只记录'已开始执行',agreement 推至 EXECUTED,escrow 资金仍锁在原处未动。",
        "agreement EXECUTED(off-chain 劳务记录)",
    ))

    # ---- COMPLETE:劳务交付,agreement terms 全完成 ----
    side.set_agreement_state(ag_id, AgSt.COMPLETED)
    trace.append(snap(
        "COMPLETE",
        "Provider 完成并交付全部条款,agreement 里程碑推进到 COMPLETED,工作已交回,为 escrow 验证准备好凭据。",
        "agreement COMPLETED(工作交付)",
    ))

    # ---- VERIFY:escrow 验证商家 ----
    side.verify_delivery(esc_id, caller=payee)
    esc_entry = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("VERIFY", esc_entry.state, side.agreement_state(ag_id))
    note = f"Provider 自验(verify_delivery,l仅 payee 可调),escrow 从 FUNDED->VERIFIED(已验,资金未动);双账本校验: {txt}"
    trace.append(snap("VERIFY", note,
                      "escrow VERIFIED(已验资金未动)+ agreement COMPLETED",
                      ok=ok, gate=ok))

    # ---- SETTLE:escrow.release 付 Provider + agreement.markSettled 握手 ----
    side.release(esc_id, caller=payer)  # 触发 escrow 释放 + 驱动 markSettled
    esc_entry = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("SETTLE", esc_entry.state, side.agreement_state(ag_id))
    note = (f"settle:escrow.release 把 funds_paid_out={esc_entry.funds_paid_out} 付给 Provider,资金锁清 0;"
            f"同时握手驱动 agreement 到 markSettled(SETTLED)终态;双账本校验: {txt}")
    trace.append(snap("SETTLE", note,
                      "escrow RELEASED(钱已付 Provider)+ agreement SETTLED(握手终态)",
                      ok=ok, gate=ok))

    # 终态断言
    assert esc_entry.state is EscSt.RELEASED
    assert side.agreement_state(ag_id) is AgSt.SETTLED
    assert esc_entry.funds_paid_out == amount and esc_entry.funds_locked == 0
    return trace


# ---------------------------------------------------------------------------
# 2) 渲染单页 HTML(纯标准库,自包含)
# ---------------------------------------------------------------------------
# 徽章文案与配色 —— 只用文字与色,不用 emoji(防 GBK 写盘崩)
ESCROW_STYLE = {
    "EMPTY":     ("空",       "badge-none"),
    "FUNDED":    ("资金已锁定", "badge-fund"),
    "VERIFIED":  ("工作已验", "badge-verify"),
    "RELEASED":  ("已付给Provider", "badge-settle"),
    "CANCELLED": ("已退回",   "badge-cancel"),
    "DISPUTED":  ("争议中",   "badge-dispute"),
}
AG_STYLE = {
    "DRAFT":     ("草稿",   "ag-draft"),
    "PROPOSED":  ("提案",   "ag-proposed"),
    "SIGNED":    ("已签署", "ag-signed"),
    "EXECUTED":  ("执行中", "ag-exec"),
    "COMPLETED": ("已完成", "ag-complete"),
    "SETTLED":   ("已结算", "ag-settle"),
    "CANCELLED": ("已取消", "ag-cancel"),
    "DISPUTED":  ("争议",   "ag-dispute"),
    "SLASHED":   ("已罚没", "ag-slashed"),
}
NODE_COLOR = {
    "SUBMIT": "step-ink", "VALIDATE": "step-ink", "SIGN": "step-ink",
    "FUND": "step-gold", "EXECUTE": "step-cyan", "COMPLETE": "step-cyan",
    "VERIFY": "step-blue", "SETTLE": "step-green",
}


def _esc_html_state(esc_name, agreement_name):
    e_lab, e_cls = ESCROW_STYLE.get(esc_name, (esc_name, "badge-none"))
    a_lab, a_cls = AG_STYLE.get(agreement_name, (agreement_name, "ag-draft"))
    es = (f'<span class="badge {e_cls}">escrow: {e_lab}</span>')
    ags = f'<span class="badge ags {a_cls}">agreement: {a_lab}</span>'
    return es, ags


def _card_html(s: dict) -> str:
    step, node = s["step"], s["node"]
    esc_html, ag_html = _esc_html_state(s["escrow_state"], s["agreement_state"])
    nc = NODE_COLOR.get(node, "step-ink")
    locked_txt = f'{s["escrow_locked"]}'
    locked_html = (f'<span class="money">{locked_txt}</span>'
                   if s["escrow_locked"] else
                   f'<span class="money zero">{locked_txt}</span>')
    paid_html = (f'<span class="money ok">{s["escrow_paid"]}</span>'
                 if s["escrow_paid"] else f'<span class="money zero">{s["escrow_paid"]}</span>')
    refund_html = (f'<span class="money">{s["escrow_refunded"]}</span>')
    gate_cls = "gate-ok" if s["gate"] else "gate-no"
    gate_txt = "双账本达成" if s["gate"] else "门禁拦下"
    return f"""
    <div class="card" data-step="{step}" id="card-{step}">
      <div class="step-head">
        <span class="step-no">{step:02d}</span>
        <span class="step-name {nc}">{node}</span>
        <span class="gate {gate_cls}">{gate_txt}</span>
      </div>
      <div class="goals">目标: {s['goal']}</div>
      <p class="note">{s['note']}</p>
      <div class="ledgers">
        <div class="ledger-cell">{esc_html}
          <div class="funds">
            <span class="fund-lab">资金锁</span>{locked_html}
            <span class="fund-lab">已付Provider</span>{paid_html}
            <span class="fund-lab">退回Consumer</span>{refund_html}
          </div>
        </div>
        <div class="ledger-cell">{ag_html}</div>
      </div>
    </div>"""


def render_html(trajectory: list) -> str:
    cards = "\n".join(_card_html(s) for s in trajectory)
    n = len(trajectory)
    css = """
      :root{--b1:#f5f9ff;--ink:#12233f;--mut:#5b6b83;--line:#dfe7f3;
            --gold:#c8951a;--cyan:#0e8f9b;--blue:#2f6bd8;--green:#1f9d55;
            --red:#ce3b3b;--purple:#7a5ac2;--card:#ffffff;}
      *{box-sizing:border-box} body{margin:0;background:
        radial-gradient(1200px 500px at 20% -5%,#e8f1ff 0%,var(--b1) 45%);
        color:var(--ink);font:15px/1.6 "Segoe UI",system-ui,Arial,sans-serif;
        padding:34px 18px 60px;}
      .wrap{max-width:900px;margin:0 auto}
      .hero{display:flex;justify-content:space-between;align-items:flex-end;
        gap:18px;flex-wrap:wrap;margin-bottom:6px}
      h1{font-size:26px;margin:0;letter-spacing:.5px}
      .hero .sub{color:var(--mut);font-size:13px;margin-top:6px}
      .toolbar{display:flex;gap:10px;margin:16px 0 22px}
      button{font:600 14px inherit;border:1px solid var(--line);
        background:#fff;color:var(--blue);border-radius:999px;padding:8px 18px;
        cursor:pointer;box-shadow:0 1px 2px rgba(18,35,63,.05);
        transition:.15s}
      button:hover{border-color:var(--blue);background:#eef4ff;transform:translateY(-1px)}
      .status-pill{display:inline-flex;align-items:center;gap:8px;
        background:#fff;border:1px solid var(--line);border-radius:999px;
        padding:6px 14px;font-size:13px;color:var(--mut);margin-left:auto}
      .dot{width:9px;height:9px;border-radius:50%;background:#cfd6e2}
      .dot.live{background:var(--green);box-shadow:0 0 0 3px #cdeedb}
      .progress{margin:4px 0 16px}
      .progress-track{height:6px;background:var(--line);border-radius:3px;
        overflow:hidden}
      .progress-fill{height:100%;width:0;background:linear-gradient(90deg,
        var(--gold),var(--green));transition:width .3s ease}
      .card{background:var(--card);border:1px solid var(--line);
        border-radius:14px;padding:16px 18px;margin:14px 0;
        box-shadow:0 2px 8px rgba(18,35,63,.05);opacity:.62;
        transition:opacity .25s,transform .25s,border-color .25s}
      .card:first-child{opacity:1}
      .card.live{opacity:1;border-color:var(--cyan);
        box-shadow:0 6px 20px rgba(14,143,155,.16);transform:translateY(-2px)}
      .step-head{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
      .step-no{font:700 16px/1 monospace;color:#fff;background:var(--ink);
        border-radius:8px;padding:4px 9px}
      .step-name{font:700 18px inherit;letter-spacing:.6px}
      .step-ink{color:#12233f}.step-gold{color:var(--gold)}
      .step-cyan{color:var(--cyan)}.step-blue{color:var(--blue)}
      .step-green{color:var(--green)}
      .gate{margin-left:auto;font-size:12px;font-weight:700;border-radius:999px;
        padding:3px 11px}
      .gate-ok{color:var(--green);background:#e8f8ef}
      .gate-no{color:var(--red);background:#fdecec}
      .goals{color:var(--mut);font-size:13px;margin:10px 0 6px}
      .goals b,.goals .g-b{color:var(--ink)}
      .note{color:#3a4a63;margin:0 0 12px}
      .ledgers{display:grid;grid-template-columns:1fr auto;gap:12px;
        align-items:stretch;border-top:1px dashed var(--line);padding-top:12px}
      .ledger-cell{display:flex;flex-direction:column;gap:6px;font-size:13px}
      .badge{border-radius:999px;padding:3px 11px;font-weight:600;font-size:12px;
        display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
      .badge-none{color:var(--mut);background:#eef2f8}
      .badge-fund{color:#926a07;background:#faf0d4}
      .badge-verify{color:#0b7a68;background:#dff5ef}
      .badge-settle{color:#137a37;background:#ddf3e3}
      .badge-cancel{color:#8a8a8a;background:#ececec}
      .badge-dispute{color:var(--purple);background:#ede5fa}
      .ags{margin-top:2px}
      .ag-draft{color:var(--mut);background:#eef2f8}
      .ag-proposed{color:#3764b8;background:#e6eefc}
      .ag-signed{color:#136a9a;background:#e0effa}
      .ag-exec{color:var(--cyan);background:#dff3f5}
      .ag-complete{color:#0b6ea2;background:#def0fa}
      .ag-settle{color:#137a37;background:#ddf3e3}
      .ag-cancel{color:#76747e;background:#efedf3}
      .ag-dispute{color:var(--purple);background:#ede5fa}
      .ag-slashed{color:var(--red);background:#fbe4e4}
      .funds{display:flex;gap:14px;flex-wrap:wrap;align-items:center;
        font-size:12px;color:var(--mut)}
      .fund-lab{opacity:.8}
      .money{font:700 15px/1 ui-monospace,"Consolas",monospace;color:var(--ink)}
      .money.ok{color:var(--green)}
      .money.zero{color:#b3bccb}
      .foot{margin-top:28px;font-size:12px;color:var(--mut);
        border-top:1px solid var(--line);padding-top:14px;
        line-height:1.9}
      .foot b{color:#8a94a6}
      @media(max-width:720px){.ledgers{grid-template-columns:1fr}}
    """
    js = """
    <script>
      (function(){
        var cards = Array.prototype.slice.call(
          document.querySelectorAll('.card'));
        var pill = document.getElementById('pill');
        var fill = document.getElementById('fill');
        var total = cards.length, idx = -1, timer = null;
        function setLive(i){
          cards.forEach(function(c,j){ c.classList.toggle('live', j<=i); });
          idx = i;
          if(pill) pill.textContent = (i+1) + ' / ' + total;
          if(fill) fill.style.width = (((i+1)/total)*100) + '%';
          var dot=document.getElementById('dot');
          if(dot){dot.classList.add('live');}
        }
        function play(){
          stop();
          setLive(0);
          var k=0;
          timer=setInterval(function(){
            k++;
            if(k>=total){ k=total-1; stop(); }
            setLive(k);
          },1300);
        }
        function reset(){ stop(); setLive(0); }
        function stop(){ if(timer){clearInterval(timer);timer=null;} }
        window.playTrajectory=play;
        window.resetTrajectory=reset;
        reset();
      })();
    </script>
    """
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>L5 结算托管双账本 · 可视化演示(off-chain)</title>
<style>{css}</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <div>
      <h1>L5 结算托管双账本</h1>
      <div class="sub">协议 <b>Agreement</b> + 资金 <b>Escrow</b> 双账本逐节点合拍 - 可视化演示(off-chain)</div>
    </div>
    <span class="status-pill" id="pillholder">进度 <span id="pill">1 / {n}</span></span>
  </div>
  <p style="color:var(--mut)">一条完整成功结算轨迹:{n} 个可观测节点,从上到下逐条点亮。双账本工作流由已验收的 <code>l5_escrow_link.py</code> 驱动。</p>
  <div class="toolbar">
    <button onclick="playTrajectory()">播放</button>
    <button onclick="resetTrajectory()">重置</button>
  </div>
  <div class="progress"><div class="progress-track"><div class="progress-fill" id="fill"></div></div></div>
  {cards}
  <div class="foot">
    诚实标注:<br>
    1<b>EXECUTE 为 off-chain 真劳务,不可链上化</b> —— 编排器/联动层只记录"已开始执行/已完成",不伪造链上工作量。<br>
    2 本演示为<b>模拟链(内存双账本)</b>;<b>真连链</b>时把 <code>EscrowSide</code> 的内存实现替换为对
    <b>AgentEscrow.sol / AgentAgreementV3.sol</b> 的实际 provider 调用即可,轨迹与校验不变。<br>
    3 SETTLE 阶段 <code>escrow.release</code> 释放资金给 Provider 的同时会<b>驱动</b> agreement 的
    <code>markSettled</code>(Completed -&gt; Settled),这是 escrow 合约内部握手语义在模拟链上的落地。
  </div>
</div>
{js}
</body>
</html>"""


# ---------------------------------------------------------------------------
# 3) 主流程
# ---------------------------------------------------------------------------
def main() -> None:
    trajectory = run_success_trajectory()
    html = render_html(trajectory)
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "l5_demo_theater.html")
    os.makedirs(here, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"轨迹步骤数: {len(trajectory)}")
    for t in trajectory:
        g = "达成" if t["gate"] else "门禁"
        print(f"  [{t['step']:02d}] {t['node']:9s} escrow={t['escrow_state']:<10s}"
              f" agree={t['agreement_state']:<10s} 锁={t['escrow_locked']:<4d}"
              f" 付={t['escrow_paid']:<4d} 退={t['escrow_refunded']:<4d} [{g}]")
    print(f"HTML 落盘路径: {out}")
    print(f"HTML 字节数 : {os.path.getsize(out)} (UTF-8)")


if __name__ == "__main__":
    main()
