// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

/// @title L5Types — shared, single-source projections across L5 contracts
/// @notice A view projection must be declared exactly ONCE and imported by both
///         the producer and the consumer. Re-declaring a look-alike struct on the
///         consumer side and decoding a different struct into it is not a
///         projection, it is a silent reinterpretation of another contract's
///         storage layout. See docs/FINDING-2026-10-26-L5-01-abi-mismatch.md.
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
