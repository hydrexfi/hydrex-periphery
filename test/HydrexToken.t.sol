// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {HydrexToken} from "../contracts/token/HydrexToken.sol";

contract HydrexTokenTest is Test {
    HydrexToken public token;

    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.prank(owner);
        token = new HydrexToken("Hydrex", "HYDX", owner);
    }

    function testInitialState() public view {
        assertEq(token.name(), "Hydrex");
        assertEq(token.symbol(), "HYDX");
        assertEq(token.decimals(), 18);
        assertEq(token.owner(), owner);
        assertEq(token.totalSupply(), 0);
        assertFalse(token.initialMinted());
    }

    function testInitialMint() public {
        vm.prank(owner);
        token.initialMint(user1);

        assertEq(token.balanceOf(user1), 500 * 1e6 * 1e18);
        assertEq(token.totalSupply(), 500 * 1e6 * 1e18);
        assertTrue(token.initialMinted());
    }

    function testInitialMintOnlyOnce() public {
        vm.startPrank(owner);
        token.initialMint(user1);
        
        vm.expectRevert("Already executed initial mint");
        token.initialMint(user2);
        vm.stopPrank();
    }

    function testInitialMintOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.initialMint(user1);
    }

    function testMint() public {
        vm.prank(owner);
        token.mint(user1, 1000 * 1e18);

        assertEq(token.balanceOf(user1), 1000 * 1e18);
        assertEq(token.totalSupply(), 1000 * 1e18);
    }

    function testMintOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.mint(user1, 1000 * 1e18);
    }

    function testBurn() public {
        vm.prank(owner);
        token.mint(user1, 1000 * 1e18);

        vm.prank(user1);
        token.burn(500 * 1e18);

        assertEq(token.balanceOf(user1), 500 * 1e18);
        assertEq(token.totalSupply(), 500 * 1e18);
    }

    function testTransfer() public {
        vm.prank(owner);
        token.mint(user1, 1000 * 1e18);

        vm.prank(user1);
        token.transfer(user2, 300 * 1e18);

        assertEq(token.balanceOf(user1), 700 * 1e18);
        assertEq(token.balanceOf(user2), 300 * 1e18);
    }
} 