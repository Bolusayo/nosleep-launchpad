// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Minimal stand-in for Uniswap V2. Testnet and unit tests only.
///
/// The pair and WETH are real contracts now, not fabricated addresses. The
/// curve seeds the pool by transferring both sides to the pair and calling
/// mint() directly, so a pair that is only an entry in a mapping is not
/// enough -- and neither is a WETH that cannot be deposited into.
///
/// MockV2Pair reproduces Uniswap V2's mint accounting, including
/// MINIMUM_LIQUIDITY, so lpAmount here matches what the real router returns.
/// The previous mock derived liquidity from the router's own arguments, which
/// is what produced the long-standing discrepancy against the geometric mean.
contract MockV2Router {
    address public immutable WETH;

    ERC20 public lp;
    bool public shouldFail;
    MockV2Factory public factoryContract;

    constructor() {
        lp = new MockLP();
        factoryContract = new MockV2Factory();
        WETH = address(new MockWETH());
    }

    function factory() external view returns (address) {
        return address(factoryContract);
    }

    function setShouldFail(bool v) external {
        shouldFail = v;
    }

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

        require(IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired), "TRANSFER_FROM_FAILED");

        uint256 liquidity = Math.sqrt(amountTokenDesired * msg.value);
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
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "TRANSFER_FROM_FAILED");
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;

        uint256 ethOut = received / 1e6;
        require(ethOut >= amountOutMin, "INSUFFICIENT_OUTPUT");
        require(address(this).balance >= ethOut, "MOCK_NO_ETH");

        (bool ok,) = to.call{value: ethOut}("");
        require(ok, "ETH_SEND_FAILED");
    }

    receive() external payable {}
}

contract MockLP is ERC20 {
    constructor() ERC20("Mock LP", "MLP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Wrapped ETH, enough of it for the graduation path.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: ETH_SEND_FAILED");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// Uniswap V2 pair accounting, trimmed to what graduation touches.
contract MockV2Pair is ERC20 {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address a, address b) ERC20("Mock Pair", "MPAIR") {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    /// Mirrors UniswapV2Pair.mint. The first mint takes the geometric mean of
    /// the two deposits and permanently locks MINIMUM_LIQUIDITY; later mints
    /// take the smaller proportional share.
    ///
    /// MINIMUM_LIQUIDITY goes to address(1) rather than address(0), because
    /// OpenZeppelin v5 rejects minting to the zero address. The only visible
    /// difference is where those 1000 wei sit.
    function mint(address to) external returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min((amount0 * supply) / reserve0, (amount1 * supply) / reserve1);
        }

        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }

    function sync() external {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }

    function createPair(address a, address b) external returns (address pair) {
        require(pairs[a][b] == address(0), "UniswapV2: PAIR_EXISTS");
        pair = address(new MockV2Pair(a, b));
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }
}
