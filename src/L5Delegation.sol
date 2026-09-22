// SPDX-License-Identifier: ORIGIN-1.0
// ═══════════════════════════════════════════════════════════
// ORIGIN L5 · L5Delegation.sol
// 授权委托层 — ERC-7710 委托模型 + AgentSpendPolicy 数据结构
// 作者：量子总督 👽 · 2026-08-17
// 版本：v0.1-erc7710-delegation
// 依据：internet-court-skill / integrations/x402-erc7710 (AgentSpendPolicy)
// ═══════════════════════════════════════════════════════════
//
// 背景：L5 结算层「贡献结算」的最后一块拼图。
//   AgentIdentity 提供了身份(ERC-8004)，AgentEscrow 提供托管，
//   但缺「谁授权谁调能力、额度上限、能否撤销」的委托模型。
//   本合约实现 ERC-7710 委托原语 + AgentSpendPolicy 数据结构。
//
// 核心设计：
//   1. Delegation = 委托方(delegator) 授权 被委托方(delegate)
//      在限定范围内调用某个能力(能力=武器库模块)
//   2. AgentSpendPolicy 数据结构和 internet-court 一致：
//      delegator / delegate / token / allowedPayTo / maxPerRequest /
//      maxPerPeriod / period / validUntil / revocable
//   3. revocable = 委托可被撤销 ← 宪法第0条「人类最高权威」链上映射
//      （人类/委托方可随时 revoke，撤销后未来调用立即失败）
//
// 对接：
//   - AgentIdentity：校验委托方/被委托方必须是已注册且 Active 的 Agent
//   - AgentEscrow：通过 delegationId 关联托管结算
//   - YUAN (ERC20)：委托范围内的结算代币

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title L5Delegation
 * @notice ERC-7710 委托权限层 + AgentSpendPolicy 结算策略
 * @dev 让智能体在限定范围内调用武器库能力，并按贡献自动结算
 */
