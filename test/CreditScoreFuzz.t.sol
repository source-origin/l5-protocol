// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CreditScore, AgentView, IAgentIdentity} from "src/CreditScore.sol";

/// @notice Minimal stand-in for AgentIdentity exposing a settable view.
contract MockIdentity is IAgentIdentity {
    AgentView internal v;

    function set(AgentView calldata nv) external {
        v = nv;
    }

    function agents(address) external view returns (AgentView memory) {
        return v;
    }

    function getAgentStatus(address) external pure returns (uint8) {
        return 1;
    }
}

/// @title CreditScore fuzz-verified invariants
/// @notice Sweeps the scoring surface: the composite score is always capped at SCORE_MAX, the
///         returned limit is always derived deterministically from the stored score, more slashes
///         never raise a score, and more contribution never lowers it. No `src/` change.
contract CreditScoreFuzzTest is Test {
    CreditScore internal cs;
    MockIdentity internal id;

    function setUp() public {
        id = new MockIdentity();
        cs = new CreditScore(address(id));
    }

    function _view(uint256 txns, uint256 succ, uint256 quality, uint256 endorsements, uint256 clock, uint256 slashes)
        internal
        pure
        returns (AgentView memory a)
    {
        a.totalRevenue = 0;
        a.totalTransactions = txns;
        a.totalSuccessful = succ;
        a.reputationScore = 0;
        a.stakedAmount = 0;
        a.endorsementCount = endorsements;
        a.longevityBonus = 0;
        a.slashCount = slashes;
        a.contributionClockScore = clock;
        a.totalQuality = quality;
        a.totalComplexity = 0;
        a.totalTimeliness = 0;
    }

    /// The composite score is a bounded quantity: never above SCORE_MAX, whatever the inputs.
    function testFuzz_ScoreNeverExceedsMax(
        uint256 txns,
        uint256 succ,
        uint256 quality,
        uint256 endorsements,
        uint256 clock,
        uint256 slashes
    ) public {
        txns = bound(txns, 0, 1e7);
        succ = bound(succ, 0, 1e7);
        quality = bound(quality, 0, 1e7);
        endorsements = bound(endorsements, 0, 1e7);
        clock = bound(clock, 0, 1e7);
        slashes = bound(slashes, 0, 1e7);

        id.set(_view(txns, succ, quality, endorsements, clock, slashes));
        (uint256 score,) = cs.calculateCredit(address(0xA));
        assertLe(score, cs.SCORE_MAX(), "score capped at SCORE_MAX");
    }

    /// The stored score and derived limit are always internally consistent.
    function testFuzz_LimitDerivesFromStoredScore(
        uint256 txns,
        uint256 succ,
        uint256 quality,
        uint256 endorsements,
        uint256 clock,
        uint256 slashes
    ) public {
        txns = bound(txns, 0, 1e6);
        succ = bound(succ, 0, txns); // realizable success rate
        quality = bound(quality, 0, 1e6);
        endorsements = bound(endorsements, 0, 1e6);
        clock = bound(clock, 0, 1e6);
        slashes = bound(slashes, 0, 1e6);

        id.set(_view(txns, succ, quality, endorsements, clock, slashes));
        (uint256 score, uint256 limit) = cs.calculateCredit(address(0xA));

        assertEq(cs.getCreditScore(address(0xA)), score, "stored score == returned");
        assertEq(limit, (score * cs.creditLimitPerK()) / 1000, "limit == score * k / 1000");
        assertEq(cs.getCreditLimit(address(0xA)), limit, "view limit == returned limit");
    }

    /// Punishment is monotone: adding slashes never increases the score.
    function testFuzz_MoreSlashesNeverRaiseScore(
        uint256 txns,
        uint256 succ,
        uint256 quality,
        uint256 endorsements,
        uint256 clock,
        uint256 base,
        uint256 extra
    ) public {
        txns = bound(txns, 0, 1000);
        succ = bound(succ, 0, txns);
        quality = bound(quality, 0, 20000);
        endorsements = bound(endorsements, 0, 100);
        clock = bound(clock, 0, 20000);
        base = bound(base, 0, 50);
        extra = bound(extra, 1, 50);

        id.set(_view(txns, succ, quality, endorsements, clock, base));
        (uint256 lo,) = cs.calculateCredit(address(0xA));

        id.set(_view(txns, succ, quality, endorsements, clock, base + extra));
        (uint256 hi,) = cs.calculateCredit(address(0xB));

        assertLe(hi, lo, "more slashes never raise the score");
    }

    /// Contribution is monotone: more contribution-clock score never lowers the score.
    function testFuzz_MoreContributionNeverLowersScore(
        uint256 txns,
        uint256 succ,
        uint256 quality,
        uint256 endorsements,
        uint256 slashes,
        uint256 base,
        uint256 extra
    ) public {
        txns = bound(txns, 0, 1000);
        succ = bound(succ, 0, txns);
        quality = bound(quality, 0, 20000);
        endorsements = bound(endorsements, 0, 100);
        slashes = bound(slashes, 0, 50);
        base = bound(base, 0, 20000);
        extra = bound(extra, 0, 20000);

        id.set(_view(txns, succ, quality, endorsements, base, slashes));
        (uint256 lo,) = cs.calculateCredit(address(0xA));

        id.set(_view(txns, succ, quality, endorsements, base + extra, slashes));
        (uint256 hi,) = cs.calculateCredit(address(0xB));

        assertGe(hi, lo, "more contribution never lowers the score");
    }

    /// Scoring is a pure function of the identity view: identical inputs, identical score.
    function testFuzz_DeterministicGivenSameView(
        uint256 txns,
        uint256 succ,
        uint256 quality,
        uint256 endorsements,
        uint256 clock,
        uint256 slashes
    ) public {
        txns = bound(txns, 0, 1e6);
        succ = bound(succ, 0, txns);
        quality = bound(quality, 0, 1e6);
        endorsements = bound(endorsements, 0, 1e6);
        clock = bound(clock, 0, 1e6);
        slashes = bound(slashes, 0, 1e6);

        id.set(_view(txns, succ, quality, endorsements, clock, slashes));
        (uint256 a,) = cs.calculateCredit(address(0xA));
        (uint256 b,) = cs.calculateCredit(address(0xB));
        assertEq(a, b, "same view -> same score");
    }
}
