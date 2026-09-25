// SPDX-License-Identifier: ORIGIN-1.0
// ═══════════════════════════════════════════════════════════
// ORIGIN L5 · L5x402.sol
// x402 支付轨 · 链上记账+收据+快照层
// 作者：量子总督 👽 · 2026-08-17
// 版本：v0.1-x402-accounting
// 依据：internet-court-skill / integrations/x402-erc7710 (Implementation Checklist)
// ═══════════════════════════════════════════════════════════
//
// 定位：L5 缺口2「x402 支付轨」的链上部分。
//   x402 是应用层 HTTP 支付协议（402 Payment Required + 签名支付载荷 + facilitator 结算）。
//   它原理上是无状态的——真正把「付费」状态化的地方叫 **policy + accounting**。
//   https://github.com/ChainAgnostic/CASA/blob/main/docs/CAIP-402.mdx
//
// 我们 L5 的策略(AgentSpendPolicy)已在 L5Delegation.sol 实现；
//   本合约补齐 accounting 侧：
//     1. PaymentReceipt 收据存储（对齐 x402 checklist #5）
//     2. getSpendSnapshot 花钱快照（对齐 checklist #6，permission manager 视图）
//     3. verifyRequirement 请求前策略校验（对齐 checklist #4 / Guardrails）
//     4. 收据 → 审计/争议/撤销 的回写挂钩（对齐 Signed Evidence + Adjudicated）
//
// 设计原则（严格遵循 x402 skill Guardrails）：
//   - 把「周期性/订阅」放 policy+accounting，不放协议本身
//   - 绝不创建无限授权/开放 Agent 权限
//   - 保留可撤销（revocable ← 宪法第0条）
//   - 收据签名校验（service-signed receipt）

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title L5x402
 * @notice x402 支付轨的链上记账+收据+快照层
 * @dev 与 L5Delegation 复用同一委托策略，x402 只做记账审计
 */
