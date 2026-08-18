// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IDividendSync {
    function onBalanceChange(address from, address to) external;
}

/// @notice Fixed-supply token deployed by the No Sleep launchpad.
///         Optional asymmetric buy/sell tax, collected to the curve during
///         the bonding phase and to the collector after graduation.
contract MemeToken is ERC20 {
    uint256 public constant MIN_SUPPLY = 1_000_000;
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_TAX_BPS = 1_000; // 10% ceiling, per UI

    address public immutable curve;
    address public immutable creator;

    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    uint64 public immutable taxEndsAt;

    /// Addresses that neither pay nor trigger tax: the curve, the router,
    /// the pair. Without these, graduation deposits less than it promises
    /// and the migration reverts on slippage.
    mapping(address => bool) public taxExempt;

    /// Set once by the curve at graduation so the pair can be marked.
    address public dexPair;

    /// False until the curve seeds the pool at graduation. While false, no
    /// transfer into `dexPair` is allowed.
    ///
    /// The pair is created up front, at curve construction, so that graduation
    /// can mint the opening position directly instead of asking the router to
    /// quote against whatever is already in the pool. That is only safe if the
    /// pair is guaranteed empty beforehand: a griefer who could put tokens in
    /// early would already hold LP, and the mint would hand them a share of
    /// the raise. This flag is the guarantee.
    bool public poolSeeded;

    /// Where tax goes. The curve during the bonding phase, the splitter after.
    address public taxCollector;

    /// Dividend vault notified before balances move, so it can settle accrued
    /// dividends and snapshot new holders. Set once at graduation.
    address public dividendVault;

    event TaxTaken(address indexed from, address indexed to, uint256 amount, bool isBuy);
    event DexPairSet(address pair);

    error SupplyOutOfRange(uint256 given);
    error ZeroAddress();
    error TaxTooHigh(uint16 given);
    error NotCurve();
    error PairAlreadySet();
    error PoolLocked();
    error VaultAlreadySet();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupplyTokens,
        address curve_,
        address creator_,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        uint32 taxDurationDays
    ) ERC20(name_, symbol_) {
        if (maxSupplyTokens < MIN_SUPPLY || maxSupplyTokens > MAX_SUPPLY) {
            revert SupplyOutOfRange(maxSupplyTokens);
        }
        if (curve_ == address(0) || creator_ == address(0)) revert ZeroAddress();
        if (buyTaxBps_ > MAX_TAX_BPS) revert TaxTooHigh(buyTaxBps_);
        if (sellTaxBps_ > MAX_TAX_BPS) revert TaxTooHigh(sellTaxBps_);

        curve = curve_;
        creator = creator_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        taxEndsAt = taxDurationDays == 0 ? 0 : uint64(block.timestamp + uint256(taxDurationDays) * 1 days);

        taxExempt[curve_] = true;
        taxExempt[address(this)] = true;
        taxCollector = curve_;

        _mint(curve_, maxSupplyTokens * 10 ** decimals());
    }

    function taxActive() public view returns (bool) {
        if (buyTaxBps == 0 && sellTaxBps == 0) return false;
        if (taxEndsAt == 0) return true; // 0 duration = forever
        return block.timestamp < taxEndsAt;
    }

    /// Called once by the curve when the DEX pair is created at graduation.
    function setDexPair(address pair) external {
        if (msg.sender != curve) revert NotCurve();
        if (dexPair != address(0)) revert PairAlreadySet();
        dexPair = pair;
        emit DexPairSet(pair);
    }

    /// Redirects tax to the fee splitter at graduation. Curve-only, once.
    function setTaxCollector(address collector) external {
        if (msg.sender != curve) revert NotCurve();
        if (collector == address(0)) revert ZeroAddress();
        taxCollector = collector;
        taxExempt[collector] = true;
    }

    /// Opens the pool. Curve-only, called immediately before the seed
    /// transfer at graduation. One-way.
    function setPoolSeeded() external {
        if (msg.sender != curve) revert NotCurve();
        poolSeeded = true;
    }

    /// Wires the dividend vault. Curve-only, once, at graduation.
    function setDividendVault(address vault) external {
        if (msg.sender != curve) revert NotCurve();
        if (vault == address(0)) revert ZeroAddress();
        if (dividendVault != address(0)) revert VaultAlreadySet();
        dividendVault = vault;
        taxExempt[vault] = true;
    }

    /// Marks the router exempt. Curve-only, callable before graduation.
    function setExempt(address who, bool on) external {
        if (msg.sender != curve) revert NotCurve();
        taxExempt[who] = on;
    }

    /// Every transfer, mint and burn flows through here in OZ v5.
    function _update(address from, address to, uint256 value) internal override {
        // Settle dividends BEFORE balances move: a receiver seen at zero
        // balance is new and must not inherit prior accruals.
        address v = dividendVault;
        if (v != address(0)) {
            IDividendSync(v).onBalanceChange(from, to);
        }

        // Nothing may enter the pair until the curve seeds it. Without this
        // the direct mint at graduation is exploitable -- see poolSeeded.
        if (!poolSeeded && to != address(0) && to == dexPair) revert PoolLocked();

        // Mints, burns, and anything involving an exempt address: no tax.
        if (from == address(0) || to == address(0) || taxExempt[from] || taxExempt[to]) {
            super._update(from, to, value);
            return;
        }

        if (!taxActive()) {
            super._update(from, to, value);
            return;
        }

        // A trade against the pair is a buy (from pair) or a sell (to pair).
        bool isBuy = from == dexPair;
        bool isSell = to == dexPair;

        if (!isBuy && !isSell) {
            super._update(from, to, value); // wallet-to-wallet is untaxed
            return;
        }

        uint256 rate = isBuy ? buyTaxBps : sellTaxBps;
        uint256 fee = (value * rate) / BPS;

        if (fee > 0) {
            super._update(from, taxCollector, fee);
            emit TaxTaken(from, to, fee, isBuy);
        }

        super._update(from, to, value - fee);
    }
}
