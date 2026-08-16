// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {IUniswapV2Router, IUniswapV2Factory} from "../src/interfaces/IUniswapV2Router.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// Graduation against the REAL Uniswap V2 deployment on Robinhood Chain (4663),
/// not MockV2Router. Exists to answer two open questions from TODO.md:
///
///   1. MockV2Router returns an lpAmount ~100x smaller than the expected
///      geometric mean. Does the real router agree with sqrt(k) - MINIMUM_LIQUIDITY?
///   2. _registerPair was only ever tested against MockV2Factory. Real Uniswap
///      creates the pair inside addLiquidityETH via CREATE2. Does the
///      setDexPair-after-migration ordering still avoid taxing the pool seed?
///
/// Run with:
///   forge test --match-path test/ForkGraduation.t.sol -vv \
///     --fork-url https://rpc.mainnet.chain.robinhood.com
contract ForkGraduationTest is Test {
    // Verified on-chain: bytecode is canonical UniswapV2Router02, and WETH()
    // returns the WETH address below.
    address constant ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// Uniswap V2 permanently locks the first 1000 LP wei.
    uint256 constant MINIMUM_LIQUIDITY = 1000;

    address internal creator = makeAddr("creator");
    address internal feeTo = makeAddr("feeTo");
    address internal alice = makeAddr("alice");

    uint256 internal constant SUPPLY = 1_000_000_000;

    uint256 internal VQ;
    uint256 internal QT;

    function setUp() public {
        // Fail loudly rather than silently testing against a blank chain.
        require(block.chainid == 4663, "ForkGraduation: must run with --fork-url pointed at Robinhood Chain mainnet");
        require(ROUTER.code.length > 0, "ForkGraduation: no router code on fork");
        require(FACTORY.code.length > 0, "ForkGraduation: no factory code on fork");

        // Confirm the constants agree with each other on-chain before we rely on them.
        assertEq(IUniswapV2Router(ROUTER).WETH(), WETH, "router WETH mismatch");
        assertEq(IUniswapV2Router(ROUTER).factory(), FACTORY, "router factory mismatch");

        vm.deal(alice, 1000 ether);
    }

    function _newCurve() internal returns (BondingCurve c) {
        c = new BondingCurve(
            "Fault Line", "FAULT", SUPPLY, creator, feeTo, 0, ROUTER, address(this), 0, 0, 0, address(0), 0, 0, 0, 0
        );
        VQ = c.VIRTUAL_QUOTE();
        QT = c.QUOTE_TARGET();
    }

    function _newTaxedCurve() internal returns (BondingCurve c) {
        c = new BondingCurve(
            "Taxed",
            "TAX",
            SUPPLY,
            creator,
            feeTo,
            0,
            ROUTER,
            address(this),
            300,
            1000,
            365,
            makeAddr("marketing"),
            4000,
            1000,
            2000,
            3000
        );
        VQ = c.VIRTUAL_QUOTE();
        QT = c.QUOTE_TARGET();
    }

    // ---------------------------------------------------------------------
    // Question 1: is lpAmount the real geometric mean?
    // ---------------------------------------------------------------------

    function test_Fork_LpAmountMatchesGeometricMean() public {
        BondingCurve curve = _newCurve();
        MemeToken tok = curve.token();

        uint256 tokensForLp = (SUPPLY * 1e18 * 2000) / 10000; // 20% of supply
        uint256 ethForLp = QT;

        vm.prank(alice);
        curve.buy{value: QT * 10}(0);
        assertTrue(curve.graduated(), "must graduate");

        address pair = IUniswapV2Factory(FACTORY).getPair(address(tok), WETH);
        assertTrue(pair != address(0), "real factory must have created the pair");

        uint256 recorded = curve.lpAmount();
        uint256 burned = IERC20Min(pair).balanceOf(curve.BURN());
        uint256 lpTotal = IERC20Min(pair).totalSupply();

        // Uniswap V2 first-mint: sqrt(a*b) - MINIMUM_LIQUIDITY
        uint256 expected = _sqrt(ethForLp * tokensForLp) - MINIMUM_LIQUIDITY;

        console.log("--- LP accounting (real Uniswap) ---");
        console.log("ethForLp     ", ethForLp);
        console.log("tokensForLp  ", tokensForLp);
        console.log("expected sqrt", expected);
        console.log("curve.lpAmount", recorded);
        console.log("burned at BURN", burned);
        console.log("pair totalSupply", lpTotal);

        assertEq(recorded, burned, "curve must record exactly what it burned");
        assertGt(burned, 0, "LP must exist");

        // totalSupply = burned + the 1000 wei Uniswap locks forever.
        assertEq(lpTotal, burned + MINIMUM_LIQUIDITY, "all LP except MINIMUM_LIQUIDITY must be burned");

        // Allow 0.1% drift for rounding; a 100x gap (the mock's behaviour) fails loudly.
        assertApproxEqRel(recorded, expected, 0.001e18, "lpAmount must equal the geometric mean");
    }

    /// Nobody keeps LP. Not the curve, not the creator, not the buyer.
    function test_Fork_NoOneHoldsLp() public {
        BondingCurve curve = _newCurve();
        MemeToken tok = curve.token();

        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        address pair = IUniswapV2Factory(FACTORY).getPair(address(tok), WETH);

        assertEq(IERC20Min(pair).balanceOf(address(curve)), 0, "curve holds no LP");
        assertEq(IERC20Min(pair).balanceOf(creator), 0, "creator holds no LP");
        assertEq(IERC20Min(pair).balanceOf(alice), 0, "buyer holds no LP");
        assertEq(IERC20Min(pair).balanceOf(ROUTER), 0, "router holds no LP");
    }

    // ---------------------------------------------------------------------
    // Where the raise actually lands
    // ---------------------------------------------------------------------

    /// The mock test asserted `address(router).balance == QT`. The real router
    /// is a pass-through: the ETH is wrapped and ends up in the PAIR as WETH.
    function test_Fork_PairHoldsRaiseAndSupply() public {
        BondingCurve curve = _newCurve();
        MemeToken tok = curve.token();

        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        address pair = IUniswapV2Factory(FACTORY).getPair(address(tok), WETH);

        uint256 pairWeth = IERC20Min(WETH).balanceOf(pair);
        uint256 pairTokens = tok.balanceOf(pair);

        console.log("--- pool reserves (real Uniswap) ---");
        console.log("pair WETH  ", pairWeth);
        console.log("pair tokens", pairTokens);

        assertEq(pairWeth, QT, "pool must hold the full raise as WETH");
        assertEq(pairTokens, (SUPPLY * 1e18 * 2000) / 10000, "pool must hold the LP token tranche");

        // The real router must not retain anything.
        assertEq(ROUTER.balance, 0, "router holds no ETH");
        assertEq(tok.balanceOf(ROUTER), 0, "router holds no tokens");
        assertEq(IERC20Min(WETH).balanceOf(ROUTER), 0, "router holds no WETH");

        // Neither must the curve.
        assertEq(address(curve).balance, 0, "curve holds no ETH");
        assertEq(tok.balanceOf(address(curve)), 0, "curve holds no tokens");
    }

    function test_Fork_GraduatesAtExactTarget() public {
        BondingCurve curve = _newCurve();

        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        assertTrue(curve.graduated());
        assertEq(curve.ethCollected(), QT, "must raise exactly the target");
        assertEq(curve.quoteReserve(), VQ + QT, "reserves must land on target");
    }

    // ---------------------------------------------------------------------
    // Question 2: CREATE2 pair registration + tax ordering
    // ---------------------------------------------------------------------

    function test_Fork_TaxedTokenRegistersRealPair() public {
        BondingCurve taxed = _newTaxedCurve();
        MemeToken tt = taxed.token();

        assertEq(tt.dexPair(), address(0), "no pair before graduation");
        assertTrue(tt.taxActive());

        vm.prank(alice);
        taxed.buy{value: QT * 10}(0);

        assertTrue(taxed.graduated());
        assertEq(taxed.ethCollected(), QT, "taxed token must still raise exactly the target");

        address registered = tt.dexPair();
        address actual = IUniswapV2Factory(FACTORY).getPair(address(tt), WETH);

        console.log("--- pair registration (real CREATE2) ---");
        console.log("registered on token", registered);
        console.log("factory getPair    ", actual);

        assertTrue(actual != address(0), "real factory must have created the pair");
        assertTrue(registered != address(0), "pair must be registered on the token");
        assertEq(registered, actual, "registered pair must be the real CREATE2 pair");

        assertTrue(tt.taxExempt(ROUTER), "router must be exempt");
    }

    /// The critical ordering property: the initial pool seed must NOT be taxed.
    /// If setDexPair ran before addLiquidityETH, the seed transfer would be
    /// treated as a sell and the pool would come up short.
    function test_Fork_PoolSeedIsNotTaxed() public {
        BondingCurve taxed = _newTaxedCurve();
        MemeToken tt = taxed.token();

        uint256 expectedTokens = (SUPPLY * 1e18 * 2000) / 10000;

        vm.prank(alice);
        taxed.buy{value: QT * 10}(0);

        address pair = IUniswapV2Factory(FACTORY).getPair(address(tt), WETH);

        uint256 pairTokens = tt.balanceOf(pair);
        uint256 pairWeth = IERC20Min(WETH).balanceOf(pair);

        console.log("--- taxed pool seed ---");
        console.log("expected tokens", expectedTokens);
        console.log("actual tokens  ", pairTokens);
        console.log("pair WETH      ", pairWeth);

        assertEq(pairTokens, expectedTokens, "tax must not skim the pool seed");
        assertEq(pairWeth, QT, "full raise must reach the pool");
        assertEq(tt.balanceOf(address(taxed)), 0, "curve keeps nothing");
    }

    function test_Fork_SplitterAndVaultWiredAgainstRealPair() public {
        BondingCurve taxed = _newTaxedCurve();
        MemeToken tt = taxed.token();

        vm.prank(alice);
        taxed.buy{value: QT * 10}(0);

        address s = address(taxed.splitter());
        address v = address(taxed.dividendVault());

        assertTrue(s != address(0), "splitter must exist");
        assertTrue(v != address(0), "vault must exist");
        assertEq(tt.taxCollector(), s, "tax must redirect to the splitter");
        assertEq(taxed.splitter().dividendVault(), v, "splitter must point at the vault");
        assertTrue(tt.taxExempt(s), "splitter must be exempt");
        assertTrue(tt.taxExempt(v), "vault must be exempt");
    }

    /// A real post-graduation sell into the real pool should be taxed.
    /// This is the behaviour the whole tax system exists for, and it has
    /// never been exercised against a real pair.
    function test_Fork_SellIntoRealPairIsTaxed() public {
        BondingCurve taxed = _newTaxedCurve();
        MemeToken tt = taxed.token();

        // Buy on the curve, then graduate.
        vm.prank(alice);
        taxed.buy{value: QT * 10}(0);

        address pair = tt.dexPair();
        uint256 aliceBal = tt.balanceOf(alice);
        assertGt(aliceBal, 0, "alice must hold tokens");

        uint256 collectorBefore = tt.balanceOf(tt.taxCollector());
        uint256 pairBefore = tt.balanceOf(pair);

        // Simulate a sell: transfer straight into the pair.
        uint256 sellAmount = aliceBal / 10;
        vm.prank(alice);
        tt.transfer(pair, sellAmount);

        uint256 collectorAfter = tt.balanceOf(tt.taxCollector());
        uint256 pairAfter = tt.balanceOf(pair);

        console.log("--- sell tax into real pair ---");
        console.log("sell amount     ", sellAmount);
        console.log("collector gained", collectorAfter - collectorBefore);
        console.log("pair gained     ", pairAfter - pairBefore);

        assertGt(collectorAfter, collectorBefore, "sell into the real pair must be taxed");
        assertEq(
            (pairAfter - pairBefore) + (collectorAfter - collectorBefore),
            sellAmount,
            "tax + delivered must equal the transfer"
        );
    }

    // ---------------------------------------------------------------------

    /// Babylonian sqrt, same as Uniswap V2's Math.sqrt.
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
