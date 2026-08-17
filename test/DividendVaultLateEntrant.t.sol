// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DividendVault} from "../src/DividendVault.sol";
import {MemeToken} from "../src/MemeToken.sol";

/// @notice Late-entrant behaviour in DividendVault.
///
/// These tests assert the properties the vault SHOULD hold. They are expected
/// to FAIL against the current implementation — that failure is the finding.
///
/// Mechanism: `pending()` multiplies the holder's CURRENT balance by
/// `accPerToken - rewardDebt`, and `rewardDebt` is only written on claim
/// (`initialised` defaults false, so debt reads as 0). A wallet that acquires
/// tokens after deposits have accrued therefore appears owed the entire
/// historical per-token amount, exactly as if it had held throughout.
///
/// This is compounded by `eligibleSupply()` excluding `dexPair`: buying from
/// the pool moves tokens from an excluded holder to an eligible one, so
/// eligible supply GROWS after `accPerToken` was computed against a smaller
/// denominator. More claimants divide an unchanged pool.
///
/// `RewardsDistributor` solves this same problem with enrolment snapshots
/// (`enroll()` seeds rewardDebt from the current accumulator). DividendVault
/// has no equivalent.
///
/// Why the existing suite misses it: `testFuzz_NeverOverPays` only lets alice
/// and bob claim — 200M of 490M eligible supply — and both hold their tokens
/// before any deposit. The curve keeps 290M of eligible supply and never
/// claims, leaving ~59% slack that absorbs any overpayment.
contract DividendVaultLateEntrantTest is Test {
    DividendVault internal vault;
    MemeToken internal token;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal splitter = makeAddr("splitter");
    address internal pair = makeAddr("pair");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol"); // the late entrant

    uint256 internal constant SUPPLY = 1_000_000_000;
    uint256 internal constant DEPOSIT = 1_000_000e18;

    function setUp() public {
        token = new MemeToken("Div", "DIV", SUPPLY, curve, creator, 300, 1000, 365);

        vm.prank(curve);
        token.setDexPair(pair);

        address[] memory ex = new address[](1);
        ex[0] = pair;
        vault = new DividendVault(token, splitter, ex);

        vm.prank(curve);
        token.setDividendVault(address(vault));

        vm.startPrank(curve);
        token.transfer(alice, 100_000_000e18); // 10%
        token.transfer(bob, 100_000_000e18); // 10%
        token.transfer(pair, 500_000_000e18); // 50% — excluded
        token.transfer(splitter, 10_000_000e18); // dividend allocation
        vm.stopPrank();

        vm.prank(splitter);
        token.approve(address(vault), type(uint256).max);
    }

    /// Carol buys from the pool. Transfers out of `dexPair` are taxed as buys.
    function _carolBuys(uint256 amount) internal {
        vm.prank(pair);
        token.transfer(carol, amount);
    }

    // -----------------------------------------------------------------
    // The core property
    // -----------------------------------------------------------------

    /// A wallet that held nothing when the dividend was deposited has earned
    /// nothing from it. EXPECTED TO FAIL.
    function test_LateEntrantEarnsNothingFromPriorDeposits() public {
        vm.prank(splitter);
        vault.deposit(DEPOSIT);

        assertEq(token.balanceOf(carol), 0, "carol holds nothing at deposit time");

        _carolBuys(400_000_000e18);

        console.log("carol balance after buying", token.balanceOf(carol));
        console.log("carol pending             ", vault.pending(carol));

        assertEq(vault.pending(carol), 0, "a wallet that arrived after the deposit has earned nothing from it");
    }

    /// The vault can never owe more than it holds. EXPECTED TO FAIL.
    function test_TotalPendingNeverExceedsDeposits() public {
        vm.prank(splitter);
        vault.deposit(DEPOSIT);

        _carolBuys(400_000_000e18);

        uint256 owed = vault.pending(alice) + vault.pending(bob) + vault.pending(carol);

        console.log("--- vault solvency ---");
        console.log("deposited      ", vault.totalDeposited());
        console.log("vault balance  ", token.balanceOf(address(vault)));
        console.log("pending alice  ", vault.pending(alice));
        console.log("pending bob    ", vault.pending(bob));
        console.log("pending carol  ", vault.pending(carol));
        console.log("total owed     ", owed);
        console.log("eligible supply", vault.eligibleSupply());

        assertLe(owed, vault.totalDeposited(), "vault must never owe more than was deposited");
    }

    /// A holder who held throughout must always be able to claim, regardless
    /// of who else claims first. EXPECTED TO FAIL — bob is left short because
    /// carol drains the pool ahead of him.
    function test_HonestHolderCanAlwaysClaimAfterLateEntrants() public {
        vm.prank(splitter);
        vault.deposit(DEPOSIT);

        uint256 bobOwed = vault.pending(bob);
        assertGt(bobOwed, 0, "bob is owed something before carol arrives");

        _carolBuys(400_000_000e18);

        // Carol claims only if she is genuinely owed something. Once the
        // vault settles on transfer she is owed nothing, which is the point.
        if (vault.pending(carol) > 0) {
            vm.prank(carol);
            vault.claim();
        }
        vm.prank(alice);
        vault.claim();

        console.log("vault balance left", token.balanceOf(address(vault)));
        console.log("bob still owed    ", vault.pending(bob));

        // Bob held from before the deposit. His claim must not fail.
        vm.prank(bob);
        vault.claim();

        assertGe(token.balanceOf(bob), 100_000_000e18 + bobOwed, "bob must receive what he was owed");
    }

    /// Total paid out must never exceed total paid in, even with late
    /// entrants claiming. EXPECTED TO FAIL.
    function test_ClaimedNeverExceedsDepositedWithLateEntrant() public {
        vm.prank(splitter);
        vault.deposit(DEPOSIT);

        _carolBuys(400_000_000e18);

        // Everyone who can claim, does — in the worst order for the vault.
        if (vault.pending(carol) > 0) {
            vm.prank(carol);
            vault.claim();
        }
        if (vault.pending(alice) > 0) {
            vm.prank(alice);
            vault.claim();
        }

        console.log("claimed  ", vault.totalClaimed());
        console.log("deposited", vault.totalDeposited());

        assertLe(vault.totalClaimed(), vault.totalDeposited(), "cannot pay out more than came in");
    }

    // -----------------------------------------------------------------
    // Same property, no pool involved
    // -----------------------------------------------------------------

    /// Isolates the rewardDebt issue from the eligible-supply issue. Carol
    /// receives from the curve (exempt, untaxed, already-eligible), so
    /// eligible supply does NOT change — yet she still shows a balance-
    /// proportional claim on a deposit that predates her.
    /// EXPECTED TO FAIL.
    function test_LateEntrantFromEligibleHolderStillEarns() public {
        vm.prank(splitter);
        vault.deposit(DEPOSIT);

        uint256 eligibleBefore = vault.eligibleSupply();

        vm.prank(curve);
        token.transfer(carol, 100_000_000e18);

        assertEq(vault.eligibleSupply(), eligibleBefore, "eligible supply unchanged - both holders count");

        console.log("carol pending (no supply growth)", vault.pending(carol));

        assertEq(vault.pending(carol), 0, "carol still earned nothing from a deposit that predates her");
    }

    // -----------------------------------------------------------------
    // Control: the existing suite's assumption
    // -----------------------------------------------------------------

    /// Sanity check that the setup itself is sound — with no late entrant,
    /// the vault stays solvent. EXPECTED TO PASS.
    function test_Control_NoLateEntrantStaysSolvent() public {
        vm.prank(splitter);
        vault.deposit(DEPOSIT);

        uint256 owed = vault.pending(alice) + vault.pending(bob);
        assertLe(owed, vault.totalDeposited(), "holders present at deposit time are covered");

        vm.prank(alice);
        vault.claim();
        vm.prank(bob);
        vault.claim();

        assertLe(vault.totalClaimed(), vault.totalDeposited());
    }
}
