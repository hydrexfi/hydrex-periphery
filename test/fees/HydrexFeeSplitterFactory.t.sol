// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydrexFeeSplitter} from "../../contracts/fees/HydrexFeeSplitter.sol";
import {HydrexFeeSplitterFactory} from "../../contracts/fees/HydrexFeeSplitterFactory.sol";
import {MockToken, MockBrokenToken, MockAlgebraPool, MockNonAlgebraPool, MockGauge, MockVoter} from "./mocks/FeeSplitterMocks.sol";

contract HydrexFeeSplitterFactoryTest is Test {
    HydrexFeeSplitterFactory internal factory;
    MockVoter internal voter;
    MockToken internal weth;
    MockToken internal usdc;

    address internal algebra = makeAddr("algebra");
    address internal bribe = makeAddr("bribe");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal algebraFactory = makeAddr("algebraFactory");

    uint16 internal constant ALGEBRA_SHARE_BPS = 150;
    uint256 internal constant POOL_COUNT = 12;

    MockAlgebraPool[] internal pools;
    MockGauge[] internal gauges;

    function setUp() public {
        voter = new MockVoter();
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        factory = new HydrexFeeSplitterFactory(
            address(voter),
            algebraFactory,
            algebra,
            ALGEBRA_SHARE_BPS,
            treasury
        );

        for (uint256 i; i < POOL_COUNT; ++i) {
            MockAlgebraPool pool = new MockAlgebraPool(address(weth), address(usdc), algebraFactory);
            MockGauge gauge = new MockGauge(address(pool), bribe);
            voter.registerGauge(address(pool), address(gauge));
            pools.push(pool);
            gauges.push(gauge);
        }
    }

    function _poolAddresses() internal view returns (address[] memory list) {
        list = new address[](POOL_COUNT);
        for (uint256 i; i < POOL_COUNT; ++i) list[i] = address(pools[i]);
    }

    function _deployAll() internal returns (address[] memory created) {
        (created, ) = factory.createSplitters(_poolAddresses());
        for (uint256 i; i < POOL_COUNT; ++i) pools[i].setCommunityVault(created[i]);
    }

    /* ---------------------------- batch deploy ------------------------ */

    function test_BatchCreateDeploysOnePerPool() public {
        (address[] memory created, bool[] memory isNew) = factory.createSplitters(_poolAddresses());

        assertEq(created.length, POOL_COUNT);
        assertEq(factory.splittersCount(), POOL_COUNT);
        for (uint256 i; i < POOL_COUNT; ++i) {
            assertTrue(isNew[i]);
            assertEq(created[i], factory.predictSplitter(address(pools[i])));
            assertEq(HydrexFeeSplitter(created[i]).pool(), address(pools[i]));
        }
    }

    function test_BatchCreateIsIdempotent() public {
        (address[] memory first, ) = factory.createSplitters(_poolAddresses());
        (address[] memory second, bool[] memory isNew) = factory.createSplitters(_poolAddresses());

        assertEq(factory.splittersCount(), POOL_COUNT, "no duplicates");
        for (uint256 i; i < POOL_COUNT; ++i) {
            assertEq(second[i], first[i]);
            assertFalse(isNew[i], "already existed");
        }
    }

    function test_BatchCreateFillsGapsOnly() public {
        address[] memory firstTwo = new address[](2);
        firstTwo[0] = address(pools[0]);
        firstTwo[1] = address(pools[1]);
        factory.createSplitters(firstTwo);

        (, bool[] memory isNew) = factory.createSplitters(_poolAddresses());
        assertFalse(isNew[0]);
        assertFalse(isNew[1]);
        assertTrue(isNew[2]);
        assertEq(factory.splittersCount(), POOL_COUNT);
    }

    function test_TrackingRegistryAfterDeploy() public {
        address[] memory created = _deployAll();

        assertEq(factory.splittersCount(), POOL_COUNT);
        for (uint256 i; i < POOL_COUNT; ++i) {
            assertEq(factory.splitters(i), created[i], "ordered registry");
            assertEq(factory.splitterForPool(address(pools[i])), created[i], "by pool");
            assertEq(factory.splitterForGauge(address(gauges[i])), created[i], "by gauge");
            assertEq(factory.poolForSplitter(created[i]), address(pools[i]), "reverse");
            assertTrue(factory.isSplitter(created[i]));
        }
    }

    /* --------------------------- batch split -------------------------- */

    function test_SplitManyDistributesAcrossFleet() public {
        address[] memory splitters = _deployAll();
        for (uint256 i; i < POOL_COUNT; ++i) pools[i].pushFees(1_000e18, 2_000e6);

        uint256 succeeded = factory.splitMany(splitters);

        assertEq(succeeded, POOL_COUNT);
        assertEq(weth.balanceOf(algebra), POOL_COUNT * 15e18);
        assertEq(usdc.balanceOf(algebra), POOL_COUNT * 30e6);
        for (uint256 i; i < POOL_COUNT; ++i) {
            assertEq(weth.balanceOf(address(gauges[i])), 985e18);
        }
    }

    function test_SplitRangePagesThroughRegistry() public {
        _deployAll();
        for (uint256 i; i < POOL_COUNT; ++i) pools[i].pushFees(1_000e18, 0);

        assertEq(factory.splitRange(0, 5), 5);
        assertEq(factory.splitRange(5, 5), 5);
        assertEq(factory.splitRange(10, 100), 2, "clamps past the end");
        assertEq(factory.splitRange(POOL_COUNT, 10), 0, "start past the end is a no-op");

        assertEq(weth.balanceOf(algebra), POOL_COUNT * 15e18);
    }

    function test_SplitManySkipsFailingSplitterWithoutBlockingTheRest() public {
        address[] memory splitters = _deployAll();

        // Give one pool a token that reverts on transfer.
        MockBrokenToken broken = new MockBrokenToken();
        MockAlgebraPool badPool = new MockAlgebraPool(address(broken), address(usdc), algebraFactory);
        MockGauge badGauge = new MockGauge(address(badPool), bribe);
        voter.registerGauge(address(badPool), address(badGauge));
        address badSplitter = factory.createSplitter(address(badPool));
        badPool.setCommunityVault(badSplitter);
        broken.mint(badSplitter, 100e18);

        for (uint256 i; i < POOL_COUNT; ++i) pools[i].pushFees(1_000e18, 0);

        address[] memory targets = new address[](POOL_COUNT + 1);
        targets[0] = badSplitter;
        for (uint256 i; i < POOL_COUNT; ++i) targets[i + 1] = splitters[i];

        vm.expectEmit(true, false, false, false);
        emit HydrexFeeSplitterFactory.SplitFailed(badSplitter);
        uint256 succeeded = factory.splitMany(targets);

        assertEq(succeeded, POOL_COUNT, "healthy splitters still ran");
        assertEq(weth.balanceOf(algebra), POOL_COUNT * 15e18);
    }

    function test_SplitManySkipsAddressesThisFactoryDidNotDeploy() public {
        address[] memory splitters = _deployAll();
        pools[0].pushFees(1_000e18, 0);

        // A foreign contract must never be called by the factory: a splitter grants the factory
        // owner-level rights, so the factory must not be an arbitrary-call proxy.
        address foreign = address(new MockGauge(address(pools[0]), bribe));
        address[] memory targets = new address[](2);
        targets[0] = foreign;
        targets[1] = splitters[0];

        vm.expectEmit(true, false, false, false);
        emit HydrexFeeSplitterFactory.SplitFailed(foreign);
        uint256 succeeded = factory.splitMany(targets);

        assertEq(succeeded, 1, "only the registered splitter ran");
        assertEq(weth.balanceOf(algebra), 15e18);
    }

    function test_SplitManyIsPermissionless() public {
        address[] memory splitters = _deployAll();
        pools[0].pushFees(1_000e18, 0);

        vm.prank(keeper);
        factory.splitMany(splitters);

        assertEq(weth.balanceOf(algebra), 15e18);
    }

    /* ------------------------------ views ----------------------------- */

    function test_SweepingTheWholeRegistryDrainsOnlyFundedSplitters() public {
        address[] memory splitters = _deployAll();
        pools[2].pushFees(1e18, 0);
        pools[7].pushFees(0, 1e6);

        // Empty splitters are a cheap no-op, so the keeper can sweep blind.
        uint256 succeeded = factory.splitRange(0, POOL_COUNT);
        assertEq(succeeded, POOL_COUNT, "every splitter ran");

        for (uint256 i; i < POOL_COUNT; ++i) {
            (uint256 balance0, uint256 balance1) = HydrexFeeSplitter(splitters[i]).pending();
            assertEq(balance0 + balance1, 0, "drained");
        }
        assertEq(weth.balanceOf(algebra), 0.015e18);
        assertEq(usdc.balanceOf(algebra), 15_000);
    }

    function test_MigrationChecklistReadsFromTheSplitters() public {
        (address[] memory created, ) = factory.createSplitters(_poolAddresses());

        for (uint256 i; i < POOL_COUNT; ++i) {
            assertFalse(HydrexFeeSplitter(created[i]).isLiveCommunityVault(), "not wired yet");
        }

        // Ops runs setCommunityVault on the Algebra pools.
        for (uint256 i; i < POOL_COUNT; ++i) pools[i].setCommunityVault(created[i]);
        for (uint256 i; i < POOL_COUNT; ++i) {
            assertTrue(HydrexFeeSplitter(created[i]).isLiveCommunityVault(), "migration complete");
        }

        // A pool later retargeted away shows up again.
        pools[4].setCommunityVault(address(0xdead));
        assertFalse(HydrexFeeSplitter(created[4]).isLiveCommunityVault());
    }

    function test_GetSplittersPagination() public {
        _deployAll();

        assertEq(factory.getSplitters().length, POOL_COUNT);
        assertEq(factory.getSplittersPaged(0, 5).length, 5);
        assertEq(factory.getSplittersPaged(10, 100).length, 2, "clamps past the end");
        assertEq(factory.getSplittersPaged(POOL_COUNT, 5).length, 0);
    }

    function test_ConfigReportsLiveWiring() public {
        address[] memory created = _deployAll();
        (, , , , address primary, address secondary, uint16 shareBps, bool live) = HydrexFeeSplitter(created[0])
            .config();

        assertEq(primary, address(gauges[0]));
        assertEq(secondary, algebra);
        assertEq(shareBps, ALGEBRA_SHARE_BPS);
        assertTrue(live);

        pools[0].setCommunityVault(address(0xdead));
        (, , , , , , , live) = HydrexFeeSplitter(created[0]).config();
        assertFalse(live);
    }


    function test_PendingInPoolReadsThePoolsUnflushedFees() public {
        address[] memory created = _deployAll();
        pools[0].setPending(123, 456);

        (uint128 p0, uint128 p1) = HydrexFeeSplitter(created[0]).pendingInPool();
        assertEq(p0, 123);
        assertEq(p1, 456);
    }

    /* ---------------------------- guardrails -------------------------- */

    function test_ConstructorValidatesInputs() public {
        vm.expectRevert(HydrexFeeSplitterFactory.ZeroAddress.selector);
        new HydrexFeeSplitterFactory(address(0), algebraFactory, algebra, ALGEBRA_SHARE_BPS, treasury);

        vm.expectRevert(HydrexFeeSplitterFactory.ZeroAddress.selector);
        new HydrexFeeSplitterFactory(address(voter), address(0), algebra, ALGEBRA_SHARE_BPS, treasury);

        vm.expectRevert(HydrexFeeSplitterFactory.ZeroAddress.selector);
        new HydrexFeeSplitterFactory(address(voter), algebraFactory, address(0), ALGEBRA_SHARE_BPS, treasury);

        vm.expectRevert(HydrexFeeSplitterFactory.ZeroAddress.selector);
        new HydrexFeeSplitterFactory(address(voter), algebraFactory, algebra, ALGEBRA_SHARE_BPS, address(0));

        vm.expectRevert(HydrexFeeSplitterFactory.ShareTooHigh.selector);
        new HydrexFeeSplitterFactory(address(voter), algebraFactory, algebra, 2_001, treasury);
    }

    function test_EmptyBatchesRevert() public {
        address[] memory empty = new address[](0);

        vm.expectRevert(HydrexFeeSplitterFactory.EmptyInput.selector);
        factory.createSplitters(empty);

        vm.expectRevert(HydrexFeeSplitterFactory.EmptyInput.selector);
        factory.splitMany(empty);

        vm.expectRevert(HydrexFeeSplitterFactory.EmptyInput.selector);
        factory.clearOverrides(empty);
    }
}
