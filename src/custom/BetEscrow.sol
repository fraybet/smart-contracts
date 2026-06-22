// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BetEscrow
/// @notice Non-custodial bilateral binary bet (design §9). Two agents stake an
///         ERC-20 (USDC) into this contract; it pays the winner, refunds on
///         VOID, and an optional arbiter resolves disputes. The platform has no
///         path to these funds — settlement only ever pays yesAgent/noAgent.
///
///         Lifecycle (design §9.6):
///
///           Funding ──both fund──▶ Live ──claim──▶ Claimed
///              │                                      │
///              │ claimDeadline                        ├─ window passes ─▶ finalize ─▶ Resolved
///              │ (unclaimed)                          │
///              ▼                                      └─ challenge ─▶ Contested ─arbiter─▶ Resolved/Voided
///           Voided ◀──voidUnclaimed────────────────────────────────────────────────────────┘
///
///         Fast path: from Live or Claimed, if both sides call agreeOutcome(x)
///         with the same x, the bet settles instantly — no claim, no window.
///
///         Outcomes: YES pays the full pot to yesAgent, NO to noAgent, VOID
///         refunds each side its own stake. Funds-conservation invariant: tokens
///         paid out always equal tokens funded.
contract BetEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    enum Status {
        Funding,
        Live,
        Claimed,
        Contested,
        Resolved,
        Voided
    }

    enum Outcome {
        Unresolved,
        Yes,
        No,
        Void
    }

    /// @dev Constructor params, grouped to avoid stack-too-deep.
    struct Terms {
        address yesAgent;
        address noAgent;
        address arbiter; // address(0) => no dispute path
        address token;
        uint256 yesStake;
        uint256 noStake;
        uint64 claimDeadline;
        uint64 challengeWindow;
        bytes32 termsHash;
        uint8 visibility; // 0 = private, 1 = public (drives the website)
    }

    // Agents are storage (not immutable) so an OPEN bet — created with one side
    // set to address(0) — can have that slot filled by the first taker who
    // accept()s. A normal bilateral bet sets both at construction and they never
    // change.
    address public yesAgent;
    address public noAgent;
    address public immutable arbiter;
    IERC20 public immutable token;
    uint256 public immutable yesStake;
    uint256 public immutable noStake;
    uint64 public immutable claimDeadline;
    uint64 public immutable challengeWindow;
    bytes32 public immutable termsHash;
    uint8 public immutable visibility;

    // Protocol arbitration fees — set by the factory, charged ONLY on arbitered
    // bets (arbiter != 0). baseFee is a % of the pot → revenueWallet; executionFee
    // is a fixed per-side deposit, the loser's of which pays the arbiter when a
    // dispute is actually arbitrated (otherwise both deposits are refunded).
    uint256 public immutable baseFeeBps;
    uint256 public immutable executionFee;
    address public immutable revenueWallet;

    Status public status;
    Outcome public claimedOutcome;
    Outcome public finalOutcome;
    uint64 public challengeDeadline;
    bool public yesFunded;
    bool public noFunded;
    bool public settled;
    bool public disputed; // a challenge was raised → arbitration executed

    // Mutual fast-settle: each side's agreed outcome (Unresolved until set).
    Outcome public yesAgentAgreed;
    Outcome public noAgentAgreed;

    event Funded(address indexed agent);
    event Accepted(address indexed taker); // open bet's counterparty filled
    event Revoked(); // open bet cancelled by the proposer before acceptance
    event WentLive();
    event Claimed(address indexed by, Outcome outcome, bytes32 evidenceHash, uint64 challengeDeadline);
    event Challenged(address indexed by);
    event OutcomeAgreed(address indexed by, Outcome outcome);
    event Settled(Outcome outcome);

    error NotParticipant();
    error NotFunding();
    error AlreadyFunded();
    error NotLive();
    error NotClaimed();
    error NotContested();
    error NotArbiter();
    error NoArbiter();
    error InvalidOutcome();
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error NotRefundable();
    error TooEarly();
    error AlreadySettled();
    error BadTerms();
    error NotOpen();

    constructor(Terms memory t, uint256 baseFeeBps_, uint256 executionFee_, address revenueWallet_) {
        // Open bet: exactly one side is address(0) (filled later by accept()).
        // Bilateral bet: both set and distinct. Both-open is invalid.
        bool openYes = t.yesAgent == address(0);
        bool openNo = t.noAgent == address(0);
        if (
            (openYes && openNo) || t.token == address(0) || t.yesStake == 0 || t.noStake == 0
                || t.challengeWindow == 0 || (!openYes && !openNo && t.yesAgent == t.noAgent)
        ) {
            revert BadTerms();
        }
        // Fees apply only to arbitered bets; if charged, a revenue wallet is required.
        if (t.arbiter != address(0) && (baseFeeBps_ > 0 || executionFee_ > 0) && revenueWallet_ == address(0)) {
            revert BadTerms();
        }
        if (baseFeeBps_ > BPS) revert BadTerms();
        yesAgent = t.yesAgent;
        noAgent = t.noAgent;
        arbiter = t.arbiter;
        token = IERC20(t.token);
        yesStake = t.yesStake;
        noStake = t.noStake;
        claimDeadline = t.claimDeadline;
        challengeWindow = t.challengeWindow;
        termsHash = t.termsHash;
        visibility = t.visibility;
        baseFeeBps = baseFeeBps_;
        executionFee = executionFee_;
        revenueWallet = revenueWallet_;
        status = Status.Funding;
    }

    /// @notice Fund your side. Each agent transfers its own stake; when both
    ///         have funded, the bet goes Live.
    function fund() external nonReentrant {
        if (status != Status.Funding) revert NotFunding();
        // Arbitered bets also escrow a refundable execution-fee deposit per side.
        uint256 deposit = arbiter != address(0) ? executionFee : 0;
        if (msg.sender == yesAgent) {
            if (yesFunded) revert AlreadyFunded();
            yesFunded = true;
            token.safeTransferFrom(msg.sender, address(this), yesStake + deposit);
        } else if (msg.sender == noAgent) {
            if (noFunded) revert AlreadyFunded();
            noFunded = true;
            token.safeTransferFrom(msg.sender, address(this), noStake + deposit);
        } else {
            revert NotParticipant();
        }
        emit Funded(msg.sender);
        if (yesFunded && noFunded) {
            status = Status.Live;
            emit WentLive();
        }
    }

    /// @notice Take the open side of an OPEN bet. The proposer must already have
    ///         funded their side (their committed stake is what makes the open
    ///         bet credible). The taker fills the empty slot, escrows the
    ///         counterparty stake (+ execution-fee deposit if arbitered), and the
    ///         bet goes Live in the same call.
    function accept() external nonReentrant {
        if (status != Status.Funding) revert NotFunding();
        bool openYes = yesAgent == address(0);
        bool openNo = noAgent == address(0);
        if (!openYes && !openNo) revert NotOpen();
        address proposer = openYes ? noAgent : yesAgent;
        if (msg.sender == proposer) revert NotParticipant(); // can't take your own bet
        // The proposer must be committed (funded) before anyone can accept.
        if (openYes ? !noFunded : !yesFunded) revert NotFunding();

        uint256 deposit = arbiter != address(0) ? executionFee : 0;
        if (openYes) {
            yesAgent = msg.sender;
            yesFunded = true;
            token.safeTransferFrom(msg.sender, address(this), yesStake + deposit);
        } else {
            noAgent = msg.sender;
            noFunded = true;
            token.safeTransferFrom(msg.sender, address(this), noStake + deposit);
        }
        emit Accepted(msg.sender);
        emit Funded(msg.sender);
        status = Status.Live;
        emit WentLive();
    }

    /// @notice Cancel an OPEN bet that has not been accepted, refunding the
    ///         proposer's escrowed stake. Only the proposer may revoke.
    function revoke() external nonReentrant {
        if (status != Status.Funding) revert NotFunding();
        bool openYes = yesAgent == address(0);
        bool openNo = noAgent == address(0);
        if (!openYes && !openNo) revert NotOpen();
        address proposer = openYes ? noAgent : yesAgent;
        if (msg.sender != proposer) revert NotParticipant();

        status = Status.Voided;
        settled = true; // no further settlement
        uint256 deposit = arbiter != address(0) ? executionFee : 0;
        if (openYes) {
            if (noFunded) token.safeTransfer(noAgent, noStake + deposit);
        } else {
            if (yesFunded) token.safeTransfer(yesAgent, yesStake + deposit);
        }
        emit Revoked();
        emit Settled(Outcome.Void);
    }

    /// @notice Claim an outcome (YES or NO) once Live. Opens the challenge window.
    function claim(Outcome outcome, bytes32 evidenceHash) external {
        if (status != Status.Live) revert NotLive();
        if (outcome != Outcome.Yes && outcome != Outcome.No) revert InvalidOutcome();
        if (msg.sender != yesAgent && msg.sender != noAgent) revert NotParticipant();
        claimedOutcome = outcome;
        status = Status.Claimed;
        challengeDeadline = uint64(block.timestamp) + challengeWindow;
        emit Claimed(msg.sender, outcome, evidenceHash, challengeDeadline);
    }

    /// @notice Fast-settle: both participants co-sign the same outcome and the
    ///         bet pays out immediately, skipping the challenge window. Available
    ///         while Live or Claimed; if the two sides name different outcomes
    ///         it is a no-op and the claim/challenge/arbiter path still applies.
    function agreeOutcome(Outcome outcome) external nonReentrant {
        if (status != Status.Live && status != Status.Claimed) revert NotLive();
        if (outcome != Outcome.Yes && outcome != Outcome.No && outcome != Outcome.Void) {
            revert InvalidOutcome();
        }
        if (msg.sender == yesAgent) {
            yesAgentAgreed = outcome;
        } else if (msg.sender == noAgent) {
            noAgentAgreed = outcome;
        } else {
            revert NotParticipant();
        }
        emit OutcomeAgreed(msg.sender, outcome);
        if (yesAgentAgreed != Outcome.Unresolved && yesAgentAgreed == noAgentAgreed) {
            finalOutcome = yesAgentAgreed;
            status = finalOutcome == Outcome.Void ? Status.Voided : Status.Resolved;
            _settle();
        }
    }

    /// @notice Finalize an unchallenged claim after its window closes.
    function finalize() external nonReentrant {
        if (status != Status.Claimed) revert NotClaimed();
        if (block.timestamp < challengeDeadline) revert ChallengeWindowOpen();
        finalOutcome = claimedOutcome;
        status = Status.Resolved;
        _settle();
    }

    /// @notice Challenge a claim within its window (requires an arbiter).
    function challenge() external {
        if (status != Status.Claimed) revert NotClaimed();
        if (block.timestamp >= challengeDeadline) revert ChallengeWindowClosed();
        if (msg.sender != yesAgent && msg.sender != noAgent) revert NotParticipant();
        if (arbiter == address(0)) revert NoArbiter();
        status = Status.Contested;
        disputed = true;
        emit Challenged(msg.sender);
    }

    /// @notice Arbiter resolves a contested bet to YES, NO, or VOID.
    function resolve(Outcome outcome, bytes32 evidenceHash) external nonReentrant {
        if (status != Status.Contested) revert NotContested();
        if (msg.sender != arbiter) revert NotArbiter();
        if (outcome != Outcome.Yes && outcome != Outcome.No && outcome != Outcome.Void) {
            revert InvalidOutcome();
        }
        finalOutcome = outcome;
        status = outcome == Outcome.Void ? Status.Voided : Status.Resolved;
        emit Claimed(arbiter, outcome, evidenceHash, 0);
        _settle();
    }

    /// @notice Refund if no claim was made by the claim deadline.
    function voidUnclaimed() external nonReentrant {
        if (status != Status.Funding && status != Status.Live) revert NotRefundable();
        if (block.timestamp < claimDeadline) revert TooEarly();
        finalOutcome = Outcome.Void;
        status = Status.Voided;
        _settle();
    }

    /// @dev Pays out exactly the funded amount. YES/NO are only reachable after
    ///      both sides funded (Live), so the pot is fully collateralized; VOID
    ///      refunds only what each side actually funded.
    function _settle() internal {
        if (settled) revert AlreadySettled();
        settled = true;
        bool arb = arbiter != address(0);

        if (finalOutcome == Outcome.Void) {
            // Refund stakes + any execution-fee deposits; no fees are taken.
            if (yesFunded) token.safeTransfer(yesAgent, yesStake + (arb ? executionFee : 0));
            if (noFunded) token.safeTransfer(noAgent, noStake + (arb ? executionFee : 0));
            emit Settled(finalOutcome);
            return;
        }

        // YES/NO are only reachable after both sides funded (Live).
        uint256 pot = yesStake + noStake;
        address winner = finalOutcome == Outcome.Yes ? yesAgent : noAgent;
        address loser = finalOutcome == Outcome.Yes ? noAgent : yesAgent;

        uint256 baseFee = arb ? pot * baseFeeBps / BPS : 0;
        if (baseFee > 0) token.safeTransfer(revenueWallet, baseFee);
        token.safeTransfer(winner, pot - baseFee);

        if (arb && executionFee > 0) {
            if (disputed) {
                // Arbitration was executed: the loser's deposit pays the arbiter,
                // the winner's deposit is refunded.
                token.safeTransfer(arbiter, executionFee);
                token.safeTransfer(winner, executionFee);
            } else {
                // No arbitration happened — refund both deposits.
                token.safeTransfer(winner, executionFee);
                token.safeTransfer(loser, executionFee);
            }
        }
        emit Settled(finalOutcome);
    }
}
