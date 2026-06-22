// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArbiterRegistry} from "../src/custom/ArbiterRegistry.sol";

contract ArbiterRegistryTest is Test {
    ArbiterRegistry reg;
    address arb;
    address other;

    function setUp() public {
        reg = new ArbiterRegistry();
        arb = makeAddr("arb");
        other = makeAddr("other");
    }

    function _register() internal {
        // 0.20% validation, 0.75% dispute, min 1 USDC, max dispute 100 USDC, bond 10 USDC.
        vm.prank(arb);
        reg.register(keccak256("meta"), 20, 75, 1e6, 100e6, 10e6);
    }

    function testRegisterAndQuote() public {
        _register();
        assertTrue(reg.isActive(arb));
        (uint256 v, uint256 d) = reg.quote(arb, 1000e6); // 1000 USDC pot
        assertEq(v, 2e6, "validation = 0.2% of 1000 = 2 USDC");
        assertEq(d, 7.5e6, "dispute = 0.75% of 1000 = 7.5 USDC");
    }

    function testQuoteAppliesMinimumFee() public {
        _register();
        (uint256 v,) = reg.quote(arb, 100e6); // 0.2% = 0.2 USDC < 1 USDC min
        assertEq(v, 1e6, "clamped to minimum fee");
    }

    function testQuoteCapsDisputeFee() public {
        _register();
        (, uint256 d) = reg.quote(arb, 1_000_000e6); // 0.75% = 7500 USDC, capped to 100
        assertEq(d, 100e6, "clamped to max dispute fee");
    }

    function testCannotRegisterTwice() public {
        _register();
        vm.prank(arb);
        vm.expectRevert(ArbiterRegistry.AlreadyRegistered.selector);
        reg.register(bytes32(0), 1, 1, 0, 0, 0);
    }

    function testBadFeeConfigReverts() public {
        vm.prank(arb);
        vm.expectRevert(ArbiterRegistry.BadFeeConfig.selector);
        reg.register(bytes32(0), 10_001, 1, 0, 0, 0); // > 100%
    }

    function testUpdateRequiresRegistration() public {
        vm.prank(other);
        vm.expectRevert(ArbiterRegistry.NotRegistered.selector);
        reg.update(bytes32(0), 1, 1, 0, 0, 0);
    }

    function testDeactivate() public {
        _register();
        vm.prank(arb);
        reg.deactivate();
        assertFalse(reg.isActive(arb));
    }
}
