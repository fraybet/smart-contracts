// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Side, SignatureType, ORDER_TYPEHASH} from "../src/markets/exchange/libraries/OrderStructs.sol";

/// @notice Cross-language EIP-712 parity for the order hash. The golden values
///         are produced by the Go signer (cli/core: TestOrderHashGolden) and
///         asserted here against the on-chain exchange. If either side changes
///         the encoding, the Go signer and the exchange will disagree on the
///         digest and the operator's matched orders would fail signature
///         recovery — so this test guards the order-book money path.
contract OrderParityTest is Test {
    // Goldens from cli/core/order_test.go (the shared parity vector).
    bytes32 constant GO_ORDER_TYPEHASH = 0xa852566c4e14d00869b6db0220888a9090a13eccdaea03713ff0a3d27bf9767c;
    bytes32 constant GO_DOMAIN_SEP = 0xd4b80587b4c0c3c4c9b785853d5c2db5b05e5fe068b7763ae26cca8292aac2b1;
    bytes32 constant GO_STRUCT_HASH = 0xaf94d62f63e26b58df9631d8938b94ee7d4e1afd0cb887dbcdaf690f2df9a747;
    bytes32 constant GO_DIGEST = 0xe4ffebc92fe466601cc9f65303301e9f98e200df6026808c29dcdd92c6529a93;

    // The Go vector's domain: name "Fray CTF Exchange", version "1", chainId 8453,
    // verifyingContract = the deployed CTFExchange address used in the Go test.
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    address constant VERIFYING_CONTRACT = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;

    function testOrderTypehashParity() public pure {
        // The exchange's ORDER_TYPEHASH must equal the Go signer's. This is the
        // field-set/ordering contract between the two implementations.
        assertEq(ORDER_TYPEHASH, GO_ORDER_TYPEHASH, "ORDER_TYPEHASH != Go OrderTypeHash");
    }

    function testOrderHashPipelineParity() public pure {
        // structHash = keccak256(abi.encode(ORDER_TYPEHASH, ...fields)) — same
        // field order and encoding the exchange's Hashing mixin uses. side and
        // signatureType encode as uint8 (left-padded to 32 bytes), matching the
        // Go encodeUint64(uint64(...)).
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                uint256(42), // salt
                address(0x1111111111111111111111111111111111111111), // maker
                address(0x1111111111111111111111111111111111111111), // signer
                address(0), // taker (public)
                uint256(97847902842828329890918613721842941496657289062292574132461597279393424722477), // tokenId
                uint256(50_000_000), // makerAmount
                uint256(100_000_000), // takerAmount
                uint256(0), // expiration
                uint256(0), // nonce
                uint256(0), // feeRateBps
                uint8(Side.BUY),
                uint8(SignatureType.EOA)
            )
        );
        assertEq(structHash, GO_STRUCT_HASH, "structHash != Go");

        // Standard (non-salt) EIP712 domain separator — what OpenZeppelin's
        // EIP712 (and therefore the exchange) produces.
        bytes32 domainSep = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Fray CTF Exchange")),
                keccak256(bytes("1")),
                uint256(8453),
                VERIFYING_CONTRACT
            )
        );
        assertEq(domainSep, GO_DOMAIN_SEP, "domainSeparator != Go");

        // digest = keccak256(0x1901 || domainSeparator || structHash).
        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), domainSep, structHash));
        assertEq(digest, GO_DIGEST, "digest != Go");
    }
}
