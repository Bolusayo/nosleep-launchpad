// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EthDividendVault} from "../src/EthDividendVault.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {MockV2Router, MockV2Pair, MockWETH} from "../src/mocks/MockV2Router.sol";
import {IUniswapV2Router} from "../src/interfaces/IUniswapV2Router.sol";

/// @notice ETH dividends: holders claim in ETH rather than in the token.
///
/// The accounting mirrors DividendVault exactly, so these tests deliberately
/// mirror DividendVault's -- including the late-entrant properties, which are
/// the reason that contract was rewritten in the first place. A second vault
/// with the same bug would be worse than no second vault.
contract EthDividendVaultTest is Test {
    EthDividendVault internal vault;
    MemeToken internal token;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal splitter = makeAddr("splitter");
    address internal pair = makeAddr("pair");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SUPPLY = 1_000_000_000;
    uint256 internal constant DEPOSIT = 1 ether;

    function setUp() public {
        token = new MemeToken("Div", "DIV", SUPPLY, curve, creator, 300, 1000, 365);

        vm.startPrank(curve);
        token.setDexPair(pair);
        token.setPoolSeeded();
        vm.stopPrank();

        address[] memory ex = new address[](1);
        ex[0] = pair;
        vault = new EthDividendVault(token, splitter, ex);

        vm.prank(curve);
        token.setDividendVault(address(vault));

        // In production the tax collector is the splitter, which the vault
        // excludes. Leaving it as the curve -- which is NOT excluded -- means
        // tax tokens land on an unsettled holder after a deposit and inflate
        // its claim. That is a genuine property of the accounting (see
        // SPEC): the collector must be excluded, or the vault over-owes.
        vm.prank(curve);
        token.setTaxCollector(splitter);

        vm.startPrank(curve);
        token.transfer(alice, 100_000_000e18); // 10%
        token.transfer(bob, 100_000_000e18); // 10%
        token.transfer(pair, 500_000_000e18); // 50% -- excluded
        vm.stopPrank();

        vm.deal(splitter, 100 ether);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(splitter);
        vault.depositEth{value: amount}();
    }

    // -----------------------------------------------------------------
    // Basics
    // -----------------------------------------------------------------

    function test_OnlySplitterCanDeposit() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EthDividendVault.NotSplitter.selector);
        vault.depositEth{value: 1 ether}();
    }

    function test_RevertWhen_DepositingNothing() public {
        vm.prank(splitter);
        vm.expectRevert(EthDividendVault.NothingSent.selector);
        vault.depositEth{value: 0}();
    }

    function test_HoldersClaimEthProportionally() public {
        _deposit(DEPOSIT);

        uint256 aliceOwed = vault.pending(alice);
        uint256 bobOwed = vault.pending(bob);

        assertGt(aliceOwed, 0, "alice is owed something");
        assertEq(aliceOwed, bobOwed, "equal holders, equal share");

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claim();

        assertEq(alice.balance - before, aliceOwed, "paid in ETH, not tokens");
        assertEq(vault.pending(alice), 0, "nothing left after claiming");
    }

    function test_ExcludedAddressGetsNothing() public {
        _deposit(DEPOSIT);
        assertEq(vault.pending(pair), 0, "the pool earns no dividends");
        assertEq(vault.pending(splitter), 0, "the splitter earns none either");
    }

    function test_RevertWhen_NothingToClaim() public {
        vm.prank(carol);
        vm.expectRevert(EthDividendVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_SecondDepositAccrues() public {
        _deposit(DEPOSIT);
        uint256 afterFirst = vault.pending(alice);

        _deposit(DEPOSIT);
        assertApproxEqAbs(vault.pending(alice), afterFirst * 2, 2, "two deposits, twice the claim");
    }

    // -----------------------------------------------------------------
    // Late entrants -- the property DividendVault was rewritten for
    // -----------------------------------------------------------------

    /// A wallet that held nothing when the dividend was deposited has earned
    /// nothing from it.
    function test_LateEntrantEarnsNothingFromPriorDeposits() public {
        _deposit(DEPOSIT);

        assertEq(token.balanceOf(carol), 0, "carol holds nothing at deposit time");

        // Carol buys from the pool afterwards.
        vm.prank(pair);
        token.transfer(carol, 100_000_000e18);

        assertGt(token.balanceOf(carol), 0, "carol now holds tokens");
        assertEq(vault.pending(carol), 0, "but earned nothing from the earlier deposit");
    }

    /// Same, with the tokens coming from an already-eligible holder so
    /// eligible supply does not change. Isolates the rewardDebt half of the
    /// original bug from the eligible-supply half.
    function test_LateEntrantFromEligibleHolderEarnsNothing() public {
        _deposit(DEPOSIT);

        uint256 eligibleBefore = vault.eligibleSupply();

        vm.prank(curve);
        token.transfer(carol, 50_000_000e18);

        assertEq(vault.eligibleSupply(), eligibleBefore, "eligible supply unchanged");
        assertEq(vault.pending(carol), 0, "still earned nothing");
    }

    /// The vault must never owe more ETH than it holds.
    function test_TotalPendingNeverExceedsBalance() public {
        _deposit(DEPOSIT);

        vm.prank(pair);
        token.transfer(carol, 400_000_000e18);

        uint256 owed = vault.pending(alice) + vault.pending(bob) + vault.pending(carol) + vault.pending(curve);

        console.log("vault balance", address(vault).balance);
        console.log("total owed   ", owed);

        assertLe(owed, address(vault).balance, "cannot owe more ETH than it holds");
    }

    /// A holder who held throughout can always claim, whoever claims first.
    function test_HonestHolderCanAlwaysClaim() public {
        _deposit(DEPOSIT);

        vm.prank(pair);
        token.transfer(carol, 400_000_000e18);

        if (vault.pending(carol) > 0) {
            vm.prank(carol);
            vault.claim();
        }
        vm.prank(alice);
        vault.claim();

        uint256 bobOwed = vault.pending(bob);
        assertGt(bobOwed, 0, "bob is still owed");

        uint256 before = bob.balance;
        vm.prank(bob);
        vault.claim();
        assertEq(bob.balance - before, bobOwed, "and receives it");
    }

    /// Selling before claiming must not create ETH from nothing.
    function test_SellingBanksWhatWasEarned() public {
        _deposit(DEPOSIT);
        uint256 owed = vault.pending(alice);

        // Cache the balance first: vm.prank applies to the next call, and an
        // inline balanceOf() would consume it, leaving transfer() to run as
        // the test contract.
        uint256 all = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(pair, all); // sell everything

        assertEq(token.balanceOf(alice), 0, "alice holds nothing now");
        assertApproxEqAbs(vault.pending(alice), owed, 2, "what she earned is banked, not lost");

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claim();
        assertApproxEqAbs(alice.balance - before, owed, 2, "and still claimable");
    }

    function testFuzz_ClaimNeverExceedsDeposited(uint96 a, uint96 b) public {
        vm.assume(uint256(a) > 0.0001 ether && uint256(b) > 0.0001 ether);
        vm.deal(splitter, uint256(a) + uint256(b));

        _deposit(a);
        _deposit(b);

        uint256 total = uint256(a) + uint256(b);

        if (vault.pending(alice) > 0) {
            vm.prank(alice);
            vault.claim();
        }
        if (vault.pending(bob) > 0) {
            vm.prank(bob);
            vault.claim();
        }

        assertLe(vault.totalClaimed(), total, "cannot pay out more than came in");
        assertEq(vault.totalDeposited(), total, "deposits recorded exactly");
    }

    /// Stray ETH must not move anyone's entitlement -- otherwise anyone could
    /// shift every holder's balance by sending dust.
    function test_StrayEthDoesNotAffectAccounting() public {
        _deposit(DEPOSIT);
        uint256 owedBefore = vault.pending(alice);

        vm.deal(carol, 5 ether);
        vm.prank(carol);
        (bool ok,) = address(vault).call{value: 5 ether}("");
        assertTrue(ok, "plain transfers are accepted");

        assertEq(vault.pending(alice), owedBefore, "but credit nobody");
        assertEq(vault.totalDeposited(), DEPOSIT, "and are not counted as a deposit");
    }
}

/// @notice The splitter side: does the dividend tranche actually become ETH?
contract FeeSplitterEthModeTest is Test {
    FeeSplitter internal splitter;
    MemeToken internal token;
    MockV2Router internal router;
    address internal pair;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal marketing = makeAddr("marketing");
    address internal alice = makeAddr("alice");

    uint256 internal constant SUPPLY = 1_000_000_000;
    uint256 internal constant THRESHOLD = 1000e18;

    function setUp() public {
        router = new MockV2Router();
        token = new MemeToken("Taxed", "TAX", SUPPLY, curve, creator, 300, 1000, 365);

        splitter = new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            marketing,
            4000,
            1000,
            2000,
            3000,
            THRESHOLD,
            FeeSplitter.BurnMode.Threshold,
            FeeSplitter.DividendMode.Eth
        );

        pair = router.factoryContract().createPair(address(token), router.WETH());

        vm.startPrank(curve);
        token.setDexPair(pair);
        token.setPoolSeeded();
        token.transfer(pair, 100_000_000e18);
        vm.stopPrank();

        // Seed the pool so swaps have something to trade against.
        vm.deal(address(this), 100 ether);
        MockWETH(payable(router.WETH())).deposit{value: 10 ether}();
        MockWETH(payable(router.WETH())).transfer(pair, 10 ether);
        MockV2Pair(pair).mint(address(this));

        // The mock router pays ETH out of its own balance.
        vm.deal(address(router), 100 ether);
    }

    function _fund(uint256 amount) internal {
        vm.prank(curve);
        token.transfer(address(splitter), amount);
    }

    function test_ModeIsRecorded() public view {
        assertEq(uint8(splitter.dividendMode()), uint8(FeeSplitter.DividendMode.Eth));
    }

    /// The tranche is sold and the vault receives ETH, not tokens.
    function test_PayDividendsSendsEthToVault() public {
        address[] memory ex = new address[](1);
        ex[0] = pair;
        EthDividendVault vault = new EthDividendVault(token, address(splitter), ex);

        vm.prank(address(this));
        // setDividendVault is deployer-gated; this test contract deployed it.
        splitter.setDividendVault(address(vault));

        _fund(100_000e18);
        splitter.process();

        uint256 pool = splitter.dividendPool();
        assertGt(pool, 0, "dividend tranche allocated");

        uint256 vaultEthBefore = address(vault).balance;
        uint256 vaultTokensBefore = token.balanceOf(address(vault));

        splitter.payDividends(0);

        assertGt(address(vault).balance, vaultEthBefore, "vault received ETH");
        assertEq(token.balanceOf(address(vault)), vaultTokensBefore, "and no tokens");
        assertGt(vault.totalDeposited(), 0, "recorded as a deposit");
    }

    /// payDividends is permissionless and minEthOut comes from the caller, so
    /// the swap cap is the real protection. Anything above it must stay put
    /// rather than being sold in one go.
    function test_SwapIsCappedAtPoolSlice() public {
        address[] memory ex = new address[](1);
        ex[0] = pair;
        EthDividendVault vault = new EthDividendVault(token, address(splitter), ex);
        splitter.setDividendVault(address(vault));

        // Fund far beyond 1% of the pool's token reserve.
        _fund(50_000_000e18);
        splitter.process();

        uint256 poolBefore = splitter.dividendPool();
        uint256 cap = splitter.swapCap();
        assertGt(poolBefore, cap, "this test needs a tranche larger than the cap");

        splitter.payDividends(0);

        uint256 poolAfter = splitter.dividendPool();
        assertEq(poolBefore - poolAfter, cap, "exactly the cap was sold");
        assertGt(poolAfter, 0, "the rest waits for the next call");
    }

    function test_RevertWhen_NoVaultSet() public {
        _fund(100_000e18);
        splitter.process();

        vm.expectRevert(FeeSplitter.NoVault.selector);
        splitter.payDividends(0);
    }
}
