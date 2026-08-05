// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract BondingCurveTest is Test {
    BondingCurve internal curve;
    MemeToken    internal token;

    address internal creator = makeAddr("creator");
    address internal feeTo   = makeAddr("feeTo");
    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000;

    function setUp() public {
        curve = new BondingCurve("Fault Line", "FAULT", SUPPLY, creator, feeTo, 0);
        token = curve.token();

        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
    }

    function test_InitialReserves() public view {
        uint256 s = (SUPPLY * 1e18 * 8_000) / 10_000;
        assertEq(curve.curveSupply(), s);
        assertEq(curve.quoteReserve(), 3 ether);
        assertEq(curve.tokenReserve(), s + (3 ether * s) / 4 ether);
        assertEq(curve.ethCollected(), 0);
        assertEq(token.balanceOf(address(curve)), SUPPLY * 1e18);
    }

    function test_BuyMovesPriceUp() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        uint256 first = token.balanceOf(alice);

        vm.prank(bob);
        curve.buy{value: 1 ether}(0);
        uint256 second = token.balanceOf(bob);

        assertLt(second, first, "later buyer must get fewer tokens");
    }

    function test_FeeGoesToRecipient() public {
        vm.prank(alice);
        curve.buy{value: 1 ether}(0);
        assertEq(feeTo.balance, 0.02 ether); // 2%
    }

    function test_SellReturnsEth() public {
        vm.startPrank(alice);
        curve.buy{value: 1 ether}(0);

        uint256 bal    = token.balanceOf(alice);
        uint256 before = alice.balance;

        token.approve(address(curve), bal);
        curve.sell(bal, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 0);
        assertGt(alice.balance, before);
        // Round trip loses ~4% to the double fee.
        assertLt(alice.balance - before, 1 ether);
    }

    /// The headline property: graduation lands on exactly 4 ETH.
    function test_GraduatesAtFourEth() public {
        vm.prank(alice);
        curve.buy{value: 50 ether}(0);

        assertTrue(curve.graduated());
        assertEq(curve.ethCollected(), 4 ether);
        assertEq(curve.quoteReserve(), 7 ether);
    }

    function test_ExcessEthRefunded() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        curve.buy{value: 50 ether}(0);

        // Only the gross needed to fill 4 ETH net of the 2% fee is kept.
        uint256 spent = before - alice.balance;
        assertLt(spent, 5 ether, "overpayment must be refunded");
    }

    function test_RevertWhen_BuyingAfterGraduation() public {
        vm.prank(alice);
        curve.buy{value: 50 ether}(0);

        vm.prank(bob);
        vm.expectRevert(BondingCurve.AlreadyGraduated.selector);
        curve.buy{value: 1 ether}(0);
    }

    function test_RevertWhen_SlippageTooHigh() public {
        vm.prank(alice);
        vm.expectRevert();
        curve.buy{value: 1 ether}(type(uint256).max);
    }

    function test_WalletCapEnforced() public {
        BondingCurve capped =
            new BondingCurve("Capped", "CAP", SUPPLY, creator, feeTo, 200); // 2%

        uint256 cap = capped.maxBuyPerWallet();
        assertEq(cap, (capped.curveSupply() * 200) / 10_000);

        vm.prank(alice);
        vm.expectRevert();
        capped.buy{value: 5 ether}(0);
    }

    /// Graduation must hit 4 ETH regardless of how the buys are split.
    function testFuzz_AlwaysGraduatesAtFourEth(uint256 chunk) public {
        chunk = bound(chunk, 0.05 ether, 2 ether);

        while (!curve.graduated()) {
            address buyer = makeAddr(string(abi.encode(curve.quoteReserve())));
            vm.deal(buyer, chunk);
            vm.prank(buyer);
            curve.buy{value: chunk}(0);
        }

        assertEq(curve.ethCollected(), 4 ether);
    }
}
