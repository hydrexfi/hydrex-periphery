// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Hydropoints} from "../../contracts/basedrop/Hydropoints.sol";

contract HydropointsTest is Test {
    Hydropoints public hydropoints;

    address public owner;
    address public minter;
    address public redeemer;
    address public user1;
    address public user2;

    function setUp() public {
        // Create addresses
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        redeemer = makeAddr("redeemer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy contract with owner as default admin
        vm.prank(owner);
        hydropoints = new Hydropoints(owner);

        // Set up minter and redeemer roles
        vm.startPrank(owner);
        hydropoints.grantRole(hydropoints.MINTER_ROLE(), minter);
        hydropoints.grantRole(hydropoints.REDEEMER_ROLE(), redeemer);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(hydropoints.name(), "Hydropoints");
        assertEq(hydropoints.symbol(), "HYDRO");
        assertEq(hydropoints.decimals(), 18);
        assertEq(hydropoints.totalSupply(), 0);
        assertTrue(hydropoints.hasRole(hydropoints.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(hydropoints.hasRole(hydropoints.MINTER_ROLE(), minter));
        assertTrue(hydropoints.hasRole(hydropoints.REDEEMER_ROLE(), redeemer));
    }

    function testMinting() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.prank(minter);
        hydropoints.mint(user1, amount);

        assertEq(hydropoints.balanceOf(user1), amount);
        assertEq(hydropoints.totalSupply(), amount);
    }

    function test_RevertWhen_NonMinterMints() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.prank(user1);
        vm.expectRevert();
        hydropoints.mint(user1, amount);
    }

    function testRedemption() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint tokens first
        vm.prank(minter);
        hydropoints.mint(user1, amount);

        // Redeem tokens
        vm.prank(redeemer);
        hydropoints.redeem(user1, amount / 2);

        assertEq(hydropoints.balanceOf(user1), amount / 2);
        assertEq(hydropoints.totalSupply(), amount / 2);
    }

    function test_RevertWhen_NonRedeemerRedeems() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint tokens first
        vm.prank(minter);
        hydropoints.mint(user1, amount);

        vm.prank(user1);
        vm.expectRevert();
        hydropoints.redeem(user1, amount);
    }

    function test_RevertWhen_Transfer() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint tokens first
        vm.prank(minter);
        hydropoints.mint(user1, amount);

        vm.prank(user1);
        vm.expectRevert("Hydropoints are non-transferable");
        hydropoints.transfer(user2, 100);
    }

    function test_RevertWhen_TransferFrom() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint tokens first
        vm.prank(minter);
        hydropoints.mint(user1, amount);

        // Need to approve first
        vm.prank(user1);
        hydropoints.approve(user2, 100);

        vm.prank(user2);
        vm.expectRevert("Hydropoints are non-transferable");
        hydropoints.transferFrom(user1, user2, 100);
    }

    function test_RevertWhen_Approve() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint tokens first
        vm.prank(minter);
        hydropoints.mint(user1, amount);

        // Approve should work (it doesn't trigger _update)
        vm.prank(user1);
        hydropoints.approve(user2, 100);

        // But transferFrom should fail
        vm.prank(user2);
        vm.expectRevert("Hydropoints are non-transferable");
        hydropoints.transferFrom(user1, user2, 100);
    }

    function testBurnFunction() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint tokens first
        vm.prank(minter);
        hydropoints.mint(user1, amount);

        // User can burn their own tokens
        vm.prank(user1);
        hydropoints.burn(amount / 2);

        assertEq(hydropoints.balanceOf(user1), amount / 2);
        assertEq(hydropoints.totalSupply(), amount / 2);
    }
}
