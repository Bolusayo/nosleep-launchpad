// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract MemeTokenTaxTest is Test {
    MemeToken internal token;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal pair = makeAddr("pair");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000;

    function setUp() public {
        // 3% buy, 10% sell, 365 days — the UI defaults.
        token = new MemeToken("Taxed", "TAX", SUPPLY, curve, creator, 300, 1000, 365);

        vm.prank(curve);
        token.setDexPair(pair);
        vm.prank(curve);
        token.setPoolSeeded();

        // Seed alice and the pair from the curve (exempt, so untaxed).
        vm.startPrank(curve);
        token.transfer(alice, 1_000_000e18);
        token.transfer(pair, 10_000_000e18);
        vm.stopPrank();
    }

    function test_TaxRatesRecorded() public view {
        assertEq(token.buyTaxBps(), 300);
        assertEq(token.sellTaxBps(), 1000);
        assertTrue(token.taxActive());
    }

    function test_CurveIsExemptFromConstruction() public view {
        assertTrue(token.taxExempt(curve));
    }

    /// Buying from the pair costs the buy rate.
    function test_BuyIsTaxed() public {
        vm.prank(pair);
        token.transfer(bob, 1000e18);

        assertEq(token.balanceOf(bob), 970e18); // 3% taken
        assertEq(token.balanceOf(curve), SUPPLY * 1e18 - 11_000_000e18 + 30e18);
    }

    /// Selling to the pair costs the sell rate.
    function test_SellIsTaxed() public {
        uint256 curveBefore = token.balanceOf(curve);

        vm.prank(alice);
        token.transfer(pair, 1000e18);

        assertEq(token.balanceOf(curve) - curveBefore, 100e18); // 10%
    }

    /// Wallet to wallet must never be taxed.
    function test_WalletToWalletUntaxed() public {
        vm.prank(alice);
        token.transfer(bob, 1000e18);

        assertEq(token.balanceOf(bob), 1000e18);
    }

    function test_ExemptAddressPaysNothing() public {
        vm.prank(curve);
        token.setExempt(bob, true);

        vm.prank(pair);
        token.transfer(bob, 1000e18);

        assertEq(token.balanceOf(bob), 1000e18);
    }

    function test_TaxStopsAfterDuration() public {
        vm.warp(block.timestamp + 366 days);
        assertFalse(token.taxActive());

        vm.prank(pair);
        token.transfer(bob, 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);
    }

    function test_ZeroTaxTokenIsNeverActive() public {
        MemeToken plain = new MemeToken("Plain", "PLN", SUPPLY, curve, creator, 0, 0, 365);
        assertFalse(plain.taxActive());
    }

    function test_RevertWhen_TaxAboveCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(MemeToken.TaxTooHigh.selector, uint16(1001)));
        new MemeToken("TooMuch", "MUCH", SUPPLY, curve, creator, 1001, 0, 365);
    }

    function test_RevertWhen_NonCurveSetsPair() public {
        MemeToken t = new MemeToken("X", "X", SUPPLY, curve, creator, 300, 300, 30);
        vm.prank(alice);
        vm.expectRevert(MemeToken.NotCurve.selector);
        t.setDexPair(pair);
    }

    /// Tax must never exceed the stated rate, at any transfer size.
    function testFuzz_TaxNeverExceedsRate(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000e18);

        uint256 before = token.balanceOf(curve);
        vm.prank(pair);
        token.transfer(bob, amount);

        uint256 taken = token.balanceOf(curve) - before;
        assertLe(taken, (amount * 300) / 10_000);
        assertEq(token.balanceOf(bob), amount - taken);
    }
}
