// SPDX-License-Identifier: ORIGIN-1.0
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title DeployGovernance
 * @notice M1 operational half: stand up the owner's 2-of-3 multisig + 48h timelock and
 *         hand every privileged L5 contract over to it.
 *
 * Owner's ruling (2026-09-25): threshold 2-of-3, timelock delay 48h.
 *
 * The multisig is an external Safe held by the human keyholders (Constitution L0:
 * humans are the highest authority; automation holds no signing key). This script does
 * NOT create the Safe -- it takes its address from the environment and wires the
 * TimelockController to it:
 *
 *     proposer = Safe          (only the 2-of-3 quorum may schedule)
 *     executor = Safe
 *     admin    = address(0)    -> self-administered: no fast-path admin key
 *
 * Ownership handover is two-step (Ownable2Step):
 *   step 1 (this script): the current owner calls transferOwnership(timelock)
 *   step 2 (the Safe):    propose + (after 48h) execute acceptOwnership() via the timelock
 * Step 2 cannot be done here: the new owner (the timelock) must itself call
 * acceptOwnership, and that call is itself timelocked. The exact calldata is printed.
 *
 * Env:
 *   MULTISIG        address  (required)  the 2-of-3 Safe
 *   TIMELOCK_DELAY  uint256  (optional)  seconds; default 48 hours = 172800
 *   AGENT_ESCROW, AGENT_IDENTITY, L5X402, L5_DELEGATION, YUAN, CREDIT_SCORE,
 *   X402_ADAPTER    address  (optional)  deployed L5 contracts to hand over
 *
 * Usage:
 *   MULTISIG=0x... AGENT_ESCROW=0x... YUAN=0x... \
 *     forge script script/DeployGovernance.s.sol --rpc-url $RPC --broadcast
 */
contract DeployGovernance is Script {
    uint256 internal constant DEFAULT_DELAY = 48 hours;

    struct Target {
        string name;
        address addr;
    }

    function run() external returns (address timelock) {
        uint256 delay = vm.envOr("TIMELOCK_DELAY", DEFAULT_DELAY);
        address multisig = vm.envAddress("MULTISIG");
        require(multisig != address(0), "Governance: zero multisig");
        require(delay >= 1 hours, "Governance: delay too short");

        Target[7] memory targets;
        targets[0] = Target("AgentEscrow", vm.envOr("AGENT_ESCROW", address(0)));
        targets[1] = Target("AgentIdentity", vm.envOr("AGENT_IDENTITY", address(0)));
        targets[2] = Target("L5x402", vm.envOr("L5X402", address(0)));
        targets[3] = Target("L5Delegation", vm.envOr("L5_DELEGATION", address(0)));
        targets[4] = Target("YUAN", vm.envOr("YUAN", address(0)));
        targets[5] = Target("CreditScore", vm.envOr("CREDIT_SCORE", address(0)));
        targets[6] = Target("X402FacilitatorAdapter", vm.envOr("X402_ADAPTER", address(0)));

        vm.startBroadcast();
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = multisig;
        executors[0] = multisig;
        TimelockController tl = new TimelockController(delay, proposers, executors, address(0));
        timelock = address(tl);

        for (uint256 i = 0; i < targets.length; ++i) {
            if (targets[i].addr == address(0)) continue;
            Ownable2Step(targets[i].addr).transferOwnership(timelock);
            console2.log("step1 transferOwnership", targets[i].name, targets[i].addr);
        }
        vm.stopBroadcast();

        console2.log("timelock", timelock);
        console2.log("minDelay (seconds)", delay);
        console2.log("proposer/executor (Safe)", multisig);
        _logStep2(timelock, targets);
    }

    /// @dev Print the acceptOwnership() op the Safe must schedule + execute (after the delay).
    function _logStep2(address timelock, Target[7] memory targets) internal view {
        console2.log("--- step 2: Safe proposes, then (after delay) executes ---");
        for (uint256 i = 0; i < targets.length; ++i) {
            if (targets[i].addr == address(0)) continue;
            console2.log("target", targets[i].name, targets[i].addr);
            console2.logBytes(abi.encodeWithSignature("acceptOwnership()"));
        }
        console2.log("schedule(target, 0, data, 0x0, 0x0, delay) on", timelock);
    }
}
