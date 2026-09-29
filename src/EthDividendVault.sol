// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemeToken} from "./MemeToken.sol";

/// @notice ETH dividends: holders claim a share of the dividend pool in ETH,
///         proportional to their token balance.
///
/// Deliberately a sibling of DividendVault rather than a modification of it.
/// The accounting below is the same, line for line, including the
/// settle-on-transfer fix for late entrants — the only difference is what
/// gets paid out. Keeping self-mode's contract untouched means the path that
/// has already been tested and deployed does not move.
///
/// The token side of the split is swapped to ETH by FeeSplitter before it
/// ever reaches here; this contract only ever holds and pays ETH.
contract EthDividendVault is ReentrancyGuard {
    uint256 private constant PRECISION = 1e27;
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;

    MemeToken public immutable token;
    address public immutable splitter;

    /// Cumulative ETH per token held, scaled by PRECISION.
    uint256 public accPerToken;

    /// Balance excluded from dividends: pair, splitter, burn, the vault itself.
    mapping(address => bool) public excluded;

    mapping(address => uint256) public rewardDebt;
    mapping(address => bool) public initialised;

    /// ETH banked at a balance change, awaiting claim.
    mapping(address => uint256) public claimable;

    uint256 public totalDeposited;
    uint256 public totalClaimed;

    event Deposited(uint256 amount, uint256 perToken);
    event Claimed(address indexed holder, uint256 amount);

    error NotSplitter();
    error NothingToClaim();
    error NoEligibleSupply();
    error NotToken();
    error SendFailed();
    error NothingSent();

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
    /// Identical to DividendVault: eligibility is about who holds the TOKEN,
    /// regardless of what the dividend is paid in.
    function eligibleSupply() public view returns (uint256) {
        uint256 supply = token.totalSupply();
        return supply - token.balanceOf(address(this)) - token.balanceOf(splitter) - token.balanceOf(BURN)
            - token.balanceOf(token.dexPair());
    }

    /// Called by the splitter with the ETH it swapped the dividend tranche
    /// into. Payable rather than pull-based, because there is no ETH
    /// equivalent of transferFrom.
    function depositEth() external payable {
        if (msg.sender != splitter) revert NotSplitter();
        if (msg.value == 0) revert NothingSent();

        uint256 eligible = eligibleSupply();
        if (eligible == 0) revert NoEligibleSupply();

        accPerToken += (msg.value * PRECISION) / eligible;
        totalDeposited += msg.value;

        emit Deposited(msg.value, (msg.value * PRECISION) / eligible);
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

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert SendFailed();

        emit Claimed(msg.sender, amount);
    }

    /// Stray ETH sent here is simply held. It is deliberately NOT credited to
    /// the accumulator: doing so would let anyone move every holder's
    /// entitlement by sending dust, and a donation with no matching deposit
    /// would leave the vault owing more than it received.
    receive() external payable {}
}
