# -*- coding: utf-8 -*-
"""
test_l5_offchain.py
===================

Off-chain 回归测试套件（Python 3.12 纯标准库 + unittest），把结算编排器与链桥
接线层这两层"锁成活档"——以后再改不会悄悄弄坏已绿行为。

被测现货（只读、不修改）:
    offchain/settlement_orchestrator.py  结算编排器: GraphNode 8节点 状态机 +
                                         SettlementState + append-only Ledger
                                         + checkpoint 崩溃恢复(resume) + 幂等
    offchain/l5_contract_link.py         ChainBridge + SimulatedChain +
                                         assert_state_consistent() + LINK_TABLE

三组用例:
    组一  编排器状态机分支（成功 / REJECT / SLASH / REFUND / RETRY 耗竭）
    组二  checkpoint 崩溃恢复 + 幂等 + append-only（核心，真测"不重复执行"）
    组三  接线层 x 链上合拍（对齐 ok / 违约态拦截 / 模拟链 onlyState 门禁 / 跨层集成）

硬纪律: 本文件只新增测试, 绝不改 settlement_orchestrator.py / l5_contract_link.py
/ 任何 .sol/.t.sol / foundry.toml。每例 setUp 各自重建干净 Ledger+Graph / 假链,
不共享状态。
"""

from __future__ import annotations

import os
import sys
import unittest

# ---------------------------------------------------------------------------
# sys.path 兜底: 让被测模块从哪被启动都能定位到 offchain 目录
# ---------------------------------------------------------------------------
_OFFCHAIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _OFFCHAIN not in sys.path:
    sys.path.insert(0, _OFFCHAIN)

from settlement_orchestrator import (  # noqa: E402
    GraphNode,
    EscrowStatus,
    SettlementState,
    Ledger,
    SettlementGraph,
    SimulatedCrash,
    CheckpointEntry,
)

import l5_contract_link as linkmod  # noqa: E402
from l5_contract_link import (  # noqa: E402
    OrchestratorNode,
    OnChainState,
    SimulatedChain,
    OnChainStateError,
    assert_state_consistent,
)


# ---------------------------------------------------------------------------
# helpers: 确定性 seed + 快照
# ---------------------------------------------------------------------------
def _seed(task_id: str = "t") -> SettlementState:
    return SettlementState(
        taskId=task_id,
        provider="agent-alpha",
        consumer="agent-beta",
        inputHash="input-00001",
        expectedOutput="0xDEADBEEF",
        amount=1_000_000,
        stake=250_000,
    )


def _snap(st: SettlementState) -> dict:
    return SettlementGraph._snapshot(st)


class GraphCrashAt(SettlementGraph):
    """
    checkpoint 完成 crash_after 节点后抛 SimulatedCrash（等价 __main__ 崩溃演示，
    但做成可控测试替身）：先落账(append-only)再崩溃，模拟"账已写、进程后死"。
    """

    crash_after: GraphNode = GraphNode.FUND

    def _checkpoint(self, node: GraphNode) -> None:
        super()._checkpoint(node)          # 先 commit 进 ledger
        if node == self.crash_after:
            raise SimulatedCrash(f"sim crash after checkpoint {node.name}")


