// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgentRegistry
/// @notice On-chain agent identity (design §15.2) with a paid registration:
///         each agent posts a non-refundable protocol **fee** (accrues to the
///         operator and is swept to a configurable revenue wallet) plus a
///         refundable **bond** (returned on deactivation, slashable for abuse —
///         the anti-sybil / anti-spam stake behind the address-is-identity auth
///         model). Funds are held in `bondToken` (e.g. USDC).
///
///         Funds invariant: bondToken held == sum(active bonds) + accruedFees.
contract AgentRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AgentProfile {
        address owner; // principal that authorized + paid for the agent
        address wallet;
        address signer; // signing key (the address used for message-signed auth)
        bytes32 policyHash;
        bytes32 metadataHash;
        uint256 bond; // refundable bond held for this agent
        uint64 createdAt;
        bool active;
    }

    IERC20 public immutable bondToken;
    uint256 public immutable registrationFee; // non-refundable → revenue
    uint256 public immutable registrationBond; // refundable / slashable

    address public admin; // protocol operator ("the runner")
    address public revenueWallet; // where swept fees land
    uint256 public accruedFees; // pending sweep

    mapping(address => AgentProfile) private _agents; // keyed by agent wallet

    event AgentRegistered(address indexed wallet, address indexed owner, address signer, uint256 bond, uint256 fee);
    event AgentPolicyUpdated(address indexed wallet, bytes32 policyHash);
    event AgentSignerUpdated(address indexed wallet, address signer);
    event AgentDeactivated(address indexed wallet);
    event BondRefunded(address indexed wallet, address indexed to, uint256 amount);
    event BondSlashed(address indexed wallet, uint256 amount);
    event FeesSwept(address indexed to, uint256 amount);
    event RevenueWalletUpdated(address indexed wallet);
    event AdminTransferred(address indexed admin);

    error AlreadyRegistered();
    error NotRegistered();
    error NotOwner();
    error NotAdmin();
    error ZeroAddress();

    constructor(
        address bondToken_,
        uint256 registrationFee_,
        uint256 registrationBond_,
        address admin_,
        address revenueWallet_
    ) {
        if (bondToken_ == address(0) || admin_ == address(0) || revenueWallet_ == address(0)) {
            revert ZeroAddress();
        }
        bondToken = IERC20(bondToken_);
        registrationFee = registrationFee_;
        registrationBond = registrationBond_;
        admin = admin_;
        revenueWallet = revenueWallet_;
    }

    /// @notice Register an agent. The caller (principal) must have approved this
    ///         contract for `registrationFee + registrationBond` of bondToken.
    function register(address wallet, address signer, bytes32 policyHash, bytes32 metadataHash) external nonReentrant {
        if (wallet == address(0) || signer == address(0)) revert ZeroAddress();
        if (_agents[wallet].owner != address(0)) revert AlreadyRegistered();

        uint256 total = registrationFee + registrationBond;
        if (total > 0) bondToken.safeTransferFrom(msg.sender, address(this), total);
        accruedFees += registrationFee;

        _agents[wallet] = AgentProfile({
            owner: msg.sender,
            wallet: wallet,
            signer: signer,
            policyHash: policyHash,
            metadataHash: metadataHash,
            bond: registrationBond,
            createdAt: uint64(block.timestamp),
            active: true
        });
        emit AgentRegistered(wallet, msg.sender, signer, registrationBond, registrationFee);
    }

    /// @notice Update the policy hash. Owner only.
    function updatePolicy(address wallet, bytes32 policyHash) external onlyOwner(wallet) {
        _agents[wallet].policyHash = policyHash;
        emit AgentPolicyUpdated(wallet, policyHash);
    }

    /// @notice Rotate the signing key. Owner only.
    function updateSigner(address wallet, address signer) external onlyOwner(wallet) {
        if (signer == address(0)) revert ZeroAddress();
        _agents[wallet].signer = signer;
        emit AgentSignerUpdated(wallet, signer);
    }

    /// @notice Deactivate an agent and refund its (unslashed) bond to the owner.
    function deactivate(address wallet) external nonReentrant onlyOwner(wallet) {
        AgentProfile storage p = _agents[wallet];
        p.active = false;
        uint256 bond = p.bond;
        p.bond = 0;
        emit AgentDeactivated(wallet);
        if (bond > 0) {
            bondToken.safeTransfer(p.owner, bond);
            emit BondRefunded(wallet, p.owner, bond);
        }
    }

    /// @notice Slash a misbehaving agent's bond into protocol revenue. Admin only.
    function slash(address wallet) external onlyAdmin {
        AgentProfile storage p = _agents[wallet];
        if (p.owner == address(0)) revert NotRegistered();
        uint256 bond = p.bond;
        p.bond = 0;
        p.active = false;
        accruedFees += bond;
        emit BondSlashed(wallet, bond);
    }

    /// @notice Sweep accrued fees to the revenue wallet. Callable by anyone (the
    ///         destination is fixed), so the operator can automate it.
    function sweepFees() external nonReentrant {
        uint256 amt = accruedFees;
        accruedFees = 0;
        if (amt > 0) {
            bondToken.safeTransfer(revenueWallet, amt);
            emit FeesSwept(revenueWallet, amt);
        }
    }

    function setRevenueWallet(address wallet) external onlyAdmin {
        if (wallet == address(0)) revert ZeroAddress();
        revenueWallet = wallet;
        emit RevenueWalletUpdated(wallet);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        emit AdminTransferred(newAdmin);
    }

    /// @notice Profile getter (reverts if unknown).
    function agent(address wallet) external view returns (AgentProfile memory) {
        AgentProfile memory p = _agents[wallet];
        if (p.owner == address(0)) revert NotRegistered();
        return p;
    }

    /// @notice The signer authorized for an agent (for message-signed auth).
    function signerOf(address wallet) external view returns (address) {
        return _agents[wallet].signer;
    }

    function isActive(address wallet) external view returns (bool) {
        return _agents[wallet].active;
    }

    modifier onlyOwner(address wallet) {
        AgentProfile storage p = _agents[wallet];
        if (p.owner == address(0)) revert NotRegistered();
        if (p.owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }
}
