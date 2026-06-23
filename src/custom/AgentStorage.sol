// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AgentStorage
/// @notice Long-lived data + funds vault behind the agent registry. It holds
///         every agent profile, the refundable bonds (and their per-bet
///         reservations against open arbitered bets), accrued protocol fees, the
///         set of authorized escrows, and the bondToken (USDC) itself.
///
///         All mutation is gated to a single `controller` — the AgentRegistry
///         logic (deployed behind a UUPS proxy). The registry's rules can then be
///         upgraded without migrating any of this state or moving the funds: the
///         admin just repoints the controller. The admin has no path to the funds.
///
///         Funds invariant: bondToken held == sum(bonds) + accruedFees.
contract AgentStorage {
    using SafeERC20 for IERC20;

    struct Profile {
        address owner; // principal that authorized + paid for the agent
        address wallet;
        address signer; // signing key (message-signed auth)
        bytes32 policyHash;
        bytes32 metadataHash;
        uint256 bond; // refundable bond held for this agent
        uint256 reserved; // portion of bond reserved against open arbitered bets
        uint64 createdAt;
        bool active;
    }

    IERC20 public immutable bondToken;
    address public admin; // repoints the controller; never touches funds
    address public controller; // the registry logic allowed to mutate state/funds

    mapping(address => Profile) internal _agents; // keyed by agent wallet
    mapping(address => bool) public isEscrow; // escrows authorized to reserve/charge
    uint256 public accruedFees; // pending sweep

    event ControllerUpdated(address indexed controller);
    event AdminTransferred(address indexed admin);

    error NotController();
    error NotAdmin();
    error ZeroAddress();

    constructor(address bondToken_, address admin_) {
        if (bondToken_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        bondToken = IERC20(bondToken_);
        admin = admin_;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // --- admin: point at the current logic; this is the entire "upgrade" step ---

    function setController(address controller_) external onlyAdmin {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit ControllerUpdated(controller_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        emit AdminTransferred(newAdmin);
    }

    // --- controller-gated state mutators (thin; the registry owns the rules) ---

    function setProfile(address wallet, Profile calldata p) external onlyController {
        _agents[wallet] = p;
    }

    function setBond(address wallet, uint256 bond, uint256 reserved) external onlyController {
        Profile storage p = _agents[wallet];
        p.bond = bond;
        p.reserved = reserved;
    }

    function setActive(address wallet, bool active) external onlyController {
        _agents[wallet].active = active;
    }

    function setSigner(address wallet, address signer) external onlyController {
        _agents[wallet].signer = signer;
    }

    function setPolicy(address wallet, bytes32 policyHash) external onlyController {
        _agents[wallet].policyHash = policyHash;
    }

    function setEscrow(address escrow, bool ok) external onlyController {
        isEscrow[escrow] = ok;
    }

    function setAccruedFees(uint256 amount) external onlyController {
        accruedFees = amount;
    }

    // --- controller-gated funds movement (this vault is the sole custodian) ---

    /// @notice Pull bondToken from `payer` into the vault. The payer must have
    ///         approved THIS contract (the custodian) for `amount`.
    function pull(address payer, uint256 amount) external onlyController {
        if (amount > 0) bondToken.safeTransferFrom(payer, address(this), amount);
    }

    /// @notice Pay bondToken out of the vault. Only the controller can move funds.
    function payout(address to, uint256 amount) external onlyController {
        if (amount > 0) bondToken.safeTransfer(to, amount);
    }

    // --- views ---

    function agent(address wallet) external view returns (Profile memory) {
        return _agents[wallet];
    }

    function exists(address wallet) external view returns (bool) {
        return _agents[wallet].owner != address(0);
    }

    function isActive(address wallet) external view returns (bool) {
        return _agents[wallet].active;
    }

    function signerOf(address wallet) external view returns (address) {
        return _agents[wallet].signer;
    }

    function bondOf(address wallet) external view returns (uint256) {
        return _agents[wallet].bond;
    }

    function reservedOf(address wallet) external view returns (uint256) {
        return _agents[wallet].reserved;
    }

    function freeBond(address wallet) external view returns (uint256) {
        Profile storage p = _agents[wallet];
        return p.bond - p.reserved;
    }
}