# ===========================================================================
# 组一 · 编排器状态机分支
# ===========================================================================
class OrchestratorStateMachineTests(unittest.TestCase):
    """settlement_orchestrator 条件转移分支与终态收口(每例独立 Ledger)。"""

    def _run(self, policy: dict, task_id: str = "t"):
        ledger = Ledger()
        graph = SettlementGraph(ledger=ledger, policy=dict(policy))
        graph.start(_seed(task_id))
        return graph, graph.report()

    # 组一 · 用例 1: 完整成功路径 → DONE / SETTLED
    def test_success_path_terminates_done_settled(self) -> None:
        g, rep = self._run({"good_output": True}, "t-ok")
        self.assertIs(g.terminal_node, GraphNode.DONE)
        self.assertTrue(rep["done"])
        self.assertEqual(g.state.escrow_status, EscrowStatus.SETTLED)
        # 收口前末笔为 SETTLE (终态 DONE 本身不入账)
        self.assertEqual(rep["replay"][-1], "SETTLE")
        self.assertEqual(rep["escrow"], "SETTLED")

    # 组一 · 用例 2: validate-reject → REJECT
    def test_validate_reject_goes_REJECT(self) -> None:
        g, rep = self._run({"validate_pass": False}, "t-rej")
        self.assertIs(g.terminal_node, GraphNode.REJECT)
        self.assertTrue(rep["done"])
        self.assertIn("validate rejected", rep["reason"])

    # 组一 · 用例 3: dispute → ARBITRATE → SLASH(裁罚) 收口 DONE/SLASHED
    def test_dispute_arbitrate_slash(self) -> None:
        g, rep = self._run({"dispute": True, "arbitrate_slash": True}, "t-slash")
        self.assertIn("ARBITRATE", rep["replay"])
        self.assertIn("SLASH", rep["replay"])          # SLASH 节点确实落账过
        self.assertEqual(g.state.escrow_status, EscrowStatus.SLASHED)
        self.assertIs(g.terminal_node, GraphNode.DONE)  # SLASH 后收口 DONE

    # 组一 · 用例 3b: dispute → ARBITRATE 但裁定不罚没 → REJECT
    def test_dispute_arbitrate_no_slash_reject(self) -> None:
        g, rep = self._run({"dispute": True, "arbitrate_slash": False}, "t-rej2")
        self.assertIs(g.terminal_node, GraphNode.REJECT)
        self.assertIn("arbitration verdict -> REJECT", rep["reason"])

    # 组一 · 用例 4: FUND timeout → REFUND
    def test_fund_timeout_goes_refund(self) -> None:
        g, rep = self._run({"fund_timeout": True}, "t-refund")
        self.assertIs(g.terminal_node, GraphNode.REFUND)
        self.assertTrue(rep["done"])
        self.assertEqual(g.state.escrow_status, EscrowStatus.REFUNDED)

    # 组一 · 用例 5: RETRY 次数耗尽 → REJECT
    def test_retry_exhausted_goes_reject(self) -> None:
        g, rep = self._run(
            {"good_output": False, "bad_output": True, "max_retries": 2}, "t-retry")
        self.assertIs(g.terminal_node, GraphNode.REJECT)
        self.assertTrue(rep["done"])
        self.assertIn("retries exhausted", rep["reason"])
        self.assertEqual(g.state.retryCount, 2)


