// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L5Delegation} from "../src/L5Delegation.sol";
import {YUAN} from "../src/YUAN.sol";

/// @title L5OwnershipTest
/// @notice M1 (stopgap): every privileged path in L5 is `onlyOwner`. A one-step
///   `transferOwnership` to a wrong or uncontrollable address would brick admin
///   permanently (frozen disputes / escrow / bonds). `Ownable2Step` makes the
///   handover complete only when the incoming owner explicitly accepts, and the
///   pending state is readable on-chain. Multisig / timelock wiring remains an
///   operational choice for the owner (see docs/GOVERNANCE-M1.md).
contract L5OwnershipTest is Test {
    address internal kOwner = address(0xABCD);
    address internal kNew = address(0xBEEF);
    address internal kRando = address(0xDEAD);

    L5Delegation internal delegation;
    YUAN internal yuan;

    function setUp() public {
        vm.prank(kOwner);
        delegation = new L5Delegation();
        vm.prank(kOwner);
        yuan = new YUAN(1 ether);
    }

    function test_Owner_SetAtConstruction() public view {
        assertEq(delegation.owner(), kOwner);
        assertEq(yuan.owner(), kOwner);
    }

    function test_TransferOwnership_IsTwoStep() public {
        vm.prank(kOwner);
        delegation.transferOwnership(kNew);
        assertEq(delegation.owner(), kOwner, "owner must not change until accepted");
        assertEq(delegation.pendingOwner(), kNew, "incoming owner must be pending");
    }

    function test_AcceptOwnership_CompletesTransfer() public {
        vm.prank(kOwner);
        delegation.transferOwnership(kNew);
        vm.prank(kNew);
        delegation.acceptOwnership();
        assertEq(delegation.owner(), kNew);
        assertEq(delegation.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_OnlyPendingOwner() public {
        vm.prank(kOwner);
        delegation.transferOwnership(kNew);
        vm.prank(kRando);
        vm.expectRevert();
        delegation.acceptOwnership();
        assertEq(delegation.owner(), kOwner);
    }

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(kRando);
        vm.expectRevert();
        delegation.transferOwnership(kNew);
    }

    function test_PrivilegedPath_FollowsNewOwner() public {
        // rando can never reach a privileged path
        vm.prank(kRando);
        vm.expectRevert();
        delegation.setIdentityContract(kRando);

        vm.prank(kOwner);
        delegation.transferOwnership(kNew);
        vm.prank(kNew);
        delegation.acceptOwnership();

        // the previous owner lost authority
        vm.prank(kOwner);
        vm.expectRevert();
        delegation.setIdentityContract(kRando);

        // the accepted owner holds it
        vm.prank(kNew);
        delegation.setIdentityContract(kRando);
        assertEq(delegation.identityContract(), kRando);
    }

    function test_YUAN_TransferAlsoTwoStep() public {
        vm.prank(kOwner);
        yuan.transferOwnership(kNew);
        assertEq(yuan.owner(), kOwner);
        vm.prank(kNew);
        yuan.acceptOwnership();
        assertEq(yuan.owner(), kNew);
    }
}
