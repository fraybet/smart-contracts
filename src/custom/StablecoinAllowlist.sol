// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title StablecoinAllowlist
/// @notice Owner-managed set of collateral tokens the protocol accepts (design
///         §8.3). The factory consults this before creating a bet/market so only
///         vetted stablecoins (e.g. USDC) are used. Holds no funds.
contract StablecoinAllowlist {
    address public owner;
    mapping(address => bool) private _allowed;

    event Allowed(address indexed token);
    event Disallowed(address indexed token);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroAddress();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function allow(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        _allowed[token] = true;
        emit Allowed(token);
    }

    function disallow(address token) external onlyOwner {
        _allowed[token] = false;
        emit Disallowed(token);
    }

    function isAllowed(address token) external view returns (bool) {
        return _allowed[token];
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
