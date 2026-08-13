// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {MockV2Router} from "../src/mocks/MockV2Router.sol";

contract BondingCurveTest is Test {
    BondingCurve internal curve;
    MemeToken    internal token;
    MockV2Router internal router;

    address internal creator = makeAddr("creator");
    address internal feeTo   = makeAddr("feeTo");
    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000_000;

    /// Read from the contract so these tests hold at any curve scale.
    uint256 internal VQ; // virtual quote reserve
    uint256 internal QT; // ETH raised to graduate

    function setUp() public {
        router = new MockV2Router();
        curve  = new BondingCurve("Fault Line", "FAULT", SUPPLY, creator, feeTo, 0, address(router), 0, 0, 0);
        token  = curve.token();

        VQ = curve.VIRTUAL_QUOTE();
        QT = curve.QUOTE_TARGET();

        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
    }

    function test_InitialReserves() public view {
        uint256 s = (SUPPLY * 1e18 * 8_000) / 10_000;
        assertEq(curve.curveSupply(), s);
        assertEq(curve.quoteReserve(), VQ);
        assertEq(curve.tokenReserve(), s + (VQ * s) / QT);
        assertEq(curve.ethCollected(), 0);
        assertEq(token.balanceOf(address(curve)), SUPPLY * 1e18);
    }

    function test_BuyMovesPriceUp() public {
        uint256 chunk = QT / 100;

        vm.prank(alice);
        curve.buy{value: chunk}(0);
        uint256 first = token.balanceOf(alice);

        vm.prank(bob);
        curve.buy{value: chunk}(0);
        uint256 second = token.balanceOf(bob);

        assertLt(second, first, "later buyer must get fewer tokens");
    }

    function test_FeeGoesToRecipient() public {
        uint256 spend = QT / 10;

        vm.prank(alice);
        curve.buy{value: spend}(0);

        assertEq(feeTo.balance, (spend * 200) / 10_000); // 2%
    }

    function test_SellReturnsEth() public {
        uint256 spend = QT / 10;

        vm.startPrank(alice);
        curve.buy{value: spend}(0);

        uint256 bal    = token.balanceOf(alice);
        uint256 before = alice.balance;

        token.approve(address(curve), bal);
        curve.sell(bal, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 0);
        assertGt(alice.balance, before);
        assertLt(alice.balance - before, spend); // ~4% lost to the double fee
    }

    /// The headline property: graduation lands on exactly QUOTE_TARGET.
    function test_GraduatesAtTarget() public {
        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        assertTrue(curve.graduated());
        assertEq(curve.ethCollected(), QT);
        assertEq(curve.quoteReserve(), VQ + QT);
    }

    function test_ExcessEthRefunded() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        uint256 spent = before - alice.balance;
        assertLt(spent, (QT * 15) / 10, "overpayment must be refunded");
    }

    function test_RevertWhen_BuyingAfterGraduation() public {
        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        vm.prank(bob);
        vm.expectRevert(BondingCurve.AlreadyGraduated.selector);
        curve.buy{value: QT / 10}(0);
    }

    function test_RevertWhen_SlippageTooHigh() public {
        vm.prank(alice);
        vm.expectRevert();
        curve.buy{value: QT / 10}(type(uint256).max);
    }

    function test_WalletCapEnforced() public {
        BondingCurve capped =
            new BondingCurve("Capped", "CAP", SUPPLY, creator, feeTo, 200, address(router), 0, 0, 0);

        uint256 cap = capped.maxBuyPerWallet();
        assertEq(cap, (capped.curveSupply() * 200) / 10_000);

        vm.prank(alice);
        vm.expectRevert();
        capped.buy{value: QT}(0);
    }

    function test_GraduationBurnsLpTokens() public {
        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        address lp = address(router.lp());
        uint256 burned = MemeToken(lp).balanceOf(curve.BURN());

        assertGt(burned, 0, "LP must exist");
        assertEq(curve.lpAmount(), burned, "curve must record what it burned");

        assertEq(MemeToken(lp).balanceOf(address(curve)), 0);
        assertEq(MemeToken(lp).balanceOf(creator), 0);
        assertEq(MemeToken(lp).balanceOf(alice), 0);
    }

    function test_PoolReceivesFullRaiseAndRemainingSupply() public {
        vm.prank(alice);
        curve.buy{value: QT * 10}(0);

        assertEq(address(router).balance, QT);
        assertEq(token.balanceOf(address(router)), (SUPPLY * 1e18 * 2000) / 10000);

        assertEq(address(curve).balance, 0);
        assertEq(token.balanceOf(address(curve)), 0);
    }

    /// A failing router must revert the buy, never strand the raise.
    function test_RevertWhen_RouterFails() public {
        router.setShouldFail(true);

        vm.prank(alice);
        vm.expectRevert(BondingCurve.MigrationFailed.selector);
        curve.buy{value: QT * 10}(0);

        assertFalse(curve.graduated());
        assertEq(curve.ethCollected(), 0);
        assertEq(alice.balance, 100 ether);
    }

    /// Graduation must hit the target regardless of how the buys are split.
    function testFuzz_AlwaysGraduatesAtTarget(uint256 chunk) public {
        chunk = bound(chunk, QT / 100, QT / 2);

        while (!curve.graduated()) {
            address buyer = makeAddr(string(abi.encode(curve.quoteReserve())));
            vm.deal(buyer, chunk);
            vm.prank(buyer);
            curve.buy{value: chunk}(0);
        }

        assertEq(curve.ethCollected(), QT);
    }
    
    function testFuzz_QuoteMatchesActualBuy(uint256 ethIn) public {
        ethIn = bound(ethIn, QT / 1000, QT * 3);

        (uint256 predicted, ) = curve.quoteBuy(ethIn);

        vm.deal(alice, ethIn);
        vm.prank(alice);
        curve.buy{value: ethIn}(0);

        assertEq(token.balanceOf(alice), predicted, "quote must match the trade exactly");
    }
}