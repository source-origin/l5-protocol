// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title YUAN — 源·ORIGIN 生态服务凭证
/// @notice 1 YUAN = 运行一次标准 AI 智能体服务单元的基准成本
///         例：1 YUAN = 生成一条 60 秒短视频 / 一次标准数据采集 / 一次合约审计调用
/// @dev SYMBOL 刻意用 4 字母 + 2x6 = 12 位, 满足常见交易所位数要求
///      功能边界：仅用于购买生态内 AI 服务 —— 属「生态积分/服务凭证」定义,
///      非投资/投机工具。公开流通与监管边界在项目治理层约束。
contract YUAN is ERC20, Ownable, ReentrancyGuard {
    /* ============ 常量 ============ */
    /// @notice 最大供应量 10亿 YUAN（18位小数对应 1e18 * 1e9）
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /* ============ 状态 ============ */
    /// @notice 生态服务商白名单（可铸造/兑换 YUAN 的主体）
    mapping(address => bool) public serviceProviders;
    /// @notice 兑换率登记：一个不可变锚定值, 由治理调整
    uint256 public yuanPerServiceUnit; // 1 基准服务单元 = N YUAN (可调)

    /* ============ 事件 ============ */
    event ServiceProviderSet(address indexed provider, bool enabled);
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
    /// @notice 设置生态服务商资格（仅 owner）
    function setServiceProvider(address provider, bool enabled) external onlyOwner {
        serviceProviders[provider] = enabled;
        emit ServiceProviderSet(provider, enabled);
    }

    /// @notice 调整锚定汇率（仅 owner, 生态成熟后交 DAO）
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
