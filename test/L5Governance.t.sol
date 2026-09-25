// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {YUAN} from "src/YUAN.sol";

/// @dev Minimal on-chain 2-of-3 approval multisig used only to *exercise* the
///      governance wiring in tests. A production deployment uses a Gnosis Safe;
///      the threshold semantics mirror it: 2 distinct signers must approve, and
///      an EOA signer holds no privileged role of its own.
contract MockSafe2of3 {
    address[3] internal signers;
    mapping(bytes32 => mapping(address => bool)) public approved;
    mapping(bytes32 => uint256) public approvals;

    constructor(address a, address b, address c) {
        signers[0] = a;
        signers[1] = b;
        signers[2] = c;
    }

    function isSigner(address who) public view returns (bool) {
        return who == signers[0] || who == signers[1] || who == signers[2];
    }

    function opHash(address target, uint256 value, bytes memory data) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data));
    }

    function approve(address target, uint256 value, bytes memory data) external {
        require(isSigner(msg.sender), "Safe: not a signer");
        bytes32 h = opHash(target, value, data);
        if (!approved[h][msg.sender]) {
            approved[h][msg.sender] = true;
            approvals[h] += 1;
        }
    }

    function execute(address target, uint256 value, bytes memory data) external payable {
        bytes32 h = opHash(target, value, data);
        require(approvals[h] >= 2, "Safe: threshold not met");
        approvals[h] = 0;
        (bool ok,) = target.call{value: value}(data);
        require(ok, "Safe: call failed");
    }
}

