// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CTFExchange} from "../src/markets/exchange/CTFExchange.sol";
import {FrayMarketResolver} from "../src/markets/fray/FrayMarketResolver.sol";

/// @title DeployMarkets
/// @notice Official deploy of the public-markets settlement stack: the Gnosis
///         Conditional Tokens framework (deploy our own, or reuse one via
///         CTF_ADDRESS), the CTFExchange (off-chain-order-book settlement), and
///         the FrayMarketResolver (the arbiter-settled CTF oracle). Run through
///         the Makefile (`make deploy-markets`), which signs with the encrypted
///         `fray-deployer` keystore and verifies on Basescan. Records the
///         deployed addresses to deployments/<chainid>-markets.json.
///
/// Env:
///   USDC_ADDRESS     (required) collateral token (Base USDC)
///   ARBITER_ADDRESS  (required) the Fray arbiter signer — the resolver's authority
///   OPERATOR_ADDRESS (optional) the off-chain matcher; granted the exchange operator role
///   CTF_ADDRESS      (optional) reuse an existing ConditionalTokens; else deploy our own
contract DeployMarkets is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");
        address operator = vm.envOr("OPERATOR_ADDRESS", address(0));
        address ctf = vm.envOr("CTF_ADDRESS", address(0));

        vm.startBroadcast();

        if (ctf == address(0)) {
            // Deploy our own Gnosis ConditionalTokens (Solidity 0.5.1) from its
            // compiled artifact. CTF is ownerless and permissionless, so a fresh
            // deployment has no admin surface.
            bytes memory code = vm.getCode("ConditionalTokens.sol:ConditionalTokens");
            address deployed;
            assembly {
                deployed := create(0, add(code, 0x20), mload(code))
            }
            require(deployed != address(0), "DeployMarkets: CTF deploy failed");
            ctf = deployed;
        }

        // EOA-only: no Polymarket proxy/safe factories.
        CTFExchange exchange = new CTFExchange(usdc, ctf, address(0), address(0));
        if (operator != address(0)) {
            exchange.addOperator(operator);
        }

        FrayMarketResolver resolver = new FrayMarketResolver(ctf, arbiter);

        vm.stopBroadcast();

        console2.log("ConditionalTokens :", ctf);
        console2.log("CTFExchange       :", address(exchange));
        console2.log("FrayMarketResolver:", address(resolver));

        _writeManifest(ctf, address(exchange), address(resolver), usdc, arbiter);
    }

    function _writeManifest(address ctf, address exchange, address resolver, address usdc, address arbiter)
        internal
    {
        string memory o = "markets";
        vm.serializeAddress(o, "conditionalTokens", ctf);
        vm.serializeAddress(o, "ctfExchange", exchange);
        vm.serializeAddress(o, "usdc", usdc);
        vm.serializeAddress(o, "arbiter", arbiter);
        string memory json = vm.serializeAddress(o, "frayMarketResolver", resolver);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), "-markets.json");
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }
}
