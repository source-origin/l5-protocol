// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title YUAN — 源·ORIGIN 生态服务凭证
/// @notice 1 YUAN = 运行一次标准 AI 智能体服务单元的基准成本
///         例：1 YUAN = 生成一条 60 秒短视频 / 一次标准数据采集 / 一次合约审计调用
/// @dev SYMBOL 刻意用 4 字母 + 2x6 = 12 位, 满足常见交易所位数要求
///      功能边界：仅用于购买生态内 AI 服务 —— 属「生态积分/服务凭证」定义,
///      非投资/投机工具。公开流通与监管边界在项目治理层约束。
contract YUAN is ERC20, Ownable2Step, ReentrancyGuard {
    /* ============ 常量 ============ */
    /// @notice 最大供应量 10亿 YUAN（18位小数对应 1e18 * 1e9）
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /* ============ 状态 ============ */
    /// @notice 生态服务商白名单（可铸造/兑换 YUAN 的主体）
    mapping(address => bool) public serviceProviders;
    /// @notice 兑换率登记：一个不可变锚定值, 由治理调整
    uint256 public yuanPerServiceUnit; // 1 基准服务单元 = N YUAN (可调)

    /// @notice M5: each provider's issuance ceiling, set by the Foundation (owner).
    ///         Issuance is a monetary-policy lever: the Foundation raises/lowers a
    ///         provider's cap as the market requires. A provider with no cap set
    ///         (0) cannot issue at all -- fail-closed, never unlimited. MAX_SUPPLY
    ///         remains the hard ceiling on top of this.
    mapping(address => uint256) public providerMintCap;
    /// @notice M5: cumulative amount already issued by each provider (against its cap).
    mapping(address => uint256) public providerMinted;

    /* ============ 事件 ============ */
    event ServiceProviderSet(address indexed provider, bool enabled);
    event ProviderMintCapSet(address indexed provider, uint256 cap);
    event AnchorRateSet(uint256 yuanPerServiceUnit);
    event ServiceIssued(address indexed provider, address indexed recipient, uint256 amount, uint256 serviceUnits);
    event ServiceBurned(address indexed holder, uint256 amount);

    /// @param initialAnchor 初始锚定：1 基准服务单元 兑换 YUAN 数量
    constructor(uint256 initialAnchor) ERC20("YUAN", "YUAN") Ownable(msg.sender) {
        yuanPerServiceUnit = initialAnchor;
    }

    /* ============ 修饰器 ============ */
    modifier onlyProvider() {
        require(serviceProviders[msg.sender], "YUAN: not a service provider");
        _;
    }

    /* ============ 治理 ============ */
    /// @notice 设置生态服务商资格（仅 owner = 源基金会）
    /// @dev 仅开通资格不赋予发行权：还需 setProviderMintCap 设上限后该服务商才能发行。
    function setServiceProvider(address provider, bool enabled) external onlyOwner {
        serviceProviders[provider] = enabled;
        emit ServiceProviderSet(provider, enabled);
    }

    /// @notice M5: 设定某服务商的发行上限（仅 owner = 源基金会）。
    ///         这是「按市场反应调节发行量」的杠杆：发行量由基金会选择的上限约束,
    ///         而不是仅由 MAX_SUPPLY 约束。上限 0 = 该服务商不可发行（fail-closed）。
    function setProviderMintCap(address provider, uint256 cap) external onlyOwner {
        providerMintCap[provider] = cap;
        emit ProviderMintCapSet(provider, cap);
    }

    /// @notice 调整锚定汇率（仅 owner = 源基金会, 生态成熟后交 DAO / timelock）
    function setAnchorRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "YUAN: rate zero");
        yuanPerServiceUnit = newRate;
        emit AnchorRateSet(newRate);
    }

    /* ============ 铸造（凭证发行） ============ */
    /// @notice 生态服务商按锚定率向受助方发行 YUAN（对应其完成的服务单元数）
    /// @dev 服务商证明「服务确实交付」（结算层验证）后才可发行, 防止凭空造币
    function issueService(address recipient, uint256 serviceUnits) external onlyProvider nonReentrant {
        require(recipient != address(0), "YUAN: zero recipient");
        uint256 amount = serviceUnits * yuanPerServiceUnit;
        require(amount > 0, "YUAN: zero amount");
        require(totalSupply() + amount <= MAX_SUPPLY, "YUAN: cap exceeded");
        // M5: the Foundation bounds each provider's issuance (market-responsive policy).
        // A provider can never mint past its cap, and an uncapped (0) provider cannot
        // mint at all -- so sole authority over supply stays with the Foundation.
        uint256 minted = providerMinted[msg.sender] + amount;
        require(minted <= providerMintCap[msg.sender], "YUAN: provider cap exceeded");
        providerMinted[msg.sender] = minted;

        _mint(recipient, amount);
        emit ServiceIssued(msg.sender, recipient, amount, serviceUnits);
    }

    /* ============ 燃烧（凭证回收） ============ */
    /// @notice 持有者用 YUAN 消费生态服务时燃烧, 实现「价值回流」。
    /// @param serviceUnits 消耗的服务单元数, 对应燃烧 amount = units * rate
    function consumeService(uint256 serviceUnits) external nonReentrant {
        uint256 amount = serviceUnits * yuanPerServiceUnit;
        require(amount > 0, "YUAN: zero amount");
        require(balanceOf(msg.sender) >= amount, "YUAN: insufficient");

        _burn(msg.sender, amount);
        emit ServiceBurned(msg.sender, amount);
    }

    /* ============ 查询 ============ */
    /// @notice 把 YUAN 数量换算成基准服务单元数（展示用）
    function yuanToUnits(uint256 yuanAmount) external view returns (uint256) {
        return yuanAmount / yuanPerServiceUnit;
    }

    /// @notice 把基准服务单元数换算成 YUAN（展示用）
    function unitsToYuan(uint256 serviceUnits) external view returns (uint256) {
        return serviceUnits * yuanPerServiceUnit;
    }
}
