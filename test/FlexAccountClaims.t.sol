// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FlexAccountClaims} from "../contracts/extra/FlexAccountClaims.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// Mock veNFT contract
contract MockVeNFT is ERC721 {
    uint256 private _nextTokenId;

    constructor() ERC721("Voting Escrow NFT", "veNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

// Mock oHYDX token
contract MockOHYDX is ERC20 {
    constructor() ERC20("Options HYDX", "oHYDX") {
        _mint(msg.sender, 10_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FlexAccountClaimsTest is Test {
    FlexAccountClaims public claims;
    MockOHYDX public ohydx;
    MockVeNFT public venft;

    address public owner;
    address public nftHolder1;
    address public nftHolder2;
    address public user1;

    uint256 public tokenId1;
    uint256 public tokenId2;

    function setUp() public {
        owner = address(this);
        nftHolder1 = makeAddr("nftHolder1");
        nftHolder2 = makeAddr("nftHolder2");
        user1 = makeAddr("user1");

        // Deploy mock contracts at the hardcoded addresses
        venft = new MockVeNFT();
        ohydx = new MockOHYDX();

        // Etch the mock contracts at the hardcoded addresses
        vm.etch(0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1, address(venft).code);
        vm.etch(0xA1136031150E50B015b41f1ca6B2e99e49D8cB78, address(ohydx).code);

        // Update references to use hardcoded addresses
        venft = MockVeNFT(0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1);
        ohydx = MockOHYDX(0xA1136031150E50B015b41f1ca6B2e99e49D8cB78);

        // Mint NFTs
        tokenId1 = venft.mint(nftHolder1);
        tokenId2 = venft.mint(nftHolder2);

        // Deploy FlexAccountClaims
        claims = new FlexAccountClaims();

        // Fund the claims contract with oHYDX
        ohydx.mint(address(claims), 1_000_000 * 10 ** 18);
    }

    /*
     * Initial State Tests
     */

    function testInitialState() public view {
        assertTrue(claims.hasRole(claims.DEFAULT_ADMIN_ROLE(), owner));
        assertEq(claims.nextAllocationId(tokenId1), 0);
        assertEq(claims.nextAllocationId(tokenId2), 0);
    }

    function testConstants() public view {
        assertEq(claims.VENFT(), 0x9ee81fD729b91095563fE6dA11c1fE92C52F9728);
        assertEq(claims.OHYDX(), 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78);
    }

    /*
     * Allocation Creation Tests
     */

    function testCreateSingleAllocation() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        FlexAccountClaims.Allocation memory allocation = claims.getAllocation(tokenId1, 0);
        assertEq(allocation.totalAmount, amount);
        assertEq(allocation.claimed, 0);
        assertEq(allocation.startTimestamp, startTime);
        assertEq(allocation.vestingSeconds, vestingSeconds);
        assertEq(claims.nextAllocationId(tokenId1), 1);
    }

    function testCreateMultipleAllocations() public {
        uint256 amount = 5_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId1;
        tokenIds[2] = tokenId2;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount;
        amounts[1] = amount * 2;
        amounts[2] = amount;

        uint256[] memory vestingTimes = new uint256[](3);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds * 2;
        vestingTimes[2] = vestingSeconds;

        uint256[] memory startTimes = new uint256[](3);
        startTimes[0] = startTime;
        startTimes[1] = startTime;
        startTimes[2] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        assertEq(claims.nextAllocationId(tokenId1), 2);
        assertEq(claims.nextAllocationId(tokenId2), 1);

        FlexAccountClaims.Allocation memory alloc1 = claims.getAllocation(tokenId1, 0);
        assertEq(alloc1.totalAmount, amount);

        FlexAccountClaims.Allocation memory alloc2 = claims.getAllocation(tokenId1, 1);
        assertEq(alloc2.totalAmount, amount * 2);

        FlexAccountClaims.Allocation memory alloc3 = claims.getAllocation(tokenId2, 0);
        assertEq(alloc3.totalAmount, amount);
    }

    function test_RevertWhen_CreateWithZeroAmount() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = 30 days;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = block.timestamp;

        vm.startPrank(owner);
        vm.expectRevert(FlexAccountClaims.InvalidAmount.selector);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateWithZeroVestingSeconds() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000 * 10 ** 18;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = 0;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = block.timestamp;

        vm.prank(owner);
        vm.expectRevert(FlexAccountClaims.InvalidDuration.selector);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
    }

    function test_RevertWhen_ArrayLengthMismatch() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10_000 * 10 ** 18;
        amounts[1] = 10_000 * 10 ** 18;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = 30 days;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = block.timestamp;

        vm.startPrank(owner);
        vm.expectRevert("Length mismatch");
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();
    }

    /*
     * Duplicate Allocation Tests
     */

    function testSkipDuplicateAllocation() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId1; // Duplicate

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount; // Same amount

        uint256[] memory vestingTimes = new uint256[](2);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds; // Same vesting

        uint256[] memory startTimes = new uint256[](2);
        startTimes[0] = startTime;
        startTimes[1] = startTime; // Same start time

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit FlexAccountClaims.DuplicateAllocation(tokenId1, amount, vestingSeconds, startTime);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // Should only create one allocation
        assertEq(claims.nextAllocationId(tokenId1), 1);
    }

    function testDuplicateAllocationAcrossBatches() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.startPrank(owner);
        // Create first allocation
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // Try to create duplicate
        vm.expectEmit(true, true, true, true);
        emit FlexAccountClaims.DuplicateAllocation(tokenId1, amount, vestingSeconds, startTime);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();

        // Should still only have one allocation
        assertEq(claims.nextAllocationId(tokenId1), 1);
    }

    function testDifferentParametersNotDuplicate() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        // Create first allocation
        uint256[] memory tokenIds1 = new uint256[](1);
        tokenIds1[0] = tokenId1;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = amount;
        uint256[] memory vestingTimes1 = new uint256[](1);
        vestingTimes1[0] = vestingSeconds;
        uint256[] memory startTimes1 = new uint256[](1);
        startTimes1[0] = startTime;

        // Create second allocation with different start time
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = tokenId1;
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = amount;
        uint256[] memory vestingTimes2 = new uint256[](1);
        vestingTimes2[0] = vestingSeconds;
        uint256[] memory startTimes2 = new uint256[](1);
        startTimes2[0] = startTime + 1 days;

        vm.startPrank(owner);
        claims.createAllocationBatch(tokenIds1, amounts1, vestingTimes1, startTimes1);
        claims.createAllocationBatch(tokenIds2, amounts2, vestingTimes2, startTimes2);
        vm.stopPrank();

        // Should create two allocations
        assertEq(claims.nextAllocationId(tokenId1), 2);
    }

    /*
     * Claiming Tests
     */

    function testClaimFullyVested() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // Fast forward past vesting period
        vm.warp(startTime + vestingSeconds);

        uint256 balanceBefore = ohydx.balanceOf(nftHolder1);

        vm.prank(nftHolder1);
        claims.claim(tokenId1, 0);

        uint256 balanceAfter = ohydx.balanceOf(nftHolder1);
        assertEq(balanceAfter - balanceBefore, amount);

        FlexAccountClaims.Allocation memory allocation = claims.getAllocation(tokenId1, 0);
        assertEq(allocation.claimed, amount);
    }

    function testClaimPartiallyVested() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // Fast forward to 50% vested
        vm.warp(startTime + vestingSeconds / 2);

        uint256 balanceBefore = ohydx.balanceOf(nftHolder1);

        vm.prank(nftHolder1);
        claims.claim(tokenId1, 0);

        uint256 balanceAfter = ohydx.balanceOf(nftHolder1);
        uint256 expectedAmount = amount / 2;
        assertApproxEqAbs(balanceAfter - balanceBefore, expectedAmount, 1);
    }

    function testClaimMultipleTimes() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // Claim at 50%
        vm.warp(startTime + vestingSeconds / 2);
        vm.prank(nftHolder1);
        claims.claim(tokenId1, 0);

        uint256 balanceAfterFirst = ohydx.balanceOf(nftHolder1);
        assertGt(balanceAfterFirst, 0);
        assertLt(balanceAfterFirst, amount);

        // Claim at 100%
        vm.warp(startTime + vestingSeconds);
        vm.prank(nftHolder1);
        claims.claim(tokenId1, 0);

        uint256 finalBalance = ohydx.balanceOf(nftHolder1);
        assertEq(finalBalance, amount); // Should have claimed everything
    }

    function testClaimAll() public {
        uint256 amount = 5_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId1;
        tokenIds[2] = tokenId1;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount;
        amounts[1] = amount;
        amounts[2] = amount;

        uint256[] memory vestingTimes = new uint256[](3);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds;
        vestingTimes[2] = vestingSeconds;

        uint256[] memory startTimes = new uint256[](3);
        startTimes[0] = startTime;
        startTimes[1] = startTime + 1; // Slightly different to avoid duplicate
        startTimes[2] = startTime + 2;

        vm.startPrank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();

        // Fast forward past vesting (need to account for the +2 offset)
        vm.warp(startTime + vestingSeconds + 2);

        vm.prank(nftHolder1);
        claims.claimAll(tokenId1);

        uint256 balance = ohydx.balanceOf(nftHolder1);
        assertEq(balance, amount * 3);
    }

    function test_RevertWhen_ClaimNotNFTHolder() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        vm.warp(startTime + vestingSeconds);

        vm.prank(user1);
        vm.expectRevert(FlexAccountClaims.NotNFTHolder.selector);
        claims.claim(tokenId1, 0);
    }

    function test_RevertWhen_ClaimNothingClaimable() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp + 1 days; // Starts in future

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        vm.prank(nftHolder1);
        vm.expectRevert(FlexAccountClaims.NoClaimableAmount.selector);
        claims.claim(tokenId1, 0);
    }

    function testClaimAfterNFTTransfer() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // Transfer NFT to user1
        vm.prank(nftHolder1);
        venft.transferFrom(nftHolder1, user1, tokenId1);

        // Fast forward
        vm.warp(startTime + vestingSeconds);

        // New holder can claim
        vm.prank(user1);
        claims.claim(tokenId1, 0);

        assertEq(ohydx.balanceOf(user1), amount);
        assertEq(ohydx.balanceOf(nftHolder1), 0);
    }

    /*
     * View Function Tests
     */

    function testGetClaimableAmount() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = vestingSeconds;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = startTime;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        // At start
        assertEq(claims.getClaimableAmount(tokenId1, 0), 0);

        // At 50%
        vm.warp(startTime + vestingSeconds / 2);
        assertApproxEqAbs(claims.getClaimableAmount(tokenId1, 0), amount / 2, 1);

        // At 100%
        vm.warp(startTime + vestingSeconds);
        assertEq(claims.getClaimableAmount(tokenId1, 0), amount);
    }

    function testGetTotalClaimable() public {
        uint256 amount = 5_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId1;
        tokenIds[2] = tokenId1;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount;
        amounts[1] = amount;
        amounts[2] = amount;

        uint256[] memory vestingTimes = new uint256[](3);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds;
        vestingTimes[2] = vestingSeconds;

        uint256[] memory startTimes = new uint256[](3);
        startTimes[0] = startTime;
        startTimes[1] = startTime + 1;
        startTimes[2] = startTime + 2;

        vm.startPrank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();

        vm.warp(startTime + vestingSeconds + 2);

        uint256 totalClaimable = claims.getTotalClaimable(tokenId1);
        assertEq(totalClaimable, amount * 3);
    }

    function testGetTotalIssuedAndClaimed() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount * 2;

        uint256[] memory vestingTimes = new uint256[](2);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds;

        uint256[] memory startTimes = new uint256[](2);
        startTimes[0] = startTime;
        startTimes[1] = startTime + 1;

        vm.startPrank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();

        (uint256 totalIssued, uint256 totalClaimed) = claims.getTotalIssuedAndClaimed(tokenId1);
        assertEq(totalIssued, amount * 3);
        assertEq(totalClaimed, 0);

        // Claim half of first allocation
        vm.warp(startTime + vestingSeconds / 2);
        vm.prank(nftHolder1);
        claims.claim(tokenId1, 0);

        (totalIssued, totalClaimed) = claims.getTotalIssuedAndClaimed(tokenId1);
        assertEq(totalIssued, amount * 3);
        assertApproxEqAbs(totalClaimed, amount / 2, 1);
    }

    function testGetGlobalIssuedAndClaimed() public {
        uint256 amount = 10_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount * 2;

        uint256[] memory vestingTimes = new uint256[](2);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds;

        uint256[] memory startTimes = new uint256[](2);
        startTimes[0] = startTime;
        startTimes[1] = startTime;

        vm.startPrank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
        vm.stopPrank();

        uint256[] memory queryTokenIds = new uint256[](2);
        queryTokenIds[0] = tokenId1;
        queryTokenIds[1] = tokenId2;

        (uint256 totalIssued, uint256 totalClaimed) = claims.getGlobalIssuedAndClaimed(queryTokenIds);
        assertEq(totalIssued, amount * 3);
        assertEq(totalClaimed, 0);

        // Claim from both
        vm.warp(startTime + vestingSeconds);
        vm.prank(nftHolder1);
        claims.claim(tokenId1, 0);
        vm.prank(nftHolder2);
        claims.claim(tokenId2, 0);

        (totalIssued, totalClaimed) = claims.getGlobalIssuedAndClaimed(queryTokenIds);
        assertEq(totalIssued, amount * 3);
        assertEq(totalClaimed, amount * 3);
    }

    function testGetAllocations() public {
        uint256 amount = 5_000 * 10 ** 18;
        uint256 vestingSeconds = 30 days;
        uint256 startTime = block.timestamp;

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId1;
        tokenIds[2] = tokenId1;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount;
        amounts[1] = amount * 2;
        amounts[2] = amount * 3;

        uint256[] memory vestingTimes = new uint256[](3);
        vestingTimes[0] = vestingSeconds;
        vestingTimes[1] = vestingSeconds;
        vestingTimes[2] = vestingSeconds;

        uint256[] memory startTimes = new uint256[](3);
        startTimes[0] = startTime;
        startTimes[1] = startTime + 1;
        startTimes[2] = startTime + 2;

        vm.prank(owner);
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);

        FlexAccountClaims.Allocation[] memory allocations = claims.getAllocations(tokenId1);
        assertEq(allocations.length, 3);
        assertEq(allocations[0].totalAmount, amount);
        assertEq(allocations[1].totalAmount, amount * 2);
        assertEq(allocations[2].totalAmount, amount * 3);
    }

    function testGetAllocationHash() public view {
        bytes32 hash1 = claims.getAllocationHash(tokenId1, 1000, 30 days, block.timestamp);
        bytes32 hash2 = claims.getAllocationHash(tokenId1, 1000, 30 days, block.timestamp);
        bytes32 hash3 = claims.getAllocationHash(tokenId1, 1001, 30 days, block.timestamp);

        assertEq(hash1, hash2);
        assertTrue(hash1 != hash3);
    }

    /*
     * Emergency Recovery Tests
     */

    function testEmergencyRecover() public {
        uint256 recoverAmount = 5000 * 10 ** 18;

        // Mint tokens directly to the claims contract
        ohydx.mint(address(claims), recoverAmount);

        uint256 balanceBefore = ohydx.balanceOf(user1);

        vm.prank(owner);
        claims.emergencyRecover(address(ohydx), recoverAmount, user1);

        uint256 balanceAfter = ohydx.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, recoverAmount);
    }

    function test_RevertWhen_EmergencyRecoverZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(FlexAccountClaims.InvalidAddress.selector);
        claims.emergencyRecover(address(0), 1000, user1);
    }

    function test_RevertWhen_EmergencyRecoverZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(FlexAccountClaims.InvalidAddress.selector);
        claims.emergencyRecover(address(ohydx), 1000, address(0));
    }

    function test_RevertWhen_EmergencyRecoverZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(FlexAccountClaims.InvalidAmount.selector);
        claims.emergencyRecover(address(ohydx), 0, user1);
    }

    /*
     * Access Control Tests
     */

    function test_RevertWhen_NonAdminCreatesAllocation() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000 * 10 ** 18;
        uint256[] memory vestingTimes = new uint256[](1);
        vestingTimes[0] = 30 days;
        uint256[] memory startTimes = new uint256[](1);
        startTimes[0] = block.timestamp;

        vm.prank(user1);
        vm.expectRevert();
        claims.createAllocationBatch(tokenIds, amounts, vestingTimes, startTimes);
    }

    function test_RevertWhen_NonAdminRecoversTokens() public {
        vm.prank(user1);
        vm.expectRevert();
        claims.emergencyRecover(address(ohydx), 1000, user1);
    }
}
