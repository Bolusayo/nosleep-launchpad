// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Minimal stand-in for Uniswap V2 Router02. Testnet only.
contract MockV2Router {
    address public immutable WETH = address(0xdead);

    ERC20 public lp;
    bool  public shouldFail;
    MockV2Factory public factoryContract;

    constructor() {
        lp = new MockLP();
        factoryContract = new MockV2Factory();
    }

    function factory() external view returns (address) {
        return address(factoryContract);
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

        if (factoryContract.getPair(token, WETH) == address(0)) {
            factoryContract.createPair(token, WETH);
        }

        return (amountTokenDesired, msg.value, liquidity);
    }

    /// Fixed rate for testing: 1 token = 1e-6 ETH.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        require(!shouldFail, "MockRouter: forced failure");

        address tokenIn = path[0];
        uint256 before  = IERC20(tokenIn).balanceOf(address(this));
        require(
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn),
            "TRANSFER_FROM_FAILED"
        );
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;

        uint256 ethOut = received / 1e6;
        require(ethOut >= amountOutMin, "INSUFFICIENT_OUTPUT");
        require(address(this).balance >= ethOut, "MOCK_NO_ETH");

        (bool ok, ) = to.call{value: ethOut}("");
        require(ok, "ETH_SEND_FAILED");
    }

    receive() external payable {}

    

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

contract MockV2Factory {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }

    function createPair(address a, address b) external returns (address pair) {
        pair = address(uint160(uint256(keccak256(abi.encode(a, b)))));
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }
}
