// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemeToken} from "./MemeToken.sol";

/// @notice Self-mode dividends: holders claim a share of the dividend pool
///         in the token itself, proportional to their balance.
contract DividendVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e27;
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;

    MemeToken public immutable token;
    address public immutable splitter;

    /// Cumulative dividend per token held, scaled by PRECISION.
    uint256 public accPerToken;

    /// Balance excluded from dividends: pair, splitter, burn, the vault itself.
    mapping(address => bool) public excluded;

    mapping(address => uint256) public rewardDebt;
    mapping(address => bool) public initialised;

    /// Dividends banked at a balance change, awaiting claim.
    mapping(address => uint256) public claimable;

    uint256 public totalDeposited;
    uint256 public totalClaimed;

    event Deposited(uint256 amount, uint256 perToken);
    event Claimed(address indexed holder, uint256 amount);

    error NotSplitter();
    error NothingToClaim();
    error NoEligibleSupply();
    error NotToken();

    constructor(MemeToken token_, address splitter_, address[] memory excluded_) {
        token = token_;
        splitter = splitter_;

        excluded[address(this)] = true;
        excluded[splitter_] = true;
        for (uint256 i = 0; i < excluded_.length; ++i) {
            excluded[excluded_[i]] = true;
        }
    }

    /// Supply eligible for dividends — total minus every excluded holder.
    function eligibleSupply() public view returns (uint256) {
        uint256 supply = token.totalSupply();
        // Subtract the known sinks. Kept short deliberately: an unbounded
        // exclusion list would make this loop a gas risk.
        return supply - token.balanceOf(address(this)) - token.balanceOf(splitter) - token.balanceOf(BURN)
            - token.balanceOf(token.dexPair());
    }

    /// Called by the splitter when it forwards the dividend allocation.
    function deposit(uint256 amount) external {
        if (msg.sender != splitter) revert NotSplitter();

        uint256 eligible = eligibleSupply();
        if (eligible == 0) revert NoEligibleSupply();

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        accPerToken += (amount * PRECISION) / eligible;
        totalDeposited += amount;

        emit Deposited(amount, (amount * PRECISION) / eligible);
    }

    /// Called by the token before every balance change. Not reentrancy-guarded
    /// on purpose: it runs inside a transfer that may itself sit inside a
    /// guarded claim. Access control is the token check.
    function onBalanceChange(address from, address to) external {
        if (msg.sender != address(token)) revert NotToken();
        _settle(from);
        _settle(to);
    }

    /// Banks what `h` has earned on their current balance, then snapshots
    /// their debt. Must be called BEFORE the balance moves.
    function _settle(address h) internal {
        if (h == address(0) || excluded[h]) return;

        uint256 acc = accPerToken;

        if (!initialised[h]) {
            initialised[h] = true;
            // Balance is still pre-transfer here. Zero means this wallet is
            // arriving for the first time, so it starts at the current
            // accumulator and earns nothing retroactively.
            if (token.balanceOf(h) == 0) {
                rewardDebt[h] = acc;
                return;
            }
            // Non-zero means it held before the vault existed; debt stays 0.
            rewardDebt[h] = 0;
        }

        uint256 debt = rewardDebt[h];
        if (acc > debt) {
            uint256 owed = (token.balanceOf(h) * (acc - debt)) / PRECISION;
            if (owed > 0) claimable[h] += owed;
        }
        rewardDebt[h] = acc;
    }

    function pending(address holder) public view returns (uint256) {
        if (excluded[holder]) return 0;
        uint256 acc = accPerToken;
        uint256 debt = initialised[holder] ? rewardDebt[holder] : 0;
        uint256 accrued = acc > debt ? (token.balanceOf(holder) * (acc - debt)) / PRECISION : 0;
        return claimable[holder] + accrued;
    }

    function claim() external nonReentrant {
        uint256 amount = pending(msg.sender);
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender] = 0;
        rewardDebt[msg.sender] = accPerToken;
        initialised[msg.sender] = true;
        totalClaimed += amount;

        IERC20(address(token)).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }
}
