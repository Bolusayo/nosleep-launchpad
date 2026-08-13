// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token deployed by the No Sleep launchpad.
///         Optional asymmetric buy/sell tax, collected to the curve during
///         the bonding phase and to the collector after graduation.
contract MemeToken is ERC20 {
    uint256 public constant MIN_SUPPLY = 1_000_000;
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000;
    uint256 public constant BPS        = 10_000;
    uint256 public constant MAX_TAX_BPS = 1_000; // 10% ceiling, per UI

    address public immutable curve;
    address public immutable creator;

    uint16  public immutable buyTaxBps;
    uint16  public immutable sellTaxBps;
    uint64  public immutable taxEndsAt;

    /// Addresses that neither pay nor trigger tax: the curve, the router,
    /// the pair. Without these, graduation deposits less than it promises
    /// and the migration reverts on slippage.
    mapping(address => bool) public taxExempt;

    /// Set once by the curve at graduation so the pair can be marked.
    address public dexPair;

    event TaxTaken(address indexed from, address indexed to, uint256 amount, bool isBuy);
    event DexPairSet(address pair);

    error SupplyOutOfRange(uint256 given);
    error ZeroAddress();
    error TaxTooHigh(uint16 given);
    error NotCurve();
    error PairAlreadySet();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupplyTokens,
        address curve_,
        address creator_,
        uint16  buyTaxBps_,
        uint16  sellTaxBps_,
        uint32  taxDurationDays
    ) ERC20(name_, symbol_) {
        if (maxSupplyTokens < MIN_SUPPLY || maxSupplyTokens > MAX_SUPPLY) {
            revert SupplyOutOfRange(maxSupplyTokens);
        }
        if (curve_ == address(0) || creator_ == address(0)) revert ZeroAddress();
        if (buyTaxBps_ > MAX_TAX_BPS)  revert TaxTooHigh(buyTaxBps_);
        if (sellTaxBps_ > MAX_TAX_BPS) revert TaxTooHigh(sellTaxBps_);

        curve      = curve_;
        creator    = creator_;
        buyTaxBps  = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        taxEndsAt  = taxDurationDays == 0
            ? 0
            : uint64(block.timestamp + uint256(taxDurationDays) * 1 days);

        taxExempt[curve_]       = true;
        taxExempt[address(this)] = true;

        _mint(curve_, maxSupplyTokens * 10 ** decimals());
    }

    function taxActive() public view returns (bool) {
        if (buyTaxBps == 0 && sellTaxBps == 0) return false;
        if (taxEndsAt == 0) return true;          // 0 duration = forever
        return block.timestamp < taxEndsAt;
    }

    /// Called once by the curve when the DEX pair is created at graduation.
    function setDexPair(address pair) external {
        if (msg.sender != curve) revert NotCurve();
        if (dexPair != address(0)) revert PairAlreadySet();
        dexPair = pair;
        emit DexPairSet(pair);
    }

    /// Marks the router exempt. Curve-only, callable before graduation.
    function setExempt(address who, bool on) external {
        if (msg.sender != curve) revert NotCurve();
        taxExempt[who] = on;
    }

    /// Every transfer, mint and burn flows through here in OZ v5.
    function _update(address from, address to, uint256 value) internal override {
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
        bool isBuy  = from == dexPair;
        bool isSell = to   == dexPair;

        if (!isBuy && !isSell) {
            super._update(from, to, value);   // wallet-to-wallet is untaxed
            return;
        }

        uint256 rate = isBuy ? buyTaxBps : sellTaxBps;
        uint256 fee  = (value * rate) / BPS;

        if (fee > 0) {
            super._update(from, curve, fee);  // tax accrues to the curve
            emit TaxTaken(from, to, fee, isBuy);
        }

        super._update(from, to, value - fee);
    }
}
