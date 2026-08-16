// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";
import {MemeToken} from "./MemeToken.sol";

interface IDividendVault {
    function deposit(uint256 amount) external;
}

/// @notice Holds post-graduation tax and splits it four ways.
///         Swaps are pull-based: anyone can trigger `process()` once the
///         balance clears the threshold. Nothing runs inside a transfer.
contract FeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    MemeToken public immutable token;
    IUniswapV2Router public immutable router;
    address public immutable marketing;

    uint16 public immutable liquidityBps;
    uint16 public immutable burnBps;
    uint16 public immutable marketingBps;
    uint16 public immutable dividendBps;

    /// Minimum token balance before `process()` will do anything.
    uint256 public immutable threshold;

    enum BurnMode {
        Threshold,
        Weekly,
        Monthly
    }

    BurnMode public immutable burnMode;
    uint64 public lastBurnAt;

    /// Accumulated for dividends, held until the dividend module claims it.
    /// Earmarked but not yet actioned. Excluded from future splits.
    /// Set once by the curve after the vault is deployed.
    address public dividendVault;
    address public immutable deployer;
    uint256 public dividendPool;
    uint256 public liquidityPool;
    uint256 public marketingPool;
    uint256 public pendingBurn;

    /// Total already allocated — the amount `process()` must ignore.
    function allocated() public view returns (uint256) {
        return dividendPool + liquidityPool + marketingPool + pendingBurn;
    }

    /// Whether the burn tranche is due. Threshold mode always burns on
    /// process(); weekly and monthly gate on elapsed time.
    function burnDue() public view returns (bool) {
        if (burnMode == BurnMode.Threshold) return true;
        uint256 interval = burnMode == BurnMode.Weekly ? 7 days : 30 days;
        return block.timestamp >= lastBurnAt + interval;
    }

    event Processed(uint256 liquidity, uint256 burned, uint256 marketing, uint256 dividends);
    event MarketingPaid(address indexed to, uint256 ethAmount);
    event LiquidityAdded(uint256 tokenAmount, uint256 ethAmount, uint256 liquidity);
    event DividendsPaid(uint256 amount);

    error SplitMustBeTotal(uint256 given);
    error BelowThreshold(uint256 balance, uint256 needed);
    error ZeroAddress();
    error NothingAllocated();
    error SendFailed();
    error NotDeployer();
    error AlreadySet();
    error NoVault();
    error BurnNotDue();

    constructor(
        MemeToken token_,
        IUniswapV2Router router_,
        address marketing_,
        uint16 liquidityBps_,
        uint16 burnBps_,
        uint16 marketingBps_,
        uint16 dividendBps_,
        uint256 threshold_,
        BurnMode burnMode_
    ) {
        if (marketing_ == address(0)) revert ZeroAddress();

        uint256 total = uint256(liquidityBps_) + burnBps_ + marketingBps_ + dividendBps_;
        if (total != BPS) revert SplitMustBeTotal(total);

        token = token_;
        router = router_;
        marketing = marketing_;
        liquidityBps = liquidityBps_;
        burnBps = burnBps_;
        marketingBps = marketingBps_;
        dividendBps = dividendBps_;
        deployer = msg.sender;
        threshold = threshold_;
        burnMode = burnMode_;
        lastBurnAt = uint64(block.timestamp);
    }

    /// Splits whatever tax has accumulated. Permissionless — anyone can call
    /// it, and it only acts once the balance is worth the gas.
    function process() external nonReentrant {
        uint256 bal = token.balanceOf(address(this)) - allocated();
        if (bal < threshold) revert BelowThreshold(bal, threshold);

        uint256 forLiquidity = (bal * liquidityBps) / BPS;
        uint256 forBurn = (bal * burnBps) / BPS;
        uint256 forMarketing = (bal * marketingBps) / BPS;
        uint256 forDividend = bal - forLiquidity - forBurn - forMarketing;

        if (forBurn > 0) {
            if (burnDue()) {
                lastBurnAt = uint64(block.timestamp);
                IERC20(address(token)).safeTransfer(BURN, forBurn);
            } else {
                // Not due yet — hold it for the next window.
                pendingBurn += forBurn;
            }
        }

        dividendPool += forDividend;
        liquidityPool += forLiquidity;
        marketingPool += forMarketing;

        emit Processed(forLiquidity, forBurn, forMarketing, forDividend);
    }

    /// Swaps the marketing allocation for ETH and forwards it.
    /// Permissionless and separate from `process()` so a failing swap
    /// can never block the split.
    function payMarketing(uint256 minEthOut) external nonReentrant {
        uint256 amount = marketingPool;
        if (amount == 0) revert NothingAllocated();

        marketingPool = 0;

        IERC20(address(token)).forceApprove(address(router), amount);

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = router.WETH();

        uint256 before = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, minEthOut, path, address(this), block.timestamp
        );

        uint256 ethOut = address(this).balance - before;
        (bool ok,) = marketing.call{value: ethOut}("");
        if (!ok) revert SendFailed();

        emit MarketingPaid(marketing, ethOut);
    }

    /// Converts half the liquidity allocation to ETH and pairs it with the
    /// other half. LP goes to the burn address, same as graduation.
    function addLiquidity(uint256 minEthOut) external nonReentrant {
        uint256 amount = liquidityPool;
        if (amount < 2) revert NothingAllocated();

        liquidityPool = 0;

        uint256 half = amount / 2;
        uint256 otherHalf = amount - half;

        // Swap half for ETH.
        IERC20(address(token)).forceApprove(address(router), half);

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = router.WETH();

        uint256 ethBefore = address(this).balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(half, minEthOut, path, address(this), block.timestamp);
        uint256 ethOut = address(this).balance - ethBefore;

        if (ethOut == 0) revert NothingAllocated();

        // Pair the other half with the ETH we just received.
        IERC20(address(token)).forceApprove(address(router), otherHalf);

        (,, uint256 liquidity) = router.addLiquidityETH{value: ethOut}(
            address(token),
            otherHalf,
            0, // ratio is set by the pool; we take what we get
            0,
            BURN,
            block.timestamp
        );

        emit LiquidityAdded(otherHalf, ethOut, liquidity);
    }

    /// Points dividends at a vault. Callable once, by whoever deployed this.
    function setDividendVault(address vault) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (dividendVault != address(0)) revert AlreadySet();
        if (vault == address(0)) revert ZeroAddress();
        dividendVault = vault;
    }

    /// Forwards the dividend allocation to the vault for holders to claim.
    function payDividends() external nonReentrant {
        if (dividendVault == address(0)) revert NoVault();
        uint256 amount = dividendPool;
        if (amount == 0) revert NothingAllocated();

        dividendPool = 0;

        IERC20(address(token)).forceApprove(dividendVault, amount);
        IDividendVault(dividendVault).deposit(amount);

        emit DividendsPaid(amount);
    }

    /// Burns anything held back while waiting for the burn window.
    function executeBurn() external nonReentrant {
        if (!burnDue()) revert BurnNotDue();
        uint256 amount = pendingBurn;
        if (amount == 0) revert NothingAllocated();

        pendingBurn = 0;
        lastBurnAt = uint64(block.timestamp);

        IERC20(address(token)).safeTransfer(BURN, amount);
    }

    receive() external payable {}
}
