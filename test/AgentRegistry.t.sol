// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract AgentRegistryTest is Test {
    AgentRegistry reg;
    MockUSDC usdc;

    address principal;
    address wallet;
    address signer;
    address other;
    address revenue;

    uint256 constant FEE = 10e6; // 10 USDC, non-refundable → revenue
    uint256 constant BOND = 100e6; // 100 USDC, refundable / slashable

    function setUp() public {
        usdc = new MockUSDC();
        principal = makeAddr("principal");
        wallet = makeAddr("wallet");
        signer = makeAddr("signer");
        other = makeAddr("other");
        revenue = makeAddr("revenue");
        // admin = this test contract.
        reg = new AgentRegistry(address(usdc), FEE, BOND, address(this), revenue);
    }

    function _register() internal {
        usdc.mint(principal, FEE + BOND);
        vm.prank(principal);
        usdc.approve(address(reg), FEE + BOND);
        vm.prank(principal);
        reg.register(wallet, signer, keccak256("policy"), keccak256("meta"));
    }

    function testRegisterPullsFeeAndBond() public {
        _register();
        assertEq(usdc.balanceOf(address(reg)), FEE + BOND);
        assertEq(reg.accruedFees(), FEE);
        AgentRegistry.AgentProfile memory p = reg.agent(wallet);
        assertEq(p.owner, principal);
        assertEq(p.signer, signer);
        assertEq(p.bond, BOND);
        assertTrue(p.active);
        assertEq(reg.signerOf(wallet), signer);
    }

    function testFundsInvariant() public {
        _register();
        // held == sum(active bonds) + accruedFees
        assertEq(usdc.balanceOf(address(reg)), reg.agent(wallet).bond + reg.accruedFees());
    }

    function testSweepFeesToRevenue() public {
        _register();
        reg.sweepFees(); // anyone may call; destination is fixed
        assertEq(usdc.balanceOf(revenue), FEE);
        assertEq(reg.accruedFees(), 0);
        assertEq(usdc.balanceOf(address(reg)), BOND, "bond stays after sweep");
    }

    function testDeactivateRefundsBond() public {
        _register();
        vm.prank(principal);
        reg.deactivate(wallet);
        assertFalse(reg.isActive(wallet));
        assertEq(usdc.balanceOf(principal), BOND, "bond refunded to owner");
    }

    function testSlashMovesBondToRevenue() public {
        _register();
        reg.slash(wallet); // admin
        assertEq(reg.accruedFees(), FEE + BOND);
        assertFalse(reg.isActive(wallet));
        reg.sweepFees();
        assertEq(usdc.balanceOf(revenue), FEE + BOND, "fee + slashed bond swept to revenue");
    }

    function testOnlyAdminSlashes() public {
        _register();
        vm.prank(other);
        vm.expectRevert(AgentRegistry.NotAdmin.selector);
        reg.slash(wallet);
    }

    function testSetRevenueWalletAdminOnly() public {
        vm.prank(other);
        vm.expectRevert(AgentRegistry.NotAdmin.selector);
        reg.setRevenueWallet(other);

        reg.setRevenueWallet(other); // admin
        assertEq(reg.revenueWallet(), other);
    }

    function testRegisterRequiresApproval() public {
        usdc.mint(principal, FEE + BOND); // minted but not approved
        vm.prank(principal);
        vm.expectRevert();
        reg.register(wallet, signer, bytes32(0), bytes32(0));
    }

    function testCannotRegisterTwice() public {
        _register();
        usdc.mint(principal, FEE + BOND);
        vm.prank(principal);
        usdc.approve(address(reg), FEE + BOND);
        vm.prank(principal);
        vm.expectRevert(AgentRegistry.AlreadyRegistered.selector);
        reg.register(wallet, signer, bytes32(0), bytes32(0));
    }

    function testConstructorRejectsZero() public {
        vm.expectRevert(AgentRegistry.ZeroAddress.selector);
        new AgentRegistry(address(0), FEE, BOND, address(this), revenue);
    }
}
