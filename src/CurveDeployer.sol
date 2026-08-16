// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BondingCurve} from "./BondingCurve.sol";

/// @notice Holds BondingCurve's bytecode so the factory doesn't have to.
///         Without this the factory exceeds the 24,576-byte EIP-170 limit.
contract CurveDeployer {
    address public factory;

    error NotFactory();
    error AlreadySet();

    /// Set once, immediately after the factory is deployed.
    function setFactory(address factory_) external {
        if (factory != address(0)) revert AlreadySet();
        factory = factory_;
    }

    struct Args {
        string name;
        string symbol;
        uint256 maxSupply;
        address creator;
        address feeRecipient;
        uint256 capBps;
        address router;
        address launchpad;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint32 taxDurationDays;
        address marketing;
        uint16 liquidityBps;
        uint16 burnBps;
        uint16 marketingBps;
        uint16 dividendBps;
    }

    function deploy(Args calldata a) external returns (BondingCurve curve) {
        if (msg.sender != factory) revert NotFactory();

        curve = new BondingCurve(
            a.name,
            a.symbol,
            a.maxSupply,
            a.creator,
            a.feeRecipient,
            a.capBps,
            a.router,
            a.launchpad,
            a.buyTaxBps,
            a.sellTaxBps,
            a.taxDurationDays,
            a.marketing,
            a.liquidityBps,
            a.burnBps,
            a.marketingBps,
            a.dividendBps
        );
    }
}
