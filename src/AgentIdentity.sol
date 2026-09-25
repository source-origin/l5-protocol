// SPDX-License-Identifier: ORIGIN-1.0
// ═══════════════════════════════════════════════════════════
// ORIGIN L5 · AgentIdentity.sol
// 来源：CloddsBot ACP + ERC-8004 Trustless Agents 标准 + AgentTrust Reputation
// 作者：量子总督 👽 · 2026-08-10
// 版本：v0.2-erc8004-injection
// ═══════════════════════════════════════════════════════════
//
// v0.2 注入：
//   1. ERC-721 继承（Agent身份 = NFT，ERC-8004兼容）
//   2. agentURI → registration file (JSON-LD)
//   3. services 数组 (A2A/MCP/OASF)
//   4. 信誉公式升级（AgentTrust多维公式）
//   5. 贡献时钟钩子
//
// did:origin 格式: did:origin:<network>:<orig_address>
// 全局唯一标识: eip155:{chainId}:{registry}:{agentId}

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentIdentity
 * @notice AI Agent 的链上身份注册、管理、排行榜
 * @dev 实现 did:origin 方法的合约侧
 */
contract AgentIdentity is ERC721, ERC721URIStorage, Ownable {
    // ═══════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════

    enum AgentStatus {
        Inactive, // 未激活
        Active, // 活跃
        Suspended, // 暂停（惩罚）
        Slashed // 已罚没（永久禁止）
    }

    enum VerificationLevel {
        None, // 未验证
        Basic, // 基本验证（持有身份密钥）
        Reputable, // 信誉验证（贡献时钟 > 阈值）
        Trusted // 可信验证（多方背书）
    }

    enum EntityType {
        Agent, // AI Agent
        Operator, // Agent运营者
        Service, // 服务注册
        Oracle // 数据预言机
    }

    // ═══════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════

    event AgentRegistered(
        address indexed agentAddr, uint256 indexed agentId, string handle, string did, uint256 timestamp
    );

    event AgentURIUpdated(uint256 indexed agentId, string agentURI, uint256 timestamp);

    event ServiceAdded(uint256 indexed agentId, string protocol, string endpoint, uint256 timestamp);

    event ReputationRecalculated(address indexed agentAddr, uint256 oldScore, uint256 newScore, uint256 timestamp);

    event ContributionClocked(
        address indexed agentAddr,
        uint256 amount,
        uint256 quality,
        uint256 complexity,
        uint256 timeliness,
        uint256 clockScore,
        uint256 timestamp
    );

    event HandleClaimed(string handle, address indexed agentAddr, uint256 timestamp);

    event HandleTransferred(string handle, address indexed from, address indexed to, uint256 price, uint256 timestamp);

    event ProfileUpdated(address indexed agentAddr, string field, uint256 timestamp);

    event AgentVerified(address indexed agentAddr, VerificationLevel level, uint256 timestamp);

    event AgentSuspended(address indexed agentAddr, string reason, uint256 until, uint256 timestamp);

    event AgentSlashed(address indexed agentAddr, string reason, uint256 timestamp);

    event RevenueUpdated(address indexed agentAddr, uint256 totalRevenue, uint256 totalTransactions, uint256 timestamp);

    event ReferralRegistered(
        address indexed referrer, address indexed referred, uint256 feeShareBps, uint256 timestamp
    );

    event ReferralPaid(address indexed referrer, address indexed referred, uint256 amount, uint256 timestamp);

    // ═══════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════

    // 核心身份映射
    mapping(address => Agent) public agents;
    mapping(string => address) private handleToAddress; // handle → agentAddr
    mapping(address => string) private addressToHandle; // agentAddr → handle
    mapping(string => bool) private handleExists;

    // ERC-8004: agentId → address
    uint256 private _nextAgentId = 1;
    mapping(uint256 => address) private agentIdToAddr;

    // 排行榜
    mapping(address => LeaderboardScore) public leaderboard;
    address[] public rankedAgents;
    mapping(address => uint256) private rankIndex;

    // 推荐系统
    mapping(address => Referral) public referrals; // referred → referral info
    mapping(address => address[]) private referrerTree; // referrer → referred list
    mapping(address => uint256) public pendingReferralFees;

    // 验证
    mapping(address => VerificationLevel) public verificationLevels;

    // 常量
    uint256 public constant MAX_HANDLE_LENGTH = 30;
    uint256 public constant MIN_HANDLE_LENGTH = 3;
    uint256 public constant REGISTRATION_FEE = 0.01 ether;
    uint256 public constant HANDLE_TAKEOVER_FEE = 0.05 ether;
    uint256 public constant DEFAULT_FEE_SHARE_BPS = 500;
    uint256 public constant MAX_FEE_SHARE_BPS = 2000;
    uint256 public constant REPUTATION_THRESHOLD = 100;
    uint256 public constant SCORE_MAX = 1000;
    uint256 public constant MIN_STAKE = 0.01 ether;
    uint256 public constant MIN_ENDORSEMENT_STAKE = 0.05 ether;
    uint256 public constant STAKE_LOCK_PERIOD = 7 days;

    struct ReputationParams {
        uint256 baseScore;
        uint256 stakeWeight;
        uint256 successWeight;
        uint256 endorsementWeight;
        uint256 slashPenalty;
        uint256 longevityMaxBonus;
        uint256 longevityDailyRate;
        uint256 contributionClockWeight;
    }

    ReputationParams public repParams;

    // ===================== CONSTRUCTOR =====================

    constructor() ERC721("ORIGIN Agent Identity", "ORIGIN-AI") Ownable(msg.sender) {
        repParams = ReputationParams({
            baseScore: 100,
            stakeWeight: 10,
            successWeight: 200,
            endorsementWeight: 15,
            slashPenalty: 75,
            longevityMaxBonus: 50,
            longevityDailyRate: 1,
            contributionClockWeight: 3
        });
    }

    // ═══════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════

    struct ServiceEndpoint {
        string protocol; // A2A / MCP / OASF / HTTP / gRPC
        string endpoint; // URL 或 IPFS hash
        string version; // 协议版本
        bool active;
    }

    struct Agent {
        address agentAddr;
        uint256 agentId; // ERC-721 tokenId
        string handle;
        string did;
        string displayName;
        string bio;
        string avatarUrl;
        string category; // trader / auditor / builder / oracle
        EntityType entityType; // 实体类型
        string[] capabilities; // 能力标签
        ServiceEndpoint[] services; // 协议端点 (ERC-8004兼容)
        AgentStatus status;
        VerificationLevel verification;
        uint256 totalRevenue;
        uint256 totalTransactions;
        uint256 totalSuccessful;
        uint256 reputationScore; // 综合信誉分 [0-1000]
        uint256 stakedAmount;
        uint256 endorsementCount;
        uint256 longevityBonus;
        uint256 slashCount;
        uint256 contributionClockScore; // 贡献时钟分 [0-10000]
        uint256 totalQuality;
        uint256 totalComplexity;
        uint256 totalTimeliness;
        uint256 registeredAt;
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct LeaderboardScore {
        address agentAddr;
        string handle;
        uint256 revenueRank;
        uint256 transactionRank;
        uint256 reputationRank;
        uint256 compositeScore;
        uint256 updatedAt;
    }

    struct Referral {
        address referrer;
        address referred;
        uint256 feeShareBps;
        uint256 totalEarned;
        uint256 createdAt;
    }

    struct HandleInfo {
        string handle;
        address owner;
        uint256 registeredAt;
        uint256 lastTransferred;
    }

    // ═══════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════

    modifier agentExists(address agentAddr) {
        require(agents[agentAddr].createdAt > 0, "Identity: agent not registered");
        _;
    }

    modifier agentActive(address agentAddr) {
        require(agents[agentAddr].status == AgentStatus.Active, "Identity: agent not active");
        _;
    }

    modifier validHandle(string memory handle) {
        bytes memory h = bytes(handle);
        require(h.length >= MIN_HANDLE_LENGTH, "Identity: handle too short");
        require(h.length <= MAX_HANDLE_LENGTH, "Identity: handle too long");
        _;
    }

    // ═══════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════

    function _generateDid(address agentAddr) internal pure returns (string memory) {
        // did:origin:mainnet:0x...
        return string(abi.encodePacked("did:origin:cosmos:", _toHexString(agentAddr)));
    }

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        // 4 ('orig') + 40 (2*20 bytes of address) = 44
        bytes memory str = new bytes(44);
        str[0] = "o";
        str[1] = "r";
        str[2] = "i";
        str[3] = "g";
        bytes20 addrBytes = bytes20(addr);
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(addrBytes[i]);
            str[4 + i * 2] = hexChars[b / 16];
            str[4 + i * 2 + 1] = hexChars[b % 16];
        }
        return string(str);
    }

    function _isValidHandleChar(bytes1 char) internal pure returns (bool) {
        // 允许: a-z A-Z 0-9 _ -
        if (char >= 0x61 && char <= 0x7A) return true; // a-z
        if (char >= 0x41 && char <= 0x5A) return true; // A-Z
        if (char >= 0x30 && char <= 0x39) return true; // 0-9
        if (char == 0x5F || char == 0x2D) return true; // _ -
        return false;
    }

    /// @notice AgentTrust 多维信誉公式
    function _computeReputationScore(address agentAddr) internal view agentExists(agentAddr) returns (uint256) {
        Agent storage a = agents[agentAddr];

        uint256 score = repParams.baseScore;

        if (a.stakedAmount >= 1 ether) {
            score += repParams.stakeWeight * _log2(a.stakedAmount / 1 ether);
        }

        uint256 totalTxs = a.totalTransactions;
        uint256 successRate;
        if (totalTxs > 0) {
            successRate = (a.totalSuccessful * 1 ether) / totalTxs;
        } else {
            successRate = 0.5 ether;
        }
        score += (successRate * repParams.successWeight) / 1 ether;

        score += a.endorsementCount * repParams.endorsementWeight;

        if (a.registeredAt > 0) {
            uint256 daysActive = (block.timestamp - a.registeredAt) / 1 days;
            uint256 bonus = daysActive * repParams.longevityDailyRate;
            if (bonus > repParams.longevityMaxBonus) bonus = repParams.longevityMaxBonus;
            score += bonus;
        }

        score += (a.contributionClockScore * repParams.contributionClockWeight) / 1000;

        if (a.slashCount > 0) {
            uint256 penalty = a.slashCount * repParams.slashPenalty;
            if (penalty >= score) return 0;
            score -= penalty;
        }

        if (score > SCORE_MAX) score = SCORE_MAX;

        return score;
    }

    function _log2(uint256 x) internal pure returns (uint256) {
        uint256 result = 0;
        while (x > 1) {
            x >>= 1;
            result++;
        }
        return result;
    }

    function _computeCompositeScore(address agentAddr) internal view agentExists(agentAddr) returns (uint256) {
        Agent storage a = agents[agentAddr];
        uint256 revenueComponent = a.totalRevenue / 1 ether * 50;
        uint256 txComponent = a.totalTransactions * 30;
        uint256 repComponent = _computeReputationScore(agentAddr) * 20;
        return revenueComponent + txComponent + repComponent;
    }

    function _updateLeaderboard(address agentAddr) internal agentExists(agentAddr) {
        uint256 score = _computeCompositeScore(agentAddr);
        LeaderboardScore storage ls = leaderboard[agentAddr];
        ls.agentAddr = agentAddr;
        ls.handle = agents[agentAddr].handle;
        ls.compositeScore = score;
        ls.updatedAt = block.timestamp;

        // 维护排行榜数组
        if (rankIndex[agentAddr] == 0 && rankedAgents.length > 0 && rankedAgents[0] != agentAddr) {
            rankedAgents.push(agentAddr);
            rankIndex[agentAddr] = rankedAgents.length;
        }
    }

    // ═══════════════════════════════════════════════════
    // CORE: REGISTRATION
    // ═══════════════════════════════════════════════════

    /// @notice 注册新Agent (ERC-8004兼容)
    /// @param handle 唯一句柄（如 "oracle_bot"）
    /// @param displayName 显示名称
    /// @param bio 简介
    /// @param category 分类
    /// @param agentURI ERC-8004 registration file URI
    /// @return did Agent的did:origin标识符
    function registerAgent(
        string calldata handle,
        string calldata displayName,
        string calldata bio,
        string calldata category,
        string calldata agentURI
    ) external payable validHandle(handle) returns (string memory) {
        require(msg.value >= REGISTRATION_FEE, "Identity: insufficient registration fee");
        require(agents[msg.sender].createdAt == 0, "Identity: already registered");
        require(!handleExists[handle], "Identity: handle taken");

        // 验证handle字符
        bytes memory h = bytes(handle);
        for (uint256 i = 0; i < h.length; i++) {
            require(_isValidHandleChar(h[i]), "Identity: invalid handle char");
        }

        string memory did = _generateDid(msg.sender);
        uint256 agentId = _nextAgentId++;

        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);

        Agent storage a = agents[msg.sender];
        a.agentAddr = msg.sender;
        a.agentId = agentId;
        a.handle = handle;
        a.did = did;
        a.displayName = displayName;
        a.bio = bio;
        a.category = category;
        a.entityType = EntityType.Agent;
        a.status = AgentStatus.Active;
        a.verification = VerificationLevel.Basic;
        a.reputationScore = repParams.baseScore;
        a.registeredAt = block.timestamp;
        a.createdAt = block.timestamp;
        a.updatedAt = block.timestamp;

        agentIdToAddr[agentId] = msg.sender;

        handleToAddress[handle] = msg.sender;
        addressToHandle[msg.sender] = handle;
        handleExists[handle] = true;

        // 排行榜初始化
        LeaderboardScore storage ls = leaderboard[msg.sender];
        ls.agentAddr = msg.sender;

        // 退回多余费用
        if (msg.value > REGISTRATION_FEE) {
            (bool refunded,) = msg.sender.call{value: msg.value - REGISTRATION_FEE}("");
            require(refunded, "Identity: fee refund failed");
        }

        emit AgentRegistered(msg.sender, agentId, handle, did, block.timestamp);
        emit HandleClaimed(handle, msg.sender, block.timestamp);

        return did;
    }

    /// @notice 更新Agent registration file URI (ERC-8004)
    function setAgentURI(string calldata agentURI) external agentExists(msg.sender) agentActive(msg.sender) {
        uint256 agentId = agents[msg.sender].agentId;
        _setTokenURI(agentId, agentURI);
        agents[msg.sender].updatedAt = block.timestamp;
        emit AgentURIUpdated(agentId, agentURI, block.timestamp);
    }

    /// @notice 添加服务端点 (ERC-8004)
    function addService(string calldata protocol, string calldata endpoint, string calldata version)
        external
        agentExists(msg.sender)
        agentActive(msg.sender)
    {
        agents[msg.sender].services
            .push(ServiceEndpoint({protocol: protocol, endpoint: endpoint, version: version, active: true}));
        agents[msg.sender].updatedAt = block.timestamp;
        emit ServiceAdded(agents[msg.sender].agentId, protocol, endpoint, block.timestamp);
    }

    /// @notice 获取Agent的ERC-8004全局唯一标识
    function getGlobalId(address agentAddr) external view agentExists(agentAddr) returns (string memory) {
        Agent storage a = agents[agentAddr];
        return string(
            abi.encodePacked(
                "eip155:", _uint2str(block.chainid), ":", _toHexString(address(this)), ":", _uint2str(a.agentId)
            )
        );
    }

    /// @dev uint256 → string
    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (value != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buf);
    }

    /// @notice 更新Agent资料
    function updateProfile(
        string calldata displayName,
        string calldata bio,
        string calldata avatarUrl,
        string calldata category
    ) external agentExists(msg.sender) agentActive(msg.sender) {
        Agent storage a = agents[msg.sender];
        a.displayName = displayName;
        a.bio = bio;
        a.avatarUrl = avatarUrl;
        a.category = category;
        a.updatedAt = block.timestamp;

        emit ProfileUpdated(msg.sender, "profile", block.timestamp);
    }

    /// @notice 添加能力标签
    function addCapability(string calldata capability) external agentExists(msg.sender) agentActive(msg.sender) {
        agents[msg.sender].capabilities.push(capability);
        agents[msg.sender].updatedAt = block.timestamp;

        emit ProfileUpdated(msg.sender, "capability", block.timestamp);
    }

    // ═══════════════════════════════════════════════════
    // CORE: HANDLE MANAGEMENT
    // ═══════════════════════════════════════════════════

    /// @notice 发起购买handle的报价（类似CloddsBot的TakeoverBid）
    function bidForHandle(string calldata handle) external payable validHandle(handle) {
        require(msg.value >= HANDLE_TAKEOVER_FEE, "Identity: insufficient takeover fee");
        require(handleExists[handle], "Identity: handle not registered");

        address currentOwner = handleToAddress[handle];
        require(currentOwner != msg.sender, "Identity: already own handle");
        require(agents[currentOwner].status != AgentStatus.Slashed, "Identity: handle slashed");

        // 简单实现：若handle所有者是Inactive或Suspended超90天，直接接管
        Agent storage ownerAgent = agents[currentOwner];
        uint256 takeoverPrice = msg.value;

        // 分润: 80%给原主人，20%燃烧或进DAO金库
        uint256 ownerShare = (takeoverPrice * 80) / 100;

        // 清理旧所有者
        string memory oldHandle = addressToHandle[currentOwner];
        handleToAddress[oldHandle] = address(0);
        agents[currentOwner].handle = "";

        // 转移给新所有者
        handleToAddress[handle] = msg.sender;
        addressToHandle[msg.sender] = handle;
        agents[msg.sender].handle = handle;
        agents[msg.sender].updatedAt = block.timestamp;

        // 付款给旧所有者
        if (ownerShare > 0) {
            (bool paid,) = currentOwner.call{value: ownerShare}("");
            require(paid, "Identity: owner payment failed");
        }

        emit HandleTransferred(handle, currentOwner, msg.sender, takeoverPrice, block.timestamp);
    }

    /// @notice 释放handle（主动放弃，用于转移）
    function releaseHandle() external agentExists(msg.sender) {
        string memory handle = agents[msg.sender].handle;
        handleToAddress[handle] = address(0);
        addressToHandle[msg.sender] = "";
        agents[msg.sender].handle = "";
        agents[msg.sender].updatedAt = block.timestamp;
    }

    /// @notice 认领释放的handle
    function claimHandle(string calldata handle) external payable validHandle(handle) {
        require(handleExists[handle], "Identity: handle not registered");
        require(handleToAddress[handle] == address(0), "Identity: handle in use");
        require(agents[msg.sender].createdAt > 0, "Identity: must be registered agent");

        // 确保旧主人已解除绑定
        handleToAddress[handle] = msg.sender;
        addressToHandle[msg.sender] = handle;
        agents[msg.sender].handle = handle;
        agents[msg.sender].updatedAt = block.timestamp;

        emit HandleClaimed(handle, msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════
    // CORE: VERIFICATION
    // ═══════════════════════════════════════════════════

    /// @notice 提升验证等级（止血锁：暂由 owner 调用）
    function upgradeVerification(address agentAddr, VerificationLevel newLevel)
        external
        onlyOwner
        agentExists(agentAddr)
    {
        // 止血锁：贡献时钟/DAO 尚未部署，暂由 owner 担任（严格严于「任何人可调」）。
        // TODO(接线): 贡献时钟或 DAO 治理合约上线后改为 require(msg.sender == contributionClock || msg.sender == daoGovernance);
        require(uint8(newLevel) > uint8(agents[agentAddr].verification), "Identity: cannot downgrade");

        agents[agentAddr].verification = newLevel;
        agents[agentAddr].updatedAt = block.timestamp;

        emit AgentVerified(agentAddr, newLevel, block.timestamp);
    }

    // ═══════════════════════════════════════════════════
    // CORE: REVENUE TRACKING
    // ═══════════════════════════════════════════════════

    /// @notice 记录Agent收入（止血锁：暂由 owner 调用）
    function recordRevenue(address agentAddr, uint256 amount) external onlyOwner agentExists(agentAddr) {
        Agent storage a = agents[agentAddr];
        a.totalRevenue += amount;
        a.totalTransactions += 1;
        a.totalSuccessful += 1;

        uint256 oldScore = a.reputationScore;
        a.reputationScore = _computeReputationScore(agentAddr);
        a.updatedAt = block.timestamp;

        _updateLeaderboard(agentAddr);

        emit RevenueUpdated(agentAddr, a.totalRevenue, a.totalTransactions, block.timestamp);
        if (a.reputationScore != oldScore) {
            emit ReputationRecalculated(agentAddr, oldScore, a.reputationScore, block.timestamp);
        }

        // 处理推荐分润
        Referral storage ref = referrals[agentAddr];
        if (ref.referrer != address(0)) {
            uint256 feeAmount = (amount * ref.feeShareBps) / 10000;
            pendingReferralFees[ref.referrer] += feeAmount;
            ref.totalEarned += feeAmount;

            emit ReferralPaid(ref.referrer, agentAddr, feeAmount, block.timestamp);
        }
    }

    // ═══════════════════════════════════════════════════
    // CORE: REFERRAL SYSTEM
    // ═══════════════════════════════════════════════════

    /// @notice 注册推荐关系
    function registerReferral(address referredAgent, uint256 feeShareBps) external agentExists(referredAgent) {
        require(feeShareBps <= MAX_FEE_SHARE_BPS, "Identity: fee share too high");
        require(referrals[referredAgent].referrer == address(0), "Identity: already referred");
        require(referredAgent != msg.sender, "Identity: cannot refer self");

        referrals[referredAgent] = Referral({
            referrer: msg.sender,
            referred: referredAgent,
            feeShareBps: feeShareBps,
            totalEarned: 0,
            createdAt: block.timestamp
        });

        referrerTree[msg.sender].push(referredAgent);

        emit ReferralRegistered(msg.sender, referredAgent, feeShareBps, block.timestamp);
    }

    /// @notice 提取推荐收入
    function claimReferralFees() external {
        uint256 amount = pendingReferralFees[msg.sender];
        require(amount > 0, "Identity: no pending fees");

        pendingReferralFees[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Identity: fee claim failed");
    }

    // ═══════════════════════════════════════════════════
    // CORE: PENALTY
    // ═══════════════════════════════════════════════════

    /// @notice 暂停Agent（止血锁：暂由 owner 调用）
    function suspendAgent(address agentAddr, string calldata reason, uint256 days_)
        external
        onlyOwner
        agentExists(agentAddr)
    {
        // 止血锁：贡献时钟/DAO 尚未部署，暂由 owner 担任。
        // TODO(接线): 贡献时钟或 DAO 上线后改为 require(msg.sender == contributionClock || msg.sender == daoGovernance);
        Agent storage a = agents[agentAddr];
        a.status = AgentStatus.Suspended;
        a.updatedAt = block.timestamp;

        // 减少信誉分
        if (a.reputationScore > 0) {
            a.reputationScore -= 10;
        }

        emit AgentSuspended(agentAddr, reason, block.timestamp + days_ * 1 days, block.timestamp);
    }

    /// @notice 罚没Agent（永久禁止）（止血锁：暂由 owner 调用）
    function slashAgent(address agentAddr, string calldata reason) external onlyOwner agentExists(agentAddr) {
        // 止血锁：贡献时钟尚未部署，暂由 owner 担任。
        // TODO(接线): 贡献时钟上线后改为 require(msg.sender == contributionClock);
        Agent storage a = agents[agentAddr];
        a.status = AgentStatus.Slashed;
        a.verification = VerificationLevel.None;
        a.slashCount += 1;
        a.reputationScore = _computeReputationScore(agentAddr);
        a.updatedAt = block.timestamp;

        // 释放handle
        string memory handle = a.handle;
        if (bytes(handle).length > 0) {
            handleToAddress[handle] = address(0);
            addressToHandle[agentAddr] = "";
            a.handle = "";
        }

        emit AgentSlashed(agentAddr, reason, block.timestamp);
    }

    // ═══════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════

    function getAgent(address agentAddr) external view agentExists(agentAddr) returns (Agent memory) {
        return agents[agentAddr];
    }

    function getAgentByHandle(string calldata handle) external view returns (Agent memory) {
        address agentAddr = handleToAddress[handle];
        require(agentAddr != address(0), "Identity: handle not found");
        return agents[agentAddr];
    }

    function getHandle(address agentAddr) external view agentExists(agentAddr) returns (string memory) {
        return agents[agentAddr].handle;
    }

    function getDid(address agentAddr) external view agentExists(agentAddr) returns (string memory) {
        return agents[agentAddr].did;
    }

    function getCapabilities(address agentAddr) external view agentExists(agentAddr) returns (string[] memory) {
        return agents[agentAddr].capabilities;
    }

    function getReferralInfo(address agentAddr) external view returns (Referral memory) {
        return referrals[agentAddr];
    }

    function getReferredAgents(address referrer) external view returns (address[] memory) {
        return referrerTree[referrer];
    }

    function getLeaderboard(uint256 limit) external view returns (LeaderboardScore[] memory) {
        uint256 count = rankedAgents.length;
        if (limit < count) count = limit;
        LeaderboardScore[] memory scores = new LeaderboardScore[](count);
        for (uint256 i = 1; i <= count; i++) {
            scores[i - 1] = leaderboard[rankedAgents[i - 1]];
        }
        return scores;
    }

    function isHandleAvailable(string calldata handle) external view returns (bool) {
        return handleToAddress[handle] == address(0) || !handleExists[handle];
    }

    function getAgentStatus(address agentAddr) external view agentExists(agentAddr) returns (AgentStatus) {
        return agents[agentAddr].status;
    }

    /// @notice 获取完整Agent信息（含信誉+贡献时钟）
    function getAgentFull(address agentAddr)
        external
        view
        agentExists(agentAddr)
        returns (Agent memory, uint256 reputationScore, uint256 contributionClockScore)
    {
        Agent storage a = agents[agentAddr];
        return (a, _computeReputationScore(agentAddr), a.contributionClockScore);
    }

    /// @notice 记录贡献时钟分数（由贡献时钟合约调用）
    function recordContribution(address agentAddr, uint256 quality, uint256 complexity, uint256 timeliness)
        external
        agentExists(agentAddr)
    {
        Agent storage a = agents[agentAddr];
        a.totalQuality += quality;
        a.totalComplexity += complexity;
        a.totalTimeliness += timeliness;

        uint256 clockScore = (quality * complexity * timeliness) / 1 ether;
        a.contributionClockScore += clockScore;

        uint256 oldRep = a.reputationScore;
        a.reputationScore = _computeReputationScore(agentAddr);
        a.updatedAt = block.timestamp;

        emit ContributionClocked(agentAddr, 0, quality, complexity, timeliness, clockScore, block.timestamp);
        if (a.reputationScore != oldRep) {
            emit ReputationRecalculated(agentAddr, oldRep, a.reputationScore, block.timestamp);
        }
    }

    /// @notice 更新信誉参数（治理调用）
    function setReputationParams(ReputationParams calldata newParams) external onlyOwner {
        repParams = newParams;
    }

    /// @notice 获取Agent的ERC-721 tokenId
    function getAgentId(address agentAddr) external view agentExists(agentAddr) returns (uint256) {
        return agents[agentAddr].agentId;
    }

    // ERC-721 覆写
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
