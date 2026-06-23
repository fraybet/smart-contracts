// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {AgentStorage} from "../src/custom/AgentStorage.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";

/// @notice Migrate to the bond-funded, upgradeable registry: deploy a fresh
///         AgentStorage + AgentRegistry (UUPS proxy) and a new BetEscrowFactory,
///         REUSING the existing allowlist / pause / revenue wallet. Wires the
///         storage controller to the proxy and authorizes the new factory.
///
///   USDC_ADDRESS, ALLOWLIST_ADDRESS, PAUSE_ADDRESS, REVENUE_WALLET (required)
///   REG_FEE_USDC (1), REG_BOND_USDC (10), ARB_FEE_USDC (2), ARB_BASE_FEE_BPS (10)
contract DeployMigrate is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address allowlist = vm.envAddress("ALLOWLIST_ADDRESS");
        address pause = vm.envAddress("PAUSE_ADDRESS");
        address revenue = vm.envAddress("REVENUE_WALLET");
        uint256 fee = vm.envOr("REG_FEE_USDC", uint256(1)) * 1e6;
        uint256 bond = vm.envOr("REG_BOND_USDC", uint256(10)) * 1e6;
        uint256 arbFee = vm.envOr("ARB_FEE_USDC", uint256(2)) * 1e6;
        uint256 baseFeeBps = vm.envOr("ARB_BASE_FEE_BPS", uint256(10));

        vm.startBroadcast();
        address admin = msg.sender;
        (AgentStorage store, AgentRegistry agents) = _deployAgents(usdc, admin, revenue, fee, bond, arbFee);
        BetEscrowFactory factory = new BetEscrowFactory(allowlist, pause, revenue, baseFeeBps, address(agents));
        agents.setFactory(address(factory));
        vm.stopBroadcast();

        console2.log("AgentStorage          ", address(store));
        console2.log("AgentRegistry (proxy) ", address(agents));
        console2.log("BetEscrowFactory      ", address(factory));
        console2.log("  admin               ", admin);
        console2.log("  revenue             ", revenue);
    }

    function _deployAgents(address usdc, address admin, address revenue, uint256 fee, uint256 bond, uint256 arbFee)
        internal
        returns (AgentStorage store, AgentRegistry agents)
    {
        store = new AgentStorage(usdc, admin);
        bytes memory initData = abi.encodeCall(
            AgentRegistry.initialize, (address(store), fee, bond, arbFee, admin, revenue, address(0))
        );
        agents = AgentRegistry(address(new ERC1967Proxy(address(new AgentRegistry()), initData)));
        store.setController(address(agents));
    }
}
