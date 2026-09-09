// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HydrexFeeSplitter} from "../../contracts/fees/HydrexFeeSplitter.sol";
import {HydrexFeeSplitterFactory} from "../../contracts/fees/HydrexFeeSplitterFactory.sol";
import {IHydrexVoter} from "../../contracts/fees/interfaces/IFeeSplitterExternal.sol";

interface IAlgebraPoolFork {
    function communityVault() external view returns (address);

    function factory() external view returns (address);

    function setCommunityVault(address newCommunityVault) external;

    function token0() external view returns (address);

    function token1() external view returns (address);

    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool);
}

interface IVoterBribes {
    function internal_bribes(address gauge) external view returns (address);
}

/**
 * @notice Fork tests against live Base state: the real voter, the real Algebra pools, the real
 *         gauges, and the real Algebra factory owner performing the `setCommunityVault` migration.
 * @dev Run with `npm run fork:fee-splitter`.
 */
contract HydrexFeeSplitterForkTest is Test {
    address internal constant VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;
    address internal constant ALGEBRA_FACTORY = 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E;
    address internal constant ALGEBRA_FACTORY_OWNER = 0x74266f2b206D1359B83fc74949EF07176FB3AE03;

    // WETH/USDC Algebra Integral pool and its GaugeIncentiveCampaign gauge.
    address internal constant POOL = 0x82dbe18346a8656dBB5E76F74bf3AE279cC16B29;
    address internal constant GAUGE = 0x22F0AFdDa80FBca0d96e29384814A897CbAdAB59;

    address internal constant ALGEBRA_RECEIVER = 0x000000000000000000000000000000000000A1Aa;
    address internal constant TREASURY = 0x000000000000000000000000000000000000bEEF;

    uint16 internal constant ALGEBRA_SHARE_BPS = 150; // 1.5%

    /// @dev Pinned so the discovered pool set stays stable across runs.
    uint256 internal constant FORK_BLOCK = 51092008;

    HydrexFeeSplitterFactory internal factory;
    address internal multisig = 0x74266f2b206D1359B83fc74949EF07176FB3AE03;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);

        vm.prank(multisig);
        factory = new HydrexFeeSplitterFactory(
            VOTER,
            ALGEBRA_FACTORY,
            ALGEBRA_RECEIVER,
            ALGEBRA_SHARE_BPS,
            TREASURY
        );
    }

    function test_Fork_GaugeIsCurrentlyTheCommunityVault() public view {
        assertEq(
            IAlgebraPoolFork(POOL).communityVault(),
            GAUGE,
            "baseline: the gauge takes 100% of community fees today"
        );
    }

    function test_Fork_DeploySplitterFromPoolAlone() public {
        address predicted = factory.predictSplitter(POOL);
        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(POOL));

        assertEq(address(splitter), predicted, "address knowable before deployment");
        assertEq(splitter.token0(), IAlgebraPoolFork(POOL).token0(), "token0 resolved from the pool");
        assertEq(splitter.token1(), IAlgebraPoolFork(POOL).token1(), "token1 resolved from the pool");
        assertEq(splitter.gauge(), GAUGE, "gauge resolved live from the voter");
        assertEq(splitter.primaryRecipient(), GAUGE);
        assertEq(splitter.secondaryRecipient(), ALGEBRA_RECEIVER);
        assertEq(splitter.secondaryShareBps(), ALGEBRA_SHARE_BPS);
    }

    function test_Fork_LookupSplitterByPoolOrGauge() public {
        address splitter = factory.createSplitter(POOL);

        assertEq(factory.splitterForPool(POOL), splitter, "by pool");
        assertEq(factory.splitterForGauge(GAUGE), splitter, "by gauge");
        assertEq(factory.poolForSplitter(splitter), POOL, "reverse");
        assertTrue(factory.isSplitter(splitter));
    }

    function test_Fork_FullMigrationAndSplit() public {
        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(POOL));

        // Before the Algebra-side call the pool still points at the gauge.
        assertFalse(splitter.isLiveCommunityVault(), "not wired yet");

        // Ops step: the Algebra factory owner repoints the pool at the splitter.
        vm.prank(ALGEBRA_FACTORY_OWNER);
        IAlgebraPoolFork(POOL).setCommunityVault(address(splitter));

        assertEq(IAlgebraPoolFork(POOL).communityVault(), address(splitter));
        assertTrue(splitter.isLiveCommunityVault(), "migration complete");

        // Simulate the pool flushing community fees into the splitter.
        address token0 = splitter.token0();
        address token1 = splitter.token1();
        deal(token0, address(splitter), 10e18);
        deal(token1, address(splitter), 20_000e6);

        uint256 gauge0Before = IERC20(token0).balanceOf(GAUGE);
        uint256 gauge1Before = IERC20(token1).balanceOf(GAUGE);

        vm.prank(makeAddr("keeper"));
        splitter.split();

        assertEq(IERC20(token0).balanceOf(ALGEBRA_RECEIVER), 0.15e18, "1.5% of token0");
        assertEq(IERC20(token1).balanceOf(ALGEBRA_RECEIVER), 300e6, "1.5% of token1");
        assertEq(IERC20(token0).balanceOf(GAUGE) - gauge0Before, 9.85e18, "98.5% of token0");
        assertEq(IERC20(token1).balanceOf(GAUGE) - gauge1Before, 19_700e6, "98.5% of token1");
        assertEq(IERC20(token0).balanceOf(address(splitter)), 0, "splitter drained");
        assertEq(IERC20(token1).balanceOf(address(splitter)), 0, "splitter drained");
    }

    function test_Fork_SplitAndClaimReachesTheInternalBribe() public {
        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(POOL));
        vm.prank(ALGEBRA_FACTORY_OWNER);
        IAlgebraPoolFork(POOL).setCommunityVault(address(splitter));

        address token0 = splitter.token0();
        address bribe = IVoterBribes(VOTER).internal_bribes(GAUGE);
        assertTrue(bribe != address(0), "gauge has an internal bribe");

        deal(token0, address(splitter), 10e18);
        uint256 bribeBefore = IERC20(token0).balanceOf(bribe);

        vm.prank(makeAddr("keeper"));
        splitter.splitAndClaim();

        assertEq(IERC20(token0).balanceOf(ALGEBRA_RECEIVER), 0.15e18, "Algebra paid");
        assertGe(
            IERC20(token0).balanceOf(bribe) - bribeBefore,
            9.85e18,
            "gauge share forwarded on to voters"
        );
        assertEq(IERC20(token0).balanceOf(GAUGE), 0, "gauge swept clean");
    }

    /**
     * @dev Discovery now lives in the rollout script, so mirror it here: walk the tail of the
     *      voter's list (where the Algebra pools sit) and keep the ones this factory would accept.
     */
    function _discoverPools(uint256 want) internal view returns (address[] memory found) {
        uint256 total = IHydrexVoter(VOTER).length();
        uint256 start = total > 40 ? total - 40 : 0;

        address[] memory buffer = new address[](want);
        uint256 count;
        for (uint256 i = start; i < total && count < want; ++i) {
            address pool = IHydrexVoter(VOTER).pools(i);
            if (pool == address(0) || factory.splitterForPool(pool) != address(0)) continue;
            if (pool.code.length == 0) continue;

            try IAlgebraPoolFork(pool).communityVault() returns (address) {
                buffer[count++] = pool;
            } catch {}
        }

        found = new address[](count);
        for (uint256 i; i < count; ++i) found[i] = buffer[i];
    }

    function test_Fork_DiscoveryFindsRealAlgebraPools() public view {
        assertGt(IHydrexVoter(VOTER).length(), 100, "voter has a real pool list");

        address[] memory pools = _discoverPools(20);
        assertGt(pools.length, 0, "found Algebra pools needing a splitter");

        for (uint256 i; i < pools.length; ++i) {
            // Every discovered pool is one the factory will actually accept.
            assertEq(IAlgebraPoolFork(pools[i]).factory(), ALGEBRA_FACTORY);
            assertEq(factory.splitterForPool(pools[i]), address(0));
        }

        console2.log("Algebra pools needing a splitter in the last 40 voter pools:", pools.length);
    }

    /**
     * @notice A real Algebra pool that has no gauge: deploy, collect, and pay the fallback
     *         recipient, then start paying the gauge the moment one appears.
     * @dev Every voter-listed Algebra pool has a gauge today, so the gaugeless state is simulated
     *      on the real pool rather than fabricated from a mock one.
     */
    function test_Fork_PoolWithNoGauge() public {
        vm.mockCall(VOTER, abi.encodeWithSignature("gauges(address)", POOL), abi.encode(address(0)));

        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(POOL));
        vm.prank(ALGEBRA_FACTORY_OWNER);
        IAlgebraPoolFork(POOL).setCommunityVault(address(splitter));

        assertEq(splitter.gauge(), address(0), "no gauge");
        assertEq(splitter.primaryRecipient(), TREASURY, "falls back to the treasury");

        address token0 = splitter.token0();
        uint256 treasuryBefore = IERC20(token0).balanceOf(TREASURY);
        deal(token0, address(splitter), 10e18);
        splitter.split();

        assertEq(
            IERC20(token0).balanceOf(TREASURY) - treasuryBefore,
            9.85e18,
            "treasury took the primary share"
        );
        assertEq(IERC20(token0).balanceOf(ALGEBRA_RECEIVER), 0.15e18, "Algebra still paid");

        // The gauge shows up later. No redeploy, no reconfiguration.
        vm.clearMockedCalls();
        assertEq(splitter.gauge(), GAUGE);
        assertEq(splitter.primaryRecipient(), GAUGE);

        uint256 gaugeBefore = IERC20(token0).balanceOf(GAUGE);
        deal(token0, address(splitter), 10e18);
        splitter.split();
        assertEq(IERC20(token0).balanceOf(GAUGE) - gaugeBefore, 9.85e18, "now paying the gauge");
    }

    function test_Fork_BatchDeployAndSplitAcrossRealPools() public {
        address[] memory batch = _discoverPools(8);
        uint256 count = batch.length;
        assertGt(count, 0);

        (address[] memory splitters, bool[] memory isNew) = factory.createSplitters(batch);

        for (uint256 i; i < count; ++i) {
            assertTrue(isNew[i]);
            vm.prank(ALGEBRA_FACTORY_OWNER);
            IAlgebraPoolFork(batch[i]).setCommunityVault(splitters[i]);

            deal(HydrexFeeSplitter(splitters[i]).token0(), splitters[i], 1_000e6);
        }

        for (uint256 i; i < count; ++i) {
            assertTrue(HydrexFeeSplitter(splitters[i]).isLiveCommunityVault(), "pool repointed");
        }

        // At least one live Base pool holds a token whose `balanceOf` traps the EVM. The sweep
        // must skip that splitter rather than reverting the keeper's whole transaction.
        uint256 succeeded = factory.splitRange(0, count);
        assertGt(succeeded, 0, "fleet swept");
        assertLt(succeeded, count + 1);

        uint256 drained;
        for (uint256 i; i < count; ++i) {
            try HydrexFeeSplitter(splitters[i]).pending() returns (uint256 balance0, uint256 balance1) {
                if (balance0 == 0 && balance1 == 0) drained++;
            } catch {}
        }
        assertEq(drained, succeeded, "every splitter that ran is now empty");
    }

    function test_Fork_OwnerRetargetsAlgebraReceiverForWholeFleetInOneTx() public {
        address[] memory batch = _discoverPools(5);
        (address[] memory splitters, ) = factory.createSplitters(batch);

        address newReceiver = makeAddr("newAlgebraReceiver");
        vm.prank(multisig);
        factory.setDefaultSecondaryRecipient(newReceiver);

        for (uint256 i; i < splitters.length; ++i) {
            assertEq(HydrexFeeSplitter(splitters[i]).secondaryRecipient(), newReceiver);
        }
    }
}
