// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract MemeTokenTest is Test {
    MemeToken internal token;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");

    uint256 internal constant SUPPLY = 1_000_000_000; // 1B, the UI default

    function setUp() public {
        token = new MemeToken("Fault Line", "FAULT", SUPPLY, curve, creator, 0, 0, 0);
    }

    function test_MetadataIsCorrect() public view {
        assertEq(token.name(), "Fault Line");
        assertEq(token.symbol(), "FAULT");
        assertEq(token.decimals(), 18);
    }

    function test_EntireSupplyMintedToCurve() public view {
        uint256 expected = SUPPLY * 1e18;
        assertEq(token.totalSupply(), expected);
        assertEq(token.balanceOf(curve), expected);
        assertEq(token.balanceOf(creator), 0);
    }

    function test_CurveAndCreatorRecorded() public view {
        assertEq(token.curve(), curve);
        assertEq(token.creator(), creator);
    }

    function test_RevertWhen_SupplyTooLow() public {
        vm.expectRevert(abi.encodeWithSelector(MemeToken.SupplyOutOfRange.selector, 999_999));
        new MemeToken("Too Small", "SMALL", 999_999, curve, creator, 0, 0, 0);
    }

    function test_RevertWhen_SupplyTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(MemeToken.SupplyOutOfRange.selector, 1_000_000_000_001));
        new MemeToken("Too Big", "BIG", 1_000_000_000_001, curve, creator, 0, 0, 0);
    }

    function test_RevertWhen_CurveIsZero() public {
        vm.expectRevert(MemeToken.ZeroAddress.selector);
        new MemeToken("Nil", "NIL", SUPPLY, address(0), creator, 0, 0, 0);
    }

    function test_CurveCanTransfer() public {
        vm.prank(curve);
        assertTrue(token.transfer(alice, 500e18));

        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.balanceOf(curve), SUPPLY * 1e18 - 500e18);
    }

    /// Fuzzed: any supply inside the bounds must mint exactly that amount.
    function testFuzz_SupplyWithinBoundsAlwaysMints(uint256 s) public {
        s = bound(s, token.MIN_SUPPLY(), token.MAX_SUPPLY());
        MemeToken t = new MemeToken("Fuzz", "FZZ", s, curve, creator, 0, 0, 0);
        assertEq(t.totalSupply(), s * 1e18);
    }
}
