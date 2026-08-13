// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";
import {MemeToken} from "./MemeToken.sol";

/// @notice Holds post-graduation tax and splits it four ways.
///         Swaps are pull-based: anyone can trigger `process()` once the
///         balance clears the threshold. Nothing runs inside a transfer.
contract FeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS  = 10_000;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    MemeToken        public immutable token;
    IUniswapV2Router public immutable router;
    address          public immutable marketing;

    uint16 public immutable liquidityBps;
    uint16 public immutable burnBps;
    uint16 public immutable marketingBps;
    uint16 public immutable dividendBps;

    /// Minimum token balance before `process()` will do anything.
    uint256 public immutable threshold;

    /// Accumulated for dividends, held until the dividend module claims it.
    /// Earmarked but not yet actioned. Excluded from future splits.
    uint256 public dividendPool;
    uint256 public liquidityPool;
    uint256 public marketingPool;

    /// Total already allocated — the amount `process()` must ignore.
    function allocated() public view returns (uint256) {
        return dividendPool + liquidityPool + marketingPool;
    }


    event Processed(uint256 liquidity, uint256 burned, uint256 marketing, uint256 dividends);
    event MarketingPaid(address indexed to, uint256 ethAmount);

    error SplitMustBeTotal(uint256 given);
    error BelowThreshold(uint256 balance, uint256 needed);
    error ZeroAddress();

    constructor(
        MemeToken token_,
        IUniswapV2Router router_,
        address marketing_,
        uint16 liquidityBps_,
        uint16 burnBps_,
        uint16 marketingBps_,
        uint16 dividendBps_,
        uint256 threshold_
    ) {
        if (marketing_ == address(0)) revert ZeroAddress();

        uint256 total = uint256(liquidityBps_) + burnBps_ + marketingBps_ + dividendBps_;
        if (total != BPS) revert SplitMustBeTotal(total);

        token        = token_;
        router       = router_;
        marketing    = marketing_;
        liquidityBps = liquidityBps_;
        burnBps      = burnBps_;
        marketingBps = marketingBps_;
        dividendBps  = dividendBps_;
        threshold    = threshold_;
    }

    /// Splits whatever tax has accumulated. Permissionless — anyone can call
    /// it, and it only acts once the balance is worth the gas.
    function process() external nonReentrant {
        uint256 bal = token.balanceOf(address(this)) - allocated();
        if (bal < threshold) revert BelowThreshold(bal, threshold);

        uint256 forLiquidity = (bal * liquidityBps) / BPS;
        uint256 forBurn      = (bal * burnBps)      / BPS;
        uint256 forMarketing = (bal * marketingBps) / BPS;
        uint256 forDividend  = bal - forLiquidity - forBurn - forMarketing;

        if (forBurn > 0) {
            IERC20(address(token)).safeTransfer(BURN, forBurn);
        }

        dividendPool  += forDividend;
        liquidityPool += forLiquidity;
        marketingPool += forMarketing;

        emit Processed(forLiquidity, forBurn, forMarketing, forDividend);
    }
    
    receive() external payable {}
}