/// @title L5 governance wiring — 2-of-3 Safe + 48h TimelockController (M1 operational half)
/// @notice Proves the owner's ruling (2026-09-25: threshold 2-of-3, delay 48h) as code:
///         only the multisig schedules, only the multisig executes, nothing lands before
///         the delay, no EOA holds a fast path, and the two-step ownership handover
///         completes *only* through the timelock.
contract L5GovernanceTest is Test {
    TimelockController internal timelock;
    MockSafe2of3 internal safe;
    YUAN internal yuan;

    uint256 internal constant DELAY = 48 hours;
    address internal s1;
    address internal s2;
    address internal s3;

    function setUp() public {
        s1 = vm.addr(0x5111);
        s2 = vm.addr(0x5222);
        s3 = vm.addr(0x5333);
        safe = new MockSafe2of3(s1, s2, s3);

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(safe);
        executors[0] = address(safe);
        // admin = address(0): the timelock administers itself -- no fast-path key.
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        yuan = new YUAN(1); // deployer (this test) is the current owner
    }

    // ---- helpers -------------------------------------------------------------

    function _accept() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("acceptOwnership()");
    }

    function _scheduleViaSafe(address target, uint256 value, bytes memory data) internal {
        bytes memory inner =
            abi.encodeCall(TimelockController.schedule, (target, value, data, bytes32(0), bytes32(0), DELAY));
        vm.prank(s1);
        safe.approve(address(timelock), 0, inner);
        vm.prank(s2);
        safe.approve(address(timelock), 0, inner);
        safe.execute(address(timelock), 0, inner);
    }

    function _executeViaSafe(address target, uint256 value, bytes memory data) internal {
        bytes memory inner = abi.encodeCall(TimelockController.execute, (target, value, data, bytes32(0), bytes32(0)));
        vm.prank(s1);
        safe.approve(address(timelock), 0, inner);
        vm.prank(s2);
        safe.approve(address(timelock), 0, inner);
        safe.execute(address(timelock), 0, inner);
    }

    function _completeHandover() internal {
        yuan.transferOwnership(address(timelock));
        bytes memory accept = _accept();
        bytes32 id = timelock.hashOperation(address(yuan), 0, accept, bytes32(0), bytes32(0));
        _scheduleViaSafe(address(yuan), 0, accept);
        vm.warp(timelock.getTimestamp(id) + 1);
        _executeViaSafe(address(yuan), 0, accept);
        assertEq(yuan.owner(), address(timelock));
    }

    // ---- the ruling, as code --------------------------------------------------

    function test_MinDelayIs48h() public view {
        assertEq(timelock.getMinDelay(), 48 hours);
        assertEq(timelock.getMinDelay(), 172800);
    }

    function test_Roles_OnlySafeIsProposerAndExecutor() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(safe)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(safe)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), s1));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), s1));
        // a signer is an EOA with no direct role; the multisig is a contract
        assertEq(s1.code.length, 0);
        assertGt(address(safe).code.length, 0);
    }

    function test_NoAdminFastPath() public view {
        // admin = address(0): nobody holds DEFAULT_ADMIN_ROLE except the timelock itself
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), s1));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function test_NonProposer_CannotSchedule() public {
        // an EOA signer cannot bypass the Safe to schedule directly
        vm.prank(s1);
        vm.expectRevert();
        timelock.schedule(address(yuan), 0, new bytes(0), bytes32(0), bytes32(0), DELAY);
    }

    function test_ScheduleBelowMinDelay_Reverts() public {
        vm.prank(address(safe));
        vm.expectRevert();
        timelock.schedule(address(yuan), 0, new bytes(0), bytes32(0), bytes32(0), DELAY - 1);
    }

    function test_Threshold_OneApprovalInsufficient() public {
        bytes memory inner =
            abi.encodeCall(TimelockController.schedule, (address(yuan), 0, _accept(), bytes32(0), bytes32(0), DELAY));
        vm.prank(s1);
        safe.approve(address(timelock), 0, inner);
        vm.expectRevert("Safe: threshold not met");
        safe.execute(address(timelock), 0, inner);
    }

    function test_NonSigner_CannotApprove() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert("Safe: not a signer");
        safe.approve(address(timelock), 0, new bytes(0));
    }

    // ---- handover + privileged path -------------------------------------------

    function test_Migration_HandoverCompletesOnlyViaTimelock() public {
        assertEq(yuan.owner(), address(this)); // deployer owns it today
        yuan.transferOwnership(address(timelock)); // step 1
        assertEq(yuan.owner(), address(this)); // two-step: not yet
        assertEq(yuan.pendingOwner(), address(timelock));

        bytes memory accept = _accept();
        bytes32 id = timelock.hashOperation(address(yuan), 0, accept, bytes32(0), bytes32(0));
        _scheduleViaSafe(address(yuan), 0, accept);
        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id)); // not before the delay

        vm.warp(timelock.getTimestamp(id) + 1);
        assertTrue(timelock.isOperationReady(id));
        _executeViaSafe(address(yuan), 0, accept);

        assertEq(yuan.owner(), address(timelock));
        assertEq(yuan.pendingOwner(), address(0));
    }

    function test_ExecuteBeforeDelay_Reverts() public {
        yuan.transferOwnership(address(timelock));
        bytes memory accept = _accept();
        _scheduleViaSafe(address(yuan), 0, accept);
        vm.prank(address(safe));
        vm.expectRevert();
        timelock.execute(address(yuan), 0, accept, bytes32(0), bytes32(0));
    }

    function test_PrivilegedCall_RoutesThroughTimelockAfterDelay() public {
        _completeHandover();

        // the former owner can no longer act directly
        vm.expectRevert();
        yuan.setAnchorRate(5);

        bytes memory setRate = abi.encodeCall(YUAN.setAnchorRate, (5));
        bytes32 id = timelock.hashOperation(address(yuan), 0, setRate, bytes32(0), bytes32(0));
        _scheduleViaSafe(address(yuan), 0, setRate);
        assertFalse(timelock.isOperationReady(id));

        vm.warp(timelock.getTimestamp(id) + 1);
        assertTrue(timelock.isOperationReady(id));
        _executeViaSafe(address(yuan), 0, setRate);

        assertEq(yuan.yuanPerServiceUnit(), 5);
    }
}
