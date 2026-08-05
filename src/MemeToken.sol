// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token deployed by the No Sleep launchpad.
///         Entire supply is minted to the bonding curve at construction.
///         There is no mint function. Supply is locked forever.
contract MemeToken is ERC20 {
    /// Supply bounds, in whole tokens — mirrors the frontend slider (1M to 1T).
    uint256 public constant MIN_SUPPLY = 1_000_000;
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000;

    /// The bonding curve holding every token. Set once, never changes.
    address public immutable curve;

    /// Wallet that launched this token. Informational only — no powers.
    address public immutable creator;

    error SupplyOutOfRange(uint256 given);
    error ZeroAddress();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupplyTokens,
        address curve_,
        address creator_
    ) ERC20(name_, symbol_) {
        if (maxSupplyTokens < MIN_SUPPLY || maxSupplyTokens > MAX_SUPPLY) {
            revert SupplyOutOfRange(maxSupplyTokens);
        }
        if (curve_ == address(0) || creator_ == address(0)) revert ZeroAddress();

        curve = curve_;
        creator = creator_;

        _mint(curve_, maxSupplyTokens * 10 ** decimals());
    }
}