// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Minimal stand-in for Uniswap V2 Router02. Testnet only.
contract MockV2Router {
    address public immutable WETH = address(0xdead);

    ERC20 public lp;
    bool  public shouldFail;

    constructor() {
        lp = new MockLP();
    }

    function setShouldFail(bool v) external { shouldFail = v; }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256
    ) external payable returns (uint256, uint256, uint256) {
        require(!shouldFail, "MockRouter: forced failure");
        require(amountTokenDesired >= amountTokenMin, "INSUFFICIENT_TOKEN");
        require(msg.value >= amountETHMin, "INSUFFICIENT_ETH");

        require(
            IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired),
            "TRANSFER_FROM_FAILED"
        );
        
        uint256 liquidity = _sqrt(amountTokenDesired * msg.value);
        MockLP(address(lp)).mint(to, liquidity);

        return (amountTokenDesired, msg.value, liquidity);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }
}

contract MockLP is ERC20 {
    constructor() ERC20("Mock LP", "MLP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
