// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmergencyPauseController} from "../src/custom/EmergencyPauseController.sol";
import {StablecoinAllowlist} from "../src/custom/StablecoinAllowlist.sol";

contract EmergencyPauseControllerTest is Test {
    EmergencyPauseController pause;
    address owner;
    address other;

    function setUp() public {
        owner = makeAddr("owner");
        other = makeAddr("other");
        pause = new EmergencyPauseController(owner);
    }

    function testPauseUnpause() public {
        assertFalse(pause.paused());
        vm.prank(owner);
        pause.pause();
        assertTrue(pause.paused());
        vm.prank(owner);
        pause.unpause();
        assertFalse(pause.paused());
    }

    function testOnlyOwnerPauses() public {
        vm.prank(other);
        vm.expectRevert(EmergencyPauseController.NotOwner.selector);
        pause.pause();
    }

    function testTransferOwnership() public {
        vm.prank(owner);
        pause.transferOwnership(other);
        assertEq(pause.owner(), other);
        vm.prank(other);
        pause.pause();
        assertTrue(pause.paused());
    }

    function testConstructorRejectsZero() public {
        vm.expectRevert(EmergencyPauseController.ZeroAddress.selector);
        new EmergencyPauseController(address(0));
    }
}

contract StablecoinAllowlistTest is Test {
    StablecoinAllowlist list;
    address owner;
    address other;
    address usdc;

    function setUp() public {
        owner = makeAddr("owner");
        other = makeAddr("other");
        usdc = makeAddr("usdc");
        list = new StablecoinAllowlist(owner);
    }

    function testAllowDisallow() public {
        assertFalse(list.isAllowed(usdc));
        vm.prank(owner);
        list.allow(usdc);
        assertTrue(list.isAllowed(usdc));
        vm.prank(owner);
        list.disallow(usdc);
        assertFalse(list.isAllowed(usdc));
    }

    function testOnlyOwnerAllows() public {
        vm.prank(other);
        vm.expectRevert(StablecoinAllowlist.NotOwner.selector);
        list.allow(usdc);
    }

    function testRejectsZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(StablecoinAllowlist.ZeroAddress.selector);
        list.allow(address(0));
    }
}
