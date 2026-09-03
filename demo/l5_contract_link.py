# -*- coding: utf-8 -*-
"""
l5_contract_link.py
===================

目的（Purpose）
---------------
本文件是源·ORIGIN「L5 智能体结算层」给已在跑的 off-chain 结算编排器
(settlement_orchestrator.py) 补的"链上联动层"。它把编排器的 GraphNode 状态机推进，
与链上 AgentAgreementV3.sol 的真实 AgreementState 状态机逐节点对齐：
编排器每过一关键节点 → 调用 ChainBridge 的对应方法 → 记录 / 返回链侧 agreement 状态。

**重要边界（务必读）**
    - 本文件是「链桥抽象 (ChainBridge) + 模拟内存链 (SimulatedChain)」，
      **不真发交易**、不连接 RPC、不使用 web3 / privy / 钱包。
      Real 上链时把 `SimulatedChain` 换成真实 provider 封装（示例见文件末 docstring）。
    - 诚实边界：FUND 的资金托管其实在 AgentEscrow.sol；EXECUTE 的真正劳务交付是
      off-chain 行动。所以"GraphNode → 链上调用"并不是每个节点都打本合约，有一批
      节点标注落点在别处（见 LINK_TABLE + 收尾 md `l5_contract_link.md`）。

对齐纪律（链上权威语义，已从 AgentAgreementV3.sol 函数体核实，不再猜状态机）
---------------------------------------------------------------------------
    enum AgreementState:
        Draft → Proposed → Signed → Executed → Completed → Settled
        / Cancelled / Disputed / Slashed
    enum GraphNode (合约侧 camelCase): Submit/Validate/Fund/Execute/Verify/
        Settle/Arbitrate/Slash
    链上自动 checkpoint：
        - propose()      Draft→Proposed 时 _autoCheckpoint(Validate)
        - markSettled()  Completed→Settled 时 _autoCheckpoint(Settle)
    入口/改动函数 onlyParty+onlyState(...)：
        createAgreement(...) → Draft 起点
        propose()            onlyState(Draft)          → Proposed (auto cp Validate)
        signAgreement()      onlyState(Proposed)       → Signed (需 EIP-712 钱包签名)
        completeTerm/Terms() onlyState(Executed)       → Executed 内逐 term 完成
        bindEscrow()         external，绑托管(仅参与方/escrow 自身)
        markSettled()        only escrow + onlyState(Completed) → Settled (auto cp Settle)
        cancelAgreement()    onlyState(Draft/Proposed) → Cancelled
        disputeAgreement()   → Disputed
    于本合约**无**的链路点：FUND(在 AgentEscrow)、真正的 EXECUTE(off-chain)、
    ARBITRATE / SLASH(裁决在 AgentEscrow / Court)。

文件：offchain\\l5_contract_link.py（UTF-8 无 BOM，注释中文，纯标准库）。
"""

from __future__ import annotations

import sys
from abc import ABC, abstractmethod
from enum import Enum
from typing import Dict, List, Optional, Tuple


def _ensure_utf8_console() -> None:
    """把 stdio 切到 UTF-8(errors=replace)，避免 GBK 控制台遇 ✅/❌ 抛异常。"""
    for stream_name in ("stdout", "stderr"):
        try:
            stream = getattr(sys, stream_name)
            if stream is not None and hasattr(stream, "reconfigure"):
                stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


_ensure_utf8_console()


# ---------------------------------------------------------------------------
# A. 两侧状态机枚举：编排器 node（side-A） 与 链上 AgreementState（side-B）
# ---------------------------------------------------------------------------
class OrchestratorNode(Enum):
    """镜像 settlement_orchestrator 编排器这边的推进节点。

    名称与 settlement_orchestrator.GraphNode 对应关键节点保持一致（全大写），
    便于坐标直接互相映射。含编表层专用 EXIT/RETRY 标签用于联络层说明语义。
    """

    SUBMIT = 1
    VALIDATE = 2
    FUND = 3
    EXECUTE = 4
    VERIFY = 5
    SETTLE = 6
    ARBITRATE = 7
    SLASH = 8
    # 编表层:重试回炉（不直接打链）
    RETRY = 90
    # 编表层终态收口（落链语义各异，见 LINK_TABLE）
    REJECT = 101
    REFUND = 102
    DONE = 103
    # ---- 中间带：不在编排器原始 GraphNode，但联络链上是必经态 ----
    SIGN = 200   # signAgreement 中间带
    CANCEL = 201  # cancelAgreement 中间带（Draft/Proposed→Cancelled）


