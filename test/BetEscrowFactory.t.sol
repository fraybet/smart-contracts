// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BetEscrow} from "../src/custom/BetEscrow.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {StablecoinAllowlist} from "../src/custom/StablecoinAllowlist.sol";
import {EmergencyPauseController} from "../src/custom/EmergencyPauseController.sol";
import {EIP712Terms} from "../src/custom/EIP712Terms.sol";
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
        factory = new BetEscrowFactory(address(0), address(0), address(0xBEEF), 0, address(0)); // controls disabled
        usdc = new MockUSDC();
        yes = makeAddr("yes");
        no = makeAddr("no");
        arb = makeAddr("arb");
    }

    function testRejectsWhenPaused() public {
        EmergencyPauseController p = new EmergencyPauseController(address(this));
        BetEscrowFactory f = new BetEscrowFactory(address(0), address(p), address(0xBEEF), 0, address(0));
        p.pause();
        vm.expectRevert(BetEscrowFactory.ProtocolPaused.selector);
        f.create(_terms());
    }

    function testRejectsNonAllowlistedToken() public {
        StablecoinAllowlist a = new StablecoinAllowlist(address(this)); // usdc not allowed
        BetEscrowFactory f = new BetEscrowFactory(address(a), address(0), address(0xBEEF), 0, address(0));
        vm.expectRevert(BetEscrowFactory.TokenNotAllowed.selector);
        f.create(_terms());
    }

    function testAllowlistedTokenCreates() public {
        StablecoinAllowlist a = new StablecoinAllowlist(address(this));
        a.allow(address(usdc));
        BetEscrowFactory f = new BetEscrowFactory(address(a), address(0), address(0xBEEF), 0, address(0));
        assertTrue(f.create(_terms()) != address(0));
    }

    function _terms() internal view returns (BetEscrow.Terms memory) {
        // Non-arbitered by default (so factory tests don't all need a bond
        // registry); arbitered-path tests set the arbiter + a registry explicitly.
        return BetEscrow.Terms({
            yesAgent: yes,
            noAgent: no,
            arbiter: address(0),
            token: address(usdc),
            yesStake: 500e6,
            noStake: 500e6,
            eventTime: uint64(block.timestamp + 12 hours),
            claimDeadline: uint64(block.timestamp + 1 days),
            challengeWindow: 1 hours,
            nonce: 0,
            statement: "Will it rain in NYC on 2026-07-01?",
            primarySource: "weather.gov",
            fallbackSource: "",
            visibility: 1
        });
    }

    // The termsHash the escrow derives on-chain from _terms().
    function _expectedHash() internal view returns (bytes32) {
        BetEscrow.Terms memory t = _terms();
        return EIP712Terms.structHash(
            EIP712Terms.BetTerms({
                yesAgent: t.yesAgent,
                noAgent: t.noAgent,
                collateralToken: t.token,
                yesStake: t.yesStake,
                noStake: t.noStake,
                statement: t.statement,
                eventTime: t.eventTime,
                claimDeadline: t.claimDeadline,
                challengeWindow: t.challengeWindow,
                primarySource: t.primarySource,
                fallbackSource: t.fallbackSource,
                arbiter: t.arbiter,
                nonce: t.nonce
            })
        );
    }

    function testCreateEmitsAndDeploys() public {
        // Escrow address isn't known ahead of time → skip matching topic1.
        vm.expectEmit(false, true, true, true);
        emit BetCreated(address(0), yes, no, _expectedHash(), 1);
        address escrow = factory.create(_terms());

        BetEscrow e = BetEscrow(escrow);
        assertEq(e.yesAgent(), yes);
        assertEq(e.noAgent(), no);
        assertEq(e.termsHash(), _expectedHash());
        assertEq(e.statement(), "Will it rain in NYC on 2026-07-01?");
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
        return new BetEscrowFactory(address(0), address(0), address(0xBEEF), 0, address(r));
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
        t.visibility = 0; // private
        t.arbiter = arb; // ...but arbitered → gated
        vm.expectRevert(BetEscrowFactory.NotRegistered.selector);
        f.create(t);
    }

    function testArbiteredBetRequiresBothAgentsRegistered() public {
        MockRegistry r = new MockRegistry();
        r.setActive(address(this), true); // creator registered
        BetEscrowFactory f = _gatedFactory(r);
        BetEscrow.Terms memory t = _terms();
        t.arbiter = arb; // both yes and no must be active too
        vm.expectRevert(BetEscrowFactory.NotRegistered.selector);
        f.create(t); // yes/no not active → revert
    }

    function testArbiteredBetOnboardsEscrow() public {
        MockRegistry r = new MockRegistry();
        r.setActive(address(this), true);
        r.setActive(yes, true);
        r.setActive(no, true);
        BetEscrowFactory f = _gatedFactory(r);
        BetEscrow.Terms memory t = _terms();
        t.arbiter = arb;
        address escrow = f.create(t);
        assertTrue(escrow != address(0));
        // The factory onboarded the escrow and reserved each participant's bond.
        assertTrue(r.onboarded(escrow), "escrow authorized at the registry");
        assertEq(r.reservedOf(yes), 1, "yes bond reserved");
        assertEq(r.reservedOf(no), 1, "no bond reserved");
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

/// @dev Minimal AgentRegistry stand-in for gating + onboarding tests.
contract MockRegistry {
    mapping(address => bool) public active;
    mapping(address => bool) public onboarded; // escrows authorized via onArbiteredBet
    mapping(address => uint256) public reservedOf;

    function setActive(address a, bool v) external {
        active[a] = v;
    }

    function isActive(address a) external view returns (bool) {
        return active[a];
    }

    function onArbiteredBet(address escrow, address yesAgent, address noAgent) external {
        onboarded[escrow] = true;
        if (yesAgent != address(0)) reservedOf[yesAgent] += 1;
        if (noAgent != address(0)) reservedOf[noAgent] += 1;
    }
}
