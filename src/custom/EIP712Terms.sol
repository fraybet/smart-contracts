// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title EIP712Terms
/// @notice Canonical EIP-712 hashing for bilateral bet terms. This MUST stay
///         byte-for-byte identical to the Go implementation in
///         internal/core/eip712.go. The shared vectors in
///         internal/core/testdata/parity_vectors.json are asserted from both
///         sides (Go: TestParity, Solidity: test/Parity.t.sol).
///
///         Hashing pipeline:
///           BetTerms --abi.encode--> keccak256 --> structHash (termsHash)
///           domain   --abi.encode--> keccak256 --> domainSeparator
///           digest = keccak256(0x1901 || domainSeparator || structHash)
library EIP712Terms {
    bytes32 internal constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant BET_TERMS_TYPEHASH = keccak256(
        "BetTerms(address yesAgent,address noAgent,address collateralToken,uint256 yesStake,uint256 noStake,string statement,uint256 eventTime,uint256 claimDeadline,uint256 challengeWindow,string primarySource,string fallbackSource,address arbiter,uint256 nonce)"
    );

    struct BetTerms {
        address yesAgent;
        address noAgent;
        address collateralToken;
        uint256 yesStake;
        uint256 noStake;
        string statement;
        uint256 eventTime;
        uint256 claimDeadline;
        uint256 challengeWindow;
        string primarySource;
        string fallbackSource;
        address arbiter;
        uint256 nonce;
    }

    /// @notice EIP-712 hashStruct(BetTerms) — the canonical termsHash.
    function structHash(BetTerms memory t) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BET_TERMS_TYPEHASH,
                t.yesAgent,
                t.noAgent,
                t.collateralToken,
                t.yesStake,
                t.noStake,
                keccak256(bytes(t.statement)),
                t.eventTime,
                t.claimDeadline,
                t.challengeWindow,
                keccak256(bytes(t.primarySource)),
                keccak256(bytes(t.fallbackSource)),
                t.arbiter,
                t.nonce
            )
        );
    }

    /// @notice EIP-712 domain separator.
    function domainSeparator(string memory name, string memory version, uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract
            )
        );
    }

    /// @notice EIP-712 signing digest for a struct hash under a domain.
    function digest(bytes32 domainSep, bytes32 sHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes2(0x1901), domainSep, sHash));
    }
}