class OnChainState(Enum):
    """镜像 AgentAgreementV3.sol 的 enum AgreementState。

    顺序/raw value 与链上契约定义一致（Draft=0..Settled=5；Cancelled/Disputed/
    Slashed 给负数以把"线性推进之外"的旁支态区分出来，便于断言比较先后）。
    """

    Draft = 0
    Proposed = 1
    Signed = 2
    Executed = 3
    Completed = 4
    Settled = 5
    Cancelled = -1
    Disputed = -2
    Slashed = -3


# ---------------------------------------------------------------------------
# B. 权威映射表  LINK_TABLE
#    含义：编排器当前关键 node → (链上函数|None, 落点标签, 若成功上链应到达的
#    AgreementState)。落点标签取值：
#        "this-contract"   —— 直接调 AgentAgreementV3.sol
#        "AgentEscrow"     —— 落点在托管合约（本合约只迁态/不真移资金）
#        "escrow-calls"    —— 由 escrow 合约作为 caller 触发的迁态
#        "off-chain(劳务)" / "off-chain(回炉)" —— 不落链，仅编排器记账
#        "AgentEscrow/Court" —— 裁决，见 AgentEscrow/Court
#    改这里 = 改权威"编排器↔合约"联络语义。件二 md 的总表与本表同构。
# ---------------------------------------------------------------------------
LINK_TABLE: List[Tuple[OrchestratorNode, Optional[str], str, Optional[OnChainState]]] = [
    # (node,                 链上函数,            落点,                      成功后合拍 AgreementState)
    (OrchestratorNode.SUBMIT,   "createAgreement", "this-contract",           OnChainState.Draft),
    (OrchestratorNode.VALIDATE, "propose",         "this-contract",           OnChainState.Proposed),       # auto cp Validate
    (OrchestratorNode.SIGN,     "signAgreement",   "this-contract",           OnChainState.Signed),         # EIP-712 钱包签名
    (OrchestratorNode.FUND,     None,              "AgentEscrow",             OnChainState.Signed),         # 真资金在 escrow
    (OrchestratorNode.EXECUTE,  None,              "off-chain(劳务)",         OnChainState.Signed),         # 真劳务不在链上
    (OrchestratorNode.VERIFY,   "completeTerm(s)", "this-contract",           OnChainState.Executed),       # 逐 term 完成
    (OrchestratorNode.SETTLE,   "bindEscrow",      "this-contract",           OnChainState.Completed),      # 绑托管(放款前置)
    (OrchestratorNode.SETTLE,   "markSettled",     "escrow-calls",            OnChainState.Settled),        # escrow caller; auto cp Settle
    (OrchestratorNode.ARBITRATE,None,              "AgentEscrow/Court",       OnChainState.Disputed),
    (OrchestratorNode.SLASH,    None,              "AgentEscrow/Court",       OnChainState.Slashed),
    (OrchestratorNode.CANCEL,   "cancelAgreement", "this-contract",           OnChainState.Cancelled),      # Draft/Proposed→Cancelled
    (OrchestratorNode.RETRY,    None,              "off-chain(回炉)",         None),
    (OrchestratorNode.REJECT,   "cancelAgreement", "this-contract",           OnChainState.Cancelled),      # 编排器驳回≈取消
    (OrchestratorNode.REFUND,   None,              "AgentEscrow",             OnChainState.Cancelled),      # 退款走 escrow 退回
    (OrchestratorNode.DONE,     None,              "this-contract(收口)",     OnChainState.Settled),        # 编排器收口:应已 Settled
]

# 便捷索引：node → (主链上函数|None, 落点, 成功后合拍 state|None)。


def _build_index() -> Dict[OrchestratorNode, Tuple[Optional[str], str, Optional[OnChainState]]]:
    idx: Dict[OrchestratorNode, Tuple[Optional[str], str, Optional[OnChainState]]] = {}
    for n, fn, loc, st in LINK_TABLE:
        idx.setdefault(n, (fn, loc, st))  # 首条为准（SETTLE 首条是 bindEscrow→Completed）
    return idx


_LINK_INDEX = _build_index()


