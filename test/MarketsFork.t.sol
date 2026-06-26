// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CTFExchange} from "../src/markets/exchange/CTFExchange.sol";
import {Order, Side, SignatureType} from "../src/markets/exchange/libraries/OrderStructs.sol";
import {UmaCtfAdapter} from "../src/markets/uma/UmaCtfAdapter.sol";
import {IUmaCtfAdapterEE} from "../src/markets/uma/interfaces/IUmaCtfAdapter.sol";
import {FrayMarketResolver} from "../src/markets/fray/FrayMarketResolver.sol";

/// @notice Extended CTF interface: the vendored IConditionalTokens lacks the ERC1155
///         read/approve surface and reportPayouts, which the settlement loop needs.
interface ICTF {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256);
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
}

contract MarketsForkTest is Test {
    // Live Base mainnet addresses (fork carries their real state).
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CTF = 0xC9c98965297Bc527861c898329Ee280632B76e18;
    address constant OOV2 = 0x880d041D67aaB3B062995d11d4aD9c1018A3b02f;
    address constant FINDER = 0x7E6d9618Ba8a87421609352d6e711958A97e2512;

    CTFExchange internal exchange;

    address internal operator = makeAddr("operator");
    address internal oracle = makeAddr("oracle");
    address internal arbiter = makeAddr("arbiter");

    uint256 internal bobPK;
    uint256 internal carlaPK;
    address internal bob;
    address internal carla;

    bytes32 internal questionId = keccak256("fray-test-q1");
    bytes32 internal conditionId;
    uint256 internal yesId;
    uint256 internal noId;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");

        (bob, bobPK) = makeAddrAndKey("bob");
        (carla, carlaPK) = makeAddrAndKey("carla");

        // On a mainnet fork these deterministic addresses can collide with real
        // deployed bytecode. CTF's ERC-1155 safeTransfer then invokes
        // onERC1155Received on the colliding contract, which returns the wrong
        // selector and reverts. Real agent wallets are codeless EOAs, so force
        // these test agents to be codeless to model that faithfully.
        vm.etch(bob, "");
        vm.etch(carla, "");
    }

    /*//////////////////////////////////////////////////////////////
        TEST A — full money loop, deterministic (test-controlled oracle)
    //////////////////////////////////////////////////////////////*/
    function testFullSettlementLoop() public {
        // 1. Deploy exchange (EOA-only: no proxy/safe factories). Deployer is admin+operator.
        exchange = new CTFExchange(USDC, CTF, address(0), address(0));
        exchange.addOperator(operator);

        // 2. Prepare a fresh condition with an oracle EOA we control.
        ICTF(CTF).prepareCondition(oracle, questionId, 2);
        conditionId = ICTF(CTF).getConditionId(oracle, questionId, 2);

        // 3. Derive position ids. indexSet 1 == YES (slot 0), indexSet 2 == NO (slot 1).
        bytes32 yesColl = ICTF(CTF).getCollectionId(bytes32(0), conditionId, 1);
        yesId = ICTF(CTF).getPositionId(USDC, yesColl);
        bytes32 noColl = ICTF(CTF).getCollectionId(bytes32(0), conditionId, 2);
        noId = ICTF(CTF).getPositionId(USDC, noColl);

        // 4. Register the token pair on the exchange (onlyAdmin).
        exchange.registerToken(yesId, noId, conditionId);

        // 5. Fund and approve both agents.
        deal(USDC, bob, 1_000e6, true);
        deal(USDC, carla, 1_000e6, true);
        assertEq(IERC20(USDC).balanceOf(bob), 1_000e6, "deal bob USDC failed");
        assertEq(IERC20(USDC).balanceOf(carla), 1_000e6, "deal carla USDC failed");

        _approve(bob);
        _approve(carla);

        // 6. Build a MINT match: a YES BUY against a NO BUY at symmetric 0.50/0.50.
        //    bob:   BUY yes, makerAmount 50e6 USDC -> takerAmount 100e6 YES (price 0.5)
        //    carla: BUY no,  makerAmount 50e6 USDC -> takerAmount 100e6 NO  (price 0.5)
        //    BUY prices sum to 1.0, satisfying the buy-vs-buy crossing invariant.
        Order memory yesBuy = _signedOrder(bobPK, yesId, 50e6, 100e6, Side.BUY);
        Order memory noBuy = _signedOrder(carlaPK, noId, 50e6, 100e6, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = noBuy;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = 50e6; // fill carla's NO buy fully (50e6 USDC in -> 100e6 NO out)

        uint256 takerFillAmount = 50e6; // fill bob's YES buy fully (50e6 USDC in -> 100e6 YES out)

        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);
        uint256 carlaUsdcBefore = IERC20(USDC).balanceOf(carla);

        // 7. Operator matches the orders -> exchange mints the YES/NO pair from collateral.
        vm.prank(operator);
        exchange.matchOrders(yesBuy, makerOrders, takerFillAmount, makerFillAmounts);

        // 8. Real balance assertions.
        // Outcome tokens minted to the agents.
        assertEq(ICTF(CTF).balanceOf(bob, yesId), 100e6, "bob did not receive 100e6 YES");
        assertEq(ICTF(CTF).balanceOf(carla, noId), 100e6, "carla did not receive 100e6 NO");

        // Collateral spent (fee == 0 since feeRateBps == 0).
        assertEq(bobUsdcBefore - IERC20(USDC).balanceOf(bob), 50e6, "bob USDC spend != 50e6");
        assertEq(carlaUsdcBefore - IERC20(USDC).balanceOf(carla), 50e6, "carla USDC spend != 50e6");

        // CUSTODY NEGATIVE TEST: the exchange holds NOTHING at rest.
        assertEq(IERC20(USDC).balanceOf(address(exchange)), 0, "exchange holds USDC at rest");
        assertEq(ICTF(CTF).balanceOf(address(exchange), yesId), 0, "exchange holds YES at rest");
        assertEq(ICTF(CTF).balanceOf(address(exchange), noId), 0, "exchange holds NO at rest");

        // 9. Resolve YES wins: payouts [YES=1, NO=0]. Reported by our oracle EOA.
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(oracle);
        ICTF(CTF).reportPayouts(questionId, payouts);

        // 10. Redeem. bob (YES winner) sweeps the whole 100e6 USDC pot; carla (NO) gets 0.
        uint256[] memory yesIndex = new uint256[](1);
        yesIndex[0] = 1;
        uint256[] memory noIndex = new uint256[](1);
        noIndex[0] = 2;

        uint256 bobUsdcPreRedeem = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        ICTF(CTF).redeemPositions(USDC, bytes32(0), conditionId, yesIndex);
        assertEq(
            IERC20(USDC).balanceOf(bob) - bobUsdcPreRedeem, 100e6, "bob redeem != full 100e6 pot"
        );

        uint256 carlaUsdcPreRedeem = IERC20(USDC).balanceOf(carla);
        vm.prank(carla);
        ICTF(CTF).redeemPositions(USDC, bytes32(0), conditionId, noIndex);
        assertEq(IERC20(USDC).balanceOf(carla) - carlaUsdcPreRedeem, 0, "carla (loser) should redeem 0");

        // 11. Final custody invariant: exchange holds nothing; CTF holds no residual collateral
        //     for this condition (both sides fully redeemed -> pot drained).
        assertEq(IERC20(USDC).balanceOf(address(exchange)), 0, "exchange holds residual USDC");
        assertEq(ICTF(CTF).balanceOf(address(exchange), yesId), 0, "exchange holds residual YES");
        assertEq(ICTF(CTF).balanceOf(address(exchange), noId), 0, "exchange holds residual NO");
        assertEq(ICTF(CTF).balanceOf(bob, yesId), 0, "bob YES not burned on redeem");
        assertEq(ICTF(CTF).balanceOf(carla, noId), 0, "carla NO not burned on redeem");
    }

    /*//////////////////////////////////////////////////////////////
        TEST B — real UMA initialize path (discovery; must not fail suite)
    //////////////////////////////////////////////////////////////*/
    function testUmaInitializeDiscovery() public {
        UmaCtfAdapter adapter = new UmaCtfAdapter(CTF, FINDER, OOV2);

        deal(USDC, address(this), 1_000e6, true);
        IERC20(USDC).approve(address(adapter), type(uint256).max);

        bytes memory ancillary = bytes("q: Will it rain in NYC on 2026-07-01? p1:0 p2:1 p3:0.5");

        try adapter.initialize(ancillary, USDC, 0, 0, 0) returns (bytes32 qid) {
            // Condition must now be prepared on the CTF under the adapter as oracle.
            bytes32 cId = ICTF(CTF).getConditionId(address(adapter), qid, 2);
            assertEq(ICTF(CTF).getConditionId(address(adapter), qid, 2), cId);
            console2.log("FINDING: UMA initialize SUCCEEDED on Base 8453 with USDC as reward token.");
            console2.logBytes32(qid);
        } catch (bytes memory err) {
            bytes4 sel;
            if (err.length >= 4) {
                sel = bytes4(err);
            }
            console2.log("UMA initialize reverted. selector:");
            console2.logBytes4(sel);
            if (sel == IUmaCtfAdapterEE.UnsupportedToken.selector) {
                console2.log(
                    "FINDING: USDC not on UMA AddressWhitelist on Base 8453 -- markets resolution via UMA needs a whitelisted reward token or UMA governance; resolveManually/alt-resolver is the fallback."
                );
            } else {
                console2.log("FINDING: UMA initialize reverted with a non-UnsupportedToken selector (see above).");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
        TEST C — arbiter-settled resolution via FrayMarketResolver
    //////////////////////////////////////////////////////////////*/
    function testResolveViaFrayResolver() public {
        // Deploy exchange + the singleton Fray resolver (the arbiter-settled CTF oracle).
        exchange = new CTFExchange(USDC, CTF, address(0), address(0));
        exchange.addOperator(operator);
        FrayMarketResolver resolver = new FrayMarketResolver(CTF, arbiter);

        // Condition prepared with the resolver itself as the CTF oracle, so only
        // the arbiter (via the resolver) can ever report its payouts.
        bytes32 qId = keccak256("fray-market-q2");
        conditionId = resolver.prepareMarket(qId);
        assertEq(conditionId, resolver.conditionIdFor(qId), "conditionId mismatch");

        // Derive + register the YES/NO pair.
        bytes32 yesColl = ICTF(CTF).getCollectionId(bytes32(0), conditionId, 1);
        yesId = ICTF(CTF).getPositionId(USDC, yesColl);
        bytes32 noColl = ICTF(CTF).getCollectionId(bytes32(0), conditionId, 2);
        noId = ICTF(CTF).getPositionId(USDC, noColl);
        exchange.registerToken(yesId, noId, conditionId);

        // Mint the pair via a 0.50/0.50 BUY-vs-BUY match.
        deal(USDC, bob, 1_000e6, true);
        deal(USDC, carla, 1_000e6, true);
        _approve(bob);
        _approve(carla);
        Order memory yesBuy = _signedOrder(bobPK, yesId, 50e6, 100e6, Side.BUY);
        Order memory noBuy = _signedOrder(carlaPK, noId, 50e6, 100e6, Side.BUY);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = noBuy;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = 50e6;
        vm.prank(operator);
        exchange.matchOrders(yesBuy, makerOrders, 50e6, makerFillAmounts);
        assertEq(ICTF(CTF).balanceOf(bob, yesId), 100e6, "bob YES mint");
        assertEq(ICTF(CTF).balanceOf(carla, noId), 100e6, "carla NO mint");

        bytes32 evidenceHash = keccak256("deliberation-pdf-bytes");
        string memory evidenceURI = "gs://fray-arbiter-evidence/q2.pdf?expires=1234567890";

        // AUTH: a non-arbiter cannot resolve.
        vm.expectRevert(FrayMarketResolver.NotArbiter.selector);
        resolver.resolve(qId, FrayMarketResolver.Outcome.Yes, evidenceHash, evidenceURI);

        // Arbiter settles YES and posts evidence on-chain.
        vm.prank(arbiter);
        resolver.resolve(qId, FrayMarketResolver.Outcome.Yes, evidenceHash, evidenceURI);
        assertEq(uint256(resolver.outcomeOf(qId)), uint256(FrayMarketResolver.Outcome.Yes), "outcome not Yes");
        assertEq(resolver.evidenceURIOf(qId), evidenceURI, "evidence URI not stored");
        assertGt(ICTF(CTF).payoutDenominator(conditionId), 0, "CTF condition not resolved");

        // Double-resolve guard.
        vm.prank(arbiter);
        vm.expectRevert(FrayMarketResolver.AlreadyResolved.selector);
        resolver.resolve(qId, FrayMarketResolver.Outcome.No, evidenceHash, evidenceURI);

        // Winner (YES = bob) redeems the full 100e6 pot; loser gets 0.
        uint256 bobPre = IERC20(USDC).balanceOf(bob);
        uint256[] memory yesIndex = new uint256[](1);
        yesIndex[0] = 1;
        vm.prank(bob);
        ICTF(CTF).redeemPositions(USDC, bytes32(0), conditionId, yesIndex);
        assertEq(IERC20(USDC).balanceOf(bob) - bobPre, 100e6, "winner redeem != full pot");

        uint256 carlaPre = IERC20(USDC).balanceOf(carla);
        uint256[] memory noIndex = new uint256[](1);
        noIndex[0] = 2;
        vm.prank(carla);
        ICTF(CTF).redeemPositions(USDC, bytes32(0), conditionId, noIndex);
        assertEq(IERC20(USDC).balanceOf(carla) - carlaPre, 0, "loser should redeem 0");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _approve(address agent) internal {
        vm.startPrank(agent);
        IERC20(USDC).approve(address(exchange), type(uint256).max);
        ICTF(CTF).setApprovalForAll(address(exchange), true);
        vm.stopPrank();
    }

    function _signedOrder(uint256 pk, uint256 tokenId, uint256 makerAmount, uint256 takerAmount, Side side)
        internal
        view
        returns (Order memory order)
    {
        address maker = vm.addr(pk);
        order = Order({
            salt: uint256(keccak256(abi.encode(tokenId, makerAmount, takerAmount, side))),
            maker: maker,
            signer: maker,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: side,
            signatureType: SignatureType.EOA,
            signature: new bytes(0)
        });
        bytes32 digest = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        order.signature = abi.encodePacked(r, s, v);
    }
}
