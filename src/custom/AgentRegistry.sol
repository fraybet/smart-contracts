// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {AgentStorage} from "./AgentStorage.sol";

/// @title AgentRegistry (logic)
/// @notice Upgradeable business logic for on-chain agent identity (design §15.2).
///         Holds no agent state and no funds — those live in the long-lived
///         AgentStorage, of which this contract is the sole `controller`. Deployed
///         behind a UUPS proxy so both the logic and the storage have stable
///         addresses; upgrading the rules never migrates state or re-registers.
///
///         Registration: each agent posts a non-refundable protocol **fee**
///         (swept to revenue) plus a refundable **bond** (returned on
///         deactivation, slashable for abuse). Arbitered bets reserve an
///         `arbitrationFee` slice of each participant's bond at entry; on a
///         disputed resolution the arbiter is paid from the loser's (or, on a
///         void, both sides') reserved bond. The bond can never be drained below
///         its outstanding reservations, so arbitration is always collateralized.
contract AgentRegistry is Initializable, UUPSUpgradeable {
    AgentStorage public store;
    uint256 public registrationFee; // non-refundable → revenue
    uint256 public registrationBond; // refundable / slashable
    uint256 public arbitrationFee; // reserved + charged per side per arbitered bet
    address public admin; // protocol operator ("the runner"); authorizes upgrades
    address public revenueWallet; // where swept fees + slashed bonds land
    address public factory; // the one factory authorized to onboard escrows

    event AgentRegistered(address indexed wallet, address indexed owner, address signer, uint256 bond, uint256 fee);
    event AgentPolicyUpdated(address indexed wallet, bytes32 policyHash);
    event AgentSignerUpdated(address indexed wallet, address signer);
    event AgentDeactivated(address indexed wallet);
    event BondRefunded(address indexed wallet, address indexed to, uint256 amount);
    event BondSlashed(address indexed wallet, uint256 amount);
    event BondReserved(address indexed wallet, uint256 amount);
    event BondReleased(address indexed wallet, uint256 amount);
    event BondCharged(address indexed wallet, address indexed to, uint256 amount);
    event FeesSwept(address indexed to, uint256 amount);
    event FactoryUpdated(address indexed factory);
    event ArbitrationFeeUpdated(uint256 fee);
    event RevenueWalletUpdated(address indexed wallet);
    event AdminTransferred(address indexed admin);

    error AlreadyRegistered();
    error NotRegistered();
    error NotOwner();
    error NotAdmin();
    error NotFactory();
    error NotEscrow();
    error NotActive();
    error ZeroAddress();
    error InsufficientBond();
    error BondReservedOpen();
    error BadAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address store_,
        uint256 registrationFee_,
        uint256 registrationBond_,
        uint256 arbitrationFee_,
        address admin_,
        address revenueWallet_,
        address factory_
    ) external initializer {
        if (store_ == address(0) || admin_ == address(0) || revenueWallet_ == address(0)) revert ZeroAddress();
        store = AgentStorage(store_);
        registrationFee = registrationFee_;
        registrationBond = registrationBond_;
        arbitrationFee = arbitrationFee_;
        admin = admin_;
        revenueWallet = revenueWallet_;
        factory = factory_;
    }

    function _authorizeUpgrade(address) internal view override onlyAdmin {}

    // --- registration ---

    /// @notice Register an agent. The caller (principal) must have approved the
    ///         AgentStorage (the funds custodian) for `registrationFee + bond`.
    function register(address wallet, address signer, bytes32 policyHash, bytes32 metadataHash) external {
        if (wallet == address(0) || signer == address(0)) revert ZeroAddress();
        if (store.exists(wallet)) revert AlreadyRegistered();

        uint256 total = registrationFee + registrationBond;
        store.pull(msg.sender, total);
        store.setAccruedFees(store.accruedFees() + registrationFee);
        store.setProfile(
            wallet,
            AgentStorage.Profile({
                owner: msg.sender,
                wallet: wallet,
                signer: signer,
                policyHash: policyHash,
                metadataHash: metadataHash,
                bond: registrationBond,
                reserved: 0,
                createdAt: uint64(block.timestamp),
                active: true
            })
        );
        emit AgentRegistered(wallet, msg.sender, signer, registrationBond, registrationFee);
    }

    function updatePolicy(address wallet, bytes32 policyHash) external onlyOwner(wallet) {
        store.setPolicy(wallet, policyHash);
        emit AgentPolicyUpdated(wallet, policyHash);
    }

    function updateSigner(address wallet, address signer) external onlyOwner(wallet) {
        if (signer == address(0)) revert ZeroAddress();
        store.setSigner(wallet, signer);
        emit AgentSignerUpdated(wallet, signer);
    }

    /// @notice Deactivate an agent and refund its (unslashed) bond. Blocked while
    ///         the agent has bond reserved against open arbitered bets — those
    ///         must settle first, so the bond can't be pulled out from under a
    ///         live dispute.
    function deactivate(address wallet) external onlyOwner(wallet) {
        AgentStorage.Profile memory p = store.agent(wallet);
        if (p.reserved != 0) revert BondReservedOpen();
        uint256 bond = p.bond;
        store.setBond(wallet, 0, 0);
        store.setActive(wallet, false);
        emit AgentDeactivated(wallet);
        if (bond > 0) {
            store.payout(p.owner, bond);
            emit BondRefunded(wallet, p.owner, bond);
        }
    }

    /// @notice Slash a misbehaving agent's entire bond into protocol revenue.
    function slash(address wallet) external onlyAdmin {
        AgentStorage.Profile memory p = store.agent(wallet);
        if (p.owner == address(0)) revert NotRegistered();
        uint256 bond = p.bond;
        store.setBond(wallet, 0, 0); // wipes any reservations too
        store.setActive(wallet, false);
        store.setAccruedFees(store.accruedFees() + bond);
        emit BondSlashed(wallet, bond);
    }

    /// @notice Sweep accrued fees (and slashed bonds) to the revenue wallet.
    ///         Callable by anyone — the destination is fixed.
    function sweepFees() external {
        uint256 amt = store.accruedFees();
        store.setAccruedFees(0);
        if (amt > 0) {
            store.payout(revenueWallet, amt);
            emit FeesSwept(revenueWallet, amt);
        }
    }

    // --- arbitration bond lifecycle (called by the factory / authorized escrows) ---

    /// @notice The factory onboards a freshly-created arbitered escrow: authorize
    ///         it to reserve/charge, and reserve the arbitration fee from each
    ///         named participant. An open side (address(0)) reserves later, when a
    ///         taker accepts.
    function onArbiteredBet(address escrow, address yesAgent, address noAgent) external onlyFactory {
        store.setEscrow(escrow, true);
        if (yesAgent != address(0)) _reserve(yesAgent);
        if (noAgent != address(0)) _reserve(noAgent);
    }

    /// @notice An open arbitered bet's taker reserves on acceptance.
    function reserveTaker(address taker) external onlyEscrow {
        _reserve(taker);
    }

    /// @notice Release a participant's per-bet reservation with no charge (the
    ///         common case: no dispute, or this side didn't owe the arbiter).
    function release(address wallet) external onlyEscrow {
        AgentStorage.Profile memory p = store.agent(wallet);
        uint256 rel = arbitrationFee <= p.reserved ? arbitrationFee : p.reserved;
        store.setBond(wallet, p.bond, p.reserved - rel);
        emit BondReleased(wallet, rel);
    }

    /// @notice Release a participant's per-bet reservation AND debit `amount` of
    ///         its bond to `to` (the arbiter). `amount` may be the full
    ///         arbitration fee (a disputed loser) or a fraction (each side's half
    ///         on a void). The reservation guarantees the bond covers it.
    function charge(address wallet, address to, uint256 amount) external onlyEscrow {
        if (amount > arbitrationFee) revert BadAmount();
        AgentStorage.Profile memory p = store.agent(wallet);
        uint256 rel = arbitrationFee <= p.reserved ? arbitrationFee : p.reserved;
        store.setBond(wallet, p.bond - amount, p.reserved - rel);
        store.payout(to, amount);
        emit BondCharged(wallet, to, amount);
    }

    function _reserve(address wallet) internal {
        AgentStorage.Profile memory p = store.agent(wallet);
        if (!p.active) revert NotActive();
        if (p.bond - p.reserved < arbitrationFee) revert InsufficientBond();
        store.setBond(wallet, p.bond, p.reserved + arbitrationFee);
        emit BondReserved(wallet, arbitrationFee);
    }

    // --- admin config ---

    function setFactory(address factory_) external onlyAdmin {
        factory = factory_;
        emit FactoryUpdated(factory_);
    }

    function setArbitrationFee(uint256 fee) external onlyAdmin {
        arbitrationFee = fee;
        emit ArbitrationFeeUpdated(fee);
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

    // --- views (pass-throughs so callers can use just the registry address) ---

    function agent(address wallet) external view returns (AgentStorage.Profile memory) {
        AgentStorage.Profile memory p = store.agent(wallet);
        if (p.owner == address(0)) revert NotRegistered();
        return p;
    }

    function isActive(address wallet) external view returns (bool) {
        return store.isActive(wallet);
    }

    function signerOf(address wallet) external view returns (address) {
        return store.signerOf(wallet);
    }

    function freeBond(address wallet) external view returns (uint256) {
        return store.freeBond(wallet);
    }

    modifier onlyOwner(address wallet) {
        AgentStorage.Profile memory p = store.agent(wallet);
        if (p.owner == address(0)) revert NotRegistered();
        if (p.owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyEscrow() {
        if (!store.isEscrow(msg.sender)) revert NotEscrow();
        _;
    }
}