def link_for(node: OrchestratorNode) -> Tuple[Optional[str], str, Optional[OnChainState]]:
    """返回编排器 node 的主链路 (链上函数|None, 落点, 成功后合拍 AgreementState|None)。"""
    if node not in _LINK_INDEX:
        raise KeyError(f"no link registered for node {node.name}")
    return _LINK_INDEX[node]


# ---------------------------------------------------------------------------
# C. ChainBridge：编排器访问链上 AgentAgreementV3/AgentEscrow 的抽象接缝
# ---------------------------------------------------------------------------
class ChainBridge(ABC):
    """结算编排器访问链上状态机的抽象接缝。各法返回链侧 AgreementState 或抛异常。

    真连链时按此接口提供实现（web3 / privy / JSON-RPC），
    SimulatedChain 是当内存假链的参考实现。编排器只依赖本抽象。
    """

    @abstractmethod
    def create_agreement(self, task_id: str, provider: str, consumer: str,
                         input_hash: str, expected_output: str,
                         amount: int, stake: int) -> OnChainState: ...      # Draft

    @abstractmethod
    def propose(self, agreement_id: str) -> OnChainState: ...               # Draft→Proposed (auto cp Validate)

    @abstractmethod
    def sign(self, agreement_id: str) -> OnChainState: ...                  # Proposed→Signed (EIP-712)

    @abstractmethod
    def complete_terms(self, agreement_id: str, term_ids: List[str]) -> OnChainState: ...

    @abstractmethod
    def bind_escrow(self, agreement_id: str, escrow_addr: str) -> OnChainState: ...

    @abstractmethod
    def mark_settled(self, agreement_id: str) -> OnChainState: ...          # escrow caller; Completed→Settled

    @abstractmethod
    def cancel(self, agreement_id: str) -> OnChainState: ...                # Draft/Proposed→Cancelled

    @abstractmethod
    def dispute(self, agreement_id: str, reason: str) -> OnChainState: ...  # →Disputed

    # reads
    @abstractmethod
    def state_of(self, agreement_id: str) -> OnChainState: ...

    @abstractmethod
    def checkpoints(self, agreement_id: str) -> List[str]: ...


