// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";

/// @notice Redeploy ONLY the BetEscrowFactory, reusing the existing protocol
///         contracts. Use when the factory changes — the registry (storage +
///         proxy), allowlist, pause, and registrations stay put; only the factory
///         address changes. The new factory is registered as the registry's
///         authorized factory so it can onboard arbitered escrows.
///
///   ALLOWLIST_ADDRESS       existing StablecoinAllowlist
///   PAUSE_ADDRESS           existing EmergencyPauseController
///   AGENT_REGISTRY_ADDRESS  existing AgentRegistry PROXY
///   REVENUE_WALLET          protocol revenue wallet (immutable in the factory)
///   ARB_BASE_FEE_BPS        default 10 (0.1%)
///
///   forge script script/DeployFactory.s.sol --rpc-url $BASE_RPC \
///     --private-key $KEY --broadcast
contract DeployFactory is Script {
    function run() external {
        address allowlist = vm.envAddress("ALLOWLIST_ADDRESS");
        address pause = vm.envAddress("PAUSE_ADDRESS");
        address registry = vm.envAddress("AGENT_REGISTRY_ADDRESS");
        address revenue = vm.envAddress("REVENUE_WALLET");
        uint256 baseFeeBps = vm.envOr("ARB_BASE_FEE_BPS", uint256(10));

        vm.startBroadcast();
        BetEscrowFactory factory = new BetEscrowFactory(allowlist, pause, revenue, baseFeeBps, registry);
        // Authorize the new factory to onboard arbitered escrows (admin only).
        AgentRegistry(registry).setFactory(address(factory));
        vm.stopBroadcast();

        console2.log("BetEscrowFactory (new)  ", address(factory));
        console2.log("  registry (gate)       ", registry);
        console2.log("  revenueWallet         ", revenue);
        console2.log("  allowlist             ", allowlist);
        console2.log("  pauseController       ", pause);
    }
}
