# -*- coding: utf-8 -*-
"""
l5_escrow_link.py — L5 托管(escrow)联动层 (C 路线 · 双账本真闭环)

目的
----
把 AgentEscrow 的资金托管三态并进 off-chain 结算管线,让
「Agreement 协议状态」 + 「Escrow 资金状态」 双账本逐节点合拍,
钱真的走托管三态。本文件是「模拟链 + 双账本联动」演示/落地层,
不真发链上交易;真连链时把本文件的内存实现替换为对
AgentEscrow.sol / AgentAgreementV3.sol 的实际 provider 调用即可。

EscrowState ↔ AgentEscrow.sol 枚举对应
-------------------------------------
    Empty     ↔ EscrowState.Empty     未初始化/未托管
    Funded    ↔ EscrowState.Funded    资金已锁定(createAndFund)
    Verified  ↔ EscrowState.Verified  工作已验(verifyDelivery),资金未动
    Released  ↔ EscrowState.Released  资金已释放给 Provider(release/settle)
    Cancelled ↔ EscrowState.Cancelled 已取消/退回 Consumer(refund)
    Disputed  ↔ EscrowState.Disputed  争议中(dispute),等 resolveDispute

双账本 invariant(一句话)
-----------------------
「资金在 escrow 里被锁定或被释放,必须与 agreement 的状态同步成立:
FUND→escrow.Funded且资金锁;VERIFY→escrow.Verified且agreement向Completed推进;
SETTLE→escrow.Released(钱已付Provider)且agreement.Settled 同到终态;
REFUND→钱回Consumer且Provider无所得;DISPUTE/ARBITRATE→escrow.Disputed→resolve。」

诚实标注
--------
* EXECUTE 是真实劳务,off-chain 不可链上化 —— 编排器/联动层只记录"已完成"。
* SETTLE 时 escrow 释放资金(escrow.release)会**驱动** agreement.markSettled 握手
  (真实架构里 escrow 合约内部调用 agentAgreement.markSettled)。
* 附件域:state channel(openChannel/topUpChannel/settleChannel/finalizeSettlement)
  与 crossChainSettle 不在本 C 范围,后续可扩。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Dict, List, Optional


# ---------------------------------------------------------------------------
# 枚举
# ---------------------------------------------------------------------------
class EscrowState(Enum):
    """镜像 AgentEscrow.sol 的 EscrowState。"""
    EMPTY = auto()      # Empty   未托管
    FUNDED = auto()     # Funded  已锁定资金
    VERIFIED = auto()   # Verified 工作已验,资金未动
    RELEASED = auto()   # Released 已释放给 Provider(SETTLE)
    CANCELLED = auto()  # Cancelled 退回 Consumer(REFUND)
    DISPUTED = auto()   # Disputed 争议中


class AgreementStateCMA(Enum):
    """镜像 AgentAgreementV3.sol 的 AgreementState(供 cross_check 对照)。"""
    DRAFT = auto()
    PROPOSED = auto()
    SIGNED = auto()
    EXECUTED = auto()
    COMPLETED = auto()
    SETTLED = auto()
    CANCELLED = auto()
    DISPUTED = auto()
    SLASHED = auto()


# oracle(namedtuple-like) -> 用 enum 值即够,不放外部依赖


# ---------------------------------------------------------------------------
# 托管账本条目
# ---------------------------------------------------------------------------
@dataclass
class EscrowEntry:
    escrow_id: str
    agreement_id: str
    payer: str                 # Consumer(注资方)
    payee: str                 # Provider(收款方)
    amount: int
    state: EscrowState = EscrowState.EMPTY
    funds_locked: int = 0
    funds_paid_out: int = 0
    funds_refunded: int = 0
    deadline: int = 0
    dispute_bond: int = 0      # 争议押金占位
    log: List[str] = field(default_factory=list)

    def note(self, msg: str) -> None:
        self.log.append(msg)


# ---------------------------------------------------------------------------
# Escrow 联动侧(内存模拟 escrow 账本 + 驱动 agreement 握手)
# ---------------------------------------------------------------------------
class EscrowSide:
    """
    双账本联动:每个 agreement 一张 escrow。
    方法镜像 AgentEscrow.sol 语义,并在 SETTLE/release 时驱动
    agreement 侧 markSettled(Completed→Settled)握手。
    """

    def __init__(self) -> None:
        self._entries: Dict[str, EscrowEntry] = {}
        # agreementId -> escrowId(mirror bindEscrow 单绑)
        self._agreement_escrow: Dict[str, str] = {}
        self._agreement_state: Dict[str, AgreementStateCMA] = {}

    # ---- 外部可注入当前 agreement 状态(模拟链上报) ----
    def set_agreement_state(self, agreement_id: str, st: AgreementStateCMA) -> None:
        self._agreement_state[agreement_id] = st

    def agreement_state(self, agreement_id: str) -> Optional[AgreementStateCMA]:
        return self._agreement_state.get(agreement_id)

    # ---- 托管方法 ----
    def create_and_fund(
        self,
        agreement_id: str,
        payer: str,
        payee: str,
        amount: int,
        deadline: int,
    ) -> str:
        """EscrowState.EMPTY -> FUNDED,资金锁定(bind 该 escrow 到 agreement)。"""
        if agreement_id in self._agreement_escrow:
            raise RuntimeError("escrow 已绑定该 agreement(只能 bind 一次)")
        ag_st = self.agreement_state(agreement_id)
        # 真实语义:须已签署的钱才托管(注释约定,不强校验只标注)
        escrow_id = f"esc:{agreement_id[-8:]}"
        entry = EscrowEntry(
            escrow_id=escrow_id,
            agreement_id=agreement_id,
            payer=payer,
            payee=payee,
            amount=amount,
            state=EscrowState.FUNDED,
            funds_locked=amount,
            deadline=deadline,
        )
        entry.note(f"create_and_fund: locked {amount} (agreement_state={ag_st})")
        self._entries[escrow_id] = entry
        self._agreement_escrow[agreement_id] = escrow_id
        return escrow_id

    def verify_delivery(self, escrow_id: str, caller: str) -> None:
        """FUNDED -> VERIFIED(工作已验,资金不移动)。仅 payee 可调(镜像)。"""
        e = self._entries.get(escrow_id)
        if e is None:
            raise RuntimeError("escrow not found")
        if e.state is not EscrowState.FUNDED:
            raise RuntimeError("verify_delivery: escrow 须 Funded")
        if caller != e.payee:
            raise RuntimeError("verify_delivery: 仅 payee 可验")
        # 语义:验证通过需 agreement 工作已完成(向 Completed)
        ag_st = self.agreement_state(e.agreement_id)
        e.state = EscrowState.VERIFIED
        e.note(f"verify_delivery: Verified (agreement_state={ag_st})")

    def release(self, escrow_id: str, caller: str) -> None:
        """
        VERIFIED -> RELEASED,资金付给 Provider(escrow.release 语义),
        并驱动 agreement markSettled(Completed->Settled)握手。
        """
        e = self._entries.get(escrow_id)
        if e is None:
            raise RuntimeError("escrow not found")
        if e.state is not EscrowState.VERIFIED:
            raise RuntimeError("release: escrow 须 Verified(先 verify_delivery)")
        if caller != e.payer:
            raise RuntimeError("release: 仅 payer(注资方)可释放")
        ag_st = self.agreement_state(e.agreement_id)
        # 双账本握手:资金释放时 agreement 必须已完成工作(Completed)才能 Settle
        if ag_st is not AgreementStateCMA.COMPLETED:
            raise RuntimeError(
                "release: agreement 须先 Completed 才能 Settle,"
                f"当前={ag_st}(应先 completeTerms 推 Completed)"
            )
        e.state = EscrowState.RELEASED
        e.funds_paid_out = e.amount
        e.funds_locked = 0
        e.note(f"release: paid out {e.amount} to Provider; agreement -> SETTLED")
        # 驱动 agreement markSettled
        self._agreement_state[e.agreement_id] = AgreementStateCMA.SETTLED

    def settle(self, escrow_id: str, caller: str) -> None:
        """settle 语义 = release 别名(Verified->Released)。"""
        self.release(escrow_id, caller)

    def refund(self, escrow_id: str) -> None:
        """退回 Consumer:escrow -> CANCELLED,钱退回,Provider 无所得。"""
        e = self._entries.get(escrow_id)
        if e is None:
            raise RuntimeError("escrow not found")
        if e.state in (EscrowState.RELEASED, EscrowState.CANCELLED):
            raise RuntimeError("refund: escrow 已终态不可退回")
        e.state = EscrowState.CANCELLED
        e.funds_refunded = e.funds_locked
        e.funds_locked = 0
        e.note(f"refund: {e.amount} -> Consumer,Provider 无所得")
        self._agreement_state[e.agreement_id] = AgreementStateCMA.CANCELLED

    def dispute(self, escrow_id: str, bond: int = 0) -> None:
        """VERIFIED -> DISPUTED(争议,交押金)。"""
        e = self._entries.get(escrow_id)
        if e is None:
            raise RuntimeError("escrow not found")
        if e.state is not EscrowState.VERIFIED:
            raise RuntimeError("dispute: escrow 须 Verified")
        e.state = EscrowState.DISPUTED
        e.dispute_bond = bond
        e.note(f"dispute: bond {bond}")
        self._agreement_state[e.agreement_id] = AgreementStateCMA.DISPUTED

    def resolve_dispute(self, escrow_id: str, payee_wins: bool) -> None:
        """DISPUTED -> 终态:payee_wins 给 Provider(Released/SETTLED),否则退回。"""
        e = self._entries.get(escrow_id)
        if e is None:
            raise RuntimeError("escrow not found")
        if e.state is not EscrowState.DISPUTED:
            raise RuntimeError("resolve_dispute: escrow 须 Disputed")
        if payee_wins:
            e.state = EscrowState.RELEASED
            e.funds_paid_out = e.amount + e.dispute_bond
            e.funds_locked = 0
            e.note(f"resolve(payee_wins): {e.amount}+bond -> Provider")
            self._agreement_state[e.agreement_id] = AgreementStateCMA.SETTLED
        else:
            e.state = EscrowState.CANCELLED
            e.funds_refunded = e.amount
            e.funds_locked = 0
            e.note("resolve(consumer_wins): amount -> Consumer")
            self._agreement_state[e.agreement_id] = AgreementStateCMA.CANCELLED

    def escrow(self, escrow_id: str) -> EscrowEntry:
        return self._entries[escrow_id]

    def escrow_by_agreement(self, agreement_id: str) -> EscrowEntry:
        return self._entries[self._agreement_escrow[agreement_id]]


# ---------------------------------------------------------------------------
# 双账本 invariant `cross_check`
# ---------------------------------------------------------------------------
def cross_check(
    node: str,
    escrow_state: EscrowState,
    agreement_state: AgreementStateCMA,
) -> tuple[bool, str]:
    """
    校验在节点 node 处,escrow 侧 EscrowState 与 agreement 侧 AgreementState
    是否同刻成立(双账本 joint invariant)。返回 (ok, 人类可读说明)。

    规则表(诚实):
    node / escrow 须在              / agreement 须在(或已向此推进)
    ------------------------------------------------------------------
    FUND    escrow.FUNDED(资金锁)    agreement 至少 SIGNED(已签名)
    VERIFY  escrow.VERIFIED(已验)    agreement 已 COMPLETED(工作交)
    SETTLE  escrow.RELEASED(钱付)    agreement 已 SETTLED(握手终态)
    REFUND  escrow.CANCELLED(退回)   agreement CANCELLED(无 Provider 所得)
    DISPUTE escrow.DISPUTED          agreement DISPUTED
    ARB     escrow resolved          agreement SETTLED / CANCELLED(看谁赢)
    """
    if node == "FUND":
        need_e, need_a = EscrowState.FUNDED, "SIGNED+"
        ok = escrow_state is EscrowState.FUNDED and agreement_state in (
            AgreementStateCMA.SIGNED,
            AgreementStateCMA.EXECUTED,
            AgreementStateCMA.COMPLETED,
        )
        why = "" if ok else (
            f"escrow={escrow_state.name} 须 Funded;"
            f"agreement={agreement_state.name} 须至少 Signed"
        )
        return ok, f"FUND: 资金锁入 escrow + agreement 已签名 [{why}]"
    if node == "VERIFY":
        ok = escrow_state is EscrowState.VERIFIED and agreement_state in (
            AgreementStateCMA.COMPLETED,
            AgreementStateCMA.SETTLED,
        )
        why = "" if ok else (
            f"escrow={escrow_state.name} 须 Verified;"
            f"agreement={agreement_state.name} 须 Completed(工作交付)"
        )
        return ok, f"VERIFY: escrow 验证资金未动 + agreement 工作交付 [{why}]"
    if node == "SETTLE":
        ok = (
            escrow_state is EscrowState.RELEASED
            and agreement_state is AgreementStateCMA.SETTLED
        )
        why = "" if ok else (
            f"escrow={escrow_state.name} 须 Released(钱已付 Provider);"
            f"agreement={agreement_state.name} 须 Settled(握手终态)"
        )
        return ok, f"SETTLE: 资金释放给 Provider + agreement 到 Settled [{why}]"
    if node == "REFUND":
        ok = (
            escrow_state is EscrowState.CANCELLED
            and agreement_state is AgreementStateCMA.CANCELLED
        )
        why = "" if ok else (
            f"escrow={escrow_state.name} 须 Cancelled;"
            f"agreement={agreement_state.name} 须 Cancelled(Provider 无所得)"
        )
        return ok, f"REFUND: 钱回 Consumer,Provider 无所得 [{why}]"
    if node == "DISPUTE":
        ok = (
            escrow_state is EscrowState.DISPUTED
            and agreement_state is AgreementStateCMA.DISPUTED
        )
        why = "" if ok else f"escrow={escrow_state.name} 须 Disputed"
        return ok, f"DISPUTE: escrow 进争议 [ {why} ]"
    if node in ("ARBITRATE", "ARB"):
        ok = escrow_state in (EscrowState.RELEASED, EscrowState.CANCELLED) and (
            agreement_state
            in (AgreementStateCMA.SETTLED, AgreementStateCMA.CANCELLED)
        )
        why = "" if ok else f"escrow={escrow_state.name} 须 resolve 后终态"
        return ok, f"ARBITRATE: 仲裁后 escrow 终态(给 Provider 或退回) [ {why} ]"
    return True, f"{node}: 无联合约束(如 EXECUTE 为 off-chain 劳务)"

    # EXECUTE:off-chain 真劳务,无 escrow 资金动作,只记录完成 —— 见 docstring
    # 之所以 return 上方,是为覆盖未料 node 的兜底。


# ---------------------------------------------------------------------------
# 演示
# ---------------------------------------------------------------------------
def run_full_settle_demo() -> None:
    print("=" * 64)
    print("demo(a) 成功路径:一条结算跑完(Agreement + Escrow 双账本)")
    print("=" * 64)
    side = EscrowSide()
    ag_id = "agreement_0xA1"
    payer, payee = "consumer_0xC", "provider_0xP"
    step = 0

    def show(node, ok, text):
        nonlocal step
        step += 1
        flag = "OK " if ok else "!! "
        print(f"  [{step:02d}] {node:8s} {flag}| {text}")

    # SUBMIT -> create agreement(Draft)
    side.set_agreement_state(ag_id, AgreementStateCMA.DRAFT)
    # VALIDATE -> propose(Proposed)
    side.set_agreement_state(ag_id, AgreementStateCMA.PROPOSED)
    # SIGN -> Signed
    side.set_agreement_state(ag_id, AgreementStateCMA.SIGNED)
    # FUND -> escrow.create_and_fund(Funded 资金锁)
    esc_id = side.create_and_fund(ag_id, payer, payee, amount=1000, deadline=3600)
    e = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("FUND", e.state, side.agreement_state(ag_id))
    show("FUND", ok, txt)
    # EXECUTE -> off-chain 劳务;agreement 进 Executed
    side.set_agreement_state(ag_id, AgreementStateCMA.EXECUTED)
    # 工作完成 -> agreement terms 全交付 -> Completed
    side.set_agreement_state(ag_id, AgreementStateCMA.COMPLETED)
    # VERIFY -> escrow.verify_delivery(Funded->Verified)
    side.verify_delivery(esc_id, caller=payee)
    e = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("VERIFY", e.state, side.agreement_state(ag_id))
    show("VERIFY", ok, txt)
    # SETTLE -> escrow.release(Verified->Released 付 Provider)驱动 markSettled->Settled
    side.release(esc_id, caller=payer)
    e = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("SETTLE", e.state, side.agreement_state(ag_id))
    show("SETTLE", ok, txt)

    print(f"\n  终态: escrow={e.state.name}"
          f" 资金锁={e.funds_locked} 已付Provider={e.funds_paid_out}"
          f" 退回={e.funds_refunded}")
    print(f"       agreement={side.agreement_state(ag_id).name}")
    assert e.state is EscrowState.RELEASED
    assert side.agreement_state(ag_id) is AgreementStateCMA.SETTLED
    assert e.funds_paid_out == 1000 and e.funds_locked == 0
    print("\n  [PASS] demo(a) 双账本到终态一致(SETTLED / Released 钱已付 Provider)")


def run_violation_demo() -> None:
    print("\n" + "=" * 64)
    print("demo(b) 违约拦截:还没 VERIFY 就想 SETTLE")
    print("=" * 64)
    side = EscrowSide()
    ag_id = "agreement_0xB2"
    payer, payee = "consumer_0xC", "provider_0xP"
    side.set_agreement_state(ag_id, AgreementStateCMA.SIGNED)
    esc_id = side.create_and_fund(ag_id, payer, payee, amount=500, deadline=3600)
    # 违约点1:escrow 还在 Funded(没 verify),却试 release(SETTLE)
    try:
        side.release(esc_id, caller=payer)
        print("  !! 未拦截:release 竟放行了(不该)")
    except RuntimeError as ex:
        print("  [PASS] 门禁拦截(escrow.release):", ex)
    # 违约点2:cross_check 视角——VERIFY 未做,直接判 SETTLE
    e = side.escrow_by_agreement(ag_id)
    ok, txt = cross_check("VERIFY", e.state, side.agreement_state(ag_id))
    print(f"  cross_check(VERIFY): ok={ok} | {txt}")
    assert ok is False  # escrow 仍 Funded -> 该先 verify_delivery
    ok2, txt2 = cross_check("SETTLE", e.state, side.agreement_state(ag_id))
    print(f"  cross_check(SETTLE): ok={ok2} | {txt2}")
    assert ok2 is False
    print("\n  [PASS] demo(b) 违约态被双保险拦下(门禁抛错 + cross_check 拦)")


if __name__ == "__main__":
    run_full_settle_demo()
    run_violation_demo()
    print("\n== 本文件链桥抽象+模拟链,不真发交易;真连链时把内存实现换成 "
          "AgentEscrow.sol/AgentAgreementV3.sol 的 provider 调用 ==")