class SimulatedChain(ChainBridge):
    """当内存假链的 ChainBridge 参考实现——不真发交易，仅供联动演示/单测。

    复刻链上 onlyState(...) 门禁与 _autoCheckpoint：非法状态转换抛 OnChainStateError
    等语义错误；propose/mark_settled 完成时自动记 Validate/Settle checkpoint。
    """

    # 例：propose 后同合约自动落 cp 的名称 → 见函数内注释

    def __init__(self) -> None:
        self._agreements: Dict[str, OnChainState] = {}
        self._cps: Dict[str, List[str]] = {}
        self._badge = 0

    # ---- helpers ----------------------------------------------------------
    def _create(self, task_id: str) -> str:
        self._badge += 1
        aid = f"agr-{self._badge:#05x}::{task_id}"
        if aid in self._agreements:
            raise OnChainStateError(f"create: agreement exists {aid}")
        self._agreements[aid] = OnChainState.Draft
        self._cps[aid] = []
        return aid

    def _require(self, aid: str, expect: OnChainState, op: str) -> OnChainState:
        cur = self._agreements.get(aid)
        if cur is None:
            raise OnChainStateError(f"{op}: no agreement {aid!r}")
        if cur != expect:
            raise OnChainStateError(
                f"{op}: {op} 违约态——链上当前 AgreementState={cur.name}, "
                f"期望 {expect.name} (复刻 Solidity onlyState require)"
            )
        return cur

    def _cp(self, aid: str, node_cp: str) -> None:
        self._cps.setdefault(aid, []).append(node_cp)

    # ---- AgentAgreementV3 主迁态 ----------------------------------------
    def create_agreement(self, task_id: str, provider: str, consumer: str,
                         input_hash, expected_output, amount, stake) -> OnChainState:
        aid = self._create(task_id)
        self._cps[aid] = []
        return OnChainState.Draft

    def propose(self, agreement_id: str) -> OnChainState:
        self._require(agreement_id, OnChainState.Draft, "propose")
        self._agreements[agreement_id] = OnChainState.Proposed
        self._cp(agreement_id, "Validate")   # _autoCheckpoint(Validate)
        return OnChainState.Proposed

    def sign(self, agreement_id: str) -> OnChainState:
        self._require(agreement_id, OnChainState.Proposed, "sign")
        self._agreements[agreement_id] = OnChainState.Signed
        return OnChainState.Signed

    def complete_terms(self, agreement_id: str, term_ids: List[str]) -> OnChainState:
        # 逐 term 完成；合约只在 Executed 态内变动，不自行跃迁到 Completed
        # (Completed 由 escrow 放款前置 / 工作收口的其它迁移驱动，取决实现约定)
        self._require(agreement_id, OnChainState.Executed, "complete_terms")
        return OnChainState.Executed

    def bind_escrow(self, agreement_id: str, escrow_addr: str) -> OnChainState:
        cur = self._agreements.get(agreement_id)
        if cur is None:
            raise OnChainStateError(f"bindEscrow: no agreement {agreement_id!r}")
        if cur not in (OnChainState.Signed, OnChainState.Executed,
                       OnChainState.Completed):
            raise OnChainStateError(
                f"bindEscrow: {cur.name} 非法——契约只在 [Signed,Executed,Completed] 区间绑托管"
            )
        return cur   # 回到当前态（未跃迁）

    # ---- work→Completed(示意)：escrow 放款收口后把状态推到 Completed ---------
    # 注：真正合约里 Executed→Completed 的迁移由 escrow/工作侧累计 term 完成触发，
    #     这里补一个显式过渡表语义的辅助，让 markSettled 前链侧能处于 Completed。
    def complete_execution(self, agreement_id: str) -> OnChainState:
        """(模拟 escrow 侧) 全部 term 完成 + 放款前置就绪 → Executed→Completed。"""
        self._require(agreement_id, OnChainState.Executed, "complete_execution")
        self._agreements[agreement_id] = OnChainState.Completed
        return OnChainState.Completed

    def mark_settled(self, agreement_id: str) -> OnChainState:
        self._require(agreement_id, OnChainState.Completed, "mark_settled")
        self._agreements[agreement_id] = OnChainState.Settled
        self._cp(agreement_id, "Settle")    # _autoCheckpoint(Settle)
        return OnChainState.Settled

    def cancel(self, agreement_id: str) -> OnChainState:
        cur = self._agreements.get(agreement_id)
        if cur is None:
            raise OnChainStateError(f"cancel: no agreement {agreement_id!r}")
        if cur not in (OnChainState.Draft, OnChainState.Proposed):
            raise OnChainStateError(
                f"cancel: onlyState(Draft|Proposed), 当前 {cur.name} 不可取消"
            )
        self._agreements[agreement_id] = OnChainState.Cancelled
        return OnChainState.Cancelled

    def dispute(self, agreement_id: str, reason: str = "") -> OnChainState:
        cur = self._agreements.get(agreement_id)
        if cur is None:
            raise OnChainStateError(f"dispute: no agreement {agreement_id!r}")
        self._agreements[agreement_id] = OnChainState.Disputed
        return OnChainState.Disputed

    # ---- reads -----------------------------------------------------------
    def state_of(self, agreement_id: str) -> OnChainState:
        st = self._agreements.get(agreement_id)
        if st is None:
            raise OnChainStateError(f"state_of: no agreement {agreement_id!r}")
        return st

    def checkpoints(self, agreement_id: str) -> List[str]:
        return list(self._cps.get(agreement_id, []))


class OnChainStateError(Exception):
    """复刻 Solidity require(...)/onlyState 语义的 revert 错误。"""

    pass


def _demo_call(bridge: SimulatedChain, aid: str, step: Tuple[str, str]) -> None:
    """一段手动驱动编排器→链迁移的小工具（仅 __main__ 打印清晰）。"""
    op, note = step
    print(f"    编排器过 {op:<10s} → 链上调用, 结果: {note}")


