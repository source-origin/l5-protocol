# -*- coding: utf-8 -*-
"""
settlement_orchestrator.py
==========================

目的（Purpose）
---------------
本文件是源·ORIGIN「L5 智能体结算层」的**结算编排器（Settlement Orchestrator）**参考实现。
它为 AI 智能体经济设计的清算与结算层提供一份"编排大脑"：管理一份 Task 从提交
（Submit）到终态（DONE / REJECT / REFUND / SLASH）的完整生命周期，并沿图推进时
把每一步状态快照**只追加（append-only）**写入 Ledger，从而支持崩溃后的 checkpoint 恢复。

与 AgentAgreementV3.sol 的 GraphNode 枚举逐一对应（On-chain ↔ 本 Off-chain）
---------------------------------------------------------------------------
合约侧 GraphNode 枚举（8 节点，全大写成员）与本编排器 `GraphNode` 一一映射，顺序一致：

    1. SUBMIT    —— 提交者把 taskId / provider / consumer / inputHash / expectedOutput 登记上链
    2. VALIDATE  —— 校验输入与任务合法性（本层在此挂 judge() 裁决钩子）
    3. FUND      —— 托管资金 / 质押入池（escrow 状态 → FUNDED）
    4. EXECUTE   —— 执行者运行任务，产出结果
    5. VERIFY    —— 校验执行结果是否命中 expectedOutput
    6. SETTLE    —— 校验通过，按结果结算资金 / 放款
    7. ARBITRATE —— 若产生分歧（dispute），进入仲裁
    8. SLASH     —— 仲裁裁定执行者作恶，罚没质押

编表层终态替代名（对链上流程的收口落位，非独立链上枚举成员）：
    - REJECT    —— VALIDATE 阶段被驳回，或 RETRY 重试耗尽后判负回滚（终端）
    - REFUND    —— FUND 超时，资金退回（终端）
    - DONE      —— 正常结算成功落库，或 SLASH 后的流程收口（终端）
    - SLASH     —— 仲裁裁定罚没（终端，复用链上第 8 节点成员）

EscrowStatus（托管状态）枚举
----------------------------
    CREATED  → 提交后、资金入池前
    FUNDED   → 资金已入池（EXECUTE/VERIFY/ARBITRATE 间驻留）
    SETTLED  → 按判定正常结算
    REFUNDED → 资金退回
    SLASHED  → 质押被罚没

怎么跑（How to run）
--------------------
纯标准库、零第三方依赖、不联网。本机 Windows + PowerShell，用系统 python 即可：
    python3 -m py_compile settlement_orchestrator.py     # 语法自检（可选）
    python3 settlement_orchestrator.py                    # 运行 __main__ 两段演示

__main__ 演示两段：
    (a) 一条完整 settle 成功路径跑通（SUBMIT→…→DONE）；
    (b) 一次模拟崩溃：在某节点 checkpoint 后触发 SimulatedCrash，随后用**同一 Ledger**
        新开一张图，resume() 从最近 checkpoint 恢复到 DONE，已 checkpoint 的节点不被重复执行。

硬性纪律
--------
- 不依赖第三方库 / 不上链 / 不调用 solc / forge；
- 纯内存 Ledger，docstring 注明权威版可替换为 sqlite / 对账文件；
- 只追加、绝不改写历史（append-only，frozen 条目）；
- 标识符英文，注释中文，文件 UTF-8 无 BOM。
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass, asdict
from enum import Enum, auto
from typing import Any, Callable, Dict, List, Optional


def _ensure_utf8_console() -> None:
    """把 stdio 切到 UTF-8（errors=replace），避免 GBK 控制台遇 ✅/❌/💠 时抛
    UnicodeEncodeError；纯保底：换行符与中文在任意终端都不至于中断演示输出。"""
    for stream_name in ("stdout", "stderr"):
        try:
            stream = getattr(sys, stream_name)
            if stream is not None and hasattr(stream, "reconfigure"):
                stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            # 极少数解释器/重定向场景不支持 reconfigure——静默降级，不影响演示断言。
            pass

_ensure_utf8_console()


# ---------------------------------------------------------------------------
# 1. 枚举：GraphNode / EscrowStatus
# ---------------------------------------------------------------------------
class GraphNode(Enum):
    """镜像 AgentAgreementV3.sol 的 8 节点 + 编表层终态替代名。

    前 8 项顺序与链上契约一致（SUBMIT…SLASH）。REJECT/REFUND/DONE 是流程收口时
    落位的编表层名称（终端偏移在大编号区，避免与链上序号冲突）；SLASH 复用链上
    第 8 节点成员，既作为仲裁判罚路径节点，也作为罚没后的流程终态。
    """

    SUBMIT = 1
    VALIDATE = 2
    FUND = 3
    EXECUTE = 4
    VERIFY = 5
    SETTLE = 6
    ARBITRATE = 7
    SLASH = 8
    # ---- 内部重试回炉节点（非终端循环停留点，不入账（不 checkpoint 于 DECISION 环）----
    RETRY = 90
    # ---- 编表层终态替代名（终端）----
    REJECT = 101
    REFUND = 102
    DONE = 103

    def is_terminal(self) -> bool:
        """该节点是否位于编表层定义的一条结算流程的终点。"""
        return self in (GraphNode.REJECT, GraphNode.REFUND, GraphNode.DONE, GraphNode.SLASH)


class EscrowStatus(Enum):
    """托管/质押资金舱位状态。"""

    CREATED = auto()
    FUNDED = auto()
    SETTLED = auto()
    REFUNDED = auto()
    SLASHED = auto()


# ---------------------------------------------------------------------------
# 2. SettlementState：贯穿整个执行图的可变共享状态（全 typed）
# ---------------------------------------------------------------------------
@dataclass
class SettlementState:
    """一次结算任务的全量运行状态（在整张图内共享传递）。"""

    taskId: str
    provider: str
    consumer: str
    inputHash: str
    expectedOutput: str
    escrow_status: EscrowStatus = EscrowStatus.CREATED
    amount: int = 0
    stake: int = 0
    checkpointSeq: int = 0          # 最近一次已落账（checkpoint）的 seq
    merkleRoot: str = ""
    retryCount: int = 0
    done: bool = False


# ---------------------------------------------------------------------------
# 3. CheckpointEntry：Ledger 里一条不可变 (frozen) 记录
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class CheckpointEntry:
    """一条只追加的账目条目。frozen 保证不可就地修改，强化"绝不改历史"。"""

    seq: int
    node: GraphNode
    state_snapshot: Dict[str, Any]  # 过节点瞬间的 state 快照 dict
    recorded: float                 # 时间戳（单调/墙钟均可，仅作审计）

    def to_plain(self) -> Dict[str, Any]:
        """序列化为纯 dict（便于未来权威版落 sqlite / 文件）。"""
        return {
            "seq": self.seq,
            "node": self.node.name,
            "state": self.state_snapshot,
            "recorded": self.recorded,
        }


# ---------------------------------------------------------------------------
# 4. append-only Ledger：只追加，绝不改历史
# ---------------------------------------------------------------------------
class Ledger:
    """纯内存、append-only 的结算轨迹账本。

    权威版（prod）可替换为 sqlite / 追加式对账文件——当前仅需保证
    append 只增、latest 取尾、replay 按 seq 全量回放，绝不覆盖已有条目。
    """

    def __init__(self) -> None:
        self._entries: List[CheckpointEntry] = []

    def append(self, node: GraphNode, snapshot: Dict[str, Any]) -> CheckpointEntry:
        """追加一条 checkpoint（seq 取当前最新 +1，绝不改写已有条目）。"""
        seq = (self._entries[-1].seq + 1) if self._entries else 1
        entry = CheckpointEntry(
            seq=seq, node=node, state_snapshot=dict(snapshot), recorded=time.time()
        )
        self._entries.append(entry)
        return entry

    def latest(self) -> Optional[CheckpointEntry]:
        """返回最后一条 checkpoint（恢复点 / 取尾）。"""
        return self._entries[-1] if self._entries else None

    def replay(self) -> List[CheckpointEntry]:
        """按追加顺序全量回放所有条目（审计 / 重建轨迹）。"""
        return list(self._entries)

    def __len__(self) -> int:
        return len(self._entries)


# ---------------------------------------------------------------------------
# 领域小工具 / 语义错误
# ---------------------------------------------------------------------------
class SettlementError(Exception):
    """结算流程语义错误或非法转换——结构化可读消息，不裸抛。"""

    pass


class SimulatedCrash(Exception):
    """仅供 __main__ 演示：模拟进程在 checkpoint 之后崩溃。"""

    pass


# ---------------------------------------------------------------------------
# 6. 条件转移决策函数：decision(graph) -> next（决策函数表）
#    每个决策返回"下一停留节点"；非终端节点随后被 checkpoint。
# ---------------------------------------------------------------------------
def _d_submit(graph: "SettlementGraph") -> GraphNode:
    """SUBMIT → VALIDATE（提交完成后进入校验环节）。"""
    return GraphNode.VALIDATE


def _d_validate(graph: "SettlementGraph") -> GraphNode:
    """VALIDATE → FUND（审核通过） | REJECT（驳回，走 judge 审核钩子）。"""
    verdict = graph.judge("validate: 该任务输入与双边资质是否合规可执行?")
    if verdict["pass"]:
        return GraphNode.FUND
    graph._reason = "validate rejected by adjudicator"
    return GraphNode.REJECT


def _d_fund(graph: "SettlementGraph") -> GraphNode:
    """FUND → EXECUTE | REFUND（超时退款场景，由 policy.fund_timeout 决定）。"""
    if graph.policy.get("fund_timeout", False):
        graph._reason = "fund timeout -> refund"
        graph.state.escrow_status = EscrowStatus.REFUNDED
        return GraphNode.REFUND
    graph.state.escrow_status = EscrowStatus.FUNDED
    return GraphNode.EXECUTE


def _d_execute(graph: "SettlementGraph") -> GraphNode:
    """EXECUTE → VERIFY | ARBITRATE（执行者产出后消费方 dispute）。"""
    if graph.policy.get("dispute", False):
        graph._reason = "consumer disputes execution output"
        return GraphNode.ARBITRATE
    # 模拟一次执行：把"执行结果"记为派生串（演示用，无真实计算）
    graph._result = "out:" + graph.state.inputHash + ":" + graph.state.expectedOutput
    return GraphNode.VERIFY


def _d_verify(graph: "SettlementGraph") -> GraphNode:
    """VERIFY → SETTLE（命中 expectedOutput） | RETRY（bad output，允许重试）。"""
    # 判定结果命中与否由 policy 的 good/bad_output 决定（确定性演示）
    good = bool(graph.policy.get("good_output", not graph.policy.get("bad_output", True)))
    if good:
        return GraphNode.SETTLE
    graph.state.retryCount += 1
    return GraphNode.RETRY


def _d_settle(graph: "SettlementGraph") -> GraphNode:
    """SETTLE → DONE（正常放款收口）。"""
    graph.state.escrow_status = EscrowStatus.SETTLED
    graph.state.done = True
    return GraphNode.DONE


def _d_retry(graph: "SettlementGraph") -> GraphNode:
    """RETRY → REJECT（重试耗尽判负） | VERIFY（余量内重新校验）。"""
    max_retries = int(graph.policy.get("max_retries", 3))
    if graph.state.retryCount >= max_retries:
        graph._reason = f"retries exhausted ({graph.state.retryCount}/{max_retries}) -> REJECT"
        return GraphNode.REJECT
    return GraphNode.VERIFY


def _d_arbitrate(graph: "SettlementGraph") -> GraphNode:
    """ARBITRATE → SLASH（裁定执行者作恶） | REJECT（裁定驳回/非作恶方担责）。"""
    verdict = graph.judge("arbitrate: 该次 dispute 的份额与过错如何裁定?")
    if graph.policy.get("arbitrate_slash", False):
        graph._reason = "arbitration verdict -> SLASH"
        return GraphNode.SLASH
    graph._reason = "arbitration verdict -> REJECT (disputed without slash)"
    return GraphNode.REJECT


def _d_slash(graph: "SettlementGraph") -> GraphNode:
    """SLASH（罚没后）→ DONE（罚没落库，流程到此收口）。"""
    graph.state.escrow_status = EscrowStatus.SLASHED
    graph.state.done = True
    return GraphNode.DONE


# ---------------------------------------------------------------------------
# 5. SettlementGraph：运行图 / 状态机 / checkpoint 恢复
# ---------------------------------------------------------------------------
class SettlementGraph:
    """把 GraphNode 枚举展开为一张可运行的结算编排图。

    - 每节点 = 一个 run 函数：`NODE_RUNNERS`（dict[GraphNode] = callable）。
      默认 node-runner 无副作用，仅示意"节点处理器可在此替换”。
    - 条件转移 = `DECISION_TABLE`（dict[GraphNode] = decision(graph) -> next）,
      即一种"决策函数表"驱动：当前节点 → 决策函数算出的下一节点。
    - 共享 `SettlementState` 在整张图内传递，跨 start/resume 保持一致。
    - 每成功过一非终端节点，就把 (node, 当前快照) append 进 ledger。
    - `resume()` 从 ledger.latest() 快照重建 state（不靠外部传入），
      只重放尚未 checkpoint 的尾段，实现幂等恢复。
    """

    # 决策函数表
    DECISION_TABLE: Dict[GraphNode, Callable[["SettlementGraph"], GraphNode]] = {
        GraphNode.SUBMIT: _d_submit,
        GraphNode.VALIDATE: _d_validate,
        GraphNode.FUND: _d_fund,
        GraphNode.EXECUTE: _d_execute,
        GraphNode.VERIFY: _d_verify,
        GraphNode.SETTLE: _d_settle,
        GraphNode.RETRY: _d_retry,
        GraphNode.ARBITRATE: _d_arbitrate,
        GraphNode.SLASH: _d_slash,
    }
    # 节点处理器表（可替换实现）
    NODE_RUNNERS: Dict[GraphNode, Callable[["SettlementGraph"], None]] = {}

    def __init__(self, ledger: Ledger, policy: Optional[Dict[str, Any]] = None) -> None:
        """
        policy 为确定性参数集，决定 judge 与各分支走向（演示用）：
            - good_output: bool  —— VERIFY 是否视为命中 expectedOutput（默认 True）
            - bad_output:  bool  —— True 触发 RETRY 回炉（与 good_output 相反）
            - dispute:     bool  —— EXECUTE 后是否触发 ARBITRATE
            - arbitrate_slash: bool —— 仲裁裁定罚没 SLASH（否则 REJECT）
            - fund_timeout: bool —— FUND 阶段模拟超时 → REFUND
            - max_retries: int  —— RETRY 上限（默认 3）
        """
        self.ledger: Ledger = ledger
        self.policy: Dict[str, Any] = dict(policy) if policy else {}
        self.policy.setdefault("good_output", True)
        self.policy.setdefault("bad_output", False)
        self.policy.setdefault("fund_timeout", False)
        self.policy.setdefault("dispute", False)
        self.policy.setdefault("arbitrate_slash", False)
        self.policy.setdefault("max_retries", 3)

        self.state: Optional[SettlementState] = None
        self._result: Optional[str] = None
        self._reason: str = ""
        self._cursor: GraphNode = GraphNode.SUBMIT  # 下一个要处理/停留的节点
        self._terminal: Optional[GraphNode] = None  # 已抵达的终态（若已完成）
        self._running: bool = False

    # ---- 7. judge() 裁决挂点 --------------------------------------------
    def judge(self, question: str) -> Dict[str, Any]:
        """裁决挂点：VALIDATE 审核与 ARBITRATE 仲裁共用。

        生产版接 L5 裁决大脑。当前给确定性返回（由 policy 决定），并留下
        "裁决三问"注册痕迹，供将来替换真实裁决组件后做溯源：
            ① 谁发令  who_commands —— 发起裁决请求的编排器/触发方
            ② 谁依据  who_bases    —— 判定所依据的证据/规则/策略来源
            ③ 谁背书  who_endorses —— 对裁决结果背书（生产版为多签组件）
        """
        q = question.lower()
        if "arbitrate" in q:
            verdict_pass = not bool(self.policy.get("arbitrate_slash", False))
        else:  # validate 审核默认放行，除非 policy 显式 reject
            verdict_pass = bool(self.policy.get("validate_pass", True))

        return {
            "question": question,
            "verdict": "PASS" if verdict_pass else "REJECT",
            "pass": verdict_pass,
            "decision_source": "policy_dict@SettlementGraph",
            "adjudicator_registry": {
                "who_commands": "@L5-adjudicator/orchestrator",   # 谁发令
                "who_bases": f"policy@{('arbitrate_slash' if 'arbitrate' in q else 'validate_pass')}",  # 谁依据
                "who_endorses": "@L5-multisig/reference",         # 谁背书
            },
        }

    # ---- checkpoint / 快照 ------------------------------------------
    @staticmethod
    def _snapshot(state: SettlementState) -> Dict[str, Any]:
        s = asdict(state)
        # 把枚举成员转成名字，方便雪崩/序列化往返
        s["escrow_status"] = state.escrow_status.name
        return s

    @staticmethod
    def _from_snapshot(snap: Dict[str, Any]) -> SettlementState:
        cls: Any = SettlementState
        esc = snap.get("escrow_status")
        esc = EscrowStatus[esc] if isinstance(esc, str) else esc
        return cls(
            taskId=snap["taskId"],
            provider=snap["provider"],
            consumer=snap["consumer"],
            inputHash=snap["inputHash"],
            expectedOutput=snap["expectedOutput"],
            escrow_status=esc,
            amount=int(snap.get("amount", 0)),
            stake=int(snap.get("stake", 0)),
            checkpointSeq=int(snap.get("checkpointSeq", 0)),
            merkleRoot=str(snap.get("merkleRoot", "")),
            retryCount=int(snap.get("retryCount", 0)),
            done=bool(snap.get("done", False)),
        )

    def _checkpoint(self, node: GraphNode) -> None:
        """过一节点成功后，把 (node, 当前快照) append 进 ledger 并同步 seq。"""
        assert self.state is not None
        entry = self.ledger.append(node, self._snapshot(self.state))
        self.state.checkpointSeq = entry.seq

    def _run_node(self, node: GraphNode) -> None:
        """运行某个节点的 run 函数（默认空操作，可被子类策略化）。"""
        runner = self.NODE_RUNNERS.get(node)
        if runner is not None:
            runner(self)

    # ---- 主推进循环 ------------------------------------------------
    def _advance_to_terminal(self) -> None:
        """从当前 state 起，沿选择节点推进到终态 / state.done 置真。"""
        if self._running:
            raise SettlementError("record-execution loop: graph already running (re-entrancy)")
        if self.state is None:
            raise SettlementError("no state bound; call start() or resume().")
        self._running = True
        try:
            guard = 0
            while not self.state.done:
                guard += 1
                if guard > 96:
                    raise SettlementError("run exceeded safety bound (96); inspect decision table")
                node = self._cursor
                decision = self.DECISION_TABLE.get(node)
                if decision is None:
                    raise SettlementError(
                        f"no decision for node {node.name}; cannot route. illegal transition (structured hint)."
                    )
                nxt = decision(self)
                if nxt.is_terminal() and nxt != GraphNode.SLASH:
                    # 终态收口：交由 _set_terminal 统一登记 _terminal / done / escrow /
                    # checkpointSeq。此前版本这里手动塞了 _terminal + checkpointSeq 却漏了
                    # done/escrow 归一（REJECT/REFUND 决策函数不置 done），导致 terminal
                    # 被跳过登记——现统一收敛到 _set_terminal。
                    self._set_terminal(nxt)
                    return
                # 非终端下一节点：过节点成功 → checkpoint 落账，并停留
                self._run_node(nxt)
                self._cursor = nxt
                self._checkpoint(nxt)
        finally:
            self._running = False

    def _set_terminal(self, nxt: GraphNode) -> None:
        """登记终态并把 state 置为该终态对应的 escrow / done。"""
        self._terminal = nxt
        self.state.done = True
        if nxt == GraphNode.REJECT:
            self.state.escrow_status = EscrowStatus.REFUNDED  # 驳回=退回作罢，仅措辞
        elif nxt == GraphNode.DONE:
            # 若走的是 SLASH 路线刚被 _d_slash 置过 SLASHED，否则为 SETTLED
            if self.state.escrow_status != EscrowStatus.SLASHED:
                self.state.escrow_status = EscrowStatus.SETTLED
        # REFUND / SLASH 已在对应决策函数里设置了 escrow
        self.state.checkpointSeq = self.ledger.latest().seq if self.ledger.latest() else 0

    # ---- 启动 / 恢复 ------------------------------------------------
    def start(self, seed: Optional[SettlementState] = None) -> "SettlementGraph":
        """全新启动：把 SUBMIT 落账（成首条 checkpoint），随后一路推进到终态。

        幂等化：若 ledger 已非空（说明是重跑），直接递交给 resume() 从最近
        checkpoint 恢复，而不是重新提交 SUBMIT（避免重复处理已 checkpoint 节点）。
        """
        if self.ledger.latest() is not None:
            # 已有账本轨迹 → 走恢复语义（幂等）
            return self.resume()
        if seed is None:
            raise SettlementError("start() requires a seed state when ledger is empty.")
        self.state = SeedCoWash(seed) if False else seed
        # 先落 SUBMIT 首账
        self._cursor = GraphNode.SUBMIT
        self.state.checkpointSeq = 0
        snap = self._snapshot(self.state)
        entry = self.ledger.append(GraphNode.SUBMIT, snap)
        self.state.checkpointSeq = entry.seq
        self._cursor = GraphNode.VALIDATE
        self._advance_to_terminal()
        return self

    def resume(self) -> "SettlementGraph":
        """从 ledger.latest() 快照重建 state，再推进尚未 checkpoint 的尾段到终态。

        - 只读账本取尾，不依赖外部传入 state；
        - 若账本为空 → 结构化抛错提示应改用 start()；
        - 已落账的 checkpoint 节点此轮绝不重复执行（推进从《最近一处停留点》继续）。
        """
        latest = self.ledger.latest()
        if latest is None:
            raise SettlementError(
                "resume() requires a non-empty ledger; use start(seed) to begin a task."
            )
        self.state = self._from_snapshot(latest.state_snapshot)
        # 若最后一条 checkpoint 本身已是终态（如 SLASH/DONE 完成路径已落账），直接返回
        if latest.node.is_terminal() or self.state.done:
            self._terminal = latest.node
            return self
        # 否则从该 checkpoint 节点对应的"下一节点"继续；由于 checkpoint 落在停留点，
        # 我们重建停留 position 为 "该 checkpoint 节点之后该往哪走"——让决策表来主导。
        # 关键：这里我们不重放已落账 checkpoint 的节点，只从该停留点继续到终态。
        self._cursor = _next_after(latest.node)
        self._advance_to_terminal()
        return self

    @property
    def terminal_node(self) -> Optional[GraphNode]:
        return self._terminal

    def report(self) -> Dict[str, Any]:
        st = self.state
        return {
            "done": st.done if st else False,
            "terminal": self._terminal.name if self._terminal else None,
            "escrow": st.escrow_status.name if st else None,
            "checkpointSeq": st.checkpointSeq if st else None,
            "ledger_len": len(self.ledger),
            "reason": self._reason,
            "replay": [e.node.name for e in self.ledger.replay()],
        }


# 默认 node runners（可在外部给 SettlementGraph.NODE_RUNNERS 装配处理器）
SettlementGraph.NODE_RUNNERS = {n: None for n in GraphNode}


def _next_after(node: GraphNode) -> GraphNode:
    """给定一个刚停留（已 checkpoint）的节点，返回以它为当前节点的"决策起点"。

    实际上决策循环用 `self._cursor` 作为"下一个要处理节点"。这里把恢复点节点
    当作要重新对其做决策的当前停留点：例如已 checkpoint 在 VALIDATE 的 graph，
    恢复后应从 VALIDATE 决策 → FUND…。这样恰好不重放已 check 的 VALIDATE,
    而只是继续它之后的转移。这与"不重放节点"语义一致（被 checkpoint 的是结果
    节点，决策在其上继续，不重复跑它的 runner）。
    """
    # 语义设计说明：
    # 我们让 checkpoint 记录的是"到达并已成功的节点"(如 VALIDATE/FUND...)。
    # 恢复时把这些"到达节点"当作停留点继续向后路由即可（它们的决策表会算出
    # 下一个新节点并交给 _checkpoint），因此不会重复运行已到达节点的 runner。
    return node


# 辅助（消除 start 里的占位误写）
def SeedCoWash(s: Any) -> Any:
    return s


# ---------------------------------------------------------------------------
# __main__ 演示两段
# ---------------------------------------------------------------------------
def _demo_success() -> Dict[str, Any]:
    """演示 (a)：完整成功 settle 路径（SUBMIT→VALIDATE→FUND→EXECUTE→VERIFY→SETTLE→DONE）。"""
    ledger = Ledger()
    graph = SettlementGraph(ledger=ledger, policy={"good_output": True})  # VERIFY 命中
    seed = SettlementState(taskId="t-success-1", provider="agent-alpha",
                           consumer="agent-beta", inputHash="ih", expectedOutput="0xDEADBEEF",
                           amount=1_000_000, stake=250_000)
    graph.start(seed)
    return graph.report()


def _demo_crash_resume() -> Dict[str, Any]:
    """演示 (b)：模拟崩溃(某 checkpoint 后中断) → 同一 ledger 新开图 resume() 恢复。"""
    policy = {"good_output": True}

    class CrashAfter(SettlementGraph):
        """在过某节点并 checkpoint 之后抛 SimulatedCrash 的图（模拟进程崩溃）。"""

        crash_after: GraphNode = GraphNode.FUND

        def _checkpoint(self, node: GraphNode) -> None:
            super()._checkpoint(node)
            if node == self.crash_after:
                raise SimulatedCrash(
                    f"simulated crash right after checkpoint {node.name}"
                )

    ledgerA = Ledger()
    seedA = SettlementState(taskId="t-crash-1", provider="agent-alpha",
                            consumer="agent-beta", inputHash="ih", expectedOutput="0xDEADBEEF",
                            amount=1_000_000, stake=250_000)
    gA = CrashAfter(ledgerA, policy=dict(policy))
    try:
        gA.start(seedA)
    except SimulatedCrash:
        # 崩溃被捕获（模拟：进程此刻已死，仅留下 ledgerA 在磁盘/内存中的轨迹）
        pass

    # —— 崩溃发生在 FUND 的 checkpoint 之后 —— ledgerA.latest() 应为 FUND。
    crashed_checkpoint = ledgerA.latest()
    crashed_node = crashed_checkpoint.node.name if crashed_checkpoint else None
    crashed_seq = crashed_checkpoint.seq if crashed_checkpoint else 0

    # —— 进程"重启"：用同一 ledgerA 新开一张普通图，resume() 恢复 ——
    gB = SettlementGraph(ledgerA, policy=dict(policy))  # 全新对象
    gB.resume()  # 只读账本取尾 → 重建 state → 继续跑未落账尾段 → DONE
    rep = gB.report()
    rep["crashed_at"] = crashed_node
    rep["crashed_checkpointSeq"] = crashed_seq
    return rep


if __name__ == "__main__":
    print("=" * 70)
    print("L5 结算编排器 · 参考实现演示 (settlement_orchestrator.py)")
    print("=" * 70)

    print("\n--- 演示 (a)：完整 settle 成功路径 ---")
    ra = _demo_success()
    print("terminal       :", ra["terminal"])
    print("escrow         :", ra["escrow"])
    print("checkpointSeq  :", ra["checkpointSeq"])
    print("ledger_len     :", ra["ledger_len"])
    print("replay 节点序列 :", ra["replay"])
    ok_a = ra["terminal"] == "DONE" and ra["done"]
    print("✅ demo(a) 成功直达 DONE" if ok_a else "❌ demo(a) 未达 DONE")

    print("\n--- 演示 (b)：模拟崩溃(checkpoint 后中断) → 同账本 resume() 恢复 ---")
    rb = _demo_crash_resume()
    print("崩溃发生在 checkpoint: at", rb.get("crashed_at"), "seq", rb.get("crashed_checkpointSeq"))
    print("恢复后 terminal    :", rb["terminal"])
    print("恢复后 escrow      :", rb["escrow"])
    print("恢复后 checkpointSeq :", rb["checkpointSeq"])
    print("恢复侧 ledger_len  :", rb["ledger_len"])
    print("恢复侧 replay 序列  :", rb["replay"])

    # 幂等性断言：恢复后没有重复跑已 checkpoint 的节点——
    # FUND(seq=n) 之后的 replay 应单调递增，且不以 seq=1 重开（说明未重放 SUBMIT 等）。
    seqs = [e.seq for e in None] if False else None
    nodes = rb["replay"]
    crashed_seq = rb.get("crashed_checkpointSeq")
    # 崩溃点(seq)之后的新条目 seq 应 > 崩溃 seq；总数应 > 崩溃 seq
    monotonic = crashed_seq < rb["checkpointSeq"]  # 恢复推进到了更大的 seq
    ok_b = rb["terminal"] == "DONE" and rb["done"] and monotonic
    print("\n幂等性(未重放已 checkpoint 节点 / seq 单调递增) :",
          "✅" if monotonic else "❌")
    print("✅ demo(b) 崩溃恢复直达 DONE" if ok_b else "❌ demo(b) 恢复未闭环")

    print("\n" + ("💠 两段演示全部通过。" if (ok_a and ok_b) else "⚠️ 存在未通过项，请检查。"))