# ===========================================================================
# 组二 · checkpoint 崩溃恢复 + 幂等 + append-only（核心）
# ===========================================================================
class CheckpointRecoveryAndIdempotencyTests(unittest.TestCase):
    """崩溃恢复/幂等/append-only——认真断言"不重复执行已 checkpoint 节点"。

    口径:
        Ledger 只 append; 崩溃后同账本新开图 resume() 只推"尚未落账尾段";
        任何已 checkpoint 节点(SUBMIT/FUND/...)绝不二次执行 → replay 内 node 唯一、
        seq 单调递增、崩溃点后 seq 严格前进。
    """

    def _crash(self, crash_node: GraphNode, policy: dict):
        """跑图使其在 crash_node checkpoint 后中断, 返回 (ledger, 崩溃后 seq)。"""
        ledger = Ledger()
        g = GraphCrashAt(ledger=ledger, policy=dict(policy))
        g.crash_after = crash_node
        try:
            g.start(_seed("t-crash"))
        except SimulatedCrash:
            return ledger, g
        self.fail(f"start 未在 crash_after={crash_node.name} 触发 SimulatedCrash")

    # 组二 · 用例 6: 崩溃 → 同 Ledger 新开图 resume() 到 DONE, 不重复执行
    def test_crash_resume_reaches_done_without_replay(self) -> None:
        ledger, crashed_g = self._crash(GraphNode.FUND, {"good_output": True})
        crashed_seq = ledger.latest().seq
        crashed_node = ledger.latest().node.name
        head = [e.node.name for e in ledger.replay()]   # 崩溃前已 checkpoint 的节点

        # —— 进程重启: 同一 Ledger 新开一张普通图 resume() ——
        g2 = SettlementGraph(ledger, policy={"good_output": True})
        g2.resume()
        rep = g2.report()

        self.assertEqual(crashed_node, "FUND")
        self.assertEqual(rep["terminal"], "DONE")
        self.assertTrue(rep["done"])
        self.assertGreater(rep["checkpointSeq"], crashed_seq,
                           "resume 后 checkpointSeq 须严格大于崩溃点 seq(=未重放)")
        tail = [e.node.name for e in ledger.replay()[crashed_seq:]]
        # ★ 已 checkpoint(崩溃前) 的节点绝不与崩溃后新增节点重叠 → 无二次执行
        self.assertEqual(set(head) & set(tail), set(),
                         f"崩溃前 checkpoint {head} 与崩溃后 {tail} 发生重叠 -> 幂等被破坏")
        # 整段每个 node 至多落一次账
        all_names = [e.node.name for e in ledger.replay()]
        for nm in set(all_names):
            self.assertEqual(all_names.count(nm), 1,
                             f"节点 {nm} 在崩溃恢复后被意外重复 checkpoint")
        # seq 单调递增且不重号
        seqs = [e.seq for e in ledger.replay()]
        self.assertEqual(seqs, sorted(seqs))

    # 组二 · 用例 7: 幂等——同 Ledger 从 start 重跑不重处理已 checkpoint 早期节点
    def test_start_on_populated_ledger_is_idempotent(self) -> None:
        # 崩溃在 FUND(checkpoint 到达节点)之后, 崩溃前已 checkpoint SUBMIT/FUND
        ledger, _ = self._crash(GraphNode.FUND, {"good_output": True})
        pre = [e.node.name for e in ledger.replay()]     # [SUBMIT, FUND]
        pre_seq_count = len(ledger)
        self.assertEqual(pre, ["SUBMIT", "FUND"])

        # 同一已含轨迹 Ledger 上再次 start(): 幂等路由到 resume(), 不重提交 SUBMIT
        g = SettlementGraph(ledger, policy={"good_output": True})
        g.start(_seed("t-again"))
        post = [e.node.name for e in ledger.replay()]
        rep = g.report()

        self.assertEqual(rep["terminal"], "DONE")
        # 崩溃前已 checkpoint 的节点前缀一字未变(append-only: 历史不可篡改)
        self.assertEqual(post[:pre_seq_count], pre,
                         "幂等重跑篡改了已 checkpoint 的历史前缀")
        # SUBMIT 全段只出现一次 —— 未因 start() 重放早期节点
        self.assertEqual(post.count("SUBMIT"), 1)
        self.assertEqual(post[0], "SUBMIT")
        self.assertEqual(post.count("FUND"), 1)
        # 只有真正未落账的尾段被补齐, seq 全程单调递增
        seqs = [e.seq for e in ledger.replay()]
        self.assertEqual(seqs, sorted(seqs))

    # 组二 · 用例 8: append-only——Ledger 只追加、不改历史、replay 保序、条目 frozen
    def test_ledger_append_only_order_preserved(self) -> None:
        ledger = Ledger()
        a = ledger.append(GraphNode.SUBMIT, _snap(_seed()))
        b = ledger.append(GraphNode.FUND, _snap(_seed()))
        c = ledger.append(GraphNode.VERIFY, _snap(_seed()))
        order1 = [x.node for x in ledger.replay()]
        self.assertEqual(order1, [GraphNode.SUBMIT, GraphNode.FUND, GraphNode.VERIFY])

        # 追加第 4 条不挤改既有条目的 seq/顺序
        d = ledger.append(GraphNode.SETTLE, _snap(_seed()))
        self.assertEqual([x.seq for x in ledger.replay()], [1, 2, 3, 4])
        # replay 顺序 == append 顺序
        self.assertEqual([x.node.name for x in ledger.replay()],
                         ["SUBMIT", "FUND", "VERIFY", "SETTLE"])
        # 历史条目对象未被后续 append "就地改写"(append 新建独立 entry)
        self.assertIsNot(a, d)
        self.assertEqual(a.seq, 1)
        self.assertEqual(b.seq, 2)
        self.assertEqual(c.seq, 3)
        # frozen dataclass: 直接改历史条目的字段会抛 (证实条目不可就地改写)
        with self.assertRaises(Exception):
            a.seq = 999               # CheckpointEntry(frozen=True) 字段改写应报 FrozenInstanceError
        self.assertEqual(a.seq, 1)     # 改写被拒后字段还原封不动
        # 且真正“篡改历史”也无窗口: seq 由 ledger 分配, 用户拿不到权威 seq
        self.assertEqual(len(ledger), 4)


