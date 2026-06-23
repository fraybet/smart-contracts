// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// @notice Stand-in for the bond registry: tracks reservations and pays the
///         arbiter out of its own USDC (the "bonds"). Tests fund it as needed.
contract MockBondRegistry {
    IERC20 public immutable token;
    uint256 public arbitrationFee;
    mapping(address => uint256) public reservedOf;

    constructor(address token_, uint256 fee_) {
        token = IERC20(token_);
        arbitrationFee = fee_;
    }

    function reserveTaker(address taker) external {
        reservedOf[taker] += arbitrationFee;
    }

    function release(address wallet) external {
        if (reservedOf[wallet] >= arbitrationFee) reservedOf[wallet] -= arbitrationFee;
    }

    function charge(address wallet, address to, uint256 amount) external {
        if (reservedOf[wallet] >= arbitrationFee) reservedOf[wallet] -= arbitrationFee;
        if (amount > 0) token.transfer(to, amount);
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

    MockBondRegistry reg; // zero arbitration fee — for plain mechanics tests
    MockBondRegistry feeReg; // arbitrationFee = EXEC_FEE — for fee tests, pre-funded

    function setUp() public {
        usdc = new MockUSDC();
        yes = makeAddr("yes");
        no = makeAddr("no");
        arb = makeAddr("arb");
        stranger = makeAddr("stranger");
        revenue = makeAddr("revenue");
        claimDeadline = uint64(block.timestamp + 1 days);
        reg = new MockBondRegistry(address(usdc), 0);
        feeReg = new MockBondRegistry(address(usdc), EXEC_FEE);
        usdc.mint(address(feeReg), 2 * EXEC_FEE); // both sides' bonds
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
                eventTime: uint64(block.timestamp),
                challengeWindow: challengeWindow,
                nonce: 0,
                statement: "Will BTC close above 100000 USD on 2026-12-31?",
                primarySource: "Coinbase BTC-USD",
                fallbackSource: "",
                visibility: 1
            }),
            0,
            revenue,
            address(reg)
        );
        usdc.mint(yes, yesStake);
        usdc.mint(no, noStake);
        vm.prank(yes);
        usdc.approve(address(e), yesStake);
        vm.prank(no);
        usdc.approve(address(e), noStake);
    }

    // Deploy an arbitered bet with the protocol base fee, and fund both sides
    // (stake only — arbitration is bonded at feeReg, which holds both bonds).
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
                eventTime: uint64(block.timestamp),
                challengeWindow: challengeWindow,
                nonce: 0,
                statement: "Will BTC close above 100000 USD on 2026-12-31?",
                primarySource: "Coinbase BTC-USD",
                fallbackSource: "",
                visibility: 1
            }),
            BASE_FEE_BPS,
            revenue,
            address(feeReg)
        );
        // Both sides are committed in the bet, so reserve their bonds (the factory
        // does this via onArbiteredBet in production).
        feeReg.reserveTaker(yes);
        feeReg.reserveTaker(no);
        usdc.mint(yes, YES_STAKE);
        usdc.mint(no, NO_STAKE);
        vm.prank(yes);
        usdc.approve(address(e), YES_STAKE);
        vm.prank(no);
        usdc.approve(address(e), NO_STAKE);
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
        e.resolve(BetEscrow.Outcome.No, keccak256("verdict"), "https://storage.googleapis.com/fray-arb/abc.pdf");

        assertEq(usdc.balanceOf(no), YES_STAKE + NO_STAKE);
        assertEq(usdc.balanceOf(yes), 0);
        assertEq(usdc.balanceOf(address(e)), 0);
        assertEq(e.evidenceURI(), "https://storage.googleapis.com/fray-arb/abc.pdf", "arbiter evidence link stored on the bet");
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
        e.resolve(BetEscrow.Outcome.Void, bytes32(0), "");
        assertEq(usdc.balanceOf(yes), YES_STAKE);
        assertEq(usdc.balanceOf(no), NO_STAKE);
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    // --- arbitration fees (base % of pot → revenue; arbitration paid from bonds) ---

    function testFeeUndisputedReleasesBonds() public {
        BetEscrow e = _deployFeesFunded(); // escrow holds only the pot (stakes)
        assertEq(usdc.balanceOf(address(e)), YES_STAKE + NO_STAKE);

        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.warp(block.timestamp + challengeWindow + 1);
        e.finalize();

        uint256 pot = YES_STAKE + NO_STAKE;
        uint256 baseFee = pot * BASE_FEE_BPS / 10_000; // 0.1%
        assertEq(usdc.balanceOf(revenue), baseFee, "base fee to revenue");
        assertEq(usdc.balanceOf(yes), pot - baseFee, "winner takes pot minus base fee");
        assertEq(usdc.balanceOf(no), 0, "loser of the bet gets nothing");
        assertEq(usdc.balanceOf(arb), 0, "arbiter unpaid when undisputed");
        assertEq(usdc.balanceOf(address(e)), 0);
        // Bonds untouched (both reservations released, nothing charged).
        assertEq(usdc.balanceOf(address(feeReg)), 2 * EXEC_FEE, "bonds intact");
        assertEq(feeReg.reservedOf(yes), 0, "yes reservation released");
        assertEq(feeReg.reservedOf(no), 0, "no reservation released");
    }

    function testFeeDisputedLoserBondPaysArbiter() public {
        BetEscrow e = _deployFeesFunded();
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        vm.prank(arb);
        e.resolve(BetEscrow.Outcome.No, bytes32(0), ""); // NO wins; yes is the loser

        uint256 pot = YES_STAKE + NO_STAKE;
        uint256 baseFee = pot * BASE_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(revenue), baseFee, "base fee to revenue");
        assertEq(usdc.balanceOf(arb), EXEC_FEE, "arbiter paid from the loser's bond");
        assertEq(usdc.balanceOf(no), pot - baseFee, "winner takes pot minus base fee");
        assertEq(usdc.balanceOf(yes), 0, "loser forfeits the bet (and its bond pays the arbiter)");
        assertEq(usdc.balanceOf(address(e)), 0);
        assertEq(usdc.balanceOf(address(feeReg)), EXEC_FEE, "loser's bond drained to arbiter");
    }

    function testFeeDisputedVoidSplitsBondsEqually() public {
        // Arbiter rules a contested bet VOID (e.g. nonsensical). It still did the
        // work, so the base fee (from the pot) + the arbitration fee (from bonds)
        // are charged, each split equally; the rest is refunded.
        BetEscrow e = _deployFeesFunded();
        vm.prank(yes);
        e.claim(BetEscrow.Outcome.Yes, bytes32(0));
        vm.prank(no);
        e.challenge();
        vm.prank(arb);
        e.resolve(BetEscrow.Outcome.Void, bytes32(0), "");

        uint256 pot = YES_STAKE + NO_STAKE;
        uint256 baseFee = pot * BASE_FEE_BPS / 10_000;
        uint256 yesBase = baseFee / 2;
        uint256 noBase = baseFee - yesBase;
        assertEq(usdc.balanceOf(revenue), baseFee, "base fee to revenue");
        assertEq(usdc.balanceOf(arb), EXEC_FEE, "arbiter paid the full fee, half from each bond");
        assertEq(usdc.balanceOf(yes), YES_STAKE - yesBase, "yes stake refunded minus its base-fee half");
        assertEq(usdc.balanceOf(no), NO_STAKE - noBase, "no stake refunded minus its base-fee half");
        assertEq(usdc.balanceOf(address(e)), 0, "escrow (stakes) fully drained");
        assertEq(usdc.balanceOf(address(feeReg)), EXEC_FEE, "half of each bond went to the arbiter");
    }

    function testFeeVoidRefundsStakesAndBonds() public {
        BetEscrow e = _deployFeesFunded();
        vm.warp(claimDeadline + 1);
        e.voidUnclaimed();
        assertEq(usdc.balanceOf(yes), YES_STAKE, "stake refunded");
        assertEq(usdc.balanceOf(no), NO_STAKE);
        assertEq(usdc.balanceOf(revenue), 0, "no fee on an undisputed void");
        assertEq(usdc.balanceOf(address(e)), 0);
        assertEq(usdc.balanceOf(address(feeReg)), 2 * EXEC_FEE, "bonds intact");
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
        e.resolve(BetEscrow.Outcome.No, bytes32(0), "");
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
            BetEscrow.Terms(
                yes, yes, arb, address(usdc), 1, 1, uint64(block.timestamp), claimDeadline, challengeWindow, 0, "x", "s", "", 0
            ),
            0,
            revenue,
            address(0)
        ); // same agents
    }

    // --- open bets (one side filled later via accept / cancelled via revoke) ---

    function _deployOpen(address arbiter_) internal returns (BetEscrow e) {
        // yes is the proposer; the NO side is open (address(0)).
        bool arbitered = arbiter_ != address(0);
        e = new BetEscrow(
            BetEscrow.Terms({
                yesAgent: yes,
                noAgent: address(0),
                arbiter: arbiter_,
                token: address(usdc),
                yesStake: YES_STAKE,
                noStake: NO_STAKE,
                eventTime: uint64(block.timestamp),
                claimDeadline: claimDeadline,
                challengeWindow: challengeWindow,
                nonce: 0,
                statement: "Open bet statement",
                primarySource: "src",
                fallbackSource: "",
                visibility: 1
            }),
            arbitered ? BASE_FEE_BPS : 0,
            revenue,
            arbitered ? address(feeReg) : address(0)
        );
        // The factory reserves the proposer's bond at creation; do the same here.
        if (arbitered) feeReg.reserveTaker(yes);
    }

    function _fundProposer(BetEscrow e, uint256 amount) internal {
        usdc.mint(yes, amount);
        vm.prank(yes);
        usdc.approve(address(e), amount);
        vm.prank(yes);
        e.fund();
    }

    function _accept(BetEscrow e, uint256 amount) internal {
        usdc.mint(no, amount);
        vm.prank(no);
        usdc.approve(address(e), amount);
        vm.prank(no);
        e.accept();
    }

    function testOpenBetAcceptGoesLive() public {
        BetEscrow e = _deployOpen(address(0));
        _fundProposer(e, YES_STAKE);
        assertEq(e.noAgent(), address(0));
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Funding));

        _accept(e, NO_STAKE);
        assertEq(e.noAgent(), no);
        assertTrue(e.noFunded());
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Live));
    }

    function testOpenBetArbiteredAcceptStakeOnly() public {
        BetEscrow e = _deployOpen(arb);
        _fundProposer(e, YES_STAKE);
        _accept(e, NO_STAKE);
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Live));
        // Escrow holds only stakes; bonds (incl. the taker's, reserved on accept)
        // live at the registry.
        assertEq(usdc.balanceOf(address(e)), YES_STAKE + NO_STAKE);
        assertEq(feeReg.reservedOf(yes), EXEC_FEE, "proposer bond reserved");
        assertEq(feeReg.reservedOf(no), EXEC_FEE, "taker bond reserved on accept");
    }

    function testRevokeRefundsProposer() public {
        BetEscrow e = _deployOpen(address(0));
        _fundProposer(e, YES_STAKE);
        vm.prank(yes);
        e.revoke();
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Voided));
        assertEq(usdc.balanceOf(yes), YES_STAKE); // refunded
        assertEq(usdc.balanceOf(address(e)), 0);
    }

    function testAcceptRequiresProposerFunded() public {
        BetEscrow e = _deployOpen(address(0)); // proposer not funded
        usdc.mint(no, NO_STAKE);
        vm.prank(no);
        usdc.approve(address(e), NO_STAKE);
        vm.prank(no);
        vm.expectRevert(BetEscrow.NotFunding.selector);
        e.accept();
    }

    function testCannotAcceptOwnOpenBet() public {
        BetEscrow e = _deployOpen(address(0));
        _fundProposer(e, YES_STAKE);
        usdc.mint(yes, NO_STAKE);
        vm.prank(yes);
        usdc.approve(address(e), NO_STAKE);
        vm.prank(yes);
        vm.expectRevert(BetEscrow.NotParticipant.selector);
        e.accept();
    }

    function testRevokeOnlyProposer() public {
        BetEscrow e = _deployOpen(address(0));
        _fundProposer(e, YES_STAKE);
        vm.prank(stranger);
        vm.expectRevert(BetEscrow.NotParticipant.selector);
        e.revoke();
    }

    function testBilateralRejectsAcceptAndRevoke() public {
        BetEscrow e = _deploy(YES_STAKE, NO_STAKE, arb);
        vm.expectRevert(BetEscrow.NotOpen.selector);
        e.accept();
        vm.prank(yes);
        vm.expectRevert(BetEscrow.NotOpen.selector);
        e.revoke();
    }

    function testBothAgentsOpenReverts() public {
        vm.expectRevert(BetEscrow.BadTerms.selector);
        new BetEscrow(
            BetEscrow.Terms(
                address(0),
                address(0),
                arb,
                address(usdc),
                1,
                1,
                uint64(block.timestamp),
                claimDeadline,
                challengeWindow,
                0,
                "x",
                "s",
                "",
                0
            ),
            0,
            revenue,
            address(0)
        );
    }

    function testOpenBetResolvesAfterAccept() public {
        BetEscrow e = _deployOpen(address(0));
        _fundProposer(e, YES_STAKE);
        _accept(e, NO_STAKE);
        // a normal live bet now: both agree YES → proposer (yes) takes the pot
        vm.prank(yes);
        e.agreeOutcome(BetEscrow.Outcome.Yes);
        vm.prank(no);
        e.agreeOutcome(BetEscrow.Outcome.Yes);
        assertEq(usdc.balanceOf(yes), YES_STAKE + NO_STAKE);
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
        e.resolve(o, bytes32(0), "");

        // Every token funded is paid out to a participant; none created or stuck.
        uint256 paid = usdc.balanceOf(yes) + usdc.balanceOf(no);
        assertEq(paid, funded, "funds conserved");
        assertEq(usdc.balanceOf(address(e)), 0, "escrow drained to participants only");
    }
}
