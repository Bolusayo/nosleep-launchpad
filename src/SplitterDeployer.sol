// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MemeToken} from "./MemeToken.sol";
import {FeeSplitter} from "./FeeSplitter.sol";
import {DividendVault} from "./DividendVault.sol";
import {EthDividendVault} from "./EthDividendVault.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";

/// @notice Holds FeeSplitter and DividendVault bytecode so BondingCurve
///         doesn't have to. Without this, CurveDeployer exceeds the EIP-170
///         24,576-byte limit. Same pattern as CurveDeployer relative to
///         LaunchpadFactory.
contract SplitterDeployer {
    struct Args {
        MemeToken token;
        IUniswapV2Router router;
        address marketing;
        uint16 liquidityBps;
        uint16 burnBps;
        uint16 marketingBps;
        uint16 dividendBps;
        uint256 threshold;
        FeeSplitter.BurnMode burnMode;
        FeeSplitter.DividendMode dividendMode;
        address[] excluded;
    }

    /// Deploys the splitter and its vault, wires them together, and hands both
    /// back. The caller (a BondingCurve) then points the token at them.
    ///
    /// Deliberately permissionless. Deploying an orphan splitter for a token
    /// you do not control grants nothing: only the token's immutable `curve`
    /// can redirect its tax collector or mark addresses exempt.
    ///
    /// FeeSplitter records its deployer as msg.sender, so this contract — not
    /// the curve — is what may call setDividendVault. It does so here, once,
    /// before returning.
    /// Returns the vault as a plain address because which contract it is
    /// depends on the mode: DividendVault pays the token itself,
    /// EthDividendVault pays ETH. Both expose the same onBalanceChange hook,
    /// which is all MemeToken needs, so the token is wired identically either
    /// way.
    function deploy(Args calldata a) external returns (FeeSplitter splitter, address vault) {
        splitter = new FeeSplitter(
            a.token,
            a.router,
            a.marketing,
            a.liquidityBps,
            a.burnBps,
            a.marketingBps,
            a.dividendBps,
            a.threshold,
            a.burnMode,
            a.dividendMode
        );

        vault = a.dividendMode == FeeSplitter.DividendMode.Eth
            ? address(new EthDividendVault(a.token, address(splitter), a.excluded))
            : address(new DividendVault(a.token, address(splitter), a.excluded));

        splitter.setDividendVault(vault);
    }
}
