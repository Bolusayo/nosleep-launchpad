// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {MockV2Router, MockV2Pair, MockWETH} from "../src/mocks/MockV2Router.sol";
import {IUniswapV2Router} from "../src/interfaces/IUniswapV2Router.sol";

contract FeeSplitterTest is Test {
    FeeSplitter internal splitter;
    MemeToken internal token;
    MockV2Router internal router;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal marketing = makeAddr("marketing");
    address internal pair;

    uint256 internal constant SUPPLY = 1_000_000_000;
    uint256 internal constant THRESHOLD = 1000e18;

    function setUp() public {
        router = new MockV2Router();
        token = new MemeToken("Taxed", "TAX", SUPPLY, curve, creator, 300, 1000, 365);

        // UI defaults: 40 / 10 / 20 / 30
        splitter = new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            marketing,
            4000,
            1000,
            2000,
            3000,
            THRESHOLD,
            FeeSplitter.BurnMode.Threshold
        );
        // addLiquidity() sizes its swap against the pair's reserves, so these
        // tests need a real pool rather than a token with no market. Mirrors
        // what graduation leaves behind: pair created, pool seeded, reserves
        // in place.
        pair = router.factoryContract().createPair(address(token), router.WETH());

        vm.startPrank(curve);
        token.setDexPair(pair);
        token.setPoolSeeded();
        token.transfer(pair, 100_000_000e18);
        vm.stopPrank();

        vm.deal(address(this), 100 ether);
        MockWETH(payable(router.WETH())).deposit{value: 10 ether}();
        MockWETH(payable(router.WETH())).transfer(pair, 10 ether);
        MockV2Pair(pair).mint(address(this));
    }

    function _fund(uint256 amount) internal {
        vm.prank(curve);
        token.transfer(address(splitter), amount);
    }

    function test_SplitMustTotalTenThousand() public {
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.SplitMustBeTotal.selector, uint256(9000)));
        new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            marketing,
            4000,
            1000,
            2000,
            2000,
            THRESHOLD,
            FeeSplitter.BurnMode.Threshold
        );
    }

    function test_RevertWhen_MarketingIsZero() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            address(0),
            4000,
            1000,
            2000,
            3000,
            THRESHOLD,
            FeeSplitter.BurnMode.Threshold
        );
    }

    function test_RevertWhen_BelowThreshold() public {
        _fund(500e18);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.BelowThreshold.selector, uint256(500e18), THRESHOLD));
        splitter.process();
    }

    function test_BurnsCorrectShare() public {
        _fund(10_000e18);
        splitter.process();

        // 10% of 10,000 = 1,000 burned
        assertEq(token.balanceOf(splitter.BURN()), 1_000e18);
    }

    function test_DividendPoolAccrues() public {
        _fund(10_000e18);
        splitter.process();

        // 30% of 10,000 = 3,000
        assertEq(splitter.dividendPool(), 3_000e18);
    }

    /// Processing twice must not re-split the dividend pool.
    function test_DividendPoolNotDoubleCounted() public {
        _fund(10_000e18);
        splitter.process();
        assertEq(splitter.dividendPool(), 3_000e18);

        _fund(10_000e18);
        splitter.process();
        assertEq(splitter.dividendPool(), 6_000e18, "second pass must add, not compound");

        assertEq(token.balanceOf(splitter.BURN()), 2_000e18);
    }

    function test_ProcessIsPermissionless() public {
        _fund(10_000e18);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        splitter.process();

        assertEq(splitter.dividendPool(), 3_000e18);
    }

    /// The four shares must always account for the whole balance.
    function testFuzz_SplitConservesTotal(uint256 amount) public {
        amount = bound(amount, THRESHOLD, 100_000_000e18);
        _fund(amount);

        splitter.process();

        uint256 burned = token.balanceOf(splitter.BURN());
        uint256 dividends = splitter.dividendPool();
        uint256 held = token.balanceOf(address(splitter));

        assertEq(burned + held, amount, "nothing may vanish");
        assertLe(dividends, held, "dividend pool cannot exceed what's held");
    }

    function test_MarketingSwapPaysEth() public {
        // The mock needs ETH to pay out with.
        vm.deal(address(router), 100 ether);

        _fund(10_000e18);
        splitter.process();

        // 20% of 10,000 = 2,000 tokens, at the mock's 1e-6 rate = 0.002 ETH
        assertEq(splitter.marketingPool(), 2_000e18);

        uint256 before = marketing.balance;
        splitter.payMarketing(0);

        assertEq(marketing.balance - before, 2_000e18 / 1e6);
        assertEq(splitter.marketingPool(), 0, "pool must be drained");
    }

    function test_RevertWhen_NothingToPay() public {
        vm.expectRevert(FeeSplitter.NothingAllocated.selector);
        splitter.payMarketing(0);
    }

    /// A failing swap must not lose the allocation.
    function test_FailedSwapRevertsCleanly() public {
        vm.deal(address(router), 100 ether);
        _fund(10_000e18);
        splitter.process();

        router.setShouldFail(true);

        vm.expectRevert();
        splitter.payMarketing(0);

        // State unchanged — the whole call reverted.
        assertEq(splitter.marketingPool(), 2_000e18);
    }

    function test_PayMarketingIsPermissionless() public {
        vm.deal(address(router), 100 ether);
        _fund(10_000e18);
        splitter.process();

        vm.prank(makeAddr("stranger"));
        splitter.payMarketing(0);

        assertGt(marketing.balance, 0);
    }

    function test_AddLiquidityPairsAndBurnsLp() public {
        vm.deal(address(router), 100 ether);
        _fund(10_000e18);
        splitter.process();

        // 40% of 10,000 = 4,000 tokens allocated to liquidity
        assertEq(splitter.liquidityPool(), 4_000e18);

        address lp = address(router.lp());
        uint256 burnedBefore = MemeToken(lp).balanceOf(splitter.BURN());

        splitter.addLiquidity(0);

        assertEq(splitter.liquidityPool(), 0, "allocation must be drained");
        assertGt(MemeToken(lp).balanceOf(splitter.BURN()), burnedBefore, "LP must be minted to the burn address");
    }

    function test_RevertWhen_NoLiquidityAllocated() public {
        vm.expectRevert(FeeSplitter.NothingAllocated.selector);
        splitter.addLiquidity(0);
    }

    function test_FailedLiquiditySwapRevertsCleanly() public {
        vm.deal(address(router), 100 ether);
        _fund(10_000e18);
        splitter.process();

        router.setShouldFail(true);

        vm.expectRevert();
        splitter.addLiquidity(0);

        assertEq(splitter.liquidityPool(), 4_000e18, "allocation must survive");
    }

    /// Full cycle: split, pay marketing, add liquidity. Nothing stranded
    /// except the dividend pool, which is held deliberately.
    function test_FullCycleLeavesOnlyDividends() public {
        vm.deal(address(router), 100 ether);
        _fund(10_000e18);

        splitter.process();
        splitter.payMarketing(0);
        splitter.addLiquidity(0);

        assertEq(splitter.liquidityPool(), 0);
        assertEq(splitter.marketingPool(), 0);
        assertEq(splitter.dividendPool(), 3_000e18);

        // Burned 10%, dividends held, the rest swapped or paired away.
        assertEq(token.balanceOf(splitter.BURN()), 1_000e18);
    }

    function test_WeeklyModeHoldsBurnUntilDue() public {
        FeeSplitter weekly = new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            marketing,
            4000,
            1000,
            2000,
            3000,
            THRESHOLD,
            FeeSplitter.BurnMode.Weekly
        );

        assertFalse(weekly.burnDue(), "first window has not elapsed");

        vm.prank(curve);
        token.transfer(address(weekly), 10_000e18);
        weekly.process();

        assertEq(weekly.pendingBurn(), 1_000e18, "held for the next window");
        assertEq(token.balanceOf(weekly.BURN()), 0, "nothing burned yet");
    }

    function test_WeeklyBurnReleasesAfterInterval() public {
        FeeSplitter weekly = new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            marketing,
            4000,
            1000,
            2000,
            3000,
            THRESHOLD,
            FeeSplitter.BurnMode.Weekly
        );

        vm.prank(curve);
        token.transfer(address(weekly), 10_000e18);
        weekly.process(); // consumes the first window

        vm.prank(curve);
        token.transfer(address(weekly), 10_000e18);
        weekly.process(); // held

        vm.expectRevert(FeeSplitter.BurnNotDue.selector);
        weekly.executeBurn();

        vm.warp(block.timestamp + 8 days);
        assertTrue(weekly.burnDue());

        weekly.executeBurn();
        assertEq(weekly.pendingBurn(), 0);
        assertEq(token.balanceOf(weekly.BURN()), 2_000e18);
    }
}
