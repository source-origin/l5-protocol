// SPDX-License-Identifier: ORIGIN-1.0
// ═══════════════════════════════════════════════════════════
// ORIGIN L5 · AgentAgreement.sol
// 来源：CloddsBot ACP + EIP-712 Typed Structured Data 签名
// 作者：量子总督 👽 · 2026-08-10
// 版本：v0.3-langgraph-injection (2026-09-01)
// ═══════════════════════════════════════════════════════════
//
// v0.3注入（LangGraph 状态图 + checkpoint 可恢复）：
//   1. 新增 GraphNode enum + Checkpoint 结构
//   2. Agreement 加 checkpointSeq / checkpoints[] / replaying
//   3. recordCheckpoint / getLatestCheckpoint / replayTo(幂等重放)
//   4. _autoCheckpoint 内部：propose→Validate / markSettled→Settle 自动落账
//   5. 防重放：同节点不重复记录；replayTo 不回滚已结算资金
//   6. 关联文档: E:\QGCore\arsenal\origin-l5-injection-v1.6-langgraph.md
//
// v0.2注入：
//   1. EIP-712 DOMAIN_SEPARATOR + typed struct hash
//   2. _verifyEIP712Signature 替代旧 ecrecover 模式
//   3. 多签阈值 M-of-N
//   4. EIP-712 兼容外部签名工具 (Metamask/Ledger)
//
// 状态机（9态）：
//   draft → proposed → signed → executed → completed → settled
//     ↓        ↓                                    ↑
//   cancelled disputed ←────────────────────────────┘

pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title AgentAgreement
 * @notice AI Agent 之间的链上协议订立、签署、执行和结算
 * @dev 每个协议从 draft 到 settled 经历9个状态
 */
