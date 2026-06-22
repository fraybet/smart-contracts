// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BetEscrow} from "../src/custom/BetEscrow.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD", "mUSDC") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract BetEscrowTest is Test {
    MockUSDC usdc;
    address yes;
    address no;
    address arb;
    address stranger;
    address revenue;

    uint256 constant YES_STAKE = 500e6;
    uint256 constant NO_STAKE = 500e6;
    uint256 constant BASE_FEE_BPS = 10; // 0.1%
    uint256 constant EXEC_FEE = 5e6; // 5 USDC fixed execution fee
    uint64 challengeWindow = 1 hours;
    uint64 claimDeadline;

    function setUp() public {
        usdc = new MockUSDC();
        yes = makeAddr("yes");
        no = makeAddr("no");
        arb = makeAddr("arb");
        stranger = makeAddr("stranger");
        revenue = makeAddr("revenue");
        claimDeadline = uint64(block.timestamp + 1 days);
    }

    function _deploy(uint256 yesStake, uint256 noStake, address arbiter) internal returns (BetEscrow e) {
        e = new BetEscrow(
            BetEscrow.Terms({
                yesAgent: yes,
                noAgent: no,
                arbiter: arbiter,
                token: address(usdc),
                yesStake: yesStake,
                noStake: noStake,
                claimDeadline: claimDeadline,
                challengeWindow: challengeWindow,
                termsHash: keccak256("terms"),
                visibility: 1
            }),
            0,
            0,
            revenue
        );
        usdc.mint(yes, yesStake);
        usdc.mint(no, noStake);
        vm.prank(yes);
        usdc.approve(address(e), yesStake);
        vm.prank(no);
        usdc.approve(address(e), noStake);
    }

    // Deploy an arbitered bet with protocol fees, and fund both sides (each pays
    // stake + the execution-fee deposit).
    function _deployFeesFunded() internal returns (BetEscrow e) {
        e = new BetEscrow(
            BetEscrow.Terms({
                yesAgent: yes,
                noAgent: no,
                arbiter: arb,
                token: address(usdc),
                yesStake: YES_STAKE,
                noStake: NO_STAKE,
                claimDeadline: claimDeadline,
                challengeWindow: challengeWindow,
                termsHash: keccak256("terms"),
                visibility: 1
            }),
            BASE_FEE_BPS,
            EXEC_FEE,
            revenue
        );
        usdc.mint(yes, YES_STAKE + EXEC_FEE);
        usdc.mint(no, NO_STAKE + EXEC_FEE);
        vm.prank(yes);
        usdc.approve(address(e), YES_STAKE + EXEC_FEE);
        vm.prank(no);
        usdc.approve(address(e), NO_STAKE + EXEC_FEE);
        vm.prank(yes);
        e.fund();
        vm.prank(no);
        e.fund();
    }

    function _fundBoth(BetEscrow e) internal {
        vm.prank(yes);
        e.fund();
        vm.prank(no);
        e.fund();
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Live));
    }

    function testFullLifecycleYesWins() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);

        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, keccak256("evidence"));

        vm.warp(block.timestamp + challengeWindow + 1);
        e.finalize();

        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Resolved));
        assertEq(usdc.balanceOf(yes), YES_STAKE + NO_STAKE);
        assertEq(usdc.balanceOf(no), 0);
        assertEq(usdc.balanceOf(address(e)), 0, "no funds left in escrow");
    }

    function testChallengeArbiterResolvesNo() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);

        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Contested));

        vm.prank(arb);
        e.resolve(BetEscrow.Outcome.No, keccak256("verdict"));

        assertEq(usdc.balanceOf(no), YES_STAKE + NO_STAKE);
        assertEq(usdc.balanceOf(yes), 0);
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    function testVoidRefundOnTimeout() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);

        vm.warp(claimDeadline + 1);
        e.voidUnclaimed();

        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Voided));
        assertEq(usdc.balanceOf(yes), YES_STAKE);
        assertEq(usdc.balanceOf(no), NO_STAKE);
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    function testVoidRefundsOnlyFundedSide() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        vm.prank(yes);
        e.fund(); // only yes funds
        vm.warp(claimDeadline + 1);
        e.voidUnclaimed();
        assertEq(usdc.balanceOf(yes), YES_STAKE, "yes refunded");
        assertEq(usdc.balanceOf(address(e)), 0, "nothing stuck");
    }

    function testArbiterVoidRefunds() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        vm.prank(arb);
        e.resolve(BetEscrow.Outcome.Void, bytes32(0));
        assertEq(usdc.balanceOf(yes), YES_STAKE);
        assertEq(usdc.balanceOf(no), NO_STAKE);
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    // --- arbitration fees (base % → revenue, fixed execution fee, loser pays) ---

    function testFeeUndisputedRefundsDeposits() public {
        BetEscrow e = _deployFeesFunded(); // escrow holds pot + 2*EXEC_FEE
        assertEq(usdc.balanceOf(address(e)), YES_STAKE + NO_STAKE + 2 * EXEC_FEE);

        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.warp(block.timestamp + challengeWindow + 1);
        e.finalize();

        uint256 pot = YES_STAKE + NO_STAKE;
        uint256 baseFee = pot * BASE_FEE_BPS / 10_000; // 0.1%
        assertEq(usdc.balanceOf(revenue), baseFee, "base fee to revenue");
        assertEq(usdc.balanceOf(yes), pot - baseFee + EXEC_FEE, "winner: pot - baseFee + own deposit refund");
        assertEq(usdc.balanceOf(no), EXEC_FEE, "loser deposit refunded (no arbitration happened)");
        assertEq(usdc.balanceOf(arb), 0, "arbiter unpaid when undisputed");
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    function testFeeDisputedLoserPaysArbiter() public {
        BetEscrow e = _deployFeesFunded();
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        vm.prank(arb);
        e.resolve(BetEscrow.Outcome.No, bytes32(0)); // NO wins; yes is the loser

        uint256 pot = YES_STAKE + NO_STAKE;
        uint256 baseFee = pot * BASE_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(revenue), baseFee, "base fee to revenue");
        assertEq(usdc.balanceOf(arb), EXEC_FEE, "arbiter paid by the loser's deposit");
        assertEq(usdc.balanceOf(no), pot - baseFee + EXEC_FEE, "winner whole minus base fee, deposit refunded");
        assertEq(usdc.balanceOf(yes), 0, "loser forfeits stake + execution-fee deposit");
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    function testFeeVoidRefundsEverything() public {
        BetEscrow e = _deployFeesFunded();
        vm.warp(claimDeadline + 1);
        e.voidUnclaimed();
        assertEq(usdc.balanceOf(yes), YES_STAKE + EXEC_FEE, "stake + deposit refunded");
        assertEq(usdc.balanceOf(no), NO_STAKE + EXEC_FEE);
        assertEq(usdc.balanceOf(revenue), 0, "no fee on void");
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    // --- fast-settle (mutual agreement) ---

    function testFastSettleYes() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(yes);
        e.agreeOutcome(BetEscrow.Outcome.Yes);
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Live), "one side agreeing must not settle");
        vm.prank(no);
        e.agreeOutcome(BetEscrow.Outcome.Yes);
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Resolved));
        assertEq(usdc.balanceOf(yes), YES_STAKE + NO_STAKE);
        assertEq(usdc.balanceOf(address(e)), 0, "instant payout, no window");
    }

    function testFastSettleVoidRefunds() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(yes);
        e.agreeOutcome(BetEscrow.Outcome.Void);
        vm.prank(no);
        e.agreeOutcome(BetEscrow.Outcome.Void);
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Voided));
        assertEq(usdc.balanceOf(yes), YES_STAKE);
        assertEq(usdc.balanceOf(no), NO_STAKE);
    }

    function testFastSettleDisagreeIsNoOp() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(yes);
        e.agreeOutcome(BetEscrow.Outcome.Yes);
        vm.prank(no);
        e.agreeOutcome(BetEscrow.Outcome.No); // disagree
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Live), "disagreement does not settle");
        assertEq(usdc.balanceOf(address(e)), YES_STAKE + NO_STAKE, "funds stay escrowed");
    }

    function testFastSettleOnlyParticipants() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(stranger);
        vm.expectRevert(BetEscrow.NotParticipant.selector);
        e.agreeOutcome(BetEscrow.Outcome.Yes);
    }

    // --- access control / guards ---

    function testStrangerCannotFund() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        vm.prank(stranger);
        vm.expectRevert(BetEscrow.NotParticipant.selector);
        e.fund();
    }

    function testCannotClaimBeforeLive() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        vm.prank(yes);
        e.fund();
        vm.prank(yes);
        vm.expectRevert(BetEscrow.NotLive.selector);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
    }

    function testCannotFinalizeDuringWindow() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.expectRevert(BetEscrow.ChallengeWindowOpen.selector);
        e.finalize();
    }

    function testOnlyArbiterResolves() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        _fundBoth(e);
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        vm.prank(stranger);
        vm.expectRevert(BetEscrow.NotArbiter.selector);
        e.resolve(BetEscrow.Outcome.No, bytes32(0));
    }

    function testChallengeNeedsArbiter() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, address(0)); // no arbiter
        _fundBoth(e);
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        vm.expectRevert(BetEscrow.NoArbiter.selector);
        e.challenge();
    }

    function testBadTermsRevert() public {
        vm.expectRevert(BetEscrow.BadTerms.selector);
        new BetEscrow(
            BetEscrow.Terms(yes, yes, arb, address(usdc), 1, 1, claimDeadline, challengeWindow, bytes32(0), 0), 0, 0, revenue
        ); // same agents
    }

    // --- the non-negotiable invariant: funds conservation ---

    function testFuzz_FundsConservation(uint96 yesStake, uint96 noStake, uint8 outcomeSel) public {
        yesStake = uint96(bound(yesStake, 1, 1e30));
        noStake = uint96(bound(noStake, 1, 1e30));
        BetEscrow e = _deploy(yesStake, noStake, arb);
        _fundBoth(e);
        uint256 funded = uint256(yesStake) + uint256(noStake);

        // Resolve to YES, NO, or VOID via the arbiter path.
        BetEscrow.Outcome o = BetEscrow.Outcome(uint8(bound(outcomeSel, 1, 3)));
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        vm.prank(arb);
        e.resolve(o, bytes32(0));

        // Every token funded is paid out to a participant; none created or stuck.
        uint256 paid = usdc.balanceOf(yes) + usdc.balanceOf(no);
        assertEq(paid, funded, "funds conserved");
        assertEq(usdc.balanceOf(address(e)), 0, "escrow drained to participants only");
    }
}
