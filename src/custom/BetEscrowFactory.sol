// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BetEscrow} from "./BetEscrow.sol";
import {StablecoinAllowlist} from "./StablecoinAllowlist.sol";
import {EmergencyPauseController} from "./EmergencyPauseController.sol";

/// @notice The slice of the AgentRegistry the factory needs: gate public/arbitered
///         bets on registration, and onboard a new arbitered escrow (authorize it
///         + reserve each participant's bond).
interface IAgentRegistry {
    function isActive(address wallet) external view returns (bool);
    function onArbiteredBet(address escrow, address yesAgent, address noAgent) external;
}

/// @title BetEscrowFactory
/// @notice Deploys BetEscrow contracts and emits a discoverable BetCreated
///         event. The event-sourced indexer projects public bets from this
///         event into the website feed (design §0.8). The factory holds no
///         funds and grants itself no authority over the escrow — funding stays
///         gated to the named agents inside BetEscrow.
///
///         Before creating, it consults the optional protocol controls: it
///         refuses when paused and refuses non-allowlisted collateral. Passing
///         address(0) for either control disables that check (dev/test).
///
///         Registration gating: a *public* (visibility == 1) or *arbitered*
///         (arbiter != 0) bet may only be created by a registered, active agent
///         — putting something in front of the public or invoking an arbiter
///         requires accountability. A *private, non-arbitered* bet is
///         permissionless: two parties can directly negotiate and settle without
///         registering. Passing address(0) for the registry disables the gate.
contract BetEscrowFactory {
    StablecoinAllowlist public immutable allowlist;
    EmergencyPauseController public immutable pauseController;
    IAgentRegistry public immutable registry;

    // Protocol base fee, applied by each escrow to arbitered bets only (% of pot →
    // revenueWallet). Arbitration itself is paid from bonds at the registry.
    address public immutable revenueWallet;
    uint256 public immutable baseFeeBps;

    event BetCreated(
        address indexed escrow,
        address indexed creator,
        address indexed yesAgent,
        address noAgent,
        bytes32 termsHash,
        uint8 visibility
    );

    error ProtocolPaused();
    error TokenNotAllowed();
    error NotRegistered();
    error NotParticipant();

    constructor(
        address allowlist_,
        address pauseController_,
        address revenueWallet_,
        uint256 baseFeeBps_,
        address registry_
    ) {
        allowlist = StablecoinAllowlist(allowlist_);
        pauseController = EmergencyPauseController(pauseController_);
        revenueWallet = revenueWallet_;
        baseFeeBps = baseFeeBps_;
        registry = IAgentRegistry(registry_);
    }

    /// @notice Deploy a new bet escrow from terms. Anyone may create a private,
    ///         non-arbitered bet; public or arbitered bets require the creator to
    ///         be a registered, active agent. BetEscrow validates the terms and
    ///         restricts funding/claims to the named participants.
    function create(BetEscrow.Terms calldata terms) external returns (address escrow) {
        _gate(terms);
        BetEscrow e = new BetEscrow(terms, baseFeeBps, revenueWallet, address(registry));
        escrow = address(e);
        bytes32 th = e.termsHash(); // derived inside the escrow from the descriptive terms
        // Onboard arbitered escrows: authorize the escrow to charge bonds and
        // reserve each named participant's arbitration fee up front.
        if (terms.arbiter != address(0) && address(registry) != address(0)) {
            registry.onArbiteredBet(escrow, terms.yesAgent, terms.noAgent);
        }
        emit BetCreated(escrow, msg.sender, terms.yesAgent, terms.noAgent, th, terms.visibility);
    }

    /// @dev Pre-deploy checks: protocol controls, creator-is-participant, and
    ///      registration gating. Split out of create() to keep its stack shallow.
    function _gate(BetEscrow.Terms calldata terms) internal view {
        if (address(pauseController) != address(0) && pauseController.paused()) {
            revert ProtocolPaused();
        }
        if (address(allowlist) != address(0) && !allowlist.isAllowed(terms.token)) {
            revert TokenNotAllowed();
        }
        // The creator must be a participant — you can only post a bet you're in.
        // This blocks naming arbitrary agents to spam the public feed / their
        // reputation. (A relayed, both-signed order book is a separate future path.)
        if (msg.sender != terms.yesAgent && msg.sender != terms.noAgent) {
            revert NotParticipant();
        }
        // Gate public + arbitered bets on registration; private direct bets are open.
        bool gated = terms.visibility == 1 || terms.arbiter != address(0);
        if (gated && address(registry) != address(0) && !registry.isActive(msg.sender)) {
            revert NotRegistered();
        }
        // Arbitered bets pay arbitration from bonds, so every named participant must
        // be a registered, active agent (the open side, if any, is checked on accept).
        if (terms.arbiter != address(0) && address(registry) != address(0)) {
            if (terms.yesAgent != address(0) && !registry.isActive(terms.yesAgent)) revert NotRegistered();
            if (terms.noAgent != address(0) && !registry.isActive(terms.noAgent)) revert NotRegistered();
        }
    }
}
