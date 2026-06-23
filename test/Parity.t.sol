// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {EIP712Terms} from "../src/custom/EIP712Terms.sol";

/// @notice Solidity side of Go<->Solidity EIP-712 parity. Reads the SAME shared
///         vectors that internal/core TestParity asserts in Go, and checks that
///         this library reproduces the frozen type hash, domain separator, and
///         per-vector terms hash + digest. If Go and Solidity hashing ever
///         diverge, one of the two parity tests fails.
///
///         Requires fs read permission for ../internal/core/testdata (see
///         foundry.toml [profile.default] fs_permissions).
contract ParityTest is Test {
    string constant VECTORS = "test/testdata/parity_vectors.json";

    function _json() internal view returns (string memory) {
        return vm.readFile(VECTORS);
    }

    function testTypeHashAndDomain() public view {
        string memory json = _json();

        assertEq(
            EIP712Terms.BET_TERMS_TYPEHASH,
            vm.parseJsonBytes32(json, ".betTermsTypeHash"),
            "BET_TERMS_TYPEHASH diverged from Go"
        );

        string memory name = vm.parseJsonString(json, ".domain.name");
        string memory version = vm.parseJsonString(json, ".domain.version");
        uint256 chainId = vm.parseJsonUint(json, ".domain.chainId");
        address verifying = vm.parseJsonAddress(json, ".domain.verifyingContract");

        assertEq(
            EIP712Terms.domainSeparator(name, version, chainId, verifying),
            vm.parseJsonBytes32(json, ".domainSeparator"),
            "domainSeparator diverged from Go"
        );
    }

    function testVector0() public view {
        _assertVector(0);
    }

    function testVector1() public view {
        _assertVector(1);
    }

    function _assertVector(uint256 i) internal view {
        string memory json = _json();
        string memory base = string.concat(".vectors[", vm.toString(i), "]");

        EIP712Terms.BetTerms memory t = EIP712Terms.BetTerms({
            yesAgent: vm.parseJsonAddress(json, string.concat(base, ".terms.yesAgent")),
            noAgent: vm.parseJsonAddress(json, string.concat(base, ".terms.noAgent")),
            collateralToken: vm.parseJsonAddress(json, string.concat(base, ".terms.collateralToken")),
            yesStake: vm.parseJsonUint(json, string.concat(base, ".terms.yesStake")),
            noStake: vm.parseJsonUint(json, string.concat(base, ".terms.noStake")),
            statement: vm.parseJsonString(json, string.concat(base, ".terms.statement")),
            eventTime: vm.parseJsonUint(json, string.concat(base, ".terms.eventTime")),
            claimDeadline: vm.parseJsonUint(json, string.concat(base, ".terms.claimDeadline")),
            challengeWindow: vm.parseJsonUint(json, string.concat(base, ".terms.challengeWindow")),
            primarySource: vm.parseJsonString(json, string.concat(base, ".terms.primarySource")),
            fallbackSource: vm.parseJsonString(json, string.concat(base, ".terms.fallbackSource")),
            arbiter: vm.parseJsonAddress(json, string.concat(base, ".terms.arbiter")),
            nonce: vm.parseJsonUint(json, string.concat(base, ".terms.nonce")),
            visibility: uint8(vm.parseJsonUint(json, string.concat(base, ".terms.visibility")))
        });

        bytes32 wantTerms = vm.parseJsonBytes32(json, string.concat(base, ".termsHash"));
        bytes32 wantDigest = vm.parseJsonBytes32(json, string.concat(base, ".digest"));

        bytes32 gotTerms = EIP712Terms.structHash(t);
        assertEq(gotTerms, wantTerms, "termsHash diverged from Go");

        string memory name = vm.parseJsonString(json, ".domain.name");
        string memory version = vm.parseJsonString(json, ".domain.version");
        uint256 chainId = vm.parseJsonUint(json, ".domain.chainId");
        address verifying = vm.parseJsonAddress(json, ".domain.verifyingContract");
        bytes32 sep = EIP712Terms.domainSeparator(name, version, chainId, verifying);

        assertEq(EIP712Terms.digest(sep, gotTerms), wantDigest, "digest diverged from Go");
    }
}
