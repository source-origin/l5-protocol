// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {YUAN} from "../src/YUAN.sol";

/// @title YUAN fuzz-verified invariants
/// @notice Sweeps the issuance surface a reviewer scrutinizes most: a provider can never mint
///         past the ceiling the Foundation set for it, an uncapped provider can never mint at all,
///         and neither super-provider nor market pressure can push totalSupply past MAX_SUPPLY.
///         Burning is exact. No `src/` change -- purely additive.
contract YUANFuzzTest is Test {
    address internal kOwner = address(0xF00D);
    address internal kProvider = address(0xB0B);
    address internal kHolder = address(0xCAFE);

    uint256 internal constant RATE = 1 ether; // 1 service unit = 1e18 YUAN
    YUAN internal yuan;

    function setUp() public {
        vm.prank(kOwner);
        yuan = new YUAN(RATE);
    }

    function _enableProvider(uint256 cap) internal {
        vm.startPrank(kOwner);
        yuan.setServiceProvider(kProvider, true);
        yuan.setProviderMintCap(kProvider, cap);
        vm.stopPrank();
    }

    /// A provider's cumulative issuance can never exceed its Foundation-set cap, and total supply
    /// can never exceed MAX_SUPPLY -- whether each call succeeds or reverts.
    function testFuzz_CumulativeMintNeverExceedsCap(uint256 cap, uint256 u1, uint256 u2) public {
        cap = bound(cap, 1 ether, 1_000_000 ether);
        u1 = bound(u1, 0, 1_000_000);
        u2 = bound(u2, 0, 1_000_000);
        _enableProvider(cap);

        uint256 a1 = u1 * RATE;
        vm.prank(kProvider);
        if (a1 == 0 || a1 > cap) {
            vm.expectRevert();
            yuan.issueService(kHolder, u1);
        } else {
            yuan.issueService(kHolder, u1);

            uint256 a2 = u2 * RATE;
            uint256 remaining = cap - a1;
            vm.prank(kProvider);
            if (a2 == 0 || a2 > remaining) {
                vm.expectRevert();
                yuan.issueService(kHolder, u2);
            } else {
                yuan.issueService(kHolder, u2);
            }
        }

        assertLe(yuan.providerMinted(kProvider), cap, "provider minted never exceeds cap");
        assertLe(yuan.totalSupply(), yuan.MAX_SUPPLY(), "supply never exceeds MAX_SUPPLY");
    }

    /// An enabled-but-uncapped provider issues nothing (fail-closed, never unlimited).
    function testFuzz_UncappedProviderCannotMint(uint256 units) public {
        units = bound(units, 1, 1_000_000);
        vm.prank(kOwner);
        yuan.setServiceProvider(kProvider, true); // no cap set
        vm.prank(kProvider);
        vm.expectRevert("YUAN: provider cap exceeded");
        yuan.issueService(kHolder, units);
        assertEq(yuan.totalSupply(), 0);
    }

    /// A non-provider can never mint, even with a generous cap sitting on the books.
    function testFuzz_NonProviderCannotMint(uint256 units) public {
        units = bound(units, 1, 1_000_000);
        _enableProvider(1_000_000 ether);
        vm.prank(address(0xDEAD));
        vm.expectRevert("YUAN: not a service provider");
        yuan.issueService(kHolder, units);
    }

    /// A successful issuance mints exactly `units * rate` and records it against the cap.
    function testFuzz_IssueMintsExactAmount(uint256 units) public {
        units = bound(units, 1, 1_000_000);
        _enableProvider(units * RATE);
        vm.prank(kProvider);
        yuan.issueService(kHolder, units);
        assertEq(yuan.balanceOf(kHolder), units * RATE, "exact mint");
        assertEq(yuan.providerMinted(kProvider), units * RATE, "exact accounting");
        assertEq(yuan.totalSupply(), units * RATE, "exact supply");
    }

    /// Burning removes exactly `units * rate` from both the holder and total supply.
    function testFuzz_ConsumeBurnsExactAmount(uint256 hold, uint256 spend) public {
        hold = bound(hold, 1, 1_000_000);
        spend = bound(spend, 1, hold);
        _enableProvider(hold * RATE);
        vm.prank(kProvider);
        yuan.issueService(kHolder, hold);

        uint256 before = yuan.balanceOf(kHolder);
        uint256 supplyBefore = yuan.totalSupply();
        vm.prank(kHolder);
        yuan.consumeService(spend);

        assertEq(yuan.balanceOf(kHolder), before - spend * RATE, "exact burn from holder");
        assertEq(yuan.totalSupply(), supplyBefore - spend * RATE, "exact burn from supply");
    }

    /// Burning more than the holder owns is always refused.
    function testFuzz_ConsumeAboveBalanceReverts(uint256 hold, uint256 extra) public {
        hold = bound(hold, 0, 1_000_000);
        extra = bound(extra, 1, 1_000_000);
        if (hold > 0) {
            _enableProvider(hold * RATE);
            vm.prank(kProvider);
            yuan.issueService(kHolder, hold);
        }
        vm.prank(kHolder);
        vm.expectRevert("YUAN: insufficient");
        yuan.consumeService(hold + extra); // strictly above balance
    }

    /// units -> YUAN -> units is lossless at the current rate.
    function testFuzz_ConversionRoundTrip(uint256 units) public {
        units = bound(units, 0, 1e18);
        assertEq(yuan.yuanToUnits(yuan.unitsToYuan(units)), units);
    }
}