contract AgentAgreement {
    // ═══════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════

    enum AgreementState {
        Draft, // 草稿 — 创建者自由编辑
        Proposed, // 已提议 — 等待对方确认
        Signed, // 已签署 — 双方签名完成
        Executed, // 执行中 — 工作开始
        Completed, // 已完成 — 工作交付
        Settled, // 已结算 — YUAN已转账（ORIGIN增强）
        Cancelled, // 已取消 — 未签名前取消
        Disputed, // 争议中 — 等待仲裁
        Slashed // 已罚没 — 仲裁结果（ORIGIN增强）
    }

    enum TermType {
        Payment, // 支付条款
        Deliverable, // 交付物
        Deadline, // 截止时间
        Condition, // 条件条款
        Custom // 自定义
    }

    enum PartyRole {
        Provider, // 服务提供方
        Consumer, // 服务消费方
        Arbiter // 可选仲裁方
    }

    // ═══════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════

    struct AgentParty {
        address agentAddr; // Agent的did:origin映射地址
        PartyRole role; // 角色
        bytes signature; // Ed25519/ECDSA签名
        uint256 signedAt; // 签名时间戳
    }

    struct SettlementTerm {
        bytes32 termId; // 条款ID
        TermType termType; // 类型
        string description; // 描述
        uint256 value; // YUAN金额（或0表示非支付项）
        uint256 dueDate; // 截止时间
        bool completed; // 是否完成
        uint256 completedAt; // 完成时间
    }

    struct Agreement {
        bytes32 agreementId; // 协议ID
        string title; // 标题
        string description; // 详细描述
        AgentParty[] parties; // 参与方
        SettlementTerm[] terms; // 条款列表
        AgreementState state; // 当前状态
        bytes32 agreementHash; // 协议哈希（用于签名验证）
        uint256 totalValue; // 总价值
        address escrowContract; // 关联的托管合约地址
        uint256 createdAt; // 创建时间
        uint256 updatedAt; // 更新时间
        uint256 version; // 版本号
        bytes32 previousVersionHash; // 前一版本哈希（修订链）
        // ── v0.3-langgraph-injection (2026-09-01) ──
        // LangGraph 状态图 + checkpoint 可恢复注入
        uint256 checkpointSeq; // ★ 当前检查点序号（每过一节点 +1）
        Checkpoint[] checkpoints; // ★ append-only 检查点账本
        bool replaying; // ★ 是否处于幂等重放中
    }

    // ── v0.3-langgraph-injection: LangGraph Checkpoint 结构 ──
    /// @notice 结算图节点（LangGraph Node 映射）
    enum GraphNode {
        Submit, // 提交
        Validate, // 校验
        Fund, // 托管注资
        Execute, // 执行
        Verify, // 验证
        Settle, // 结算
        Arbitrate, // 仲裁
        Slash // 罚没
    }

    /// @notice 每个状态图节点的检查点快照
    struct Checkpoint {
        uint256 seq; // 检查点序号
        GraphNode node; // 所在图节点
        AgreementState state; // 当时协议状态
        bytes32 stateHash; // 状态哈希（防篡改/防重放）
        uint256 recordedAt; // 记录时间戳
    }

    // ═══════════════════════════════════════════════════
    // EIP-712 TYPED DATA
    // ═══════════════════════════════════════════════════

    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 public constant AGREEMENT_TYPEHASH = keccak256(
        "Agreement(bytes32 agreementId,string title,string description,bytes32 partyHash,bytes32 termHash,uint256 totalValue,uint256 version,bytes32 previousVersionHash)"
    );

    uint256 public requiredSignatures = 2; // M-of-N 阈值
    mapping(bytes32 => uint256) private agreementSigCount; // 已签名计数

    // ═══════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════

    mapping(bytes32 => Agreement) public agreements;
    mapping(bytes32 => bytes32) private hashToId; // hash → agreementId
    mapping(address => bytes32[]) private agentAgreements; // Agent → 协议列表
    bytes32[] private allAgreementIds;

    uint256 public agreementCount;
    uint256 public constant TERM_ID_PREFIX = 0x7465726d; // "term"

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ORIGIN Agent Agreement")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // ═══════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════

    event AgreementCreated(
        bytes32 indexed agreementId, address indexed creator, string title, uint256 totalValue, uint256 timestamp
    );

    event AgreementProposed(bytes32 indexed agreementId, address indexed proposer, uint256 timestamp);

    event AgreementSigned(bytes32 indexed agreementId, address indexed signer, PartyRole role, uint256 timestamp);

    event AgreementExecuted(bytes32 indexed agreementId, uint256 timestamp);

    event TermCompleted(bytes32 indexed agreementId, bytes32 indexed termId, uint256 timestamp);

    event AgreementCompleted(bytes32 indexed agreementId, uint256 timestamp);

    event AgreementSettled(
        bytes32 indexed agreementId, address indexed payer, address indexed payee, uint256 amount, uint256 timestamp
    );

    event AgreementCancelled(bytes32 indexed agreementId, address indexed canceller, uint256 timestamp);

    event AgreementDisputed(bytes32 indexed agreementId, address indexed disputer, string reason, uint256 timestamp);

    event AgreementSlashed(
        bytes32 indexed agreementId, address indexed slashee, uint256 penaltyAmount, uint256 timestamp
    );

    event AgreementAmended(
        bytes32 indexed agreementId, bytes32 indexed newAgreementId, uint256 newVersion, uint256 timestamp
    );

    // ── v0.3-langgraph-injection: checkpoint 事件 ──
    event CheckpointRecorded(
        bytes32 indexed agreementId, uint256 seq, uint8 node, bytes32 stateHash, uint256 timestamp
    );

    event ReplayCompleted(bytes32 indexed agreementId, uint256 fromSeq, uint256 toSeq);

    // ═══════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════

    modifier onlyParty(bytes32 agreementId) {
        require(isParty(agreementId, msg.sender), "Agreement: caller is not a party");
        _;
    }

    modifier onlyState(bytes32 agreementId, AgreementState expectedState) {
        require(agreements[agreementId].state == expectedState, "Agreement: invalid state");
        _;
    }

    modifier agreementExists(bytes32 agreementId) {
        require(agreements[agreementId].createdAt > 0, "Agreement: does not exist");
        _;
    }

    // ═══════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════

    /// @dev 生成协议ID
    function _generateAgreementId(address creator, string memory title, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("agmt_", creator, title, nonce, block.timestamp));
    }

    /// @dev 生成条款ID
    function _generateTermId(bytes32 agreementId, uint256 index) internal pure returns (bytes32) {
        return bytes32(TERM_ID_PREFIX | uint256(keccak256(abi.encodePacked(agreementId, index))));
    }

    /// @dev 计算协议哈希（用于签名验证，排除可变字段）
    /// @dev EIP-712: 构建Agreement类型哈希
    function _computeAgreementHash(Agreement storage agreement) internal view returns (bytes32) {
        bytes memory partyData;
        for (uint256 i = 0; i < agreement.parties.length; i++) {
            partyData = abi.encodePacked(partyData, agreement.parties[i].agentAddr, uint8(agreement.parties[i].role));
        }

        bytes memory termData;
        for (uint256 i = 0; i < agreement.terms.length; i++) {
            termData = abi.encodePacked(
                termData,
                agreement.terms[i].termId,
                uint8(agreement.terms[i].termType),
                agreement.terms[i].value,
                agreement.terms[i].dueDate
            );
        }

        bytes32 partyHash = keccak256(partyData);
        bytes32 termHash = keccak256(termData);

        return keccak256(
            abi.encode(
                AGREEMENT_TYPEHASH,
                agreement.agreementId,
                keccak256(bytes(agreement.title)),
                keccak256(bytes(agreement.description)),
                partyHash,
                termHash,
                agreement.totalValue,
                agreement.version,
                agreement.previousVersionHash
            )
        );
    }

    /// @dev 检查地址是否为协议参与方
    function isParty(bytes32 agreementId, address addr) public view returns (bool) {
        Agreement storage ag = agreements[agreementId];
        for (uint256 i = 0; i < ag.parties.length; i++) {
            if (ag.parties[i].agentAddr == addr) {
                return true;
            }
        }
        return false;
    }

    /// @dev 检查是否达到多签阈值 (M-of-N)
    function _isFullySigned(Agreement storage agreement) internal view returns (bool) {
        uint256 count = 0;
        for (uint256 i = 0; i < agreement.parties.length; i++) {
            if (agreement.parties[i].signature.length > 0) {
                count++;
            }
        }
        return count >= requiredSignatures;
    }

    /// @dev EIP-712 签名验证（替代旧 ecrecover + personal_sign）
    /// M4 (2026-09-25): OZ ECDSA.tryRecover 强制规范 low-s 与 v∈{27,28}，
    /// 使可延展（high-s）签名被直接拒绝（旧手写 ecrecover 无此校验）。
    function _verifyEIP712Signature(bytes32 structHash, bytes memory signature, address signer)
        internal
        view
        returns (bool)
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer && recovered != address(0);
    }

    // ═══════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════

    /// @notice 创建新协议（draft状态）
    /// @param title 协议标题
    /// @param description 协议描述
    /// @param parties 参与方列表
    /// @param terms 条款列表
    /// @param totalValue 总价值（YUAN wei）
    /// @return agreementId 生成的协议ID
    function createAgreement(
        string calldata title,
        string calldata description,
        AgentParty[] calldata parties,
        SettlementTerm[] calldata terms,
        uint256 totalValue
    ) external returns (bytes32) {
        require(parties.length >= 2, "Agreement: need at least 2 parties");
        require(terms.length > 0, "Agreement: need at least 1 term");

        bytes32 id = _generateAgreementId(msg.sender, title, agreementCount);
        require(agreements[id].createdAt == 0, "Agreement: ID collision");

        // 创建协议存储
        Agreement storage ag = agreements[id];
        ag.agreementId = id;
        ag.title = title;
        ag.description = description;
        ag.state = AgreementState.Draft;
        ag.totalValue = totalValue;
        ag.createdAt = block.timestamp;
        ag.updatedAt = block.timestamp;
        ag.version = 1;

        // 复制参与方
        for (uint256 i = 0; i < parties.length; i++) {
            ag.parties
                .push(
                    AgentParty({
                        agentAddr: parties[i].agentAddr, role: parties[i].role, signature: new bytes(0), signedAt: 0
                    })
                );
        }

        // 复制条款
        for (uint256 i = 0; i < terms.length; i++) {
            ag.terms
                .push(
                    SettlementTerm({
                        termId: _generateTermId(id, i),
                        termType: terms[i].termType,
                        description: terms[i].description,
                        value: terms[i].value,
                        dueDate: terms[i].dueDate,
                        completed: false,
                        completedAt: 0
                    })
                );
        }

        // 计算哈希
        ag.agreementHash = _computeAgreementHash(ag);

        allAgreementIds.push(id);
        agentAgreements[msg.sender].push(id);
        agreementCount++;

        emit AgreementCreated(id, msg.sender, title, totalValue, block.timestamp);
        return id;
    }

    /// @notice 将协议推进到Proposed状态
    function propose(bytes32 agreementId)
        external
        agreementExists(agreementId)
        onlyParty(agreementId)
        onlyState(agreementId, AgreementState.Draft)
    {
        Agreement storage ag = agreements[agreementId];
        ag.state = AgreementState.Proposed;
        ag.updatedAt = block.timestamp;

        emit AgreementProposed(agreementId, msg.sender, block.timestamp);
        // v0.3: 图节点已转移 → 自动落 checkpoint
        _autoCheckpoint(agreementId, GraphNode.Validate);
    }

    /// @notice 参与方签署协议
    /// @param agreementId 协议ID
    /// @param signature ECDSA签名（65字节）
    function signAgreement(bytes32 agreementId, bytes calldata signature)
        external
        agreementExists(agreementId)
        onlyParty(agreementId)
        onlyState(agreementId, AgreementState.Proposed)
    {
        Agreement storage ag = agreements[agreementId];

        // 验证签名
        require(_verifyEIP712Signature(ag.agreementHash, signature, msg.sender), "Agreement: invalid EIP-712 signature");

        // 记录签名 + 多签计数
        for (uint256 i = 0; i < ag.parties.length; i++) {
            if (ag.parties[i].agentAddr == msg.sender) {
                require(ag.parties[i].signature.length == 0, "Agreement: already signed");
                ag.parties[i].signature = signature;
                ag.parties[i].signedAt = block.timestamp;
                agreementSigCount[agreementId]++;
                break;
            }
        }

        ag.updatedAt = block.timestamp;

        emit AgreementSigned(agreementId, msg.sender, ag.parties[0].role, block.timestamp);

        // M-of-N 阈值达成 → 自动进入Executed
        if (_isFullySigned(ag)) {
            ag.state = AgreementState.Executed;
            emit AgreementExecuted(agreementId, block.timestamp);
        }
    }

    /// @notice 标记条款完成
    function completeTerm(bytes32 agreementId, bytes32 termId)
        external
        agreementExists(agreementId)
        onlyParty(agreementId)
        onlyState(agreementId, AgreementState.Executed)
    {
        Agreement storage ag = agreements[agreementId];

        for (uint256 i = 0; i < ag.terms.length; i++) {
            if (ag.terms[i].termId == termId) {
                require(!ag.terms[i].completed, "Agreement: term already completed");
                ag.terms[i].completed = true;
                ag.terms[i].completedAt = block.timestamp;
                ag.updatedAt = block.timestamp;
                emit TermCompleted(agreementId, termId, block.timestamp);
                break;
            }
        }

        // 检查所有条款是否完成
        _checkCompletion(agreementId);
    }

    /// @notice 批量完成条款（一次交易中标记多个条款）
    function completeTerms(bytes32 agreementId, bytes32[] calldata termIds)
        external
        agreementExists(agreementId)
        onlyParty(agreementId)
        onlyState(agreementId, AgreementState.Executed)
    {
        for (uint256 i = 0; i < termIds.length; i++) {
            // 内部调用标记每个条款
            Agreement storage ag = agreements[agreementId];
            for (uint256 j = 0; j < ag.terms.length; j++) {
                if (ag.terms[j].termId == termIds[i] && !ag.terms[j].completed) {
                    ag.terms[j].completed = true;
                    ag.terms[j].completedAt = block.timestamp;
                    emit TermCompleted(agreementId, termIds[i], block.timestamp);
                    break;
                }
            }
        }

        agreements[agreementId].updatedAt = block.timestamp;
        _checkCompletion(agreementId);
    }

    function _checkCompletion(bytes32 agreementId) internal {
        Agreement storage ag = agreements[agreementId];
        for (uint256 i = 0; i < ag.terms.length; i++) {
            if (!ag.terms[i].completed) return;
        }
        ag.state = AgreementState.Completed;
        emit AgreementCompleted(agreementId, block.timestamp);
    }

    /// @notice 由托管合约把自身绑定到协议（createAndFund 时调用）
    /// @dev 修复：escrowContract 字段原本永无写入，导致 markSettled 恒失败
    function bindEscrow(bytes32 agreementId, address escrowAddr) external agreementExists(agreementId) {
        // 仅允许：任一协议参与方，或 escrowAddr 自身（createAndFund 内部由 escrow 调用时 msg.sender=escrow）
        require(isParty(agreementId, msg.sender) || msg.sender == escrowAddr, "Agreement: unauthorized bind");
        require(escrowAddr != address(0), "Agreement: zero escrow");
        require(agreements[agreementId].escrowContract == address(0), "Agreement: escrow already bound");
        agreements[agreementId].escrowContract = escrowAddr;
        agreements[agreementId].updatedAt = block.timestamp;
    }

    /// @notice 标记结算完成（由托管合约调用）
    function markSettled(bytes32 agreementId)
        external
        agreementExists(agreementId)
        onlyState(agreementId, AgreementState.Completed)
    {
        // 仅允许关联的托管合约调用
        require(agreements[agreementId].escrowContract == msg.sender, "Agreement: only escrow contract");

        agreements[agreementId].state = AgreementState.Settled;
        agreements[agreementId].updatedAt = block.timestamp;

        // 找到Consumer和Provider用于事件
        Agreement storage ag = agreements[agreementId];
        address payer;
        address payee;
        for (uint256 i = 0; i < ag.parties.length; i++) {
            if (ag.parties[i].role == PartyRole.Consumer) payer = ag.parties[i].agentAddr;
            if (ag.parties[i].role == PartyRole.Provider) payee = ag.parties[i].agentAddr;
        }

        emit AgreementSettled(agreementId, payer, payee, ag.totalValue, block.timestamp);
        // v0.3: 结算节点完成 → 自动落 checkpoint
        _autoCheckpoint(agreementId, GraphNode.Settle);
    }

    /// @notice 取消协议（仅draft或proposed状态）
    function cancelAgreement(bytes32 agreementId) external agreementExists(agreementId) onlyParty(agreementId) {
        Agreement storage ag = agreements[agreementId];
        require(
            ag.state == AgreementState.Draft || ag.state == AgreementState.Proposed,
            "Agreement: can only cancel draft/proposed"
        );

        ag.state = AgreementState.Cancelled;
        ag.updatedAt = block.timestamp;

        emit AgreementCancelled(agreementId, msg.sender, block.timestamp);
    }

    /// @notice 发起争议
    function disputeAgreement(bytes32 agreementId, string calldata reason)
        external
        agreementExists(agreementId)
        onlyParty(agreementId)
        onlyState(agreementId, AgreementState.Executed)
    {
        Agreement storage ag = agreements[agreementId];
        ag.state = AgreementState.Disputed;
        ag.updatedAt = block.timestamp;

        emit AgreementDisputed(agreementId, msg.sender, reason, block.timestamp);
    }

    /// @notice 修订协议（创建新版本）
    function amendAgreement(
        bytes32 agreementId,
        string calldata newTitle,
        string calldata newDescription,
        SettlementTerm[] calldata newTerms,
        uint256 newTotalValue
    ) external agreementExists(agreementId) onlyParty(agreementId) returns (bytes32 newId) {
        Agreement storage ag = agreements[agreementId];
        require(
            ag.state == AgreementState.Draft || ag.state == AgreementState.Proposed,
            "Agreement: can only amend draft/proposed"
        );

        // 复制参与方信息
        AgentParty[] memory parties = new AgentParty[](ag.parties.length);
        for (uint256 i = 0; i < ag.parties.length; i++) {
            parties[i] = AgentParty({
                agentAddr: ag.parties[i].agentAddr,
                role: ag.parties[i].role,
                signature: new bytes(0), // 新版本需要重新签名
                signedAt: 0
            });
        }

        // 创建修订版本
        newId = this.createAgreement(newTitle, newDescription, parties, newTerms, newTotalValue);
        agreements[newId].version = ag.version + 1;
        agreements[newId].previousVersionHash = ag.agreementHash;

        emit AgreementAmended(agreementId, newId, agreements[newId].version, block.timestamp);
        return newId;
    }

    // ═══════════════════════════════════════════════════
    // v0.3-langgraph-injection: CHECKPOINT 状态图（LangGraph checkpoint 映射）
    // ═══════════════════════════════════════════════════

    /// @dev 计算当前协议的状态哈希（幂等键的一部分，防篡改/防重放）
    function _computeStateHash(Agreement storage ag) internal view returns (bytes32) {
        return
            keccak256(abi.encode(ag.agreementHash, uint8(ag.state), ag.totalValue, ag.escrowContract, ag.checkpointSeq));
    }

    /// @dev 从 GraphNode 计算状态哈希（供 recordCheckpoint 用）
    function _computeNodeHash(Agreement storage ag, GraphNode node) internal view returns (bytes32) {
        return keccak256(abi.encode(ag.agreementId, uint8(node), uint8(ag.state), ag.totalValue, ag.checkpointSeq));
    }

    /// @notice 记录一个状态图检查点（由状态转移函数内部调用）
    /// @dev 每个节点完成时调用，append-only 写入 checkpoints[] 账本
    function recordCheckpoint(bytes32 agreementId, GraphNode node)
        external
        agreementExists(agreementId)
        returns (uint256 seq)
    {
        Agreement storage ag = agreements[agreementId];
        // 允许：任一参与方 或 关联 escrow
        require(
            isParty(agreementId, msg.sender) || msg.sender == ag.escrowContract, "Agreement: unauthorized checkpoint"
        );
        // 防重放：同节点不重复记录（除非 replaying 重放模式）
        if (!ag.replaying && ag.checkpoints.length > 0) {
            Checkpoint storage last = ag.checkpoints[ag.checkpoints.length - 1];
            require(uint8(last.node) != uint8(node), "Agreement: checkpoint already recorded");
        }
        seq = ag.checkpointSeq + 1;
        ag.checkpointSeq = seq;
        ag.checkpoints
            .push(
                Checkpoint({
                    seq: seq,
                    node: node,
                    state: ag.state,
                    stateHash: _computeNodeHash(ag, node),
                    recordedAt: block.timestamp
                })
            );
        ag.updatedAt = block.timestamp;
        emit CheckpointRecorded(
            agreementId, seq, uint8(node), ag.checkpoints[ag.checkpoints.length - 1].stateHash, block.timestamp
        );
        return seq;
    }

    /// @notice 获取最新检查点（恢复点）
    function getLatestCheckpoint(bytes32 agreementId)
        external
        view
        agreementExists(agreementId)
        returns (uint256 seq, uint8 node, bytes32 stateHash)
    {
        Checkpoint[] storage cps = agreements[agreementId].checkpoints;
        if (cps.length == 0) return (0, 0, bytes32(0));
        Checkpoint storage last = cps[cps.length - 1];
        return (last.seq, uint8(last.node), last.stateHash);
    }

    /// @notice 获取全部检查点（审计/回放）
    function getCheckpoints(bytes32 agreementId)
        external
        view
        agreementExists(agreementId)
        returns (Checkpoint[] memory)
    {
        return agreements[agreementId].checkpoints;
    }

    /// @notice 幂等重放：恢复到指定检查点后，重放剩余节点（不重算不双花）
    /// @dev LangGraph checkpoint 的 resilient 语义：
    ///      网络中断/节点重启后，从最近 checkpoint 恢复，不回滚已结算、不重复已执行节点。
    function replayTo(bytes32 agreementId, uint256 targetSeq)
        external
        agreementExists(agreementId)
        onlyParty(agreementId)
        returns (uint256 reachedSeq)
    {
        Agreement storage ag = agreements[agreementId];
        uint256 lastSeq = ag.checkpointSeq;
        require(targetSeq <= lastSeq, "Agreement: targetSeq beyond recorded");
        if (targetSeq == lastSeq && !ag.replaying) {
            return lastSeq;
        }
        if (targetSeq < lastSeq && !ag.replaying) {
            // 目标早于当前 → 校验目标检查点状态哈希是否一致（防篡改回滚）
            Checkpoint storage target = ag.checkpoints[targetSeq - 1];
            require(target.stateHash == _computeNodeHash(ag, target.node), "Agreement: checkpoint hash mismatch");
            ag.checkpointSeq = targetSeq; // 回滚序列（仅序列，不回滚资金）
            ag.replaying = true;
            emit ReplayCompleted(agreementId, lastSeq, targetSeq);
        }
        ag.replaying = false;
        return ag.checkpointSeq;
    }

    /// @notice 查询协议已记录的检查点数量
    function getCheckpointCount(bytes32 agreementId) external view agreementExists(agreementId) returns (uint256) {
        return agreements[agreementId].checkpoints.length;
    }

    /// @dev 内部版 recordCheckpoint（状态转移函数使用，免重复权限检查）
    function _autoCheckpoint(bytes32 agreementId, GraphNode node) internal {
        Agreement storage ag = agreements[agreementId];
        if (ag.checkpoints.length > 0) {
            Checkpoint storage last = ag.checkpoints[ag.checkpoints.length - 1];
            if (uint8(last.node) == uint8(node)) return; // 幂等：同节点不重复记录
        }
        uint256 seq = ag.checkpointSeq + 1;
        ag.checkpointSeq = seq;
        ag.checkpoints
            .push(
                Checkpoint({
                    seq: seq,
                    node: node,
                    state: ag.state,
                    stateHash: _computeNodeHash(ag, node),
                    recordedAt: block.timestamp
                })
            );
        emit CheckpointRecorded(
            agreementId, seq, uint8(node), ag.checkpoints[ag.checkpoints.length - 1].stateHash, block.timestamp
        );
    }

    // ═══════════════════════════════════════════════════
    // POST-JUMP helpers (CHECKPOINT)
    // ═══════════════════════════════════════════════════

    /// @notice 获取协议完整信息
    function getAgreement(bytes32 agreementId) external view agreementExists(agreementId) returns (Agreement memory) {
        return agreements[agreementId];
    }

    /// @notice 获取协议参与方
    function getParties(bytes32 agreementId) external view returns (AgentParty[] memory) {
        return agreements[agreementId].parties;
    }

    /// @notice 获取协议条款
    function getTerms(bytes32 agreementId) external view returns (SettlementTerm[] memory) {
        return agreements[agreementId].terms;
    }

    /// @notice 获取Agent参与的所有协议
    function getAgentAgreements(address agent) external view returns (bytes32[] memory) {
        return agentAgreements[agent];
    }

    /// @notice 获取协议总数
    function getAgreementCount() external view returns (uint256) {
        return agreementCount;
    }

    /// @notice 验证单个参与方签名
    function verifySignature(bytes32 agreementId, address signer)
        external
        view
        agreementExists(agreementId)
        returns (bool)
    {
        Agreement storage ag = agreements[agreementId];
        for (uint256 i = 0; i < ag.parties.length; i++) {
            if (ag.parties[i].agentAddr == signer) {
                return ag.parties[i].signature.length > 0;
            }
        }
        return false;
    }

    /// @notice 检查协议是否完全签署
    function isFullySigned(bytes32 agreementId) external view agreementExists(agreementId) returns (bool) {
        return _isFullySigned(agreements[agreementId]);
    }

    /// @notice 检查是否所有条款完成
    function areAllTermsCompleted(bytes32 agreementId) external view agreementExists(agreementId) returns (bool) {
        Agreement storage ag = agreements[agreementId];
        for (uint256 i = 0; i < ag.terms.length; i++) {
            if (!ag.terms[i].completed) return false;
        }
        return true;
    }

    /// @notice 获取EIP-712域分隔符
    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    /// @notice 获取已签名计数 (M-of-N)
    function getSignatureCount(bytes32 agreementId) external view agreementExists(agreementId) returns (uint256) {
        return agreementSigCount[agreementId];
    }

    /// @notice 设置多签阈值（治理调用）
    function setRequiredSignatures(uint256 newThreshold) external {
        require(newThreshold >= 2, "Agreement: need at least 2 signatures");
        requiredSignatures = newThreshold;
    }
}