contract L5x402 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════

    // x402 标准 assetTransferMethod 值
    bytes32 public constant TRANSFER_ERC20 = keccak256("erc20");
    bytes32 public constant TRANSFER_ERC7710 = keccak256("erc7710");
    bytes32 public constant TRANSFER_NATIVE = keccak256("native");

    // P0 #3 (canonicalization): the *complete* typed action. Every material field
    // of the action is enumerated here, so a canonical digest commits to the whole
    // action and not to "too little". A verifier recomputes this field set and
    // gets byte-stable bytes (EMILIA: RFC 8785 JCS + SHA-256 on their side; the
    // EVM analogue is the keccak256 EIP-712 struct hash below).
    bytes32 public constant PAYMENT_ACTION_TYPEHASH = keccak256(
        "PaymentAction(bytes32 requestId,address payer,address payee,address token,uint256 amount,bytes32 routeHash,bytes32 payloadHash,bytes32 permissionHash,uint256 deadline)"
    );
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // H3 (domain binding): the service evidence signature covers the receipt it
    // belongs to, so a valid signature for one receipt/chain cannot be replayed
    // against another receipt or another deployment.
    bytes32 public constant RECEIPT_EVIDENCE_TYPEHASH =
        keccak256("ReceiptEvidence(bytes32 receiptId,bytes32 payloadHash)");

    // ═══════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════

    enum ReceiptStatus {
        Pending, // 已登记，待结算
        Settled, // 已结算
        Disputed, // 争议中（路由到裁决）
        Refunded, // 已退款（Arkhai/GenLayer 裁决释放）
        Failed // 结算失败/作废
    }

    /// @notice Finality dimension of a receipt (Boundary rule, see CONTRIBUTION-SPEC 1).
    /// A receipt declares what it proves and stops. It never claims a finality it
    /// does not have; a later verdict is the artifact that holds the back-reference.
    enum ReceiptFinality {
        Open, // P0 #4: registered but value has NOT moved -> no finality may be claimed
        Final, // auto-conditioned release: value moved, no external verdict exists, terminal
        ProvisionalSubjectToVerdict // value moved but reversal is still possible; finality pending verdict
    }

    // ═══════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════

    /// @notice x402 支付收据（对齐 x402 checklist #5）
    struct PaymentReceipt {
        bytes32 receiptId; // 收据唯一 ID
        bytes32 requestId; // 父请求 ID（HTTP 请求关联）
        address payer; // 付款方（Agent 或被委托方）
        address payee; // 收款方（服务/能力提供方）
        address token; // 结算代币（YUAN）
        uint256 amount; // 金额
        uint256 chainId; // 链 ID
        string route; // HTTP 路由/资源
        bytes32 payloadHash; // 请求参数哈希（Signed Evidence）
        bytes32 permissionHash; // 委托策略哈希（关联 L5Delegation）
        uint256 timestamp; // 登记时间
        ReceiptStatus status; // 状态
        bool evidenceVerified; // 服务端签名证据是否通过
        ReceiptFinality finality; // 终局性：Open | Final | ProvisionalSubjectToVerdict
        bytes32 verdictRef; // 经裁定释放时引用已先铸的 verdict digest；否则 0
        bytes32 actionDigest; // 被授权动作的规范摘要（P0 #3）：第三方可逐字段重算
    }

    /// @notice Post-hoc verdict artifact. Minted after the receipt it judges, so
    /// it holds the backward reference (receiptRef) -- never the other way around.
    struct Verdict {
        bytes32 verdictId; // verdict digest
        bytes32 receiptRef; // the receipt this verdict judges (back-reference)
        bool isFinal; // whether this verdict renders the release final
        uint256 timestamp;
    }

    /// @notice 权限管理器快照（对齐 x402 checklist #6）
    struct SpendSnapshot {
        bytes32 policyId; // 关联的委托策略 ID（L5Delegation.delegation id）
        address delegate; // 被委托方
        uint256 spentTotal; // 累计花费
        uint256 spentPeriod; // 周期已花费
        uint256 requestCount; // 请求次数
        uint256 periodStart; // 当前周期起点
        uint256 period; // 周期
        uint256 maxPerPeriod; // 周期上限
    }

    // ═══════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════

    // 收据存储：receiptId → PaymentReceipt
    mapping(bytes32 => PaymentReceipt) public receipts;
    // payee → 收据 ID 列表
    mapping(address => bytes32[]) private payeeReceipts;
    // payer → 收据 ID 列表
    mapping(address => bytes32[]) private payerReceipts;

    // 花钱快照：policyId → SpendSnapshot
    mapping(bytes32 => SpendSnapshot) public snapshots;

    // 依赖注入
    address public delegationContract; // L5Delegation 地址
    address public identityContract; // AgentIdentity 地址
    address public escrowContract; // AgentEscrow 地址（争议时托管）

    // 裁决存储：verdictId → Verdict（后铸工件持有反向引用）
    mapping(bytes32 => Verdict) public verdicts;
    // receiptId → 其后铸的 verdict
    mapping(bytes32 => bytes32) public verdictOfReceipt;

    // P0 #1: an action digest may be consumed (authorized) exactly once.
    mapping(bytes32 => bool) public consumedAuthorizations;

    // EIP-712 domain separator, bound to this chain + this contract.
    bytes32 public immutable DOMAIN_SEPARATOR;

    // 记录数
    uint256 public receiptCount;
    uint256 public snapshotCount;

    // ═══════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════

    event ReceiptRecorded(
        bytes32 indexed receiptId,
        bytes32 indexed requestId,
        address indexed payer,
        address payee,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    event ReceiptSettled(bytes32 indexed receiptId, bytes32 indexed paymentHash, uint256 timestamp);

    event ReceiptDisputed(bytes32 indexed receiptId, string reason, uint256 timestamp);

    event ReceiptRefunded(bytes32 indexed receiptId, uint256 refundAmount, uint256 timestamp);

    event ReceiptMarkedProvisional(bytes32 indexed receiptId, uint256 timestamp);

    /// @notice Adjudicated path: receipt cites a verdict minted before it.
    event ReceiptCitedVerdict(bytes32 indexed receiptId, bytes32 indexed verdictRef, uint256 timestamp);

    /// @notice Post-hoc path: a verdict minted after the receipt back-references it.
    event VerdictRecorded(bytes32 indexed verdictId, bytes32 indexed receiptRef, bool isFinal, uint256 timestamp);

    event SnapshotUpdated(
        bytes32 indexed policyId, address indexed delegate, uint256 spentTotal, uint256 requestCount, uint256 timestamp
    );

    event RequirementVerified(bytes32 indexed policyId, bool allowed, string reason, uint256 timestamp);

    /// @notice Evidence for a receipt was submitted and bound (payloadHash + pinned signer).
    event EvidenceVerified(bytes32 indexed receiptId, address indexed signer, bytes32 evidenceHash, uint256 timestamp);

    // ═══════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════

    modifier onlyAdmin() {
        require(msg.sender == owner(), "L5x402: not owner");
        _;
    }

    // ═══════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════

    constructor() Ownable(msg.sender) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("ORIGIN L5 x402"), keccak256("1"), block.chainid, address(this))
        );
    }

    // ═══════════════════════════════════════════════════
    // ADMIN: 依赖注入
    // ═══════════════════════════════════════════════════

    function setDelegationContract(address _del) external onlyAdmin {
        delegationContract = _del;
    }

    function setIdentityContract(address _id) external onlyAdmin {
        identityContract = _id;
    }

    function setEscrowContract(address _esc) external onlyAdmin {
        escrowContract = _esc;
    }

    // ═══════════════════════════════════════════════════
    // CORE 1: 请求前策略校验（x402 checklist #4）
    // ═══════════════════════════════════════════════════

    /**
     * @notice 在发起 x402 请求前，校验策略是否允许这笔支付
     * @dev 只读校验（pure business logic），不产生状态变化。
     *  下放给 L5Delegation 的 spend() 做真正的额度扣减。
     */
    function verifyRequirement(
        bytes32 _policyId,
        address _delegate,
        address _payee,
        address _token,
        uint256 _amount,
        bytes32 _resourcePatternHash
    ) external view returns (bool allowed, string memory reason) {
        // 通过 delegation 合约查询策略状态
        // 注：此处为轻量校验接口。真正额度扣减在 L5Delegation.spend
        SpendSnapshot storage snap = snapshots[_policyId];
        if (snap.delegate == address(0)) {
            return (false, "policy not registered");
        }
        if (snap.delegate != _delegate) {
            return (false, "delegate mismatch");
        }
        if (_amount > snap.maxPerPeriod) {
            return (false, "exceeds period cap");
        }
        // 周期滚动检查
        uint256 spent = snap.spentPeriod;
        if (block.timestamp > snap.periodStart + snap.period) {
            spent = 0; // 周期已过，视为满额预算
        }
        if (spent + _amount > snap.maxPerPeriod) {
            return (false, "insufficient period budget");
        }
        return (true, "ok");
    }

    // ═══════════════════════════════════════════════════
    // CORE 2: 登记收据（x402 checklist #5）
    // ═══════════════════════════════════════════════════

    /**
     * @notice 服务方/facilitator 在 x402 支付后登记收据
     * @dev payer 授权扣款（从 payer 转给 payee），同时更新快照
     */
    function recordReceipt(
        bytes32 _requestId,
        address _payer,
        address _payee,
        address _token,
        uint256 _amount,
        bytes32 _routeHash,
        bytes32 _payloadHash,
        bytes32 _permissionHash,
        uint256 _deadline,
        bytes calldata _payerAuth
    ) external nonReentrant returns (bytes32 receiptId) {
        require(_payer != address(0) && _payee != address(0), "L5x402: bad address");
        require(_amount > 0, "L5x402: zero amount");
        require(block.timestamp <= _deadline, "L5x402: authorization expired");

        // P0 #1 + P0 #3: the caller must present the payer's signature over the
        // canonically-encoded action. Nothing here is caller-selected authority:
        // the digest covers requestId/payer/payee/token/amount/route/payload/
        // permission/deadline, so the approved action and the dispatched action
        // are byte-identical or the call reverts.
        bytes32 digest = actionDigest(
            _requestId, _payer, _payee, _token, _amount, _routeHash, _payloadHash, _permissionHash, _deadline
        );
        require(!consumedAuthorizations[digest], "L5x402: authorization replayed");
        address authSigner = ECDSA.recover(digest, _payerAuth);
        require(authSigner == _payer, "L5x402: not payer-authorized");
        consumedAuthorizations[digest] = true;

        receiptId = _generateReceiptId(_requestId, _payer, _payee, _amount, _payloadHash);
        require(receipts[receiptId].receiptId == bytes32(0), "L5x402: duplicate");

        receipts[receiptId] = PaymentReceipt({
            receiptId: receiptId,
            requestId: _requestId,
            payer: _payer,
            payee: _payee,
            token: _token,
            amount: _amount,
            chainId: block.chainid,
            route: _bytes32ToString(_routeHash), // 简化：route 以 hash 存储
            payloadHash: _payloadHash,
            permissionHash: _permissionHash,
            timestamp: block.timestamp,
            status: ReceiptStatus.Pending,
            evidenceVerified: false,
            finality: ReceiptFinality.Open, // P0 #4: value has not moved yet -> claim no finality
            verdictRef: bytes32(0),
            actionDigest: digest
        });

        payeeReceipts[_payee].push(receiptId);
        payerReceipts[_payer].push(receiptId);
        receiptCount++;

        // 尝试从 payer 转移代币完成结算（若无 allowance 则留在 Pending 待 facilitator 结算）
        // 注意：这里要求 payer 已对 x402 合约 approve
        // H2: settlement requires BOTH an approved allowance AND a registered policy
        // within its on-chain cap. An unknown policy grants nothing (we never mint an
        // unlimited authority), so the receipt simply stays Pending instead of settling.
        IERC20 tk = IERC20(_token);
        uint256 allowance = tk.allowance(_payer, address(this));
        if (allowance >= _amount && _policyAllows(_permissionHash, _payer, _amount)) {
            tk.safeTransferFrom(_payer, _payee, _amount);
            receipts[receiptId].status = ReceiptStatus.Settled;
            receipts[receiptId].finality = ReceiptFinality.Final; // auto-conditioned release: value moved
            _consumePolicy(_permissionHash, _payer, _amount);
            emit ReceiptSettled(
                receiptId, keccak256(abi.encodePacked(_payee, _amount, block.timestamp)), block.timestamp
            );
        }

        emit ReceiptRecorded(receiptId, _requestId, _payer, _payee, _token, _amount, block.timestamp);
        return receiptId;
    }

    // ═══════════════════════════════════════════════════
    // CORE 3: 快照更新（x402 checklist #6）
    // ═══════════════════════════════════════════════════

    /// @notice 登记/更新花钱快照（permission manager 视图）
    function updateSnapshot(
        bytes32 _policyId,
        address _delegate,
        uint256 _amount,
        uint256 _maxPerPeriod,
        uint256 _period
    ) external onlyAdmin returns (SpendSnapshot memory) {
        SpendSnapshot storage snap = snapshots[_policyId];
        if (snap.delegate == address(0)) {
            // 新快照
            snap.policyId = _policyId;
            snap.delegate = _delegate;
            snap.period = _period;
            snap.maxPerPeriod = _maxPerPeriod;
            snap.periodStart = block.timestamp;
            snap.spentPeriod = 0;
            snap.spentTotal = 0;
            snap.requestCount = 0;
            snapshotCount++;
        }
        // 周期滚动
        if (block.timestamp > snap.periodStart + snap.period) {
            snap.periodStart = block.timestamp;
            snap.spentPeriod = 0;
        }
        // A zero-amount call is a registration / period roll only, not a spend.
        if (_amount > 0) {
            snap.spentPeriod += _amount;
            snap.spentTotal += _amount;
            snap.requestCount++;
        }
        emit SnapshotUpdated(_policyId, _delegate, snap.spentTotal, snap.requestCount, block.timestamp);
        return snap;
    }

    /// @notice H2: read-only policy gate used at settlement time. Mirrors
    ///   verifyRequirement's rules (registered + delegate match + within cap) and
    ///   returns false for an UNKNOWN policy -- it never grants unlimited authority.
    function _policyAllows(bytes32 _policyId, address _delegate, uint256 _amount) internal view returns (bool) {
        SpendSnapshot storage snap = snapshots[_policyId];
        if (snap.delegate == address(0)) return false; // unknown policy -> no authority
        if (snap.delegate != _delegate) return false;
        if (_amount > snap.maxPerPeriod) return false;
        uint256 spent = snap.spentPeriod;
        if (block.timestamp > snap.periodStart + snap.period) spent = 0;
        return spent + _amount <= snap.maxPerPeriod;
    }

    /// @notice H2: consume a settled spend against the policy snapshot.
    function _consumePolicy(bytes32 _policyId, address _delegate, uint256 _amount) internal {
        SpendSnapshot storage snap = snapshots[_policyId];
        if (block.timestamp > snap.periodStart + snap.period) {
            snap.periodStart = block.timestamp;
            snap.spentPeriod = 0;
        }
        snap.spentPeriod += _amount;
        snap.spentTotal += _amount;
        snap.requestCount++;
        emit SnapshotUpdated(_policyId, _delegate, snap.spentTotal, snap.requestCount, block.timestamp);
    }

    // ═══════════════════════════════════════════════════
    // DISPUTE / REFUND（对齐 Adjudicated + Signed Evidence）
    // ═══════════════════════════════════════════════════

    /// @notice 标记收据进入争议（路由到裁决）
    function disputeReceipt(bytes32 _receiptId, string calldata _reason) external onlyAdmin returns (bool) {
        PaymentReceipt storage r = receipts[_receiptId];
        require(r.receiptId != bytes32(0), "L5x402: no receipt");
        require(r.status != ReceiptStatus.Settled, "L5x402: already settled");
        r.status = ReceiptStatus.Disputed;
        // A disputed receipt must not keep claiming Final: value has moved and
        // finality is now pending a verdict. Enter the third state explicitly,
        // so a receipt can never be both Disputed and Final at the same time.
        if (r.finality != ReceiptFinality.ProvisionalSubjectToVerdict) {
            r.finality = ReceiptFinality.ProvisionalSubjectToVerdict;
            emit ReceiptMarkedProvisional(_receiptId, block.timestamp);
        }
        emit ReceiptDisputed(_receiptId, _reason, block.timestamp);
        return true;
    }

    /// @notice 裁决结果：退款（对应 Arkhai/GenLayer 裁决释放 escrow）
    function refundReceipt(bytes32 _receiptId, uint256 _refundAmount) external onlyAdmin nonReentrant returns (bool) {
        PaymentReceipt storage r = receipts[_receiptId];
        require(r.receiptId != bytes32(0), "L5x402: no receipt");
        require(r.status == ReceiptStatus.Disputed, "L5x402: not disputed");
        require(_refundAmount <= r.amount, "L5x402: over refund");

        // 从 payee 退回 payer（裁决追回）
        IERC20(r.token).safeTransferFrom(r.payee, r.payer, _refundAmount);
        r.status = ReceiptStatus.Refunded;
        // Verdict spoken: the adjudicated refund closes the dispute, so finality
        // is reached here rather than asserted up front at mint time.
        r.finality = ReceiptFinality.Final;
        emit ReceiptRefunded(_receiptId, _refundAmount, block.timestamp);
        return true;
    }

    // ═══════════════════════════════════════════════════
    // FINALITY / BOUNDARY (adjudicated + post-hoc paths)
    // ═══════════════════════════════════════════════════

    /// @notice Adjudicated path: the verdict was minted first (off-chain, signed)
    /// and this receipt consumes it -- the receipt holds the backward reference.
    function attachVerdict(bytes32 _receiptId, bytes32 _verdictDigest) external onlyAdmin returns (bool) {
        PaymentReceipt storage r = receipts[_receiptId];
        require(r.receiptId != bytes32(0), "L5x402: no receipt");
        require(_verdictDigest != bytes32(0), "L5x402: empty verdict");
        require(r.verdictRef == bytes32(0), "L5x402: verdict already set");
        // H4: a verdict may only render *final* an action whose value has actually
        // moved. A receipt that never settled must not be promoted to Final.
        require(r.status == ReceiptStatus.Settled, "L5x402: value not moved");
        r.verdictRef = _verdictDigest;
        r.finality = ReceiptFinality.Final;
        emit ReceiptCitedVerdict(_receiptId, _verdictDigest, block.timestamp);
        return true;
    }

    /// @notice Post-release dispute: the receipt cannot cite a verdict that did
    /// not exist when it was minted, so it declares itself provisional and stops.
    function markProvisional(bytes32 _receiptId) external onlyAdmin returns (bool) {
        PaymentReceipt storage r = receipts[_receiptId];
        require(r.receiptId != bytes32(0), "L5x402: no receipt");
        require(r.finality != ReceiptFinality.ProvisionalSubjectToVerdict, "L5x402: already provisional");
        // H4: provisionality implies value has moved and is subject to reversal;
        // a never-moved receipt is Open and must not claim this state either.
        require(r.finality != ReceiptFinality.Open, "L5x402: value not moved");
        r.finality = ReceiptFinality.ProvisionalSubjectToVerdict;
        emit ReceiptMarkedProvisional(_receiptId, block.timestamp);
        return true;
    }

    /// @notice Post-hoc verdict: minted after the receipt, so it holds the
    /// backward reference. Flipping finality is the verdict's claim to make.
    function recordPostHocVerdict(bytes32 _receiptId, bytes32 _verdictDigest, bool _isFinal)
        external
        onlyAdmin
        returns (bool)
    {
        PaymentReceipt storage r = receipts[_receiptId];
        require(r.receiptId != bytes32(0), "L5x402: no receipt");
        require(_verdictDigest != bytes32(0), "L5x402: empty verdict");
        require(verdicts[_verdictDigest].verdictId == bytes32(0), "L5x402: duplicate verdict");
        // H4: only a receipt whose value moved can be rendered final by a verdict.
        if (_isFinal) {
            require(r.status == ReceiptStatus.Settled || r.status == ReceiptStatus.Refunded, "L5x402: value not moved");
        }
        verdicts[_verdictDigest] = Verdict({
            verdictId: _verdictDigest,
            receiptRef: _receiptId, // backward reference
            isFinal: _isFinal,
            timestamp: block.timestamp
        });
        verdictOfReceipt[_receiptId] = _verdictDigest;
        if (_isFinal) {
            r.finality = ReceiptFinality.Final;
        }
        emit VerdictRecorded(_verdictDigest, _receiptId, _isFinal, block.timestamp);
        return true;
    }

    // ═══════════════════════════════════════════════════
    // VERIFY EVIDENCE
    // ═══════════════════════════════════════════════════

    /// @notice 校验服务端签名的收据证据（Signed Evidence Pattern）
    function verifyReceiptEvidence(
        bytes32 _receiptId,
        bytes32 _evidenceHash,
        bytes calldata _signature,
        address _signer
    ) external returns (bool valid) {
        PaymentReceipt storage r = receipts[_receiptId];
        require(r.receiptId != bytes32(0), "L5x402: no receipt");
        // P0 #2 binding (a): the presented evidence must be the exact digest the
        // receipt committed to at record time -- not a separately supplied hash.
        if (_evidenceHash != r.payloadHash) return false;
        // P0 #2 binding (b): the signer is pinned to the service of record (the
        // payee), not chosen by the caller.
        if (_signer != r.payee) return false;
        // 恢复签名者并比对。H3: the evidence signature is domain-bound (chainId +
        // verifyingContract + receiptId + payloadHash), so a signature for one receipt
        // cannot be replayed against another receipt or another chain/deployment.
        address recovered = ECDSA.recover(receiptEvidenceDigest(_receiptId, r.payloadHash), _signature);
        valid = recovered == _signer;
        if (valid) {
            r.evidenceVerified = true;
            emit EvidenceVerified(_receiptId, _signer, _evidenceHash, block.timestamp);
        }
    }

    /// @notice Canonical, fully-enumerated action digest (P0 #3). A third party
    ///   recomputes this from the field set and gets byte-stable bytes; the
    ///   payer signs exactly this digest (EIP-712), so approval binds to the
    ///   complete typed action rather than to an under-specified blob.
    function actionDigest(
        bytes32 _requestId,
        address _payer,
        address _payee,
        address _token,
        uint256 _amount,
        bytes32 _routeHash,
        bytes32 _payloadHash,
        bytes32 _permissionHash,
        uint256 _deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYMENT_ACTION_TYPEHASH,
                _requestId,
                _payer,
                _payee,
                _token,
                _amount,
                _routeHash,
                _payloadHash,
                _permissionHash,
                _deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// @notice H3: canonical, domain-bound digest a service signs for its evidence.
    ///   Same shape as actionDigest (EIP-712) but bound to (receiptId, payloadHash).
    function receiptEvidenceDigest(bytes32 _receiptId, bytes32 _payloadHash) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(RECEIPT_EVIDENCE_TYPEHASH, _receiptId, _payloadHash));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    // ═══════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════

    function getReceipt(bytes32 _receiptId) external view returns (PaymentReceipt memory) {
        return receipts[_receiptId];
    }

    function getReceiptsByPayee(address _payee) external view returns (bytes32[] memory) {
        return payeeReceipts[_payee];
    }

    function getReceiptsByPayer(address _payer) external view returns (bytes32[] memory) {
        return payerReceipts[_payer];
    }

    /// @notice x402 权限管理器通用快照视图（对齐 checklist #6 的 getDelegatedSpendSnapshot）
    function getDelegatedSpendSnapshot(bytes32 _policyId)
        external
        view
        returns (
            address delegate,
            uint256 spentTotal,
            uint256 spentPeriod,
            uint256 requestCount,
            uint256 periodStart,
            uint256 maxPerPeriod
        )
    {
        SpendSnapshot storage snap = snapshots[_policyId];
        delegate = snap.delegate;
        spentTotal = snap.spentTotal;
        requestCount = snap.requestCount;
        periodStart = snap.periodStart;
        maxPerPeriod = snap.maxPerPeriod;
        // 若周期已过返回 0 已花费
        if (block.timestamp > snap.periodStart + snap.period) {
            spentPeriod = 0;
        } else {
            spentPeriod = snap.spentPeriod;
        }
    }

    /// @notice 快照原始数据（供审计/裁决）
    function getSnapshot(bytes32 _policyId) external view returns (SpendSnapshot memory) {
        return snapshots[_policyId];
    }

    // ═══════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════

    function _generateReceiptId(
        bytes32 _requestId,
        address _payer,
        address _payee,
        uint256 _amount,
        bytes32 _payloadHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_requestId, _payer, _payee, _amount, _payloadHash));
    }

    function _bytes32ToString(bytes32 _h) internal pure returns (string memory) {
        // 简化：bytes32 直接转为十六进制字符串前缀（route hash）
        bytes memory s = new bytes(66);
        s[0] = "0";
        s[1] = "x";
        bytes16 hexDigits = "0123456789abcdef";
        bytes32 val = _h;
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(uint256(val >> (i * 8)));
            s[2 + i * 2] = hexDigits[b >> 4];
            s[3 + i * 2] = hexDigits[b & 0x0f];
        }
        return string(s);
    }
}
