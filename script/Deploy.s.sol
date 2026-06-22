// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {StablecoinAllowlist} from "../src/custom/StablecoinAllowlist.sol";
import {EmergencyPauseController} from "../src/custom/EmergencyPauseController.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";
import {ArbiterRegistry} from "../src/custom/ArbiterRegistry.sol";

/// @notice Deploy the protocol. Configurable via env for real chains:
///
///   USDC_ADDRESS    real USDC; if unset, a MockUSDC is deployed (dev/anvil)
///   REVENUE_WALLET  where AgentRegistry fees sweep; defaults to the deployer
///   REG_FEE_USDC    registration fee, whole USDC (default 1)
///   REG_BOND_USDC   registration bond, whole USDC (default 10)
///
/// Local anvil:
///   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
///     --private-key 0xac0974... --broadcast
///
/// Base Sepolia (real USDC + your revenue wallet):
///   USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e \
///   REVENUE_WALLET=0xYourTreasury \
///   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_KEY --broadcast --verify
contract Deploy is Script {
    function run() external {
        address usdcEnv = vm.envOr("USDC_ADDRESS", address(0));
        address revenue = vm.envOr("REVENUE_WALLET", address(0));
        uint256 feeUsdc = vm.envOr("REG_FEE_USDC", uint256(1));
        uint256 bondUsdc = vm.envOr("REG_BOND_USDC", uint256(10));
        uint256 arbBaseFeeBps = vm.envOr("ARB_BASE_FEE_BPS", uint256(10)); // 0.1%
        uint256 arbExecFeeUsdc = vm.envOr("ARB_EXEC_FEE_USDC", uint256(5)); // fixed execution fee

        vm.startBroadcast();
        address deployer = msg.sender;
        if (revenue == address(0)) revenue = deployer;

        address token = usdcEnv;
        if (token == address(0)) {
            token = address(new MockUSDC()); // dev only
        }

        AgentRegistry agents = new AgentRegistry(token, feeUsdc * 1e6, bondUsdc * 1e6, deployer, revenue);
        ArbiterRegistry arbiters = new ArbiterRegistry();
        EmergencyPauseController pause = new EmergencyPauseController(deployer);
        StablecoinAllowlist allowlist = new StablecoinAllowlist(deployer);
        allowlist.allow(token);
        BetEscrowFactory factory = new BetEscrowFactory(
            address(allowlist), address(pause), revenue, arbBaseFeeBps, arbExecFeeUsdc * 1e6, address(agents)
        );

        vm.stopBroadcast();

        console2.log("MockUSDC/USDC          ", token);
        console2.log("AgentRegistry          ", address(agents));
        console2.log("  registration fee     ", feeUsdc, "USDC -> revenue", revenue);
        console2.log("  registration bond    ", bondUsdc, "USDC (refundable/slashable)");
        console2.log("ArbiterRegistry        ", address(arbiters));
        console2.log("EmergencyPauseController", address(pause));
        console2.log("StablecoinAllowlist    ", address(allowlist));
        console2.log("BetEscrowFactory       ", address(factory));
    }
}
