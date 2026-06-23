// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712Terms} from "./EIP712Terms.sol";

/// @notice The bond-funded arbitration interface the escrow needs from the
///         AgentRegistry: read the fee, reserve an open-bet taker's bond, and at
///         settlement release or charge a participant's reserved bond.
interface IBondRegistry {
    function arbitrationFee() external view returns (uint256);
    function reserveTaker(address taker) external;
    function release(address wallet) external;
    function charge(address wallet, address to, uint256 amount) external;
}

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

    /// @dev Constructor params, grouped to avoid stack-too-deep. Carries the full
    ///      descriptive terms (statement + sources + event time + nonce) so the
    ///      escrow can store them on-chain AND derive termsHash from them — the
    ///      stored terms and the canonical hash can never disagree. An arbiter
    ///      reads the agreed bet straight from contract storage; no off-chain
    ///      preimage to lose or dispute.
    struct Terms {
        address yesAgent;
        address noAgent;
        address arbiter; // address(0) => no dispute path
        address token;
        uint256 yesStake;
        uint256 noStake;
        uint64 eventTime; // when the real-world event resolves
        uint64 claimDeadline;
        uint64 challengeWindow;
        uint256 nonce; // disambiguates otherwise-identical terms
        string statement; // the human-readable bet
        string primarySource; // canonical resolution source
        string fallbackSource; // secondary source (may be empty)
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
    uint64 public immutable eventTime;
    uint64 public immutable claimDeadline;
    uint64 public immutable challengeWindow;
    uint256 public immutable nonce;
    bytes32 public immutable termsHash; // derived on-chain from the terms below
    uint8 public immutable visibility;

    // Descriptive terms, kept in storage so an arbiter (and anyone) reads the
    // exact agreed bet on-chain. termsHash is computed from these, so they are
    // provably the committed terms — not an unverified off-chain copy.
    string public statement;
    string public primarySource;
    string public fallbackSource;

    // The arbiter's published deliberation (a link to the full Claude/OpenAI/Gemini
    // transcript PDF), set on resolve() so the resolution's evidence lives on the bet.
    string public evidenceURI;

    // Protocol fees — applied ONLY to arbitered bets (arbiter != 0). baseFee is a
    // % of the pot → revenueWallet, taken at settlement. Arbitration itself is paid
    // from the participants' registration BONDS (not a per-bet deposit): the
    // registry reserves a slice of each side's bond at entry and, on a disputed
    // resolution, the arbiter is charged the loser's (or, on a void, both sides')
    // reserved bond. So an arbitered bet escrows only stake here.
    uint256 public immutable baseFeeBps;
    address public immutable revenueWallet;
    IBondRegistry public immutable registry; // bond-funded arbitration source

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
    // Emitted when the arbiter resolves a dispute, carrying the link to its
    // published deliberation so indexers/clients can attach it to the bet.
    event ArbiterResolved(Outcome outcome, bytes32 evidenceHash, string evidenceURI);

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

    constructor(Terms memory t, uint256 baseFeeBps_, address revenueWallet_, address registry_) {
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
        // Arbitered bets need a revenue wallet (base fee) and a bond registry
        // (arbitration is paid from bonds). Non-arbitered bets need neither.
        if (t.arbiter != address(0)) {
            if (baseFeeBps_ > 0 && revenueWallet_ == address(0)) revert BadTerms();
            if (registry_ == address(0)) revert BadTerms();
        }
        if (baseFeeBps_ > BPS) revert BadTerms();
        yesAgent = t.yesAgent;
        noAgent = t.noAgent;
        arbiter = t.arbiter;
        token = IERC20(t.token);
        yesStake = t.yesStake;
        noStake = t.noStake;
        eventTime = t.eventTime;
        claimDeadline = t.claimDeadline;
        challengeWindow = t.challengeWindow;
        nonce = t.nonce;
        statement = t.statement;
        primarySource = t.primarySource;
        fallbackSource = t.fallbackSource;
        visibility = t.visibility;
        // Derive the canonical termsHash from the stored terms (EIP-712). Because
        // it is computed here, not supplied, the on-chain statement/sources are
        // guaranteed to be exactly what the hash commits to — open side included
        // (the open agent is address(0) at creation, matching the off-chain hash).
        termsHash = EIP712Terms.structHash(
            EIP712Terms.BetTerms({
                yesAgent: t.yesAgent,
                noAgent: t.noAgent,
                collateralToken: t.token,
                yesStake: t.yesStake,
                noStake: t.noStake,
                statement: t.statement,
                eventTime: t.eventTime,
                claimDeadline: t.claimDeadline,
                challengeWindow: t.challengeWindow,
                primarySource: t.primarySource,
                fallbackSource: t.fallbackSource,
                arbiter: t.arbiter,
                nonce: t.nonce
            })
        );
        baseFeeBps = baseFeeBps_;
        revenueWallet = revenueWallet_;
        registry = IBondRegistry(registry_);
        status = Status.Funding;
    }

    /// @notice Fund your side. Each agent transfers its own stake; when both
    ///         have funded, the bet goes Live.
    function fund() external nonReentrant {
        if (status != Status.Funding) revert NotFunding();
        // Stake only — arbitration is bonded at the registry, not deposited here.
        if (msg.sender == yesAgent) {
            if (yesFunded) revert AlreadyFunded();
            yesFunded = true;
            token.safeTransferFrom(msg.sender, address(this), yesStake);
        } else if (msg.sender == noAgent) {
            if (noFunded) revert AlreadyFunded();
            noFunded = true;
            token.safeTransferFrom(msg.sender, address(this), noStake);
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
    ///         counterparty stake, and the bet goes Live in the same call. On an
    ///         arbitered bet the taker's bond is reserved at the registry (which
    ///         requires the taker to be a registered agent with free bond).
    function accept() external nonReentrant {
        if (status != Status.Funding) revert NotFunding();
        bool openYes = yesAgent == address(0);
        bool openNo = noAgent == address(0);
        if (!openYes && !openNo) revert NotOpen();
        address proposer = openYes ? noAgent : yesAgent;
        if (msg.sender == proposer) revert NotParticipant(); // can't take your own bet
        // The proposer must be committed (funded) before anyone can accept.
        if (openYes ? !noFunded : !yesFunded) revert NotFunding();

        if (openYes) {
            yesAgent = msg.sender;
            yesFunded = true;
            token.safeTransferFrom(msg.sender, address(this), yesStake);
        } else {
            noAgent = msg.sender;
            noFunded = true;
            token.safeTransferFrom(msg.sender, address(this), noStake);
        }
        if (arbiter != address(0)) registry.reserveTaker(msg.sender);
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
        // Release the proposer's reserved bond and refund their stake. The open
        // side was never accepted, so it neither funded nor reserved.
        if (arbiter != address(0)) registry.release(proposer);
        if (openYes) {
            if (noFunded) token.safeTransfer(noAgent, noStake);
        } else {
            if (yesFunded) token.safeTransfer(yesAgent, yesStake);
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

    /// @notice Arbiter resolves a contested bet to YES, NO, or VOID. evidenceURI_
    ///         is the link to the arbiter's published deliberation (the full
    ///         Claude/OpenAI/Gemini transcript PDF); evidenceHash commits to it.
    function resolve(Outcome outcome, bytes32 evidenceHash, string calldata evidenceURI_) external nonReentrant {
        if (status != Status.Contested) revert NotContested();
        if (msg.sender != arbiter) revert NotArbiter();
        if (outcome != Outcome.Yes && outcome != Outcome.No && outcome != Outcome.Void) {
            revert InvalidOutcome();
        }
        evidenceURI = evidenceURI_;
        finalOutcome = outcome;
        status = outcome == Outcome.Void ? Status.Voided : Status.Resolved;
        emit Claimed(arbiter, outcome, evidenceHash, 0);
        emit ArbiterResolved(outcome, evidenceHash, evidenceURI_);
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
    ///      refunds only what each side actually funded. Arbitration is paid from
    ///      the participants' bonds via the registry (only on a *disputed*
    ///      resolution); the per-bet bond reservations are released here too.
    function _settle() internal {
        if (settled) revert AlreadySettled();
        settled = true;
        bool arb = arbiter != address(0);

        if (finalOutcome == Outcome.Void) {
            if (!(arb && disputed)) {
                // Undisputed void (mutual agreeOutcome / unclaimed timeout): no
                // arbiter did any work. Refund stakes; release both reservations.
                if (yesFunded) token.safeTransfer(yesAgent, yesStake);
                if (noFunded) token.safeTransfer(noAgent, noStake);
                if (arb) {
                    if (yesAgent != address(0)) registry.release(yesAgent);
                    if (noAgent != address(0)) registry.release(noAgent);
                }
                emit Settled(finalOutcome);
                return;
            }
            // Arbiter adjudicated the bet VOID (e.g. nonsensical / unresolvable).
            // It still did the work, so the base fee (from the pot) AND the
            // arbitration fee (from bonds) are charged, each split EQUALLY between
            // the two sides — a void has no loser. A disputed void is only
            // reachable from Contested, so both sides funded.
            uint256 pot = yesStake + noStake;
            uint256 baseFee = pot * baseFeeBps / BPS;
            uint256 yesBase = baseFee / 2;
            uint256 noBase = baseFee - yesBase; // NO absorbs any odd-wei remainder
            if (baseFee > 0) token.safeTransfer(revenueWallet, baseFee);
            token.safeTransfer(yesAgent, yesStake - yesBase);
            token.safeTransfer(noAgent, noStake - noBase);
            uint256 fee = registry.arbitrationFee();
            uint256 halfFee = fee / 2;
            registry.charge(yesAgent, arbiter, halfFee);
            registry.charge(noAgent, arbiter, fee - halfFee);
            emit Settled(finalOutcome);
            return;
        }

        // YES/NO are only reachable after both sides funded (Live).
        uint256 pot2 = yesStake + noStake;
        address winner = finalOutcome == Outcome.Yes ? yesAgent : noAgent;
        address loser = finalOutcome == Outcome.Yes ? noAgent : yesAgent;

        uint256 base = arb ? pot2 * baseFeeBps / BPS : 0;
        if (base > 0) token.safeTransfer(revenueWallet, base);
        token.safeTransfer(winner, pot2 - base);

        if (arb) {
            if (disputed) {
                // Arbitration executed: the loser's bond pays the arbiter; the
                // winner's reservation is released untouched.
                registry.charge(loser, arbiter, registry.arbitrationFee());
                registry.release(winner);
            } else {
                // No arbitration happened — release both reservations, charge none.
                registry.release(winner);
                registry.release(loser);
            }
        }
        emit Settled(finalOutcome);
    }
}
