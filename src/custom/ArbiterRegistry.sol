// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ArbiterRegistry
/// @notice On-chain arbiter profiles and fee configuration (design §15.3).
///         Arbiters self-register; only an arbiter may mutate its own profile.
///         Holds no funds — fee routing is handled elsewhere (ArbiterFeeRouter).
contract ArbiterRegistry {
    uint256 internal constant BPS = 10_000;

    struct ArbiterProfile {
        bytes32 metadataHash;
        uint256 validationFeeBps;
        uint256 disputeFeeBps;
        uint256 minimumFee;
        uint256 maximumDisputeFee;
        uint256 bondAmount;
        uint256 reputationScore;
        bool active;
    }

    mapping(address => ArbiterProfile) private _arbiters;

    event ArbiterRegistered(address indexed arbiter, uint256 validationFeeBps, uint256 disputeFeeBps);
    event ArbiterUpdated(address indexed arbiter);
    event ArbiterDeactivated(address indexed arbiter);

    error AlreadyRegistered();
    error NotRegistered();
    error BadFeeConfig();

    /// @notice Register the caller as an arbiter with a fee config.
    function register(
        bytes32 metadataHash,
        uint256 validationFeeBps,
        uint256 disputeFeeBps,
        uint256 minimumFee,
        uint256 maximumDisputeFee,
        uint256 bondAmount
    ) external {
        if (_arbiters[msg.sender].validationFeeBps != 0 || _arbiters[msg.sender].active) {
            revert AlreadyRegistered();
        }
        if (validationFeeBps > BPS || disputeFeeBps > BPS) revert BadFeeConfig();
        _arbiters[msg.sender] = ArbiterProfile({
            metadataHash: metadataHash,
            validationFeeBps: validationFeeBps,
            disputeFeeBps: disputeFeeBps,
            minimumFee: minimumFee,
            maximumDisputeFee: maximumDisputeFee,
            bondAmount: bondAmount,
            reputationScore: 0,
            active: true
        });
        emit ArbiterRegistered(msg.sender, validationFeeBps, disputeFeeBps);
    }

    /// @notice Update the caller's fee config / metadata.
    function update(
        bytes32 metadataHash,
        uint256 validationFeeBps,
        uint256 disputeFeeBps,
        uint256 minimumFee,
        uint256 maximumDisputeFee,
        uint256 bondAmount
    ) external onlyRegistered {
        if (validationFeeBps > BPS || disputeFeeBps > BPS) revert BadFeeConfig();
        ArbiterProfile storage p = _arbiters[msg.sender];
        p.metadataHash = metadataHash;
        p.validationFeeBps = validationFeeBps;
        p.disputeFeeBps = disputeFeeBps;
        p.minimumFee = minimumFee;
        p.maximumDisputeFee = maximumDisputeFee;
        p.bondAmount = bondAmount;
        emit ArbiterUpdated(msg.sender);
    }

    /// @notice Deactivate the caller's arbiter profile.
    function deactivate() external onlyRegistered {
        _arbiters[msg.sender].active = false;
        emit ArbiterDeactivated(msg.sender);
    }

    /// @notice Profile getter (reverts if unknown).
    function arbiter(address who) external view returns (ArbiterProfile memory) {
        ArbiterProfile memory p = _arbiters[who];
        if (p.validationFeeBps == 0 && !p.active) revert NotRegistered();
        return p;
    }

    function isActive(address who) external view returns (bool) {
        return _arbiters[who].active;
    }

    /// @notice Quote the validation and dispute fees for a given pot size.
    function quote(address who, uint256 pot) external view returns (uint256 validationFee, uint256 disputeFee) {
        ArbiterProfile memory p = _arbiters[who];
        if (!p.active) revert NotRegistered();
        validationFee = pot * p.validationFeeBps / BPS;
        if (validationFee < p.minimumFee) validationFee = p.minimumFee;
        disputeFee = pot * p.disputeFeeBps / BPS;
        if (p.maximumDisputeFee != 0 && disputeFee > p.maximumDisputeFee) disputeFee = p.maximumDisputeFee;
    }

    modifier onlyRegistered() {
        if (!_arbiters[msg.sender].active) revert NotRegistered();
        _;
    }
}
