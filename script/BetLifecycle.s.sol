// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {BetEscrow} from "../src/custom/BetEscrow.sol";
import {BetEscrowFactory} from "../src/custom/BetEscrowFactory.sol";
import {StablecoinAllowlist} from "../src/custom/StablecoinAllowlist.sol";
import {EmergencyPauseController} from "../src/custom/EmergencyPauseController.sol";

/// @notice Narrated end-to-end bilateral bet on a local EVM — deploy, create,
///         fund both sides, claim YES, finalize, settle. Run:
///
///     forge script script/BetLifecycle.s.sol -vvv
///
///         It runs in simulation (no node needed) and prints USDC balances at
///         each step so you can watch the money move and the invariant hold
///         (escrow ends at 0; winner takes the pot).
contract BetLifecycle is Script {
    function run() external {
        // --- deploy the protocol controls + factory + a mock USDC ---
        address owner = vm.addr(42);
        MockUSDC usdc = new MockUSDC();
        EmergencyPauseController pause = new EmergencyPauseController(owner);
        StablecoinAllowlist allowlist = new StablecoinAllowlist(owner);
        vm.prank(owner);
        allowlist.allow(address(usdc));
        BetEscrowFactory factory = new BetEscrowFactory(address(allowlist), address(pause), owner, 0, 0, address(0));

        address alice = vm.addr(1); // YES
        address bob = vm.addr(2); // NO
        address arbiter = vm.addr(3);
        uint256 stake = 500e6; // 500 USDC each
        usdc.mint(alice, stake);
        usdc.mint(bob, stake);

        console2.log("== Deployed ==");
        console2.log("USDC    ", address(usdc));
        console2.log("factory ", address(factory));

        // --- create the bet ---
        BetEscrow.Terms memory terms = BetEscrow.Terms({
            yesAgent: alice,
            noAgent: bob,
            arbiter: arbiter,
            token: address(usdc),
            yesStake: stake,
            noStake: stake,
            claimDeadline: uint64(block.timestamp + 1 days),
            challengeWindow: 1 hours,
            termsHash: keccak256("ETH above 5000 on 2027-01-01"),
            visibility: 1
        });
        BetEscrow escrow = BetEscrow(factory.create(terms));
        console2.log("== Bet created ==");
        console2.log("escrow  ", address(escrow));
        console2.log("status (Funding=0):", uint256(escrow.status()));

        // --- both sides fund ---
        vm.prank(alice);
        usdc.approve(address(escrow), stake);
        vm.prank(alice);
        escrow.fund();
        vm.prank(bob);
        usdc.approve(address(escrow), stake);
        vm.prank(bob);
        escrow.fund();
        console2.log("== Both funded ==");
        console2.log("status (Live=1):    ", uint256(escrow.status()));
        console2.log("escrow USDC balance:", usdc.balanceOf(address(escrow)));

        // --- alice claims YES, challenge window passes, finalize ---
        vm.prank(alice);
        escrow.claim(BetEscrow.Outcome.Yes, keccak256("evidence: ETH closed at 5120"));
        console2.log("== YES claimed; waiting out the challenge window ==");

        vm.warp(block.timestamp + 1 hours + 1);
        escrow.finalize();

        console2.log("== Settled ==");
        console2.log("final outcome (Yes=1):", uint256(escrow.finalOutcome()));
        console2.log("alice (YES) USDC:     ", usdc.balanceOf(alice));
        console2.log("bob   (NO)  USDC:     ", usdc.balanceOf(bob));
        console2.log("escrow USDC (==0):    ", usdc.balanceOf(address(escrow)));
    }
}
