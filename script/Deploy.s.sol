// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {StablecoinAllowlist} from "../src/custom/StablecoinAllowlist.sol";
import {EmergencyPauseController} from "../src/custom/EmergencyPauseController.sol";
import {AgentStorage} from "../src/custom/AgentStorage.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";
import {ArbiterRegistry} from "../src/custom/ArbiterRegistry.sol";

/// @notice Deploy the protocol. Configurable via env for real chains:
///
///   USDC_ADDRESS    real USDC; if unset, a MockUSDC is deployed (dev/anvil)
///   REVENUE_WALLET  where AgentRegistry fees sweep; defaults to the deployer
///   REG_FEE_USDC    registration fee, whole USDC (default 1)
///   REG_BOND_USDC   registration bond, whole USDC (default 10)
///   ARB_BASE_FEE_BPS  base fee on arbitered pots, bps (default 10 = 0.1%)
///   ARB_FEE_USDC      per-side arbitration fee charged from bonds (default 1)
///
/// The agent registry is deployed as AgentStorage (long-lived data + funds) + an
/// AgentRegistry logic contract behind a UUPS proxy. The storage's controller is
/// the proxy; the registry's factory is the BetEscrowFactory.
///
/// Local anvil:
///   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
///     --private-key 0xac0974... --broadcast
contract Deploy is Script {
    function run() external {
        address usdcEnv = vm.envOr("USDC_ADDRESS", address(0));
        address revenue = vm.envOr("REVENUE_WALLET", address(0));
        uint256 feeUsdc = vm.envOr("REG_FEE_USDC", uint256(1));
        uint256 bondUsdc = vm.envOr("REG_BOND_USDC", uint256(10));
        uint256 arbBaseFeeBps = vm.envOr("ARB_BASE_FEE_BPS", uint256(10)); // 0.1%
        uint256 arbFeeUsdc = vm.envOr("ARB_FEE_USDC", uint256(1)); // per-side, from bond

        vm.startBroadcast();
        address deployer = msg.sender;
        if (revenue == address(0)) revenue = deployer;

        address token = usdcEnv;
        if (token == address(0)) {
            token = address(new MockUSDC()); // dev only
        }

        // Agent registry: long-lived storage + upgradeable logic behind a proxy.
        (AgentStorage store, AgentRegistry agents) =
            _deployAgents(token, deployer, revenue, feeUsdc * 1e6, bondUsdc * 1e6, arbFeeUsdc * 1e6);

        ArbiterRegistry arbiters = new ArbiterRegistry();
        EmergencyPauseController pause = new EmergencyPauseController(deployer);
        StablecoinAllowlist allowlist = new StablecoinAllowlist(deployer);
        allowlist.allow(token);
        BetEscrowFactory factory =
            new BetEscrowFactory(address(allowlist), address(pause), revenue, arbBaseFeeBps, address(agents));
        agents.setFactory(address(factory));

        vm.stopBroadcast();

        console2.log("MockUSDC/USDC          ", token);
        console2.log("AgentStorage           ", address(store));
        console2.log("AgentRegistry (proxy)  ", address(agents));
        console2.log("ArbiterRegistry        ", address(arbiters));
        console2.log("EmergencyPauseController", address(pause));
        console2.log("StablecoinAllowlist    ", address(allowlist));
        console2.log("BetEscrowFactory       ", address(factory));
    }

    /// @dev Deploy AgentStorage + an AgentRegistry proxy and wire the controller.
    function _deployAgents(address token, address admin, address revenue, uint256 fee, uint256 bond, uint256 arbFee)
        internal
        returns (AgentStorage store, AgentRegistry agents)
    {
        store = new AgentStorage(token, admin);
        bytes memory initData = abi.encodeCall(
            AgentRegistry.initialize, (address(store), fee, bond, arbFee, admin, revenue, address(0))
        );
        agents = AgentRegistry(address(new ERC1967Proxy(address(new AgentRegistry()), initData)));
        store.setController(address(agents));
    }
}
