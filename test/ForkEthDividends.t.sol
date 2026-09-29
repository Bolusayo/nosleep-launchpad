// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {EthDividendVault} from "../src/EthDividendVault.sol";
import {SplitterDeployer} from "../src/SplitterDeployer.sol";
import {IUniswapV2Router, IUniswapV2Factory} from "../src/interfaces/IUniswapV2Router.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice ETH dividends against the real Uniswap deployment.
///
/// The unit tests use MockV2Router, whose swap is a flat 1e-6 rate with no
/// slippage and no fee. Real Uniswap has both. This project has already been
/// caught twice by that gap -- the lpAmount discrepancy, and the graduation
/// front-run that only appeared against a real pair -- so the swap path gets
/// the same treatment before it ships.
///
/// Run:
///   forge test --match-path test/ForkEthDividends.t.sol -vv \
///     --fork-url https://rpc.mainnet.chain.robinhood.com
contract ForkEthDividendsTest is Test {
    address constant ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    SplitterDeployer internal splitterDeployer;

    address internal creator = makeAddr("creator");
    address internal feeTo = makeAddr("feeTo");
    address internal marketing = makeAddr("marketing");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal seller = makeAddr("seller");

    uint256 internal constant SUPPLY = 1_000_000_000;

    BondingCurve internal curve;
    MemeToken internal token;
    uint256 internal QT;

    function setUp() public {
        require(block.chainid == 4663, "must run with --fork-url on Robinhood Chain mainnet");
        require(ROUTER.code.length > 0, "no router code on fork");

        splitterDeployer = new SplitterDeployer();

        // Taxed token, ETH dividend mode: 40% liquidity, 10% burn,
        // 20% marketing, 30% dividends.
        curve = new BondingCurve(
            "Payout",
            "PAY",
            SUPPLY,
            creator,
            feeTo,
            0,
            ROUTER,
            address(this),
            300, // 3% buy tax
            1000, // 10% sell tax
            365,
            marketing,
            4000,
            1000,
            2000,
            3000,
            address(splitterDeployer),
            FeeSplitter.DividendMode.Eth
        );

        token = curve.token();
        QT = curve.QUOTE_TARGET();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(seller, 1000 ether);
    }

    /// Buy on the curve, graduate, then generate tax with a real sell.
    function _graduateAndAccrueTax() internal returns (FeeSplitter s, EthDividendVault v) {
        // A fraction of the target, so alice is still holding when the
        // dividend lands. Anything at or above QT would graduate the curve
        // on its own -- the partial-fill cap refunds the excess -- and the
        // second buy would then revert AlreadyGraduated.
        vm.prank(alice);
        curve.buy{value: QT / 4}(0);
        assertFalse(curve.graduated(), "alice must not finish the curve alone");

        vm.prank(bob);
        curve.buy{value: QT * 10}(0);
        assertTrue(curve.graduated(), "bob completes it");

        s = curve.splitter();
        v = EthDividendVault(payable(curve.dividendVault()));
        require(address(s) != address(0), "no splitter");
        require(address(v) != address(0), "no vault");

        // A real sell into the real pair: taxed at 1000 bps to the splitter.
        uint256 amount = token.balanceOf(bob) / 4;
        vm.prank(bob);
        token.transfer(address(this), amount);

        address pair = token.dexPair();
        token.transfer(pair, amount);
    }

    // -----------------------------------------------------------------

    function test_Fork_EthModeWiredAtGraduation() public {
        (FeeSplitter s, EthDividendVault v) = _graduateAndAccrueTax();

        assertEq(uint8(s.dividendMode()), uint8(FeeSplitter.DividendMode.Eth), "splitter is in ETH mode");
        assertEq(s.dividendVault(), address(v), "splitter points at the vault");
        assertEq(token.dividendVault(), address(v), "token points at the vault too");
        assertEq(address(v.token()), address(token), "vault knows its token");
        assertTrue(token.taxExempt(address(v)), "vault is tax exempt");
    }

    /// The whole path: tax accrues, is split, sold for ETH, and lands in the
    /// vault as ETH rather than tokens.
    function test_Fork_DividendTrancheBecomesEth() public {
        (FeeSplitter s, EthDividendVault v) = _graduateAndAccrueTax();

        assertGt(token.balanceOf(address(s)), 0, "splitter collected tax");

        s.process();
        uint256 pool = s.dividendPool();
        assertGt(pool, 0, "dividend tranche allocated");

        uint256 ethBefore = address(v).balance;
        uint256 tokensBefore = token.balanceOf(address(v));

        s.payDividends(0);

        uint256 gained = address(v).balance - ethBefore;

        console.log("--- ETH dividends (real Uniswap) ---");
        console.log("dividend tranche (tokens)", pool);
        console.log("ETH delivered to vault   ", gained);
        console.log("vault token balance      ", token.balanceOf(address(v)));

        assertGt(gained, 0, "vault received real ETH");
        assertEq(token.balanceOf(address(v)), tokensBefore, "and no tokens");
        assertEq(v.totalDeposited(), gained, "recorded exactly what arrived");
    }

    /// A holder who held through the deposit can claim real ETH.
    function test_Fork_HolderClaimsRealEth() public {
        (FeeSplitter s, EthDividendVault v) = _graduateAndAccrueTax();

        s.process();
        s.payDividends(0);

        uint256 owed = v.pending(alice);
        assertGt(owed, 0, "alice is owed ETH");

        uint256 before = alice.balance;
        vm.prank(alice);
        v.claim();

        uint256 received = alice.balance - before;

        console.log("--- holder claim ---");
        console.log("alice token balance", token.balanceOf(alice));
        console.log("alice owed         ", owed);
        console.log("alice received     ", received);

        assertEq(received, owed, "received exactly what was pending");
        assertEq(v.pending(alice), 0, "nothing left after claiming");
    }

    /// The vault must never owe more ETH than it holds, with real amounts.
    function test_Fork_VaultStaysSolvent() public {
        (FeeSplitter s, EthDividendVault v) = _graduateAndAccrueTax();

        s.process();
        s.payDividends(0);

        uint256 owed = v.pending(alice) + v.pending(bob) + v.pending(creator) + v.pending(address(this));

        console.log("vault balance", address(v).balance);
        console.log("total owed   ", owed);

        assertLe(owed, address(v).balance, "cannot owe more than it holds");
    }

    /// The tax collector is the splitter, and the vault excludes it. That
    /// coupling is what keeps the vault solvent -- tax landing on an
    /// unsettled, non-excluded holder would inflate its claim.
    function test_Fork_TaxCollectorIsExcluded() public {
        (FeeSplitter s, EthDividendVault v) = _graduateAndAccrueTax();

        assertEq(token.taxCollector(), address(s), "tax goes to the splitter");
        assertTrue(v.excluded(address(s)), "and the splitter earns no dividends");
        assertEq(v.pending(address(s)), 0, "confirmed");
    }

    /// Real slippage: the cap limits one call to a slice of the pool, and the
    /// remainder waits rather than being sold into a worse price.
    function test_Fork_SwapCapHoldsAgainstRealReserves() public {
        (FeeSplitter s,) = _graduateAndAccrueTax();

        s.process();

        uint256 pool = s.dividendPool();
        uint256 cap = s.swapCap();

        console.log("dividend pool", pool);
        console.log("swap cap     ", cap);

        assertGt(cap, 0, "cap reads the real pair's reserves");

        s.payDividends(0);

        if (pool > cap) {
            assertEq(s.dividendPool(), pool - cap, "only the cap was sold");
        } else {
            assertEq(s.dividendPool(), 0, "the whole tranche fitted under the cap");
        }
    }

    /// Anyone can trigger the payout -- it must not be owner-gated, or the
    /// dividends would depend on us staying online.
    function test_Fork_PayDividendsIsPermissionless() public {
        (FeeSplitter s, EthDividendVault v) = _graduateAndAccrueTax();

        s.process();

        vm.prank(seller);
        s.payDividends(0);

        assertGt(v.totalDeposited(), 0, "a stranger moved the dividends along");
    }

    receive() external payable {}
}