# ---------------------------------------------------------------------------
# D. 对齐检查 assert_state_consistent
#    拿到编排器当前 node 与该链 agreement state，验证两者合拍；不合拍给
#    "谁先/谁后错"的可读提示，防编排器在链上违约状态下误 call。
# ---------------------------------------------------------------------------
def assert_state_consistent(node: OrchestratorNode,
                            onchain_state: OnChainState) -> Tuple[bool, str]:
    """校验编排器 node 与链上 agreement state 是否合拍。

    只对"会改本合约主 AgreementState 的节点"(落点 this-contract / escrow-calls)
    做严格比对：编排器说当前动 node N，则链上应处于 LINK_TABLE 标注的"成功后合拍
    state"。对落点在 AgentEscrow / off-chain / Court / 硬收口则不强求某一 AgreementState。
    返回 (ok, 说明)。ok=False 时说明哪个环节先/后错。
    """
    fn, loc, expect = link_for(node)
    strict = loc in ("this-contract", "escrow-calls")
    if not strict or expect is None:
        # 跨合约/off-chain/收口节点：本合约不承担主迁态对等，视为合拍
        return True, (f"{node.name}: 落点 {loc}, 链上 {onchain_state.name} - "
                      "不改变本合约主 AgreementState, 合拍(无需逐一对等)")
    if onchain_state == expect:
        why = "auto cp Validate" if node == OrchestratorNode.VALIDATE else (
              "auto cp Settle" if expect == OnChainState.Settled else "state after call")
        return True, (f"{node.name}: 链上 {onchain_state.name} = 期望 {expect.name} 合拍 "
                      f"[{why}]")
    # 不符合 → 判定谁先谁后错
    if 0 <= onchain_state.value < expect.value:
        pos = (f"链上落后：编排器想动 {expect.name}，链上还在 {onchain_state.name}——"
               f"应先把链推上 {expect.name} 再放编排器")
    else:
        pos = (f"链上超前/偏离：链上已 {onchain_state.name}，编排器仍想动 "
               f"{expect.name}——编排器应回退/等链，先对账再 call")
    return False, f"{node.name}: 不一致，期望链上 {expect.name} 实际 {onchain_state.name}。{pos}"


