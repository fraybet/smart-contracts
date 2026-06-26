// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Gnosis CTF surface this resolver needs.
interface IConditionalTokensReport {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
}

/// @title FrayMarketResolver
/// @notice The single CTF oracle for every Fray binary market. Markets are
///         100% AI-settled: the Fray arbiter (the same LLM panel that settles
///         agent-to-agent bets) deliberates off-chain, then calls `resolve` to
///         report the binary payout vector to the Conditional Tokens Framework
///         and post its justification on-chain — byte-for-byte the evidence
///         pattern of the A2A `BetEscrow.resolve` (a GCS-hosted deliberation PDF
///         with a 60-day TTL, committed to by `evidenceHash`).
///
///         A market condition is prepared with THIS contract as its CTF oracle,
///         so only this contract (and therefore only the arbiter) can report its
///         payouts. Outcome → payout vector:
///           YES  -> [1, 0]   (slot 0 wins)
///           NO   -> [0, 1]   (slot 1 wins)
///           VOID -> [1, 1]   (50/50 split: both sides redeem their collateral)
contract FrayMarketResolver {
    enum Outcome {
        Unresolved,
        Yes,
        No,
        Void
    }

    /// @notice The Conditional Tokens Framework this resolver reports to.
    IConditionalTokensReport public immutable ctf;

    /// @notice The authorized arbiter (the Fray LLM-panel arbiter signing key).
    address public arbiter;

    /// @notice Admin able to rotate the arbiter key (e.g. on key rotation).
    address public admin;

    /// @notice questionId => decided outcome (Unresolved until settled).
    mapping(bytes32 => Outcome) public outcomeOf;

    /// @notice questionId => evidence URI (the published deliberation PDF).
    mapping(bytes32 => string) public evidenceURIOf;

    event ConditionPrepared(bytes32 indexed questionId, bytes32 indexed conditionId);
    event MarketResolved(
        bytes32 indexed questionId,
        bytes32 indexed conditionId,
        Outcome outcome,
        uint256[] payouts,
        bytes32 evidenceHash,
        string evidenceURI
    );
    event ArbiterUpdated(address indexed previous, address indexed next);
    event AdminUpdated(address indexed previous, address indexed next);

    error NotArbiter();
    error NotAdmin();
    error AlreadyResolved();
    error InvalidOutcome();
    error ZeroAddress();

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _ctf, address _arbiter) {
        if (_ctf == address(0) || _arbiter == address(0)) revert ZeroAddress();
        ctf = IConditionalTokensReport(_ctf);
        arbiter = _arbiter;
        admin = msg.sender;
    }

    /// @notice Prepare a binary condition on the CTF with this resolver as oracle.
    ///         Permissionless — `questionId` namespaces the condition, and only
    ///         this resolver can ever report its payouts. Idempotent-safe: a
    ///         repeat call reverts inside the CTF (condition already prepared).
    function prepareMarket(bytes32 questionId) external returns (bytes32 conditionId) {
        ctf.prepareCondition(address(this), questionId, 2);
        conditionId = ctf.getConditionId(address(this), questionId, 2);
        emit ConditionPrepared(questionId, conditionId);
    }

    /// @notice The CTF conditionId for a Fray market question.
    function conditionIdFor(bytes32 questionId) public view returns (bytes32) {
        return ctf.getConditionId(address(this), questionId, 2);
    }

    /// @notice Arbiter settles a market to YES, NO, or VOID and posts evidence.
    /// @param questionId   The market's question id (namespaces its CTF condition).
    /// @param outcome      Yes, No, or Void (Unresolved is rejected).
    /// @param evidenceHash keccak256 commitment to the deliberation evidence.
    /// @param evidenceURI  URI of the published deliberation (e.g. the GCS PDF).
    function resolve(bytes32 questionId, Outcome outcome, bytes32 evidenceHash, string calldata evidenceURI)
        external
        onlyArbiter
    {
        if (outcome == Outcome.Unresolved) revert InvalidOutcome();
        if (outcomeOf[questionId] != Outcome.Unresolved) revert AlreadyResolved();

        bytes32 conditionId = ctf.getConditionId(address(this), questionId, 2);
        // Belt-and-suspenders: the CTF marks a condition resolved by setting a
        // non-zero payout denominator. Never double-report.
        if (ctf.payoutDenominator(conditionId) != 0) revert AlreadyResolved();

        uint256[] memory payouts = new uint256[](2);
        if (outcome == Outcome.Yes) {
            payouts[0] = 1;
            payouts[1] = 0;
        } else if (outcome == Outcome.No) {
            payouts[0] = 0;
            payouts[1] = 1;
        } else {
            // Void: 50/50 so both sides redeem their original collateral back.
            payouts[0] = 1;
            payouts[1] = 1;
        }

        outcomeOf[questionId] = outcome;
        evidenceURIOf[questionId] = evidenceURI;

        ctf.reportPayouts(questionId, payouts);
        emit MarketResolved(questionId, conditionId, outcome, payouts, evidenceHash, evidenceURI);
    }

    /// @notice Rotate the arbiter signing key.
    function setArbiter(address next) external onlyAdmin {
        if (next == address(0)) revert ZeroAddress();
        emit ArbiterUpdated(arbiter, next);
        arbiter = next;
    }

    /// @notice Transfer admin control.
    function setAdmin(address next) external onlyAdmin {
        if (next == address(0)) revert ZeroAddress();
        emit AdminUpdated(admin, next);
        admin = next;
    }
}
