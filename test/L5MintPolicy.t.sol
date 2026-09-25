// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {YUAN} from "../src/YUAN.sol";

/// @title L5MintPolicyTest
/// @notice M5 (resolved 2026-09-25 by the owner / 源基金会): issuance authority
///   belongs to the Foundation. A whitelisted provider may only mint within the
///   ceiling the Foundation sets for it, and that ceiling is the market-responsive
///   lever the Foundation adjusts. An uncapped provider mints nothing (fail-closed).
contract L5MintPolicyTest is Test {
    address internal kOwner = address(0xF00D);
    address internal kProvider = address(0xB0B);
    address internal kRecipient = address(0xCAFE);
    address internal kRando = address(0xDEAD);

    uint256 internal constant RATE = 1 ether; // 1 服务单元 = 1e18 YUAN
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

    function test_EnableWithoutCap_CannotMint() public {
        // enabling a provider grants no issuance right on its own (fail-closed)
        vm.prank(kOwner);
        yuan.setServiceProvider(kProvider, true);
        vm.prank(kProvider);
        vm.expectRevert(bytes("YUAN: provider cap exceeded"));
        yuan.issueService(kRecipient, 1);
    }

    function test_MintWithinCap_Succeeds() public {
        _enableProvider(5 ether);
        vm.prank(kProvider);
        yuan.issueService(kRecipient, 3);
        assertEq(yuan.balanceOf(kRecipient), 3 ether);
        assertEq(yuan.providerMinted(kProvider), 3 ether);
    }

    function test_MintBeyondCap_Reverts() public {
        _enableProvider(5 ether);
        vm.prank(kProvider);
        yuan.issueService(kRecipient, 5);
        // cumulative 6 > cap 5
        vm.prank(kProvider);
        vm.expectRevert(bytes("YUAN: provider cap exceeded"));
        yuan.issueService(kRecipient, 1);
        assertEq(yuan.totalSupply(), 5 ether);
    }

    function test_CumulativeAcrossCalls_IsBounded() public {
        _enableProvider(5 ether);
        vm.startPrank(kProvider);
        yuan.issueService(kRecipient, 2);
        yuan.issueService(kRecipient, 2);
        vm.stopPrank();
        assertEq(yuan.providerMinted(kProvider), 4 ether);
        vm.prank(kProvider);
        vm.expectRevert(bytes("YUAN: provider cap exceeded"));
        yuan.issueService(kRecipient, 2); // 4 + 2 > 5
    }

    /// @notice The market-responsive lever: the Foundation lowers a cap and further
    ///   issuance is immediately blocked -- supply is under Foundation control.
    function test_FoundationLoweringCap_BlocksFurtherMint() public {
        _enableProvider(10 ether);
        vm.prank(kProvider);
        yuan.issueService(kRecipient, 4);

        vm.prank(kOwner);
        yuan.setProviderMintCap(kProvider, 4 ether); // tighten to already-issued level

        vm.prank(kProvider);
        vm.expectRevert(bytes("YUAN: provider cap exceeded"));
        yuan.issueService(kRecipient, 1);
    }

    function test_SetProviderMintCap_OnlyOwner() public {
        vm.prank(kRando);
        vm.expectRevert();
        yuan.setProviderMintCap(kProvider, 100 ether);
        assertEq(yuan.providerMintCap(kProvider), 0);
    }

    function test_SetAnchorRate_OnlyOwner() public {
        vm.prank(kRando);
        vm.expectRevert();
        yuan.setAnchorRate(2 ether);
        assertEq(yuan.yuanPerServiceUnit(), RATE);

        vm.prank(kOwner);
        yuan.setAnchorRate(2 ether);
        assertEq(yuan.yuanPerServiceUnit(), 2 ether);
    }

    function test_NonProvider_CannotMint_EvenWithCap() public {
        _enableProvider(5 ether);
        // a random address has value but is not a provider
        vm.prank(kRando);
        vm.expectRevert(bytes("YUAN: not a service provider"));
        yuan.issueService(kRecipient, 1);
    }

    function test_OwnerControlsRate_IssuanceScalesWithIt() public {
        _enableProvider(100 ether);
        vm.prank(kOwner);
        yuan.setAnchorRate(2 ether); // 1 unit -> 2 YUAN
        vm.prank(kProvider);
        yuan.issueService(kRecipient, 3); // 3 units -> 6 ether
        assertEq(yuan.balanceOf(kRecipient), 6 ether);
    }
}