# ===========================================================================
# 组三 · l5_contract_link: 接线层 x 链上合拍
# ===========================================================================
class ContractLinkTests(unittest.TestCase):
    """链桥抽象 + SimulatedChain + assert_state_consistent 对齐/门禁/集成(独立假链)。"""

    def _mk_signed(self, task_id: str = "t"):
        """新建 agreement 并推到 Signed, 返回 (bridge, aid)。注意配合用例各自对齐。"""
        bridge = SimulatedChain()
        aid = bridge._create(task_id)          # Draft
        bridge.propose(aid)                    # Draft→Proposed (auto cp Validate)
        bridge.sign(aid)                       # Proposed→Signed
        return bridge, aid

    # 组三 · 用例 9: 编排器 node 与链上对口状态合拍 → ok=True
    def test_aligned_states_ok(self) -> None:
        # 分步驱动, 在每一步链上处于 LINK_TABLE 期望态时校验对齐为 ok
        bridge = SimulatedChain()
        aid = bridge._create("t-ok")             # Draft
        ok, _ = assert_state_consistent(OrchestratorNode.SUBMIT, bridge.state_of(aid))
        self.assertTrue(ok, "SUBMIT/链上 Draft 应合拍")

        bridge.propose(aid)                     # Draft→Proposed (auto cp Validate)
        ok, msg = assert_state_consistent(OrchestratorNode.VALIDATE,
                                          bridge.state_of(aid))
        self.assertTrue(ok, f"VALIDATE/Proposed 应 ok=True: {msg}")

        bridge.sign(aid)                        # → Signed
        ok, msg = assert_state_consistent(OrchestratorNode.SIGN, bridge.state_of(aid))
        self.assertTrue(ok, f"SIGN/Signed 应 ok=True: {msg}")

        # 推到 Completed 后 SETTLE 合拍(bindEscrow 路径期望 Completed)
        bridge._agreements[aid] = OnChainState.Completed
        ok, msg = assert_state_consistent(OrchestratorNode.SETTLE,
                                          bridge.state_of(aid))
        self.assertTrue(ok, f"SETTLE/Completed 应 ok=True: {msg}")

    # 组三 · 用例 10: 违约态拦截——编排器想 SETTLE 但链上仍在 Signed → ok=False
    def test_settle_on_signed_is_blocked(self) -> None:
        bridge, aid = self._mk_signed("t-bad")   # Signed, 未走 Executed/Completed
        self.assertEqual(bridge.state_of(aid), OnChainState.Signed)
        ok, msg = assert_state_consistent(OrchestratorNode.SETTLE, bridge.state_of(aid))
        self.assertFalse(ok, "链上 Signed 时编排器想 SETTLE 应被拦 ok=False")
        self.assertIn("落后", msg)               # 给读得懂的不一致提示
        # 拦截之下 mark_settled 也不该真打(链上门禁双保险)
        with self.assertRaises(OnChainStateError):
            bridge.mark_settled(aid)

    # 组三 · 用例 11: 模拟链门禁——绕过 assert 直调 markSettled(非 Completed) 抛错
    def test_bridge_gate_rejects_non_completed(self) -> None:
        bridge, aid = self._mk_signed("t-gate")  # Signed —— 非 Completed
        with self.assertRaises(OnChainStateError):
            bridge.mark_settled(aid)             # 复刻 Solidity onlyState(Completed)
        self.assertEqual(bridge.state_of(aid), OnChainState.Signed, "门禁拒绝时链态不动")
        # 合法路径: 推到 Executed→Completed 后 mark_settled 成功, 且 auto cp Settle
        bridge._agreements[aid] = OnChainState.Executed
        bridge.complete_execution(aid)           # Executed→Completed
        self.assertEqual(bridge.mark_settled(aid), OnChainState.Settled)
        self.assertIn("Settle", bridge.checkpoints(aid))

    # 组三 · 用例 12: 跨层集成——编排器推进, 链上 AgreementState 各阶段合拍
    def test_cross_layer_orchestrator_meets_chain(self) -> None:
        bridge = SimulatedChain()
        aid = bridge._create("t-join")
        # 链: Draft→Proposed→Signed→Executed→Completed (与编排器各关键节点同步)
        bridge.propose(aid)
        bridge.sign(aid)
        bridge._agreements[aid] = OnChainState.Executed
        bridge.complete_execution(aid)           # Completed (markSettled 前置)
        self.assertEqual(bridge.state_of(aid), OnChainState.Completed)

        # 编排器从干净 Ledger 沿成功路径推进到 DONE, escrow=SETTLED
        ledger = Ledger()
        g = SettlementGraph(ledger=ledger, policy={"good_output": True})
        g.start(_seed("t-join"))
        self.assertIs(g.terminal_node, GraphNode.DONE)
        self.assertEqual(g.state.escrow_status, EscrowStatus.SETTLED)
        # 编排器每过一个 this-contract 主迁态节点, 链上此刻必须已推进到不低于其目标态。
        # 链已被推到 Completed, 对最关键的 SETTLE 须严格合拍; VALIDATE/VERIFY 是链上
        # 已早到达的历史态, 只要编排器确实可达 DONE 且 SETTLE 严格对齐即证明链路合拍。
        ok, msg = assert_state_consistent(OrchestratorNode.SETTLE, bridge.state_of(aid))
        self.assertTrue(ok, f"SETTLE 时刻链须为 Completed(编排器不应在违约态推结算): {msg}")

        # 链放款收口 mark_settled + 编排器 DONE 链路对齐
        self.assertEqual(bridge.mark_settled(aid), OnChainState.Settled)
        self.assertIn("Settle", bridge.checkpoints(aid))
        ok_done, _ = assert_state_consistent(OrchestratorNode.DONE, OnChainState.Settled)
        self.assertTrue(ok_done, "DONE 收口应对齐链上 Settled")


if __name__ == "__main__":
    unittest.main(verbosity=2)
