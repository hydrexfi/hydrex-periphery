// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexBadges} from "../../contracts/basedrop/HydrexBadges.sol";

contract HydrexBadgesTest is Test {
    HydrexBadges public badges;

    address public owner;
    address public minter;
    address public user1;
    address public user2;

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.startPrank(owner);
        badges = new HydrexBadges();
        badges.grantRole(badges.MINTER_ROLE(), minter);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertTrue(badges.hasRole(badges.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(badges.hasRole(badges.MINTER_ROLE(), minter));
        assertTrue(badges.limitToSingleBadge());
    }

    function testMintSingleBadge() public {
        vm.prank(minter);
        badges.mint(user1, 1, 1, "");

        assertEq(badges.balanceOf(user1, 1), 1);
    }

    function test_RevertWhen_MintingMultipleSameBadge() public {
        vm.prank(minter);
        badges.mint(user1, 1, 1, "");

        vm.prank(minter);
        vm.expectRevert("Badge limit exceeded: only one badge per account allowed");
        badges.mint(user1, 1, 1, "");
    }

    function test_RevertWhen_MintingAmountGreaterThanOne() public {
        vm.prank(minter);
        vm.expectRevert("Badge limit exceeded: only one badge per account allowed");
        badges.mint(user1, 1, 2, "");
    }

    function testMintAfterDisablingLimit() public {
        vm.prank(owner);
        badges.setLimitToSingleBadge(false);

        vm.prank(minter);
        badges.mint(user1, 1, 5, "");

        assertEq(badges.balanceOf(user1, 1), 5);
    }

    function testMintBatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(minter);
        badges.mintBatch(user1, ids, amounts, "");

        assertEq(badges.balanceOf(user1, 1), 1);
        assertEq(badges.balanceOf(user1, 2), 1);
    }

    function test_RevertWhen_BatchMintExceedsLimit() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(minter);
        vm.expectRevert("Badge limit exceeded: only one badge per account allowed");
        badges.mintBatch(user1, ids, amounts, "");
    }

    function test_RevertWhen_Transfer() public {
        vm.prank(minter);
        badges.mint(user1, 1, 1, "");

        vm.prank(user1);
        vm.expectRevert("HydrexBadges are non-transferable");
        badges.safeTransferFrom(user1, user2, 1, 1, "");
    }

    function test_RevertWhen_NonMinterMints() public {
        vm.prank(user1);
        vm.expectRevert();
        badges.mint(user1, 1, 1, "");
    }

    function test_RevertWhen_NonAdminSetsLimit() public {
        vm.prank(user1);
        vm.expectRevert();
        badges.setLimitToSingleBadge(false);
    }

    function testBurn() public {
        vm.prank(minter);
        badges.mint(user1, 1, 1, "");

        vm.prank(user1);
        badges.burn(user1, 1, 1);

        assertEq(badges.balanceOf(user1, 1), 0);
    }
} 