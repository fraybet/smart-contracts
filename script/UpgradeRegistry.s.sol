// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";

/// @notice UUPS-upgrade the AgentRegistry logic behind the existing proxy. State
///         (agents, bonds, fees) lives in AgentStorage + the proxy, so nothing
///         migrates and no one re-registers — only the logic changes. Used to
///         ship the wallet-self-registration security fix (#3).
///
///   AGENT_REGISTRY_ADDRESS  the existing AgentRegistry PROXY (admin = caller)
///
///   forge script script/UpgradeRegistry.s.sol --rpc-url $BASE_RPC \
///     --private-key $KEY --broadcast
contract UpgradeRegistry is Script {
    function run() external {
        address proxy = vm.envAddress("AGENT_REGISTRY_ADDRESS");
        vm.startBroadcast();
        AgentRegistry impl = new AgentRegistry();
        AgentRegistry(proxy).upgradeToAndCall(address(impl), ""); // no re-init
        vm.stopBroadcast();
        console2.log("new AgentRegistry impl ", address(impl));
        console2.log("proxy upgraded         ", proxy);
    }
}