contract L5Delegation is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════

    // ERC-7710 接口标识(参考 draft)
    bytes4 public constant IERC7710_DELEGATION = 0xDE1E6A00;
    uint256 public constant MAX_PERIOD = 365 days;
    uint256 public constant MIN_PERIOD = 1 minutes;
    uint96 public constant MAX_SPEND_PER_UINT = type(uint96).max;

    // ═══════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════

    enum DelegationStatus {
        Active, // 委托有效
        Revoked, // 已撤销（人类/委托方撤销）
        Expired, // 已过期（validUntil 到）
        Exhausted, // 额度耗尽（周期或总上限用完）
        Suspended // 因委托方/被委托方被 slash 暂停
    }

    // ═══════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════

    /// @notice 委托策略（对齐 internet-court AgentSpendPolicy）
    struct Delegation {
        bytes32 id; // 委托唯一 ID
        address delegator; // 委托方（能力提供方/授权人）
        address delegate; // 被委托方（调用智能体）
        address token; // 结算代币（YUAN）
        address allowedPayTo; // 限定收款方（=能力方，防转付）
        string resourcePattern; // 允许的资源/能力标识（武器库模块）
        uint256 maxPerRequest; // 单次调用上限
        uint256 maxPerPeriod; // 周期上限
        uint256 period; // 周期（秒）
        uint256 validAfter; // 生效时刻
        uint256 validUntil; // 过期时刻
        bool revocable; // 是否可撤销（true=人类权威可撤销）
        uint256 periodStart; // 当前周期起点
        uint256 spentThisPeriod; // 当前周期已花费
        uint256 totalSpent; // 累计花费
        uint256 requestCount; // 调用次数
        DelegationStatus status; // 状态
    }

    // ═══════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════

    // 委托存储
    mapping(bytes32 => Delegation) public delegations;
    // 被委托方 → 委托ID列表
    mapping(address => bytes32[]) private delegateDelegations;
    // 委托方 → 委托ID列表
    mapping(address => bytes32[]) private delegatorDelegations;

    // 授权接口：identity 合约(校验 Agent 身份) — 可选注入
    address public identityContract;
    address public escrowContract;

    // ═══════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════

    event DelegationCreated(
        bytes32 indexed id,
        address indexed delegator,
        address indexed delegate,
        address token,
        address allowedPayTo,
        string resourcePattern,
        uint256 maxPerPeriod,
        uint256 period,
        uint256 validUntil,
        bool revocable
    );

    event DelegationSpent(
        bytes32 indexed id,
        address indexed delegate,
        address payTo,
        uint256 amount,
        uint256 remainingThisPeriod,
        uint256 totalSpent
    );

    event DelegationRevoked(bytes32 indexed id, address indexed revokedBy, string reason);

    event DelegationSuspended(bytes32 indexed id, address indexed by, string reason);

    event DelegationPeriodRolled(bytes32 indexed id, uint256 newPeriodStart, uint256 newPeriodBudget);

    // ═══════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════

    modifier onlyDelegator(bytes32 id) {
        require(msg.sender == delegations[id].delegator, "L5D: not delegator");
        _;
    }

    modifier onlyDelegate(bytes32 id) {
        require(msg.sender == delegations[id].delegate, "L5D: not delegate");
        _;
    }

    // ═══════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════

    constructor() Ownable(msg.sender) {}

    // ═══════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════

    /// @notice 注入 AgentIdentity 合约地址（用于身份校验）
    function setIdentityContract(address _ident) external onlyOwner {
        identityContract = _ident;
    }

    /// @notice 注入 AgentEscrow 合约地址（用于结算联动）
    function setEscrowContract(address _escrow) external onlyOwner {
        escrowContract = _escrow;
    }

    // ═══════════════════════════════════════════════════
    // CORE: 创建委托
    // ═══════════════════════════════════════════════════

    /**
     * @notice 创建一笔委托（ERC-7710 委托原语）
     * @dev delegator 授权 delegate 在限定范围内调用能力
     * 若注入 identity 合约，则校验双方必须是已注册 Agent
     */
    function createDelegation(
        address _delegate,
        address _token,
        address _allowedPayTo,
        string calldata _resourcePattern,
        uint256 _maxPerRequest,
        uint256 _maxPerPeriod,
        uint256 _period,
        uint256 _validFor
    ) external returns (bytes32) {
        require(_delegate != address(0) && _delegate != msg.sender, "L5D: bad delegate");
        require(_allowedPayTo != address(0), "L5D: bad payTo");
        require(_maxPerRequest > 0 && _maxPerPeriod > 0, "L5D: zero cap");
        require(_maxPerRequest <= _maxPerPeriod, "L5D: req>period");
        require(_period >= MIN_PERIOD && _period <= MAX_PERIOD, "L5D: bad period");
        require(_validFor > 0 && _validFor <= MAX_PERIOD, "L5D: bad validFor");

        bytes32 id = _generateId(msg.sender, _delegate, _resourcePattern);
        require(delegations[id].delegate == address(0), "L5D: exists");

        uint256 now_ = block.timestamp;
        delegations[id] = Delegation({
            id: id,
            delegator: msg.sender,
            delegate: _delegate,
            token: _token,
            allowedPayTo: _allowedPayTo,
            resourcePattern: _resourcePattern,
            maxPerRequest: _maxPerRequest,
            maxPerPeriod: _maxPerPeriod,
            period: _period,
            validAfter: now_,
            validUntil: now_ + _validFor,
            revocable: true, // 默认可撤销（宪法第0条）
            periodStart: now_,
            spentThisPeriod: 0,
            totalSpent: 0,
            requestCount: 0,
            status: DelegationStatus.Active
        });

        delegateDelegations[_delegate].push(id);
        delegatorDelegations[msg.sender].push(id);

        emit DelegationCreated(
            id,
            msg.sender,
            _delegate,
            _token,
            _allowedPayTo,
            _resourcePattern,
            _maxPerPeriod,
            _period,
            now_ + _validFor,
            true
        );
        return id;
    }

    /**
     * @notice 被委托方调用能力并结算（核心：贡献结算）
     * @param id 委托ID
     * @param _payTo 实际收款方（必须 == allowedPayTo）
     * @param _amount 本次结算金额
     * @param _resource 实际调用的资源标识（必须匹配 resourcePattern）
     * @return remaining 本次结算后周期剩余额度
     */
    function spend(bytes32 id, address _payTo, uint256 _amount, string calldata _resource)
        external
        onlyDelegate(id)
        nonReentrant
        returns (uint256)
    {
        Delegation storage d = delegations[id];

        // 1. 状态检查
        require(d.status == DelegationStatus.Active, "L5D: not active");
        require(block.timestamp <= d.validUntil, "L5D: expired");
        require(block.timestamp >= d.validAfter, "L5D: not started");
        require(_payTo == d.allowedPayTo, "L5D: payTo mismatch");
        require(_matchesResource(d.resourcePattern, _resource), "L5D: resource mismatch");
        require(_amount > 0 && _amount <= d.maxPerRequest, "L5D: exceeds per-request");

        // 2. 周期滚动（period 到了重置额度）
        _rollPeriod(d);

        // 3. 周期/总量检查
        require(d.spentThisPeriod + _amount <= d.maxPerPeriod, "L5D: exceeds period cap");

        // 4. 转账结算（YUAN 从这里流给能力方）
        IERC20(d.token).safeTransferFrom(msg.sender, _payTo, _amount);

        // 5. 记账
        d.spentThisPeriod += _amount;
        d.totalSpent += _amount;
        d.requestCount += 1;

        emit DelegationSpent(id, msg.sender, _payTo, _amount, d.maxPerPeriod - d.spentThisPeriod, d.totalSpent);
        return d.maxPerPeriod - d.spentThisPeriod;
    }

    /// @notice 结算后确认完成（返回本周期剩余额度）
    function remaining(bytes32 id) external view returns (uint256) {
        Delegation storage d = delegations[id];
        if (d.status == DelegationStatus.Active && block.timestamp <= d.validUntil) {
            // 若周期已过则视为满额
            if (block.timestamp > d.periodStart + d.period) {
                return d.maxPerPeriod;
            }
            return d.maxPerPeriod - d.spentThisPeriod;
        }
        return 0;
    }

    // ═══════════════════════════════════════════════════
    // REVOKE（宪法第0条 · 人类最高权威）
    // ═══════════════════════════════════════════════════

    /**
     * @notice 撤销委托（永久性）
     * @dev 委托方(人类/能力方)可随时撤销。撤销后未来 spend 立即失败。
     * 这是「人类意志为最高法则」的链上映射。
     */
    function revoke(bytes32 id, string calldata reason) external onlyDelegator(id) returns (bool) {
        Delegation storage d = delegations[id];
        require(d.revocable, "L5D: not revocable");
        require(d.status == DelegationStatus.Active, "L5D: already inactive");
        d.status = DelegationStatus.Revoked;
        emit DelegationRevoked(id, msg.sender, reason);
        return true;
    }

    /// @notice 变更委托（调整额度/收款方），需委托方操作
    function amendDelegation(
        bytes32 id,
        uint256 _maxPerRequest,
        uint256 _maxPerPeriod,
        uint256 _period,
        uint256 _extendFor
    ) external onlyDelegator(id) returns (bool) {
        Delegation storage d = delegations[id];
        require(d.status == DelegationStatus.Active, "L5D: not active");
        require(_maxPerRequest > 0 && _maxPerRequest <= _maxPerPeriod, "L5D: bad caps");
        d.maxPerRequest = _maxPerRequest;
        d.maxPerPeriod = _maxPerPeriod;
        if (_period > 0) d.period = _period;
        if (_extendFor > 0) d.validUntil += _extendFor;
        return true;
    }

    // ═══════════════════════════════════════════════════
    // SUSPEND（配合 slashAgent）
    // ═══════════════════════════════════════════════════

    /// @notice 仲裁/管理员暂停委托（批量用于 slash 场景）
    function suspend(bytes32 id, string calldata reason) external onlyOwner returns (bool) {
        Delegation storage d = delegations[id];
        require(d.status == DelegationStatus.Active, "L5D: not active");
        d.status = DelegationStatus.Suspended;
        emit DelegationSuspended(id, msg.sender, reason);
        return true;
    }

    /// @notice 恢复委托
    function unsuspend(bytes32 id) external onlyOwner returns (bool) {
        Delegation storage d = delegations[id];
        require(d.status == DelegationStatus.Suspended, "L5D: not suspended");
        d.status = DelegationStatus.Active;
        d.periodStart = block.timestamp;
        d.spentThisPeriod = 0;
        return true;
    }

    // ═══════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════

    function getDelegation(bytes32 id) external view returns (Delegation memory) {
        return delegations[id];
    }

    function getDelegationsByDelegate(address _delegate) external view returns (bytes32[] memory, Delegation[] memory) {
        bytes32[] memory ids = delegateDelegations[_delegate];
        Delegation[] memory out = new Delegation[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            out[i] = delegations[ids[i]];
        }
        return (ids, out);
    }

    function getDelegationsByDelegator(address _delegator)
        external
        view
        returns (bytes32[] memory, Delegation[] memory)
    {
        bytes32[] memory ids = delegatorDelegations[_delegator];
        Delegation[] memory out = new Delegation[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            out[i] = delegations[ids[i]];
        }
        return (ids, out);
    }

    function isActive(bytes32 id) external view returns (bool) {
        Delegation storage d = delegations[id];
        return d.status == DelegationStatus.Active && block.timestamp <= d.validUntil;
    }

    /// @notice ERC-8004/7710 兼容：能力可被委托校验
    function canDelegate(address _delegator, address _delegate, string calldata _resource)
        external
        view
        returns (bool)
    {
        bytes32[] memory ids = delegatorDelegations[_delegator];
        for (uint256 i = 0; i < ids.length; i++) {
            Delegation storage d = delegations[ids[i]];
            if (
                d.delegate == _delegate && d.status == DelegationStatus.Active && block.timestamp <= d.validUntil
                    && _matchesResource(d.resourcePattern, _resource)
            ) {
                return true;
            }
        }
        return false;
    }

    // ═══════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════

    function _generateId(address _delegator, address _delegate, string memory _resource)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_delegator, _delegate, _resource, block.timestamp));
    }

    /// @notice 简单资源匹配：pattern 为空则全匹配；支持前缀/包含
    function _matchesResource(string memory _pattern, string memory _resource) internal pure returns (bool) {
        if (bytes(_pattern).length == 0) return true;
        // 直接相等
        if (keccak256(abi.encodePacked(_pattern)) == keccak256(abi.encodePacked(_resource))) {
            return true;
        }
        // 前缀匹配(如 "origin:" 开头)
        bytes memory p = bytes(_pattern);
        bytes memory r = bytes(_resource);
        if (p.length > 1 && p[p.length - 1] == 0x3A) {
            // 以 ':' 结尾 = 前缀
            if (r.length < p.length) return false;
            for (uint256 i = 0; i < p.length; i++) {
                if (p[i] != r[i]) return false;
            }
            return true;
        }
        return false;
    }

    /// @notice 周期滚动：若当前周期已过，重置已花费
    function _rollPeriod(Delegation storage d) internal {
        if (block.timestamp > d.periodStart + d.period) {
            d.periodStart = block.timestamp;
            d.spentThisPeriod = 0;
            emit DelegationPeriodRolled(d.id, block.timestamp, d.maxPerPeriod);
        }
    }
}
