// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {SplitterDeployer} from "../src/SplitterDeployer.sol";
import {IUniswapV2Router, IUniswapV2Factory} from "../src/interfaces/IUniswapV2Router.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Graduation cannot be front-run by seeding the Uniswap pair.
///
/// The original hole: `_graduate` called `addLiquidityETH`, which quotes
/// against whatever reserves already exist. An attacker could create the
/// TOKEN/WETH pair, seed it with dust at an absurd price, and every
/// graduation attempt would then revert on the slippage floor -- permanently
/// blocking the launch, for the cost of a dust seed, with no admin anywhere
/// able to fix it. Loosening the floor was worse: the attacker would set the
/// opening price and skim the raise.
///
/// The fix has two halves:
///   1. the curve creates the pair itself, at construction, so there is
///      nothing left to front-run;
///   2. MemeToken refuses every transfer into that pair until the curve opens
///      it at graduation (PoolLocked), so the pair is provably empty on the
///      token side when the curve mints the opening position directly.
///
/// Run:
///   forge test --match-path test/ForkFrontrunGraduation.t.sol -vv \
///     --fork-url https://rpc.mainnet.chain.robinhood.com
contract ForkFrontrunGraduationTest is Test {
    address constant ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    SplitterDeployer internal splitterDeployer;

    address internal creator = makeAddr("creator");
    address internal feeTo = makeAddr("feeTo");
    address internal victim = makeAddr("victim");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant SUPPLY = 1_000_000_000;

    BondingCurve internal curve;
    MemeToken internal token;
    uint256 internal QT;

    function setUp() public {
        require(block.chainid == 4663, "must run with --fork-url on Robinhood Chain mainnet");
        require(ROUTER.code.length > 0, "no router code on fork");

        splitterDeployer = new SplitterDeployer();

        curve = new BondingCurve(
            "Fault Line",
            "FAULT",
            SUPPLY,
            creator,
            feeTo,
            0,
            ROUTER,
            address(this),
            0,
            0,
            0,
            address(0),
            0,
            0,
            0,
            0,
            address(splitterDeployer)
        );
        token = curve.token();
        QT = curve.QUOTE_TARGET();

        vm.deal(victim, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    // -----------------------------------------------------------------

    /// The pair exists before anyone can race for it, and belongs to the curve.
    function test_Fork_PairExistsFromConstruction() public view {
        address pair = IUniswapV2Factory(FACTORY).getPair(address(token), WETH);

        assertTrue(pair != address(0), "pair exists from construction");
        assertEq(pair, curve.lpToken(), "curve owns the pair it will seed");
        assertEq(token.dexPair(), pair, "token knows the pair");
        assertFalse(token.poolSeeded(), "pool starts locked");
        assertEq(IERC20Min(address(token)).balanceOf(pair), 0, "pair starts empty");
    }

    /// Creating the pair a second time is impossible.
    function test_Fork_AttackerCannotCreatePair() public {
        vm.prank(attacker);
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        IUniswapV2Factory(FACTORY).createPair(address(token), WETH);
    }

    /// Nor can an attacker who holds tokens put any into the pair.
    function test_Fork_AttackerCannotSeedPair() public {
        vm.prank(attacker);
        curve.buy{value: 0.5 ether}(0);
        assertGt(token.balanceOf(attacker), 0, "attacker holds tokens");

        address pair = curve.lpToken();

        // Direct transfer is refused.
        vm.prank(attacker);
        vm.expectRevert(); // MemeToken.PoolLocked
        token.transfer(pair, 1000e18);

        // And so is going through the router.
        vm.prank(attacker);
        IERC20Min(address(token)).approve(ROUTER, type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert();
        IUniswapV2Router(ROUTER).addLiquidityETH{value: 1 ether}(
            address(token), 1000e18, 0, 0, attacker, block.timestamp + 1
        );

        assertEq(IERC20Min(address(token)).balanceOf(pair), 0, "pair is still empty");
    }

    /// With the pair locked, graduation seeds it exactly as intended.
    function test_Fork_GraduationSucceedsDespiteAttempts() public {
        vm.prank(attacker);
        curve.buy{value: 0.5 ether}(0);

        vm.prank(attacker);
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        IUniswapV2Factory(FACTORY).createPair(address(token), WETH);

        vm.prank(victim);
        curve.buy{value: QT * 10}(0);
        assertTrue(curve.graduated(), "must graduate");

        address pair = curve.lpToken();
        uint256 expectedTokens = (SUPPLY * 1e18 * 2000) / 10000;

        console.log("--- pool after graduation ---");
        console.log("pair WETH  ", IERC20Min(WETH).balanceOf(pair));
        console.log("pair tokens", IERC20Min(address(token)).balanceOf(pair));

        assertEq(IERC20Min(WETH).balanceOf(pair), QT, "pool holds the full raise");
        // >= not ==: an earlier buy can leave a wei of curve rounding dust,
        // which ends up in the pool rather than stranded.
        assertGe(IERC20Min(address(token)).balanceOf(pair), expectedTokens, "pool holds at least the full tranche");
        assertLe(IERC20Min(address(token)).balanceOf(pair) - expectedTokens, 1e12, "and no more than rounding dust");
        assertEq(address(curve).balance, 0, "nothing stranded in the curve");
        assertEq(token.balanceOf(address(curve)), 0, "no tokens stranded in the curve");
        assertTrue(token.poolSeeded(), "pool is open after graduation");
    }

    /// Once seeded, the pair trades normally.
    function test_Fork_PairIsTradeableAfterGraduation() public {
        vm.prank(victim);
        curve.buy{value: QT * 10}(0);

        address pair = curve.lpToken();
        uint256 bal = token.balanceOf(victim);

        vm.prank(victim);
        token.transfer(pair, bal / 100);

        assertGt(
            IERC20Min(address(token)).balanceOf(pair), (SUPPLY * 1e18 * 2000) / 10000, "transfers into the pair work"
        );
    }

    /// Control: the ordinary path, with nobody interfering.
    function test_Fork_Control_NoFrontrun() public {
        vm.prank(victim);
        curve.buy{value: QT * 10}(0);

        address pair = curve.lpToken();
        assertEq(IERC20Min(WETH).balanceOf(pair), QT, "pool holds the full raise");
        assertEq(token.balanceOf(pair), (SUPPLY * 1e18 * 2000) / 10000, "pool holds the full tranche");
        assertEq(address(curve).balance, 0, "curve holds no ETH");
        assertEq(token.balanceOf(address(curve)), 0, "curve holds no tokens");
    }
}
