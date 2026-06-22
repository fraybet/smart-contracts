// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";

/// @notice Redeploy ONLY the BetEscrowFactory, reusing the existing protocol
///         contracts. Use when the factory changes (e.g. adding registration
///         gating) — the registry/allowlist/pause/registration stay put, only
///         the factory address changes. The factory's revenueWallet + fees are
///         immutable, so they're re-supplied here.
///
///   ALLOWLIST_ADDRESS       existing StablecoinAllowlist
///   PAUSE_ADDRESS           existing EmergencyPauseController
///   AGENT_REGISTRY_ADDRESS  existing AgentRegistry (gates public/arbitered bets)
///   REVENUE_WALLET          protocol revenue wallet (immutable in the factory)
///   ARB_BASE_FEE_BPS        default 10 (0.1%)
///   ARB_EXEC_FEE_USDC       default 5
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
        uint256 execFeeUsdc = vm.envOr("ARB_EXEC_FEE_USDC", uint256(5));

        vm.startBroadcast();
        BetEscrowFactory factory =
            new BetEscrowFactory(allowlist, pause, revenue, baseFeeBps, execFeeUsdc * 1e6, registry);
        vm.stopBroadcast();

        console2.log("BetEscrowFactory (new)  ", address(factory));
        console2.log("  registry (gate)       ", registry);
        console2.log("  revenueWallet         ", revenue);
        console2.log("  allowlist             ", allowlist);
        console2.log("  pauseController       ", pause);
    }
}
