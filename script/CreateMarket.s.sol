// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CTFExchange} from "../src/markets/exchange/CTFExchange.sol";
import {FrayMarketResolver} from "../src/markets/fray/FrayMarketResolver.sol";

/// @notice Reads the CTF position-id helpers off the live ConditionalTokens.
interface ICTFIds {
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external view returns (uint256);
}

/// @title CreateMarket
/// @notice Stands up one binary market: prepares a CTF condition with the
///         FrayMarketResolver as oracle (questionId = keccak256(QUESTION)), then
///         registers the YES/NO token pair on the exchange so it can trade.
///         Logs the conditionId + token ids for the off-chain `POST /markets`.
///
/// Env: RESOLVER_ADDRESS, EXCHANGE_ADDRESS, USDC_ADDRESS, QUESTION
contract CreateMarket is Script {
    function run() external {
        FrayMarketResolver resolver = FrayMarketResolver(vm.envAddress("RESOLVER_ADDRESS"));
        CTFExchange exchange = CTFExchange(vm.envAddress("EXCHANGE_ADDRESS"));
        address usdc = vm.envAddress("USDC_ADDRESS");
        string memory question = vm.envString("QUESTION");
        bytes32 questionId = keccak256(bytes(question));
        address ctf = address(resolver.ctf());

        vm.startBroadcast();
        bytes32 conditionId = resolver.prepareMarket(questionId);
        uint256 yesId = ICTFIds(ctf).getPositionId(usdc, ICTFIds(ctf).getCollectionId(bytes32(0), conditionId, 1));
        uint256 noId = ICTFIds(ctf).getPositionId(usdc, ICTFIds(ctf).getCollectionId(bytes32(0), conditionId, 2));
        exchange.registerToken(yesId, noId, conditionId);
        vm.stopBroadcast();

        console2.log("question   :", question);
        console2.log("questionId :");
        console2.logBytes32(questionId);
        console2.log("conditionId:");
        console2.logBytes32(conditionId);
        console2.log("yesToken   :", yesId);
        console2.log("noToken    :", noId);
    }
}
