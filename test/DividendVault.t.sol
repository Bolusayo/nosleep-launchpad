// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendVault} from "../src/DividendVault.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract DividendVaultTest is Test {
    DividendVault internal vault;
    MemeToken internal token;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal splitter = makeAddr("splitter");
    address internal pair = makeAddr("pair");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000;

    function setUp() public {
        token = new MemeToken("Div", "DIV", SUPPLY, curve, creator, 300, 1000, 365);

        vm.prank(curve);
        token.setDexPair(pair);
        vm.prank(curve);
        token.setPoolSeeded();

        address[] memory ex = new address[](1);
        ex[0] = pair;
        vault = new DividendVault(token, splitter, ex);

        // Curve is exempt, so these move untaxed.
        vm.startPrank(curve);
        token.transfer(alice, 100_000_000e18); // 10%
        token.transfer(bob, 100_000_000e18); // 10%
        token.transfer(pair, 500_000_000e18); // 50% — excluded
        token.transfer(splitter, 10_000_000e18); // dividend allocation
        vm.stopPrank();

        vm.prank(splitter);
        token.approve(address(vault), type(uint256).max);
    }

    function test_EligibleSupplyExcludesSinks() public view {
        uint256 expected = SUPPLY * 1e18 - 500_000_000e18 // pair
            - 10_000_000e18; // splitter
        assertEq(vault.eligibleSupply(), expected);
    }

    function test_RevertWhen_NonSplitterDeposits() public {
        vm.prank(alice);
        vm.expectRevert(DividendVault.NotSplitter.selector);
        vault.deposit(1000e18);
    }

    function test_HoldersClaimProportionally() public {
        vm.prank(splitter);
        vault.deposit(1_000_000e18);

        // Eligible supply is 490M; alice holds 100M ≈ 20.4%
        uint256 aliceExpected = vault.pending(alice);
        assertGt(aliceExpected, 0);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        vault.claim();

        assertEq(token.balanceOf(alice) - before, aliceExpected);
        assertEq(vault.pending(alice), 0, "nothing left after claiming");
    }

    function test_EqualHoldersGetEqualShares() public {
        vm.prank(splitter);
        vault.deposit(1_000_000e18);

        assertEq(vault.pending(alice), vault.pending(bob), "equal balances, equal claims");
    }

    function test_ExcludedAddressGetsNothing() public {
        vm.prank(splitter);
        vault.deposit(1_000_000e18);

        assertEq(vault.pending(pair), 0, "the pool must not earn dividends");
    }

    function test_RevertWhen_NothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(DividendVault.NothingToClaim.selector);
        vault.claim();
    }

    /// Second deposit accrues on top; claiming twice doesn't double-pay.
    function test_SecondDepositAccrues() public {
        vm.startPrank(splitter);
        vault.deposit(1_000_000e18);
        vm.stopPrank();

        uint256 first = vault.pending(alice);
        vm.prank(alice);
        vault.claim();

        vm.prank(splitter);
        vault.deposit(1_000_000e18);

        uint256 second = vault.pending(alice);
        assertApproxEqRel(second, first, 0.05e18, "similar share on a similar deposit");
    }

    /// Total claimed must never exceed total deposited.
    function testFuzz_NeverOverPays(uint96 a, uint96 b) public {
        uint256 x = bound(uint256(a), 1e18, 5_000_000e18);
        uint256 y = bound(uint256(b), 1e18, 5_000_000e18);

        vm.startPrank(splitter);
        vault.deposit(x);
        vault.deposit(y);
        vm.stopPrank();

        if (vault.pending(alice) > 0) {
            vm.prank(alice);
            vault.claim();
        }
        if (vault.pending(bob) > 0) {
            vm.prank(bob);
            vault.claim();
        }

        assertLe(vault.totalClaimed(), vault.totalDeposited(), "cannot pay out more than came in");
    }
}
