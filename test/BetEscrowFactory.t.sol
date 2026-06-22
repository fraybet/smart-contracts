// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BetEscrow} from "../src/custom/BetEscrow.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {StablecoinAllowlist} from "../src/custom/StablecoinAllowlist.sol";
import {EmergencyPauseController} from "../src/custom/EmergencyPauseController.sol";
import {MockUSDC} from "./BetEscrow.t.sol";

contract BetEscrowFactoryTest is Test {
    BetEscrowFactory factory;
    MockUSDC usdc;
    address yes;
    address no;
    address arb;

    event BetCreated(
        address indexed escrow, address indexed yesAgent, address indexed noAgent, bytes32 termsHash, uint8 visibility
    );

    function setUp() public {
        factory = new BetEscrowFactory(address(0), address(0), address(0xBEEF), 0, 0, address(0)); // controls disabled
        usdc = new MockUSDC();
        yes = makeAddr("yes");
        no = makeAddr("no");
        arb = makeAddr("arb");
    }

    function testRejectsWhenPaused() public {
        EmergencyPauseController p = new EmergencyPauseController(address(this));
        BetEscrowFactory f = new BetEscrowFactory(address(0), address(p), address(0xBEEF), 0, 0, address(0));
        p.pause();
        vm.expectRevert(BetEscrowFactory.ProtocolPaused.selector);
        f.create(_terms());
    }

    function testRejectsNonAllowlistedToken() public {
        StablecoinAllowlist a = new StablecoinAllowlist(address(this)); // usdc not allowed
        BetEscrowFactory f = new BetEscrowFactory(address(a), address(0), address(0xBEEF), 0, 0, address(0));
        vm.expectRevert(BetEscrowFactory.TokenNotAllowed.selector);
        f.create(_terms());
    }

    function testAllowlistedTokenCreates() public {
        StablecoinAllowlist a = new StablecoinAllowlist(address(this));
        a.allow(address(usdc));
        BetEscrowFactory f = new BetEscrowFactory(address(a), address(0), address(0xBEEF), 0, 0, address(0));
        assertTrue(f.create(_terms()) != address(0));
    }

    function _terms() internal view returns (BetEscrow.Terms memory) {
        return BetEscrow.Terms({
            yesAgent: yes,
            noAgent: no,
            arbiter: arb,
            token: address(usdc),
            yesStake: 500e6,
            noStake: 500e6,
            claimDeadline: uint64(block.timestamp + 1 days),
            challengeWindow: 1 hours,
            termsHash: keccak256("t"),
            visibility: 1
        });
    }

    function testCreateEmitsAndDeploys() public {
        // Escrow address isn't known ahead of time → skip matching topic1.
        vm.expectEmit(false, true, true, true);
        emit BetCreated(address(0), yes, no, keccak256("t"), 1);
        address escrow = factory.create(_terms());

        BetEscrow e = BetEscrow(escrow);
        assertEq(e.yesAgent(), yes);
        assertEq(e.noAgent(), no);
        assertEq(e.termsHash(), keccak256("t"));
        assertEq(e.visibility(), 1);
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Funding));
    }

    function testCreatedEscrowFundsToLive() public {
        BetEscrow e = BetEscrow(factory.create(_terms()));
        usdc.mint(yes, 500e6);
        usdc.mint(no, 500e6);
        vm.prank(yes);
        usdc.approve(address(e), 500e6);
        vm.prank(no);
        usdc.approve(address(e), 500e6);
        vm.prank(yes);
        e.fund();
        vm.prank(no);
        e.fund();
        assertEq(uint8(e.status()), uint8(BetEscrow.Status.Live));
    }

    function testBadTermsRevertThroughFactory() public {
        BetEscrow.Terms memory t = _terms();
        t.noAgent = yes; // same agents → BetEscrow rejects
        vm.expectRevert(BetEscrow.BadTerms.selector);
        factory.create(t);
    }

    // --- registration gating (public / arbitered require an active agent) ---

    function _gatedFactory(MockRegistry r) internal returns (BetEscrowFactory) {
        return new BetEscrowFactory(address(0), address(0), address(0xBEEF), 0, 0, address(r));
    }

    function testPublicBetRequiresRegistration() public {
        MockRegistry r = new MockRegistry();
        BetEscrowFactory f = _gatedFactory(r); // caller (this) not active
        vm.expectRevert(BetEscrowFactory.NotRegistered.selector);
        f.create(_terms()); // visibility 1
    }

    function testRegisteredAgentCreatesPublic() public {
        MockRegistry r = new MockRegistry();
        r.setActive(address(this), true);
        BetEscrowFactory f = _gatedFactory(r);
        assertTrue(f.create(_terms()) != address(0));
    }

    function testArbiteredPrivateBetRequiresRegistration() public {
        MockRegistry r = new MockRegistry();
        BetEscrowFactory f = _gatedFactory(r);
        BetEscrow.Terms memory t = _terms();
        t.visibility = 0; // private, but arbiter still set → gated
        vm.expectRevert(BetEscrowFactory.NotRegistered.selector);
        f.create(t);
    }

    function testPrivateUnarbiteredIsPermissionless() public {
        MockRegistry r = new MockRegistry();
        BetEscrowFactory f = _gatedFactory(r);
        BetEscrow.Terms memory t = _terms();
        t.visibility = 0; // private
        t.arbiter = address(0); // no arbiter
        assertTrue(f.create(t) != address(0)); // no registration needed
    }
}

/// @dev Minimal AgentRegistry stand-in for gating tests.
contract MockRegistry {
    mapping(address => bool) public active;

    function setActive(address a, bool v) external {
        active[a] = v;
    }

    function isActive(address a) external view returns (bool) {
        return active[a];
    }
}
