// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {MockV2Router, MockV2Pair, MockWETH} from "../src/mocks/MockV2Router.sol";
import {IUniswapV2Router} from "../src/interfaces/IUniswapV2Router.sol";

/// @notice The marketing swap is bounded by the same cap as the other two.
///
/// `addLiquidity` and `payDividends` both sell at most `MAX_SWAP_BPS_OF_POOL`
/// of the pool in one call, and addLiquidity's own comment explains why that
/// cap -- not `minEthOut` -- is what stops a sandwich: the call is
/// permissionless, so an attacker sandwiching it just calls it themselves and
/// passes zero. `payMarketing` sold its entire allocation in one go, which
/// made the marketing tranche the easiest of the three to sandwich and the
/// only one whose size was unbounded.
///
/// These tests pin the fixed behaviour: capped per call, remainder retained,
/// nothing stranded, and small allocations still settled in a single call.
contract FeeSplitterMarketingCapTest is Test {
    FeeSplitter internal splitter;
    MemeToken internal token;
    MockV2Router internal router;
    MockV2Pair internal pair;

    address internal curve = makeAddr("curve");
    address internal creator = makeAddr("creator");
    address internal marketing = makeAddr("marketing");
    address internal caller = makeAddr("caller");

    uint256 internal constant SUPPLY = 1_000_000_000;
    uint256 internal constant POOL_TOKENS = 200_000_000e18;
    /// MAX_SWAP_BPS_OF_POOL is 1%, so this is what one call may sell.
    uint256 internal constant CAP = POOL_TOKENS / 100;

    function setUp() public {
        vm.deal(address(this), 100 ether);

        router = new MockV2Router();
        vm.deal(address(router), 1000 ether);

        token = new MemeToken("Marketing", "MKT", SUPPLY, curve, creator, 500, 500, 365);

        address weth = router.WETH();
        pair = new MockV2Pair(address(token), weth);

        vm.startPrank(curve);
        token.setDexPair(address(pair));
        token.setPoolSeeded();
        vm.stopPrank();

        // Seed the pool so swapCap() has reserves to measure against.
        vm.prank(curve);
        token.transfer(address(pair), POOL_TOKENS);

        MockWETH(payable(weth)).deposit{value: 4 ether}();
        MockWETH(payable(weth)).transfer(address(pair), 4 ether);
        pair.sync();

        splitter = new FeeSplitter(
            token,
            IUniswapV2Router(address(router)),
            marketing,
            2500, // liquidity
            2500, // burn
            2500, // marketing
            2500, // dividends
            1e18, // threshold
            FeeSplitter.BurnMode.Threshold,
            FeeSplitter.DividendMode.SelfToken
        );

        vm.prank(curve);
        token.setTaxCollector(address(splitter));
    }

    /// Puts `amount` of tax through the splitter and returns what the
    /// marketing tranche came to.
    function _allocate(uint256 amount) internal returns (uint256) {
        vm.prank(curve);
        token.transfer(address(splitter), amount);
        splitter.process();
        return splitter.marketingPool();
    }

    function test_CapIsOnePercentOfPoolReserves() public view {
        assertEq(splitter.swapCap(), CAP, "cap should be 1% of the pool's token reserve");
    }

    /// The core property: one call never sells more than the cap.
    function test_MarketingSwapIsCappedPerCall() public {
        uint256 allocation = _allocate(40_000_000e18); // 25% of it is marketing
        assertGt(allocation, CAP, "test needs an allocation larger than the cap");

        uint256 before = marketing.balance;

        vm.prank(caller);
        splitter.payMarketing(0);

        // The mock swaps at a flat 1 token = 1e-6 ETH.
        assertEq(marketing.balance - before, CAP / 1e6, "one call must sell exactly the cap");
        assertEq(splitter.marketingPool(), allocation - CAP, "the remainder stays for the next call");
    }

    /// Repeated calls drain it completely -- the cap slows payout down, it
    /// does not strand anything.
    function test_MarketingPaysOutInSlicesUntilEmpty() public {
        uint256 allocation = _allocate(40_000_000e18);
        uint256 before = marketing.balance;

        uint256 calls;
        while (splitter.marketingPool() > 0 && calls < 50) {
            vm.prank(caller);
            splitter.payMarketing(0);
            calls++;
        }

        console.log("allocation   ", allocation);
        console.log("cap per call ", CAP);
        console.log("calls needed ", calls);

        assertEq(splitter.marketingPool(), 0, "nothing may be left behind");
        assertEq(marketing.balance - before, allocation / 1e6, "marketing receives the whole allocation");
        assertEq(calls, 5, "10M allocation at a 2M cap is five slices");
    }

    /// An allocation under the cap must still settle in one call. Without
    /// this, the fix could quietly turn every payout into an instalment.
    function test_SmallAllocationSettlesInOneCall() public {
        uint256 allocation = _allocate(4_000_000e18); // 1M to marketing, under the cap
        assertLt(allocation, CAP, "test needs an allocation below the cap");

        uint256 before = marketing.balance;

        vm.prank(caller);
        splitter.payMarketing(0);

        assertEq(splitter.marketingPool(), 0, "a small allocation clears in one go");
        assertEq(marketing.balance - before, allocation / 1e6);
    }

    /// Still permissionless: anyone may trigger it, the proceeds always go to
    /// the marketing wallet.
    function test_PayMarketingStaysPermissionless() public {
        _allocate(4_000_000e18);
        uint256 before = marketing.balance;

        vm.prank(caller);
        splitter.payMarketing(0);

        assertGt(marketing.balance, before, "a stranger's call still pays the marketing wallet");
        assertEq(caller.balance, 0, "and pays the caller nothing");
    }

    function test_RevertWhen_NothingAllocated() public {
        vm.expectRevert(FeeSplitter.NothingAllocated.selector);
        splitter.payMarketing(0);
    }

    /// With no pool there is no cap to measure against, so the call refuses
    /// rather than falling back to an unbounded swap. Mirrors addLiquidity.
    function test_RevertWhen_PoolIsEmpty() public {
        _allocate(40_000_000e18);

        // Drain the pool's token side so the reserves read zero.
        vm.prank(address(pair));
        token.transfer(curve, POOL_TOKENS);
        pair.sync();

        assertEq(splitter.swapCap(), 0, "no reserves, no cap");

        vm.expectRevert(FeeSplitter.NothingAllocated.selector);
        splitter.payMarketing(0);
    }
}
