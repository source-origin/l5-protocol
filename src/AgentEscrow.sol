// SPDX-License-Identifier: ORIGIN-1.0

//  ══════════════════════════════════════════════════════════
//  ORIGIN L5 · AgentEscrow.sol

//  来源：CloddsBot ACP escrow + AgentTrust PaymentChannel 流式微支
//  作者：量子总督 👽 · 2026-08-10
// 版本：v0.2-payment-channel-injection

//  ══════════════════════════════════════════════════════════
//

//  v0.2注入
//    1. PaymentChannel 流式微支付（off-chain签N on-chain结算1次）

//    2. agreementDeposit 签约预付模式（先存后服务
//    3. 争议保证金动态计算（按协议总价值的1%
//    4. crossChainSettle() CCTP钩子
//
// 托管生命周期：Empty→Funded→Verified→Released→Refunded→Cancelled→Disputed
// 支付通道生命周期：Closed→Open→Active→Settling→Dispute

pragma solidity ^0.8.28;

import "./AgentAgreement.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title AgentEscrow
 * @notice AI Agent 之间的链上托管支付合?+
 * @dev 与AgentAgreement紧密集成，通过agreementId关联
 */
contract AgentEscrow is Ownable2Step, ReentrancyGuard {
    //  ══════════════════════════════════════════════════
    //  ENUMS
    // ══════════════════════════════════════════════════
    enum EscrowState {
        Empty, // 未初始化
        Funded,
        Verified,
        //  工作已验
        Released,
        //  资金已释放给Provider
        Cancelled, // 已取消（退回Consumer
        Disputed
    }

    //  ══════════════════════════════════════════════════
    //  STRUCTS
    // ══════════════════════════════════════════════════
    struct Escrow {
        bytes32 escrowId;
        bytes32 agreementId; // 关联的协议ID
        address payer; // Consumer（
        address payee;
        //  Provider（收款方
        address arbiter;
        //  仲裁方（可选，默认贡献时钟
        uint256 amount;
        //  锁定金额（YUAN wei
        EscrowState state;
        uint256 fundedAt; // 存入时间
        uint256 deadline; // 截止时间
        uint256 releasedAt; // 释放时间
        bytes proofOfDelivery; // 交付证明（IPFS
        uint256 disputeBond; // 争议押金
    }

    //  ══════════════════════════════════════════════════
    //  STORAGE
    // ══════════════════════════════════════════════════
    mapping(bytes32 => Escrow) public escrows;

    // PaymentChannel storage
    mapping(bytes32 => PaymentChannel) public channels;
    mapping(address => bytes32[]) private agentChannels;
    uint256 public channelCount;

    // PaymentChannel events
    event ChannelOpened(
        bytes32 indexed channelId, address indexed sender, address indexed receiver, uint256 balance, uint256 timestamp
    );
    event ChannelPayment(
        bytes32 indexed channelId, uint256 previousNonce, uint256 newNonce, uint256 amount, uint256 timestamp
    );
    event ChannelSettled(bytes32 indexed channelId, uint256 finalBalance, uint256 timestamp);
    event ChannelSettling(bytes32 indexed channelId, uint256 finalNonce, uint256 cumulativeAmount, uint256 settlingAt);
    event ChannelDisputed(bytes32 indexed channelId, address initiator, uint256 timestamp);
    event ChannelDisputeResolved(
        bytes32 indexed channelId, bool payeeWins, uint256 correctNonce, uint256 correctAmount
    );
    event ChannelClosed(bytes32 indexed channelId, uint256 timestamp);
    event ChannelToppedUp(bytes32 indexed channelId, uint256 amount, uint256 newBalance, uint256 timestamp);
    event CrossChainSettled(
        bytes32 indexed channelId, uint256 destChainId, address indexed destPayee, uint256 amount, uint256 timestamp
    );
    event DisputeBondUpdated(uint256 oldBps, uint256 newBps, uint256 timestamp);
    mapping(bytes32 => bytes32) private agreementToEscrow; // agreementId
    mapping(address => bytes32[]) private agentEscrows;

    bytes32[] private allEscrowIds;
    uint256 public escrowCount;

    // 争议押金比例（基点）
    uint256 public disputeBondBps = 100; // 1%
    uint256 public challengePeriod = 7 days;
    uint256 public channelDisputeBond = 0.05 ether;
    uint256 public constant MAX_DISPUTE_BOND_BPS = 500; // 5%上限

    // AgentAgreement合约引用
    AgentAgreement public agentAgreement;

    //  ══════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════
    event EscrowCreated(
        bytes32 indexed escrowId,
        bytes32 indexed agreementId,
        address indexed payer,
        address payee,
        uint256 amount,
        uint256 timestamp
    );

    event EscrowFunded(bytes32 indexed escrowId, address indexed funder, uint256 amount, uint256 timestamp);

    event EscrowVerified(bytes32 indexed escrowId, bytes proofOfDelivery, uint256 timestamp);

    event EscrowReleased(bytes32 indexed escrowId, address indexed payee, uint256 amount, uint256 timestamp);

    event EscrowRefunded(bytes32 indexed escrowId, address indexed payer, uint256 amount, uint256 timestamp);

    event EscrowCancelled(bytes32 indexed escrowId, address indexed canceller, uint256 timestamp);

    event EscrowDisputed(bytes32 indexed escrowId, address indexed disputer, uint256 bondAmount, uint256 timestamp);

    event DisputeResolved(bytes32 indexed escrowId, address indexed resolvedBy, bool payeeWins, uint256 timestamp);

    event EscrowTimeout(bytes32 indexed escrowId, uint256 deadline, uint256 timestamp);

    //  ══════════════════════════════════════════════════
    //  MODIFIERS
    // ══════════════════════════════════════════════════
    modifier onlyEscrowParty(bytes32 escrowId) {
        Escrow storage esc = escrows[escrowId];
        require(msg.sender == esc.payer || msg.sender == esc.payee || msg.sender == esc.arbiter, "Escrow: not a party");
        _;
    }
    enum ChannelState {
        Closed,
        Open,
        Active,
        Settling,
        Dispute
    }

    struct PaymentChannel {
        bytes32 channelId;
        address sender;
        address receiver;
        uint256 balance;
        uint256 nonce;
        uint256 openedAt;
        uint256 lastUsedAt;
        uint256 settlingAt;
        uint256 pendingAmount;
        bytes pendingSignature;
        uint256 disputeBond;
        ChannelState state;
    }

    modifier onlyState(bytes32 escrowId, EscrowState expectedState) {
        require(escrows[escrowId].state == expectedState, "Escrow: invalid state");
        _;
    }

    modifier escrowExists(bytes32 escrowId) {
        require(escrows[escrowId].amount > 0 || escrows[escrowId].state != EscrowState.Empty, "Escrow: does not exist");
        _;
    }

    //  ══════════════════════════════════════════════════
    //  M3 (2026-09-25): domain-bound payment-channel vouchers.
    // ══════════════════════════════════════════════════
    bytes32 public constant CHANNEL_VOUCHER_TYPEHASH =
        keccak256("ChannelVoucher(bytes32 channelId,uint256 nonce,uint256 amount)");
    bytes32 private immutable _DOMAIN_SEPARATOR;

    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════
    constructor(address _agentAgreement) Ownable(msg.sender) {
        require(_agentAgreement != address(0), "Escrow: zero address");
        agentAgreement = AgentAgreement(_agentAgreement);
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ORIGIN L5 AgentEscrow"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice M3: the domain-bound digest a channel party signs over a voucher.
    /// @dev Binds (chainId, verifying contract), so a voucher cannot be replayed
    ///      on another chain or another deployment of this contract.
    function channelVoucherDigest(bytes32 channelId, uint256 nonce, uint256 amount) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CHANNEL_VOUCHER_TYPEHASH, channelId, nonce, amount));
        return keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
    }

    //  ══════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ══════════════════════════════════════════════════
    function _generateEscrowId(bytes32 agreementId, address payer, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("escrow_", agreementId, payer, nonce, block.timestamp));
    }

    //  ══════════════════════════════════════════════════
    //  CORE FUNCTIONS
    // ══════════════════════════════════════════════════

    // / @notice Consumer创建托管并存入资
    // / @param agreementId 关联的协议ID（必须是已签署状态）
    /// @param payee Provider地址
    /// @param deadline 截止时间（超时后可退款）
    /// @return escrowId
    function createAndFund(bytes32 agreementId, address payee, uint256 deadline) external payable returns (bytes32) {
        require(msg.value > 0, "Escrow: zero value");
        require(payee != address(0), "Escrow: zero payee");
        require(payee != msg.sender, "Escrow: cannot pay yourself");
        require(deadline > block.timestamp, "Escrow: deadline in past");

        // 验证协议存在且为Provider/Consumer关系
        AgentAgreement.AgentParty[] memory parties = agentAgreement.getParties(agreementId);
        bool foundConsumer;
        bool foundProvider;
        for (uint256 i = 0; i < parties.length; i++) {
            if (
                parties[i].agentAddr == msg.sender && uint8(parties[i].role) == uint8(AgentAgreement.PartyRole.Consumer)
            ) {
                foundConsumer = true;
            }
            if (parties[i].agentAddr == payee && uint8(parties[i].role) == uint8(AgentAgreement.PartyRole.Provider)) {
                foundProvider = true;
            }
        }
        require(foundConsumer, "Escrow: caller not consumer in agreement");
        require(foundProvider, "Escrow: payee not provider in agreement");

        require(agreementToEscrow[agreementId] == bytes32(0), "Escrow: already exists for agreement");

        bytes32 id = _generateEscrowId(agreementId, msg.sender, escrowCount);

        Escrow storage esc = escrows[id];
        esc.escrowId = id;
        esc.agreementId = agreementId;
        esc.payer = msg.sender;
        esc.payee = payee;
        esc.arbiter = address(0); // 默认无仲裁方，由贡献时钟裁决
        esc.amount = msg.value;
        esc.state = EscrowState.Funded;
        esc.fundedAt = block.timestamp;
        esc.deadline = deadline;

        agreementToEscrow[agreementId] = id;
        agentEscrows[msg.sender].push(id);
        agentEscrows[payee].push(id);
        allEscrowIds.push(id);
        escrowCount++;

        emit EscrowCreated(id, agreementId, msg.sender, payee, msg.value, block.timestamp);
        emit EscrowFunded(id, msg.sender, msg.value, block.timestamp);

        // 把本托管合约绑定到协议（否则 markSettled 的 escrowContract 校验恒失败）
        agentAgreement.bindEscrow(agreementId, address(this));

        return id;
    }

    /// @notice Provider提交交付证明（→ Verified状态）
    function verifyDelivery(bytes32 escrowId, bytes calldata proofOfDelivery)
        external
        escrowExists(escrowId)
        onlyState(escrowId, EscrowState.Funded)
    {
        Escrow storage esc = escrows[escrowId];
        require(msg.sender == esc.payee, "Escrow: only payee can verify");

        esc.proofOfDelivery = proofOfDelivery;
        esc.state = EscrowState.Verified;

        emit EscrowVerified(escrowId, proofOfDelivery, block.timestamp);
    }

    /// @notice Consumer确认释放资金给Provider
    function release(bytes32 escrowId) external escrowExists(escrowId) onlyState(escrowId, EscrowState.Verified) {
        Escrow storage esc = escrows[escrowId];
        require(msg.sender == esc.payer, "Escrow: only payer can release");

        uint256 amount = esc.amount;
        esc.state = EscrowState.Released;
        esc.releasedAt = block.timestamp;

        // 标记关联协议为Settled
        bytes32 agreementId = esc.agreementId;
        agentAgreement.markSettled(agreementId);

        // 转账给Provider
        (bool success,) = esc.payee.call{value: amount}("");
        require(success, "Escrow: release transfer failed");

        emit EscrowReleased(escrowId, esc.payee, amount, block.timestamp);
    }

    /// @notice Consumer在Verified后确认结算（与release等价但更语义化）
    function settle(bytes32 escrowId) external escrowExists(escrowId) onlyState(escrowId, EscrowState.Verified) {
        this.release(escrowId);
    }

    /// @notice 退款：超时或Consumer取消
    function refund(bytes32 escrowId) external escrowExists(escrowId) {
        Escrow storage esc = escrows[escrowId];

        // 两种退款条件：
        // 1. Consumer在Funded状态下取消
        // 2. 超时自动退款（
        bool isCancellation = esc.state == EscrowState.Funded && msg.sender == esc.payer;
        bool isTimeout = block.timestamp > esc.deadline && esc.state == EscrowState.Funded;

        require(isCancellation || isTimeout, "Escrow: cannot refund");

        uint256 amount = esc.amount;

        if (isCancellation) {
            esc.state = EscrowState.Cancelled;
            emit EscrowCancelled(escrowId, msg.sender, block.timestamp);
        } else {
            esc.state = EscrowState.Verified;
            emit EscrowTimeout(escrowId, esc.deadline, block.timestamp);
        }

        // 退款给Consumer
        (bool success,) = esc.payer.call{value: amount}("");
        require(success, "Escrow: refund transfer failed");

        emit EscrowRefunded(escrowId, esc.payer, amount, block.timestamp);
    }

    // / @notice 发起争议（需支付押金 = 托管金额 × disputeBondBps
    function dispute(bytes32 escrowId)
        external
        payable
        escrowExists(escrowId)
        onlyEscrowParty(escrowId)
        onlyState(escrowId, EscrowState.Verified)
    {
        Escrow storage esc = escrows[escrowId];
        uint256 requiredBond = (esc.amount * disputeBondBps) / 10000;

        require(msg.value >= requiredBond, "Escrow: insufficient dispute bond");

        esc.disputeBond = msg.value;
        esc.state = EscrowState.Disputed;

        if (msg.value > requiredBond) {
            (bool refunded,) = msg.sender.call{value: msg.value - requiredBond}("");
            require(refunded, "Escrow: bond refund failed");
        }

        emit EscrowDisputed(escrowId, msg.sender, requiredBond, block.timestamp);
    }

    // / @notice 争议裁决（由贡献时钟合约调用
    // / @param payeeWins true=Provider获胜得全款，false=Consumer获胜退
    function resolveDispute(bytes32 escrowId, bool payeeWins)
        external
        onlyOwner
        nonReentrant
        escrowExists(escrowId)
        onlyState(escrowId, EscrowState.Disputed)
    {
        Escrow storage esc = escrows[escrowId];

        // 止血锁：贡献时钟尚未部署，裁决者暂由 owner 担任（严格严于「任何人可调」）。
        // TODO(接线): 贡献时钟合约上线后改为 require(msg.sender == address(contributionClock), "Escrow: only contribution clock");

        uint256 escrowAmount = esc.amount;
        uint256 bondAmount = esc.disputeBond;

        esc.state = EscrowState.Released;
        esc.releasedAt = block.timestamp;

        if (payeeWins) {
            // Provider获胜：
            (bool success1,) = esc.payee.call{value: escrowAmount}("");
            require(success1, "Escrow: payee transfer failed");
            (bool success2,) = esc.payee.call{value: bondAmount}("");
            require(success2, "Escrow: bond to payee failed");
        } else {
            // Consumer获胜：
            (bool success1,) = esc.payer.call{value: escrowAmount}("");
            require(success1, "Escrow: payer transfer failed");
            (bool success2,) = esc.payer.call{value: bondAmount}("");
            require(success2, "Escrow: bond to payer failed");
        }

        emit DisputeResolved(escrowId, msg.sender, payeeWins, block.timestamp);
    }

    //  ══════════════════════════════════════════════════
    //  GETTERS
    // ══════════════════════════════════════════════════
    function getEscrow(bytes32 escrowId) external view escrowExists(escrowId) returns (Escrow memory) {
        return escrows[escrowId];
    }

    function getEscrowByAgreement(bytes32 agreementId) external view returns (Escrow memory) {
        bytes32 escrowId = agreementToEscrow[agreementId];
        require(escrowId != bytes32(0), "Escrow: no escrow for agreement");
        return escrows[escrowId];
    }

    function getAgentEscrows(address agent) external view returns (bytes32[] memory) {
        return agentEscrows[agent];
    }

    function getEscrowCount() external view returns (uint256) {
        return escrowCount;
    }

    //  ══════════════════════════════════════════════════
    //  ADMIN
    // ══════════════════════════════════════════════════
    function setDisputeBond(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_DISPUTE_BOND_BPS, "Escrow: bond too high");
        disputeBondBps = newBps;
    }

    // ══════════════════════════════════════════════════════
    // PAYMENT CHANNEL: 流式微支付
    // Off-chain签N次 + On-chain结算1次
    // ══════════════════════════════════════════════════════

    /// @notice 开通支付通道（Consumer存入总资金）
    function openChannel(address receiver) external payable returns (bytes32 channelId) {
        require(msg.value > 0, "Channel: deposit required");
        require(receiver != address(0) && receiver != msg.sender, "Channel: invalid receiver");

        channelCount++;
        channelId = keccak256(abi.encodePacked(msg.sender, receiver, channelCount, block.timestamp));

        PaymentChannel storage ch = channels[channelId];
        ch.channelId = channelId;
        ch.sender = msg.sender;
        ch.receiver = receiver;
        ch.balance = msg.value;
        ch.nonce = 0;
        ch.openedAt = block.timestamp;
        ch.lastUsedAt = block.timestamp;
        ch.state = ChannelState.Open;

        agentChannels[msg.sender].push(channelId);
        agentChannels[receiver].push(channelId);

        emit ChannelOpened(channelId, msg.sender, receiver, msg.value, block.timestamp);
    }

    /// @notice 向已有通道追加资金
    function topUpChannel(bytes32 channelId) external payable {
        PaymentChannel storage ch = channels[channelId];
        require(ch.sender == msg.sender, "Channel: only sender");
        require(ch.state == ChannelState.Open || ch.state == ChannelState.Active, "Channel: not open");

        ch.balance += msg.value;
        ch.lastUsedAt = block.timestamp;

        emit ChannelToppedUp(channelId, msg.value, ch.balance, block.timestamp);
    }

    /// @notice Off-chain签名 → On-chain结算（批量）
    /// @param channelId 通道ID
    /// @param finalNonce 最后使用的nonce
    /// @param cumulativeAmount 累计支付总额
    /// @param signature ECDSA签名 over (channelId, finalNonce, cumulativeAmount)
    function settleChannel(bytes32 channelId, uint256 finalNonce, uint256 cumulativeAmount, bytes calldata signature)
        external
    {
        PaymentChannel storage ch = channels[channelId];
        require(ch.state == ChannelState.Open || ch.state == ChannelState.Active, "Channel: not open");
        require(finalNonce >= ch.nonce, "Channel: nonce rewind");
        require(cumulativeAmount <= ch.balance, "Channel: exceeds balance");

        bytes32 digest = channelVoucherDigest(channelId, finalNonce, cumulativeAmount);
        address signer = _recoverSigner(digest, signature);
        // M3: either channel party may vouch -- the payer (sender) authorizes a
        // release, the payee (receiver) claims one -- but the voucher must be
        // domain-bound and low-s (see channelVoucherDigest / _recoverSigner).
        require(signer == ch.receiver || signer == ch.sender, "Channel: invalid signer");

        // === 不立即结算，进入挑战期 ===
        ch.state = ChannelState.Settling;
        ch.nonce = finalNonce;
        ch.settlingAt = block.timestamp;
        ch.pendingAmount = cumulativeAmount;
        ch.pendingSignature = signature;
        ch.lastUsedAt = block.timestamp;

        emit ChannelSettled(channelId, cumulativeAmount, block.timestamp);
        emit ChannelSettling(channelId, finalNonce, cumulativeAmount, block.timestamp + challengePeriod);
    }

    /// @notice 挑战期过后完成结算
    function finalizeSettlement(bytes32 channelId) external nonReentrant {
        PaymentChannel storage ch = channels[channelId];
        require(ch.state == ChannelState.Settling, "Channel: not settling");
        require(block.timestamp >= ch.settlingAt + challengePeriod, "Channel: challenge period not over");

        uint256 cumulativeAmount = ch.pendingAmount;
        uint256 senderRefund = ch.balance - cumulativeAmount;

        // Checks-Effects-Interactions：先落状态再转账（防重入双重支付）
        ch.balance = 0;
        ch.state = ChannelState.Closed;

        if (cumulativeAmount > 0) {
            (bool paid,) = ch.receiver.call{value: cumulativeAmount}("");
            require(paid, "Channel: payment failed");
        }
        if (senderRefund > 0) {
            (bool refunded,) = ch.sender.call{value: senderRefund}("");
            require(refunded, "Channel: refund failed");
        }

        emit ChannelSettled(channelId, cumulativeAmount, block.timestamp);
    }

    /// @notice 发起通道争议
    /// @notice Sender发起挑战：用更高nonce签名覆盖Receiver的欺诈性低nonce
    /// @dev 非对称信息博弈：谁的nonce大，谁赢 (Schelling Point)
    function disputeChannel(
        bytes32 channelId,
        uint256 correctNonce,
        uint256 correctAmount,
        bytes calldata correctSignature
    ) external payable {
        PaymentChannel storage ch = channels[channelId];
        require(ch.state == ChannelState.Settling, "Channel: not settling");
        require(msg.sender == ch.sender, "Channel: only sender can dispute");
        require(msg.value >= channelDisputeBond, "Channel: bond required");
        require(correctNonce > ch.nonce || correctAmount < ch.pendingAmount, "Channel: must prove better terms");
        require(block.timestamp < ch.settlingAt + challengePeriod, "Channel: challenge period expired");

        bytes32 digest = channelVoucherDigest(channelId, correctNonce, correctAmount);
        address signer = _recoverSigner(digest, correctSignature);
        require(signer == ch.receiver, "Channel: signature must be from receiver");

        // Schelling Point: 最大nonce胜
        if (correctNonce > ch.nonce) {
            ch.nonce = correctNonce;
            ch.pendingAmount = correctAmount;
            ch.pendingSignature = correctSignature;
            ch.settlingAt = block.timestamp;

            (bool refunded,) = msg.sender.call{value: msg.value}("");
            require(refunded, "Channel: bond refund failed");

            emit ChannelDisputed(channelId, msg.sender, block.timestamp);
            emit ChannelDisputeResolved(channelId, true, correctNonce, correctAmount);
        } else {
            ch.state = ChannelState.Dispute;
            ch.disputeBond = msg.value;

            uint256 penalty = msg.value / 2;
            (bool paid,) = ch.receiver.call{value: penalty}("");
            require(paid, "Channel: penalty transfer failed");

            emit ChannelDisputed(channelId, msg.sender, block.timestamp);
        }
    }

    /// @notice CCTP跨链结算钩子
    function crossChainSettle(bytes32 channelId, uint256 destChainId, address destPayee, uint256 amount) external {
        PaymentChannel storage ch = channels[channelId];
        require(ch.sender == msg.sender || ch.receiver == msg.sender, "Channel: not a party");
        require(amount <= ch.balance, "Channel: exceeds balance");
        require(ch.state == ChannelState.Open || ch.state == ChannelState.Active, "Channel: not open");

        ch.balance -= amount;
        ch.lastUsedAt = block.timestamp;

        emit CrossChainSettled(channelId, destChainId, destPayee, amount, block.timestamp);
        // ⚠️ 未来：调用 Axelar / LayerZero / IBC 协议进行实际跨链转账
    }

    /// @dev ECDSA 签名恢复，强制规范 low-s 与 v∈{27,28}（OZ ECDSA.tryRecover）。
    ///      M3 (2026-09-25)：可延展（high-s）或畸形签名一律返回 address(0)。
    function _recoverSigner(bytes32 digest, bytes memory signature) internal pure returns (address) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);
        return recovered;
    }
}
