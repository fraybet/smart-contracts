// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentStorage} from "../src/custom/AgentStorage.sol";
import {AgentRegistry} from "../src/custom/AgentRegistry.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract AgentRegistryTest is Test {
    AgentStorage store;
    AgentRegistry reg; // the proxy
    MockUSDC usdc;

    address principal;
    address wallet;
    address signer;
    address wallet2;
    address other;
    address revenue;
    address arbiter;

    uint256 constant FEE = 10e6; // 10 USDC, non-refundable → revenue
    uint256 constant BOND = 100e6; // 100 USDC, refundable / slashable
    uint256 constant ARB_FEE = 20e6; // per-side arbitration fee, from bond

    function setUp() public {
        usdc = new MockUSDC();
        principal = makeAddr("principal");
        wallet = makeAddr("wallet");
        signer = makeAddr("signer");
        wallet2 = makeAddr("wallet2");
        other = makeAddr("other");
        revenue = makeAddr("revenue");
        arbiter = makeAddr("arbiter");

        // Storage (admin = this) + logic behind a UUPS proxy (admin = this).
        store = new AgentStorage(address(usdc), address(this));
        AgentRegistry impl = new AgentRegistry();
        bytes memory initData = abi.encodeCall(
            AgentRegistry.initialize, (address(store), FEE, BOND, ARB_FEE, address(this), revenue, address(0))
        );
        reg = AgentRegistry(address(new ERC1967Proxy(address(impl), initData)));
        store.setController(address(reg));
    }

    // A wallet self-registers (owner == wallet), as the registry now requires.
    function _register(address w) internal {
        usdc.mint(w, FEE + BOND);
        vm.prank(w);
        usdc.approve(address(store), FEE + BOND); // storage is the funds custodian
        vm.prank(w);
        reg.register(w, w, keccak256("policy"), keccak256("meta"));
    }

    function testRegisterPullsFeeAndBond() public {
        _register(wallet);
        assertEq(usdc.balanceOf(address(store)), FEE + BOND, "funds held in storage");
        assertEq(store.accruedFees(), FEE);
        AgentStorage.Profile memory p = reg.agent(wallet);
        assertEq(p.owner, wallet);
        assertEq(p.signer, wallet);
        assertEq(p.bond, BOND);
        assertTrue(p.active);
    }

    function testFundsInvariant() public {
        _register(wallet);
        // held == sum(bonds) + accruedFees
        assertEq(usdc.balanceOf(address(store)), store.bondOf(wallet) + store.accruedFees());
    }

    function testSweepFeesToRevenue() public {
        _register(wallet);
        reg.sweepFees(); // anyone may call; destination is fixed
        assertEq(usdc.balanceOf(revenue), FEE);
        assertEq(store.accruedFees(), 0);
        assertEq(usdc.balanceOf(address(store)), BOND, "bond stays after sweep");
    }

    function testDeactivateRefundsBond() public {
        _register(wallet);
        vm.prank(wallet);
        reg.deactivate(wallet);
        assertFalse(reg.isActive(wallet));
        assertEq(usdc.balanceOf(wallet), BOND, "bond refunded to owner");
    }

    function testSlashMovesBondToRevenue() public {
        _register(wallet);
        reg.slash(wallet); // admin
        assertEq(store.accruedFees(), FEE + BOND);
        assertFalse(reg.isActive(wallet));
        reg.sweepFees();
        assertEq(usdc.balanceOf(revenue), FEE + BOND, "fee + slashed bond swept to revenue");
    }

    function testOnlyAdminSlashes() public {
        _register(wallet);
        vm.prank(other);
        vm.expectRevert(AgentRegistry.NotAdmin.selector);
        reg.slash(wallet);
    }

    function testRegisterRequiresApproval() public {
        usdc.mint(wallet, FEE + BOND); // minted but not approved
        vm.prank(wallet);
        vm.expectRevert();
        reg.register(wallet, signer, bytes32(0), bytes32(0));
    }

    function testCannotRegisterTwice() public {
        _register(wallet);
        usdc.mint(wallet, FEE + BOND);
        vm.prank(wallet);
        usdc.approve(address(store), FEE + BOND);
        vm.prank(wallet);
        vm.expectRevert(AgentRegistry.AlreadyRegistered.selector);
        reg.register(wallet, signer, bytes32(0), bytes32(0));
    }

    function testStorageRejectsZero() public {
        vm.expectRevert(AgentStorage.ZeroAddress.selector);
        new AgentStorage(address(0), address(this));
    }

    function testStorageMutatorsControllerOnly() public {
        vm.prank(other);
        vm.expectRevert(AgentStorage.NotController.selector);
        store.setActive(wallet, false);
    }

    // --- bond reservation / charge / release (the arbitration funding path) ---

    address constant ESCROW = address(0xE5C0);

    function _onboardArbiteredBet() internal {
        _register(wallet);
        _register(wallet2);
        reg.setFactory(address(this)); // act as the authorized factory
        reg.onArbiteredBet(ESCROW, wallet, wallet2); // authorizes ESCROW + reserves both
    }

    function testReserveLocksFreeBond() public {
        _onboardArbiteredBet();
        assertEq(store.reservedOf(wallet), ARB_FEE, "fee reserved");
        assertEq(reg.freeBond(wallet), BOND - ARB_FEE, "free bond reduced");
    }

    function testReserveRevertsWithoutEnoughBond() public {
        _register(wallet);
        reg.setArbitrationFee(BOND + 1); // more than the bond
        reg.setFactory(address(this));
        vm.expectRevert(AgentRegistry.InsufficientBond.selector);
        reg.onArbiteredBet(ESCROW, wallet, address(0));
    }

    function testChargeDrainsBondToArbiter() public {
        _onboardArbiteredBet();
        vm.prank(ESCROW);
        reg.charge(wallet, arbiter, ARB_FEE); // disputed loser pays the full fee
        assertEq(usdc.balanceOf(arbiter), ARB_FEE, "arbiter paid from bond");
        assertEq(store.bondOf(wallet), BOND - ARB_FEE, "bond debited");
        assertEq(store.reservedOf(wallet), 0, "reservation cleared");
    }

    function testReleaseFreesReservationNoCharge() public {
        _onboardArbiteredBet();
        vm.prank(ESCROW);
        reg.release(wallet);
        assertEq(store.reservedOf(wallet), 0, "reservation released");
        assertEq(store.bondOf(wallet), BOND, "bond untouched");
    }

    function testChargeOnlyAuthorizedEscrow() public {
        _onboardArbiteredBet();
        vm.prank(other);
        vm.expectRevert(AgentRegistry.NotEscrow.selector);
        reg.charge(wallet, arbiter, ARB_FEE);
    }

    function testDeactivateBlockedWhileReserved() public {
        _onboardArbiteredBet();
        vm.prank(wallet);
        vm.expectRevert(AgentRegistry.BondReservedOpen.selector);
        reg.deactivate(wallet);
    }

    // --- upgradeability (UUPS): state in storage survives a logic swap ---

    function testUpgradePreservesState() public {
        _register(wallet);
        AgentRegistry newImpl = new AgentRegistry();
        reg.upgradeToAndCall(address(newImpl), ""); // admin authorized
        // Agent + config still intact (storage is separate; config in proxy slot).
        assertTrue(reg.isActive(wallet));
        assertEq(reg.agent(wallet).bond, BOND);
        assertEq(reg.arbitrationFee(), ARB_FEE);
    }

    function testUpgradeOnlyAdmin() public {
        AgentRegistry newImpl = new AgentRegistry();
        vm.prank(other);
        vm.expectRevert(AgentRegistry.NotAdmin.selector);
        reg.upgradeToAndCall(address(newImpl), "");
    }
}
