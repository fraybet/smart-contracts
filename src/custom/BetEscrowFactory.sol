// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BetEscrow} from "./BetEscrow.sol";
import {StablecoinAllowlist} from "./StablecoinAllowlist.sol";
import {EmergencyPauseController} from "./EmergencyPauseController.sol";

/// @notice Minimal view into the AgentRegistry used to gate public/arbitered bets.
interface IAgentRegistry {
    function isActive(address wallet) external view returns (bool);
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

    // Protocol arbitration fees, applied by each escrow to arbitered bets only.
    address public immutable revenueWallet;
    uint256 public immutable baseFeeBps; // base fee, % of pot → revenueWallet
    uint256 public immutable executionFee; // fixed per-side deposit; loser's pays the arbiter

    event BetCreated(
        address indexed escrow, address indexed yesAgent, address indexed noAgent, bytes32 termsHash, uint8 visibility
    );

    error ProtocolPaused();
    error TokenNotAllowed();
    error NotRegistered();

    constructor(
        address allowlist_,
        address pauseController_,
        address revenueWallet_,
        uint256 baseFeeBps_,
        uint256 executionFee_,
        address registry_
    ) {
        allowlist = StablecoinAllowlist(allowlist_);
        pauseController = EmergencyPauseController(pauseController_);
        revenueWallet = revenueWallet_;
        baseFeeBps = baseFeeBps_;
        executionFee = executionFee_;
        registry = IAgentRegistry(registry_);
    }

    /// @notice Deploy a new bet escrow from terms. Anyone may create a private,
    ///         non-arbitered bet; public or arbitered bets require the creator to
    ///         be a registered, active agent. BetEscrow validates the terms and
    ///         restricts funding/claims to the named participants.
    function create(BetEscrow.Terms calldata terms) external returns (address escrow) {
        if (address(pauseController) != address(0) && pauseController.paused()) {
            revert ProtocolPaused();
        }
        if (address(allowlist) != address(0) && !allowlist.isAllowed(terms.token)) {
            revert TokenNotAllowed();
        }
        // Gate public + arbitered bets on registration; private direct bets are open.
        bool gated = terms.visibility == 1 || terms.arbiter != address(0);
        if (gated && address(registry) != address(0) && !registry.isActive(msg.sender)) {
            revert NotRegistered();
        }
        BetEscrow e = new BetEscrow(terms, baseFeeBps, executionFee, revenueWallet);
        escrow = address(e);
        emit BetCreated(escrow, terms.yesAgent, terms.noAgent, terms.termsHash, terms.visibility);
    }
}
