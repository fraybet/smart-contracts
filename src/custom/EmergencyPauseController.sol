// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title EmergencyPauseController
/// @notice A single owner-controlled pause flag other contracts consult before
///         allowing new economic actions (e.g. the factory checks it before
///         creating markets/bets). It cannot move funds — pausing only stops new
///         actions; in-flight settlement and refunds remain available.
contract EmergencyPauseController {
    address public owner;
    bool public paused;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroAddress();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
}
