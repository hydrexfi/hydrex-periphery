// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydrexFeeSplitter} from "../../contracts/fees/HydrexFeeSplitter.sol";
import {HydrexFeeSplitterFactory} from "../../contracts/fees/HydrexFeeSplitterFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockToken, MockAlgebraPool, MockNonAlgebraPool, MockGauge, MockVoter} from "./mocks/FeeSplitterMocks.sol";

contract HydrexFeeSplitterTest is Test {
    HydrexFeeSplitterFactory internal factory;
    MockVoter internal voter;
    MockToken internal weth;
    MockToken internal usdc;
    MockAlgebraPool internal pool;
    MockGauge internal gauge;

    address internal owner = address(this);
    address internal algebra = makeAddr("algebra");
    address internal bribe = makeAddr("bribe");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal algebraFactory = makeAddr("algebraFactory");

    uint16 internal constant ALGEBRA_SHARE_BPS = 150; // 1.5%

    function setUp() public {
        voter = new MockVoter();
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);

        pool = new MockAlgebraPool(address(weth), address(usdc), algebraFactory);
        gauge = new MockGauge(address(pool), bribe);
        voter.registerGauge(address(pool), address(gauge));

        factory = new HydrexFeeSplitterFactory(
            address(voter),
            algebraFactory,
            algebra,
            ALGEBRA_SHARE_BPS,
            treasury
        );
    }

    function _deploy() internal returns (HydrexFeeSplitter splitter) {
        splitter = HydrexFeeSplitter(factory.createSplitter(address(pool)));
        pool.setCommunityVault(address(splitter));
    }

    /* --------------------------- deployment --------------------------- */

    function test_DeploysWithPoolAloneAndResolvesTokensAndGauge() public {
        HydrexFeeSplitter splitter = _deploy();

        assertEq(splitter.pool(), address(pool));
        assertEq(splitter.gauge(), address(gauge), "gauge resolved live from the voter");
        assertEq(splitter.token0(), address(weth));
        assertEq(splitter.token1(), address(usdc));
        assertEq(address(splitter.factory()), address(factory));
    }

    function test_DefaultsAreGaugeAndAlgebra() public {
        HydrexFeeSplitter splitter = _deploy();

        assertEq(splitter.primaryRecipient(), address(gauge));
        assertEq(splitter.secondaryRecipient(), algebra);
        assertEq(splitter.secondaryShareBps(), ALGEBRA_SHARE_BPS);
    }

    function test_PredictedAddressMatchesDeployment() public {
        address predicted = factory.predictSplitter(address(pool));
        HydrexFeeSplitter splitter = _deploy();
        assertEq(address(splitter), predicted);
    }

    function test_CannotDeployTwiceForSamePool() public {
        HydrexFeeSplitter splitter = _deploy();

        vm.expectRevert(
            abi.encodeWithSelector(
                HydrexFeeSplitterFactory.SplitterExists.selector,
                address(pool),
                address(splitter)
            )
        );
        factory.createSplitter(address(pool));
    }

    function test_CreateSplitterRevertsForNonAlgebraPool() public {
        MockNonAlgebraPool v2Pool = new MockNonAlgebraPool(address(weth), address(usdc), algebraFactory);

        vm.expectRevert(
            abi.encodeWithSelector(HydrexFeeSplitterFactory.NotAnAlgebraPool.selector, address(v2Pool))
        );
        factory.createSplitter(address(v2Pool));
    }

    function test_CreateSplitterRevertsForCodelessAddress() public {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(HydrexFeeSplitterFactory.NotAnAlgebraPool.selector, eoa));
        factory.createSplitter(eoa);
    }

    function test_CreateSplitterRevertsForForeignAlgebraFactory() public {
        MockAlgebraPool foreign = new MockAlgebraPool(address(weth), address(usdc), makeAddr("otherFactory"));

        vm.expectRevert(
            abi.encodeWithSelector(HydrexFeeSplitterFactory.NotAnAlgebraPool.selector, address(foreign))
        );
        factory.createSplitter(address(foreign));
    }

    function test_AnyoneCanCreateSplitter() public {
        vm.prank(keeper);
        address splitter = factory.createSplitter(address(pool));
        assertEq(splitter, factory.predictSplitter(address(pool)));
        assertEq(HydrexFeeSplitter(splitter).secondaryRecipient(), algebra);
    }

    /* ------------------------ pools without gauges -------------------- */

    function test_SplitterDeploysForPoolWithNoGauge() public {
        MockAlgebraPool bare = new MockAlgebraPool(address(weth), address(usdc), algebraFactory);
        voter.registerPoolWithoutGauge(address(bare));

        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(address(bare)));
        bare.setCommunityVault(address(splitter));

        assertEq(splitter.gauge(), address(0), "no gauge yet");
        assertEq(splitter.primaryRecipient(), treasury, "falls back to the treasury");

        bare.pushFees(1_000e18, 0);
        splitter.split();

        assertEq(weth.balanceOf(treasury), 985e18);
        assertEq(weth.balanceOf(algebra), 15e18);
    }

    function test_GaugelessSplitterStartsPayingItsGaugeOnceOneExists() public {
        MockAlgebraPool bare = new MockAlgebraPool(address(weth), address(usdc), algebraFactory);
        voter.registerPoolWithoutGauge(address(bare));
        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(address(bare)));
        bare.setCommunityVault(address(splitter));

        bare.pushFees(1_000e18, 0);
        splitter.split();
        assertEq(weth.balanceOf(treasury), 985e18);

        // A gauge is created later. No redeploy, no reconfiguration.
        MockGauge lateGauge = new MockGauge(address(bare), bribe);
        voter.setGauge(address(bare), address(lateGauge));

        assertEq(splitter.gauge(), address(lateGauge));
        assertEq(splitter.primaryRecipient(), address(lateGauge));

        bare.pushFees(1_000e18, 0);
        splitter.split();

        assertEq(weth.balanceOf(address(lateGauge)), 985e18, "now paying the gauge");
        assertEq(weth.balanceOf(treasury), 985e18, "treasury share unchanged");
    }

    function test_SplitterFollowsGaugeReplacement() public {
        HydrexFeeSplitter splitter = _deploy();

        MockGauge newGauge = new MockGauge(address(pool), bribe);
        voter.setGauge(address(pool), address(newGauge));

        pool.pushFees(1_000e18, 0);
        splitter.split();

        assertEq(weth.balanceOf(address(newGauge)), 985e18);
        assertEq(weth.balanceOf(address(gauge)), 0, "old gauge no longer paid");
    }

    function test_KilledGaugeFallsBackToTreasury() public {
        HydrexFeeSplitter splitter = _deploy();
        voter.clearGauge(address(pool));

        assertEq(splitter.gauge(), address(0));
        assertEq(splitter.primaryRecipient(), treasury);

        pool.pushFees(1_000e18, 0);
        splitter.splitAndClaim();

        assertEq(weth.balanceOf(treasury), 985e18);
        assertEq(gauge.claimCount(), 0, "no gauge to claim on");
    }

    function test_SplitHoldsFeesWhenNoGaugeAndNoFallback() public {
        MockAlgebraPool bare = new MockAlgebraPool(address(weth), address(usdc), algebraFactory);
        HydrexFeeSplitter splitter = HydrexFeeSplitter(factory.createSplitter(address(bare)));
        bare.setCommunityVault(address(splitter));
        factory.setFallbackPrimaryRecipient(address(0));

        bare.pushFees(1_000e18, 0);

        // Reverting is the safe outcome: the fees stay put until a gauge or fallback exists.
        vm.expectRevert(HydrexFeeSplitter.NoPrimaryRecipient.selector);
        splitter.split();
        assertEq(weth.balanceOf(address(splitter)), 1_000e18, "fees held, not burned");

        factory.setFallbackPrimaryRecipient(treasury);
        splitter.split();
        assertEq(weth.balanceOf(treasury), 985e18);
    }

    /* ---------------------------- lookups ----------------------------- */

    function test_LookupSplitterByPoolOrGauge() public {
        HydrexFeeSplitter splitter = _deploy();

        assertEq(factory.splitterForPool(address(pool)), address(splitter), "by pool");
        assertEq(factory.splitterForGauge(address(gauge)), address(splitter), "by gauge");
        assertEq(factory.poolForSplitter(address(splitter)), address(pool), "reverse");
        assertTrue(factory.isSplitter(address(splitter)));

        assertEq(factory.splitterForPool(makeAddr("unknownPool")), address(0));
        assertEq(factory.splitterForGauge(makeAddr("unknownGauge")), address(0));
    }

    function test_SplitterConfigIsTheDashboardRead() public {
        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(10e18, 20e6);

        (
            address p,
            address g,
            address t0,
            address t1,
            address primary,
            address secondary,
            uint16 shareBps,
            bool live
        ) = splitter.config();

        assertEq(p, address(pool));
        assertEq(g, address(gauge));
        assertEq(t0, address(weth));
        assertEq(t1, address(usdc));
        assertEq(primary, address(gauge));
        assertEq(secondary, algebra);
        assertEq(shareBps, ALGEBRA_SHARE_BPS);
        assertTrue(live);

        (uint256 pending0, uint256 pending1) = splitter.pending();
        assertEq(pending0, 10e18);
        assertEq(pending1, 20e6);
    }

    /* ----------------------------- split ------------------------------ */

    function test_SplitSends98Point5PercentToGaugeAnd1Point5ToAlgebra() public {
        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(1_000e18, 2_000e6);

        splitter.split();

        assertEq(weth.balanceOf(address(gauge)), 985e18, "gauge weth");
        assertEq(weth.balanceOf(algebra), 15e18, "algebra weth");
        assertEq(usdc.balanceOf(address(gauge)), 1_970e6, "gauge usdc");
        assertEq(usdc.balanceOf(algebra), 30e6, "algebra usdc");

        assertEq(weth.balanceOf(address(splitter)), 0);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    function test_SplitIsPermissionless() public {
        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(1_000e18, 0);

        vm.prank(keeper);
        splitter.split();

        assertEq(weth.balanceOf(address(gauge)), 985e18);
    }

    function test_SplitOnEmptySplitterIsNoOp() public {
        HydrexFeeSplitter splitter = _deploy();

        (uint256 p0, uint256 s0, uint256 p1, uint256 s1) = splitter.split();
        assertEq(p0 + s0 + p1 + s1, 0);
    }

    function test_RepeatedSplitsAccumulateCorrectly() public {
        HydrexFeeSplitter splitter = _deploy();

        // 4 pushes a day, split after each: totals must match a single large split.
        for (uint256 i; i < 8; ++i) {
            pool.pushFees(100e18, 0);
            splitter.split();
        }

        assertEq(weth.balanceOf(algebra), 12e18, "8 * 1.5% of 100e18");
        assertEq(weth.balanceOf(address(gauge)), 788e18);
        assertEq(weth.balanceOf(address(splitter)), 0);
    }

    function test_SplitTwiceInARowIsHarmless() public {
        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(1_000e18, 0);

        splitter.split();
        splitter.split();

        assertEq(weth.balanceOf(address(gauge)), 985e18);
        assertEq(weth.balanceOf(algebra), 15e18);
    }

    function test_SplitReturnValuesMatchWhatMoved() public {
        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(777e18, 12_345e6);

        (uint256 p0, uint256 s0, uint256 p1, uint256 s1) = splitter.split();

        assertEq(weth.balanceOf(address(gauge)), p0, "token0 primary");
        assertEq(weth.balanceOf(algebra), s0, "token0 secondary");
        assertEq(usdc.balanceOf(address(gauge)), p1, "token1 primary");
        assertEq(usdc.balanceOf(algebra), s1, "token1 secondary");

        // Odd amounts: conservation still holds and the split is exact.
        assertEq(p0 + s0, 777e18);
        assertEq(p1 + s1, 12_345e6);
        assertEq(s0, (uint256(777e18) * ALGEBRA_SHARE_BPS) / 10_000);
        assertEq(s1, (uint256(12_345e6) * ALGEBRA_SHARE_BPS) / 10_000);
    }

    function test_DustRoundsInFavourOfGauge() public {
        HydrexFeeSplitter splitter = _deploy();
        // 1.5% of 1 wei rounds down to 0, so the gauge takes the whole wei.
        pool.pushFees(1, 0);

        splitter.split();

        assertEq(weth.balanceOf(address(gauge)), 1);
        assertEq(weth.balanceOf(algebra), 0);
    }

    function test_SplitAndClaimForwardsToInternalBribe() public {
        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(1_000e18, 2_000e6);

        splitter.splitAndClaim();

        assertEq(weth.balanceOf(bribe), 985e18, "bribe weth");
        assertEq(usdc.balanceOf(bribe), 1_970e6, "bribe usdc");
        assertEq(weth.balanceOf(algebra), 15e18);
        assertEq(gauge.claimCount(), 1);
    }

    function test_SplitAndClaimStillSplitsWhenGaugeClaimReverts() public {
        HydrexFeeSplitter splitter = _deploy();
        gauge.setClaimReverts(true);
        pool.pushFees(1_000e18, 0);

        splitter.splitAndClaim();

        // Split completed; only the downstream bribe forward was skipped.
        assertEq(weth.balanceOf(address(gauge)), 985e18);
        assertEq(weth.balanceOf(algebra), 15e18);
        assertEq(weth.balanceOf(bribe), 0);
    }

    function test_SplitSendsEverythingToPrimaryWhenSecondaryShareIsZero() public {
        HydrexFeeSplitter splitter = _deploy();
        factory.setDefaultSecondaryShareBps(0);

        pool.pushFees(1_000e18, 0);
        splitter.split();

        assertEq(weth.balanceOf(address(gauge)), 1_000e18, "no fees stranded");
        assertEq(weth.balanceOf(algebra), 0);
        assertEq(weth.balanceOf(address(splitter)), 0);
    }

    /* -------------------------- configuration ------------------------- */

    function test_FactoryOwnerRetargetsAlgebraForEveryPoolAtOnce() public {
        HydrexFeeSplitter splitterA = _deploy();

        MockAlgebraPool poolB = new MockAlgebraPool(address(weth), address(usdc), algebraFactory);
        MockGauge gaugeB = new MockGauge(address(poolB), bribe);
        voter.registerGauge(address(poolB), address(gaugeB));
        HydrexFeeSplitter splitterB = HydrexFeeSplitter(factory.createSplitter(address(poolB)));

        address newAlgebra = makeAddr("newAlgebra");
        factory.setDefaultSecondaryRecipient(newAlgebra);

        assertEq(splitterA.secondaryRecipient(), newAlgebra);
        assertEq(splitterB.secondaryRecipient(), newAlgebra);
    }

    function test_FactoryOwnerRepricesShareForEveryPoolAtOnce() public {
        HydrexFeeSplitter splitter = _deploy();
        factory.setDefaultSecondaryShareBps(500); // 5%

        pool.pushFees(1_000e18, 0);
        splitter.split();

        assertEq(weth.balanceOf(algebra), 50e18);
        assertEq(weth.balanceOf(address(gauge)), 950e18);
    }

    function test_PerSplitterOverrideBeatsFactoryDefault() public {
        HydrexFeeSplitter splitter = _deploy();

        address[] memory targets = new address[](1);
        targets[0] = address(splitter);
        factory.setSecondaryShareOverrides(targets, 1_000); // 10% for this pool only

        factory.setDefaultSecondaryShareBps(300);
        assertEq(splitter.secondaryShareBps(), 1_000);

        factory.clearOverrides(targets);
        assertEq(splitter.secondaryShareBps(), 300, "back to inheriting");

        // Zero is the sentinel for "inherit", so it cannot pin a 0% share.
        factory.setSecondaryShareOverrides(targets, 1_000);
        factory.setSecondaryShareOverrides(targets, 0);
        assertEq(splitter.secondaryShareBps(), 300, "zero restores inheritance");
    }

    function test_PrimaryRecipientOverrideRedirectsGaugeShare() public {
        HydrexFeeSplitter splitter = _deploy();
        address partnerVault = makeAddr("partnerVault");

        address[] memory targets = new address[](1);
        targets[0] = address(splitter);
        factory.setPrimaryRecipientOverrides(targets, partnerVault);

        pool.pushFees(1_000e18, 0);
        splitter.splitAndClaim();

        assertEq(weth.balanceOf(partnerVault), 985e18);
        assertEq(weth.balanceOf(address(gauge)), 0);
        assertEq(gauge.claimCount(), 0, "no point claiming a gauge that got nothing");
    }

    function test_ShareIsCappedAtMax() public {
        vm.expectRevert(HydrexFeeSplitterFactory.ShareTooHigh.selector);
        factory.setDefaultSecondaryShareBps(2_001);

        HydrexFeeSplitter splitter = _deploy();
        address[] memory targets = new address[](1);
        targets[0] = address(splitter);
        vm.expectRevert(HydrexFeeSplitter.ShareTooHigh.selector);
        factory.setSecondaryShareOverrides(targets, 2_001);
    }

    function test_OnlyFactoryOwnerCanConfigureSplitter() public {
        HydrexFeeSplitter splitter = _deploy();

        vm.prank(keeper);
        vm.expectRevert(HydrexFeeSplitter.NotFactoryOwner.selector);
        splitter.setSecondaryRecipientOverride(keeper);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        factory.setDefaultSecondaryShareBps(0);
    }

    function test_OwnershipTransferMovesSplitterControlToo() public {
        HydrexFeeSplitter splitter = _deploy();
        address newOwner = makeAddr("newOwner");

        factory.transferOwnership(newOwner);
        vm.prank(newOwner);
        factory.acceptOwnership();

        vm.prank(newOwner);
        splitter.setSecondaryRecipientOverride(newOwner);
        assertEq(splitter.secondaryRecipient(), newOwner);

        vm.prank(owner);
        vm.expectRevert(HydrexFeeSplitter.NotFactoryOwner.selector);
        splitter.setSecondaryRecipientOverride(owner);
    }

    function test_FactoryRejectsConfiguringForeignSplitter() public {
        address[] memory targets = new address[](1);
        targets[0] = makeAddr("foreign");

        vm.expectRevert(
            abi.encodeWithSelector(HydrexFeeSplitterFactory.NotASplitter.selector, makeAddr("foreign"))
        );
        factory.setPrimaryRecipientOverrides(targets, keeper);
    }

    /* ------------------------------ rescue ---------------------------- */

    function test_RescueRecoversStrayToken() public {
        HydrexFeeSplitter splitter = _deploy();
        MockToken stray = new MockToken("Stray", "STRAY", 18);
        stray.mint(address(splitter), 5e18);

        factory.rescueFromSplitter(address(splitter), address(stray), owner);
        assertEq(stray.balanceOf(owner), 5e18);
    }

    function test_RescueNativeRecoversForceSentEth() public {
        HydrexFeeSplitter splitter = _deploy();

        // No `receive()`, so ETH can only arrive force-sent; `deal` reproduces that end state.
        vm.deal(address(splitter), 3 ether);
        assertEq(address(splitter).balance, 3 ether);

        address recipient = makeAddr("ethRecipient");
        uint256 amount = factory.rescueNativeFromSplitter(address(splitter), recipient);

        assertEq(amount, 3 ether);
        assertEq(recipient.balance, 3 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_RescueNativeIsOwnerOnlyAndRevertsWhenEmpty() public {
        HydrexFeeSplitter splitter = _deploy();

        vm.prank(keeper);
        vm.expectRevert(HydrexFeeSplitter.NotFactoryOwner.selector);
        splitter.rescueNative(keeper);

        vm.expectRevert(HydrexFeeSplitter.NothingToRescue.selector);
        splitter.rescueNative(makeAddr("ethRecipient"));

        vm.deal(address(splitter), 1 ether);
        vm.expectRevert(HydrexFeeSplitter.ZeroAddress.selector);
        splitter.rescueNative(address(0));
    }

    function test_RescueNativeRevertsWhenRecipientRejectsEth() public {
        HydrexFeeSplitter splitter = _deploy();
        vm.deal(address(splitter), 1 ether);

        // The pool mock has no `receive()`, so it rejects plain ETH transfers.
        vm.expectRevert(HydrexFeeSplitter.NativeTransferFailed.selector);
        splitter.rescueNative(address(pool));

        assertEq(address(splitter).balance, 1 ether, "eth stays put on failure");
    }

    function test_FactoryRescuesItsOwnForceSentEth() public {
        vm.deal(address(factory), 2 ether);
        address recipient = makeAddr("ethRecipient");

        uint256 amount = factory.rescueNative(recipient);

        assertEq(amount, 2 ether);
        assertEq(recipient.balance, 2 ether);
        assertEq(address(factory).balance, 0);

        vm.expectRevert(HydrexFeeSplitterFactory.NothingToRescue.selector);
        factory.rescueNative(recipient);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        factory.rescueNative(keeper);
    }

    function test_FactoryHasNoReceiveSoEthCannotBeSentNormally() public {
        vm.deal(address(this), 1 ether);

        (bool okFactory, ) = address(factory).call{value: 1 ether}("");
        assertFalse(okFactory, "factory rejects plain ETH");

        HydrexFeeSplitter splitter = _deploy();
        (bool okSplitter, ) = address(splitter).call{value: 1 ether}("");
        assertFalse(okSplitter, "splitter rejects plain ETH");
    }

    function test_RescueIsOwnerOnly() public {
        HydrexFeeSplitter splitter = _deploy();
        vm.prank(keeper);
        vm.expectRevert(HydrexFeeSplitter.NotFactoryOwner.selector);
        splitter.rescue(address(weth), keeper);
    }

    /* ------------------------------- fuzz ----------------------------- */

    function testFuzz_SplitConservesValueAndRespectsShare(uint128 amount0, uint128 amount1, uint16 shareBps) public {
        shareBps = uint16(bound(shareBps, 0, factory.MAX_SECONDARY_SHARE_BPS()));
        factory.setDefaultSecondaryShareBps(shareBps);

        HydrexFeeSplitter splitter = _deploy();
        pool.pushFees(amount0, amount1);

        (uint256 p0, uint256 s0, uint256 p1, uint256 s1) = splitter.split();

        assertEq(p0 + s0, uint256(amount0), "token0 conserved");
        assertEq(p1 + s1, uint256(amount1), "token1 conserved");
        assertEq(s0, (uint256(amount0) * shareBps) / 10_000);
        assertEq(s1, (uint256(amount1) * shareBps) / 10_000);
        assertEq(weth.balanceOf(address(splitter)), 0, "nothing left behind");
        assertEq(usdc.balanceOf(address(splitter)), 0, "nothing left behind");
    }
}