# ---------------------------------------------------------------------------
# __main__ 演示：
#   段1 一段编排器推进打印『编排器 node → 链上调用 → 模拟链 AgreementState』;
#   段2 违约态误调被 assert 拦下 + 链上门禁双保险。
# ---------------------------------------------------------------------------
def _demo() -> None:
    print("=" * 74)
    print("L5 结算编排器 <-> AgentAgreementV3.sol  链上联动演示 (l5_contract_link.py)")
    print("=" * 74)

    bridge = SimulatedChain()
    # ---- 段 1：正常成功 settle 链 ----
    print("\n[段1] 正常成功 settle 链：每个关键 node → 链上函数 → Simulated 链 AgreementState")
    cur = bridge.create_agreement("t-ok-1", "agent-alpha", "agent-beta",
                                  "ih", "0xDEADBEEF", 1_000_000, 250_000)
    try:
        aid = next(k for k, v in bridge._agreements.items() if k.endswith("::t-ok-1"))
    except StopIteration:
        # 兼容：若 create 用了不同 id 化，取唯一写入的那份
        aid = next(iter(bridge._agreements))
    print(f"    初始 AgreementState = {bridge.state_of(aid).name}   (Draft 起点)")

    def banner(node: OrchestratorNode) -> None:
        fn, loc, expect = link_for(node)
        fn_txt = fn if fn else f"(落点 {loc}, 不落本合约)"
        exp_txt = expect.name if expect else "—"
        print(f"    编排器 node {node.name:<9s} | 应调 {fn_txt:<18s} | 成功后合拍 {exp_txt:<9s}")

    banner(OrchestratorNode.SUBMIT)
    banner(OrchestratorNode.VALIDATE)
    cur = bridge.propose(aid)                       # have to actually advance after banner
    print(f"      execute propose            -> {bridge.state_of(aid).name}  (auto cp Validate, cps={bridge.checkpoints(aid)})")
    ok, msg = assert_state_consistent(OrchestratorNode.VALIDATE, bridge.state_of(aid))
    print(f"      ✅/❌  align(VALIDATE)      -> ok={ok} | {msg}" if ok else f"      ❌ align(VALIDATE) -> {msg}")

    # SIGN
    banner(OrchestratorNode.SIGN)
    bridge.sign(aid)
    print(f"      execute signAgreement      -> {bridge.state_of(aid).name}  (真实需 EIP-712 钱包签名)")

    # FUND / EXECUTE 均不落本合约，标记移出
    banner(OrchestratorNode.FUND)      # 落点 AgentEscrow
    banner(OrchestratorNode.EXECUTE)   # 落点 off-chain 劳务
    ok, msg = assert_state_consistent(OrchestratorNode.EXECUTE, bridge.state_of(aid))
    print(f"      align(EXECUTE)            -> ok={ok} | {msg}")
    print(f"      (FUND/EXECUTE 期间链上持 {bridge.state_of(aid).name}，均在 escrow/线下推进)")

    # escrow 放款触发 Executed - 这里模拟完整执行后 term 完成 -> Executed
    # 真实流程：VERIFY=complete_terms 需链已经 Executed。为演示我们先把链推到
    # Executed(模拟 escrow 已把部分 term 完成到可 complete 的 Executed)。
    bridge._agreements[aid] = OnChainState.Executed   # 模拟 escrow 已把状态铺到 Executed
    print(f"      (escrow 工作交付)         -> 链上 = {bridge.state_of(aid).name}")
    banner(OrchestratorNode.VERIFY)
    bridge.complete_terms(aid, ["term-1", "term-2"])
    ok, msg = assert_state_consistent(OrchestratorNode.VERIFY, bridge.state_of(aid))
    print(f"      align(VERIFY)              -> ok={ok} | {msg}")

    # escrow 全部 term 完成 → Completed
    bridge.complete_execution(aid)
    print(f"      (escrow complete_execution)-> 链上 = {bridge.state_of(aid).name}")
    banner(OrchestratorNode.SETTLE)     # ① bindEscrow 在 Completed 区间
    ok, msg = assert_state_consistent(OrchestratorNode.SETTLE, bridge.state_of(aid))
    print(f"      align(SETTLE pre-mark)     -> ok={ok} <{msg}>")
    bridge.bind_escrow(aid, "escrow-0xAAA")
    cur = bridge.mark_settled(aid)      # escrow caller
    print(f"      execute markSettled        -> {bridge.state_of(aid).name}  (auto cp Settle, cps={bridge.checkpoints(aid)})")

    # 段 2 违约态拦截：新建一份停留在 Signed 的 agreement,编排器误以为可打 markSettled
    print("\n[段2] 违约态误调拦截演示（编排器以为已 Completed，链上却仍是 Signed）")
    bridge.create_agreement("t-bad-1", "agent-a", "agent-b", "ih", "exp", 1_000_000, 250_000)
    aid2 = next(k for k in bridge._agreements if k.endswith("::t-bad-1"))
    bridge.propose(aid2)
    bridge.sign(aid2)                     # 现在 Signed, 未推进到 Executed/Completed
    vs = OnChainState.Signed
    print(f"    链上当前 AgreementState = {bridge.state_of(aid2).name} "
          f"(编排器却误以为已走完 VERIFY, 链侧应为 Completed)")
    ok, msg = assert_state_consistent(OrchestratorNode.SETTLE, bridge.state_of(aid2))
    print(f"    assert_state_consistent(SETTLE,{bridge.state_of(aid2).name}) -> ok={ok}")
    print(f"     提示: {msg}")
    print("    —— 于是编排器不会对链上违约态误调 markSettled ——")

    print("\n演示说明：本文件为链桥抽象 + 模拟链，不真发交易；"
          "真连链时把 SimulatedChain 换成 web3/privy provider（见文件末示例）。")


# ---------------------------------------------------------------------------
# 真连链的替换方向（写入门内注释, 不实际执行）
# ---------------------------------------------------------------------------
"""
真连链时示例（web3 / privy / JSON-RPC），把 SimulatedChain 换成它：

    class Web3AgentBridge(ChainBridge):
        def __init__(self, provider_url, contract_addr, escrow_addr, signer): ...

        def propose(self, agreement_id):
            # w3.eth.contract(address=addr,
            #                abi=<AgentAgreementV3 ABI>).functions\\
            #        .propose(agreement_id).transact({"from": signer})
            # return self.state_of(agreement_id)
        # - sign 注意：EIP-712.signature 由参与方离线/钱包生成后以 bytes 传入
        #   signAgreement(agreementId, signature)，不是私钥裸传给合约。
        # - mark_settled 的 caller 必须是 escrow 合约地址（onlyEscrow），
        #   编排器/参与方不能直接调，需授权 escrow 放款后由 escrow 侧调用。

    真正接线：把 SettlementGraph.NODE_RUNNERS 对应 node 换成对 bridge 的调用 + 过
    assert_state_consistent 校验（见收尾 l5_contract_link.md 的接线示意）。
这样编排器状态机与链上状态机由 LINK_TABLE + assert_state_consistent 协同保证合拍。
"""


if __name__ == "__main__":
    _demo()
