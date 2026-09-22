// SPDX-License-Identifier: ORIGIN-1.0
// ORIGIN L5 · CreditScore.sol
// 量子总督 👽 · 2026-08-29
// 定位：信用评分层 —— 读 AgentIdentity 链上行为 → 算 4 维加权信用分 → 映射 YUAN 可调动上限
// 原则：不改动 AgentIdentity，通过 interface 读其 public getter，实现「定价权落地」

pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice 从 CreditScore 视角读取 AgentIdentity：仅声明需要读取的字段视图与 getter
/// @dev 字段视图顺序必须与 AgentIdentity.Agent 逐一对应，ABI 才能正确解码
struct AgentView {
    uint256 totalRevenue;
    uint256 totalTransactions;
    uint256 totalSuccessful;
    uint256 reputationScore;
    uint256 stakedAmount;
    uint256 endorsementCount;
    uint256 longevityBonus;
    uint256 slashCount;
    uint256 contributionClockScore;
    uint256 totalQuality;
    uint256 totalComplexity;
    uint256 totalTimeliness;
}

/// @notice 与被调合约 AgentIdentity 对齐的最小接口（只读所需 getter）
interface IAgentIdentity {
    function agents(address agentAddr) external view returns (AgentView memory);
    function getAgentStatus(address agentAddr) external view returns (uint8 status);
}

/// @title CreditScore — 智能体信用评分（信用分 → YUAN 调动上限）
/// @notice 信用分 = 任务成功率×W1 + 质量×W2 + 稳定性×W3 + 贡献×W4 - 惩罚(slash/投诉)
///         信用分直接决定智能体可调动的 YUAN 上限 → 「高信用→更多机会→更高收入→更高信用」正循环
/// @dev 不修改 AgentIdentity；通过 IAgentIdentity interface 读其 agents() public getter
contract CreditScore is Ownable {
    /* ============ 能力=只读引用（接口已提到文件顶层） ============ */
    /* ============ 常量 ============ */
    uint256 public constant SCORE_MAX = 10000; // 信用分上限 0-10000
    uint256 public constant W_DENOM = 10000; // 权重分母（basis points）

    /* ============ 状态 ============ */
    IAgentIdentity public identity;

    // 4 维权重重心（basis points，和 = W_DENOM）
    uint256 public wSuccess; // 任务成功率权重
    uint256 public wQuality; // 质量权重
    uint256 public wStability; // 稳定性权重
    uint256 public wContribution; // 贡献时钟权重
    uint256 public slashPenalty; // 每次 slash 扣分

    // 信用分 → 每 1000 分可调动的 YUAN 基准额（治理可调）
    // 例：creditLimitPerK = 1000 → 信用分 10000 的 agent 可调动 10000 YUAN
    uint256 public creditLimitPerK;

    // 额度快照：最后一次计算的信用分
    mapping(address => uint256) public creditScore;
    mapping(address => uint256) public lastUpdated;

    /* ============ 事件 ============ */
    event CreditCalculated(address indexed agent, uint256 score, uint256 limit, uint256 timestamp);
    event IdentitySet(address indexed identity);
    event WeightsSet(uint256 wSuccess, uint256 wQuality, uint256 wStability, uint256 wContribution);
    event SlashPenaltySet(uint256 penalty);

    /* ============ 构造 ============ */
    constructor(address identity_) Ownable(msg.sender) {
        identity = IAgentIdentity(identity_);
        wSuccess = 4000; // 40%
        wQuality = 3000; // 30%
        wStability = 2000; // 20%
        wContribution = 1000; // 10%
        slashPenalty = 500; // 每次 slash 扣 500 分
        creditLimitPerK = 1000; // 每 1000 信用分 = 1000 YUAN 调动上限
    }

    /* ============ 治理 ============ */
    function setIdentity(address identity_) external onlyOwner {
        require(identity_ != address(0), "CreditScore: zero identity");
        identity = IAgentIdentity(identity_);
        emit IdentitySet(identity_);
    }

    function setWeights(uint256 _wSuccess, uint256 _wQuality, uint256 _wStability, uint256 _wContribution)
        external
        onlyOwner
    {
        uint256 total = _wSuccess + _wQuality + _wStability + _wContribution;
        require(total == W_DENOM, "CreditScore: weights must sum to 10000");
        wSuccess = _wSuccess;
        wQuality = _wQuality;
        wStability = _wStability;
        wContribution = _wContribution;
        emit WeightsSet(_wSuccess, _wQuality, _wStability, _wContribution);
    }

    function setSlashPenalty(uint256 penalty) external onlyOwner {
        slashPenalty = penalty;
        emit SlashPenaltySet(penalty);
    }

    function setCreditLimitPerK(uint256 limit) external onlyOwner {
        creditLimitPerK = limit;
    }

    /* ============ 核心：计算信用分 ============ */
    /// @notice 计算某 Agent 的信用分并持久化，返回分数与可调动 YUAN 上限
    function calculateCredit(address agentAddr) external returns (uint256 score, uint256 limit) {
        AgentView memory a = identity.agents(agentAddr);

        // 维度1：成功率 [0-1 scaled]
        uint256 successRate = a.totalTransactions == 0
            ? 5000  // 无历史按中性 0.5
            : (a.totalSuccessful * W_DENOM) / a.totalTransactions;

        // 维度2：质量（totalQuality 累计，规格化为 0-10000）
        uint256 qualityScore = a.totalQuality > 10000 ? 10000 : a.totalQuality;

        // 维度3：稳定性（总交易越多、slash 越少越稳）
        uint256 stabilityScore = 3000; // 基分
        if (a.totalTransactions >= 10) stabilityScore += 3000;
        if (a.totalTransactions >= 100) stabilityScore += 2000;
        if (a.endorsementCount > 0) {
            stabilityScore += (a.endorsementCount * 500 > 2000 ? 2000 : a.endorsementCount * 500);
        }
        if (stabilityScore > 10000) stabilityScore = 10000;

        // 维度4：贡献时钟 [0-10000]
        uint256 contributionScore = a.contributionClockScore > 10000 ? 10000 : a.contributionClockScore;

        // 加权合成
        uint256 composite =
            ((successRate * wSuccess)
                    + (qualityScore * wQuality)
                    + (stabilityScore * wStability)
                    + (contributionScore * wContribution)) / W_DENOM;

        // 惩罚：slash
        if (a.slashCount > 0) {
            uint256 penalty = a.slashCount * slashPenalty;
            composite = composite > penalty ? composite - penalty : 0;
        }

        // 封顶
        if (composite > SCORE_MAX) composite = SCORE_MAX;

        // 信用分 → YUAN 调动上限
        limit = (composite * creditLimitPerK) / 1000;

        creditScore[agentAddr] = composite;
        lastUpdated[agentAddr] = block.timestamp;
        emit CreditCalculated(agentAddr, composite, limit, block.timestamp);
        return (composite, limit);
    }

    /* ============ 查询 ============ */
    function getCreditScore(address agentAddr) external view returns (uint256) {
        return creditScore[agentAddr];
    }

    function getCreditLimit(address agentAddr) external view returns (uint256) {
        return (creditScore[agentAddr] * creditLimitPerK) / 1000;
    }
}
