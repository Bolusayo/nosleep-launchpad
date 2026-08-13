// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MemeToken} from "./MemeToken.sol";
import {ReferralNFT} from "./ReferralNFT.sol";
import {IUniswapV2Router, IUniswapV2Factory} from "./interfaces/IUniswapV2Router.sol";
/// @notice Constant-product bonding curve with virtual reserves.
///         Deploys its own token and holds 100% of the supply:
///         80% sells on the curve, 20% seeds the DEX pool at graduation.
contract BondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS             = 10_000;
    uint256 public constant VIRTUAL_QUOTE   = 0.003 ether;
    uint256 public constant QUOTE_TARGET    = 0.004 ether;
    uint256 public constant CURVE_SHARE_BPS = 8_000; // 80%
    uint256 public constant FEE_BPS         = 200;   // 2% trading fee
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;


    MemeToken public immutable token;
    address   public immutable creator;
    address   public immutable factory;
    address   public immutable feeRecipient;

    /// Tokens available on the curve (80% of supply), in wei.
    uint256 public immutable curveSupply;
    /// Max tokens one wallet may buy before graduation. 0 = no cap.
    uint256 public immutable maxBuyPerWallet;

    uint256 public quoteReserve; // virtual + real ETH
    uint256 public tokenReserve; // virtual token reserve
    bool    public graduated;

    IUniswapV2Router public immutable router;
    address public lpToken;
    uint256 public lpAmount;

    /// Referral NFT that earns a cut of this token's fees. Set once by the factory.
    ReferralNFT public referralNFT;
    uint256     public referralId;
    uint16      public referralBps;

    /// Cumulative tokens bought per wallet — never decreases.
    mapping(address => uint256) public purchased;

    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 fee);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 fee);
    event Graduated(uint256 ethCollected, uint256 tokensLeft);

    error AlreadyGraduated();
    error ZeroAmount();
    error SlippageExceeded(uint256 got, uint256 wanted);
    error WalletCapExceeded(uint256 attempted, uint256 cap);
    error TransferFailed();
    error NotFactory();
    error AlreadySet();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupplyTokens,
        address creator_,
        address feeRecipient_,
        uint256 capBps,
        address router_,
        uint16  buyTaxBps_,
        uint16  sellTaxBps_,
        uint32  taxDurationDays_
    ) {
        router = IUniswapV2Router(router_);
        token   = new MemeToken(
            name_, symbol_, maxSupplyTokens, address(this), creator_,
            buyTaxBps_, sellTaxBps_, taxDurationDays_
        );
        creator = creator_;
        factory = msg.sender;
        feeRecipient = feeRecipient_;

        uint256 s = (token.totalSupply() * CURVE_SHARE_BPS) / BPS;
        curveSupply = s;

        quoteReserve = VIRTUAL_QUOTE;
        tokenReserve = s + (VIRTUAL_QUOTE * s) / QUOTE_TARGET;

        maxBuyPerWallet = capBps == 0 ? 0 : (s * capBps) / BPS;
    }

    /// Real ETH held for the graduation pool. Derived, never stored.
    function ethCollected() public view returns (uint256) {
        return quoteReserve - VIRTUAL_QUOTE;
    }

    /// Exact token output for a given ETH input, including the partial-fill cap.
    /// Frontends call this instead of reimplementing the curve maths.
    function quoteBuy(uint256 ethIn) external view returns (uint256 tokensOut, uint256 ethAccepted) {
        if (graduated || ethIn == 0) return (0, 0);

        uint256 room     = VIRTUAL_QUOTE + QUOTE_TARGET - quoteReserve;
        uint256 grossMax = Math.mulDiv(room, BPS, BPS - FEE_BPS);
        uint256 gross    = ethIn > grossMax ? grossMax : ethIn;

        uint256 fee     = (gross * FEE_BPS) / BPS;
        uint256 quoteIn = gross - fee;

        uint256 k    = quoteReserve * tokenReserve;
        uint256 newQ = quoteReserve + quoteIn;
        uint256 newT = Math.ceilDiv(k, newQ);

        return (tokenReserve - newT, gross);
    }

    /// Exact ETH output for selling a given token amount, net of fees.
    function quoteSell(uint256 tokenAmount) external view returns (uint256 ethOut) {
        if (graduated || tokenAmount == 0) return 0;

        uint256 k    = quoteReserve * tokenReserve;
        uint256 newT = tokenReserve + tokenAmount;
        uint256 newQ = Math.ceilDiv(k, newT);
        uint256 out  = quoteReserve - newQ;

        return out - (out * FEE_BPS) / BPS;
    }

    /// Called once by the factory immediately after deployment.
    function setReferral(ReferralNFT nft, uint256 id, uint16 bps) external {
        if (msg.sender != factory) revert NotFactory();
        if (address(referralNFT) != address(0)) revert AlreadySet();
        referralNFT = nft;
        referralId  = id;
        referralBps = bps;
    }

    function buy(uint256 minTokensOut) external payable nonReentrant {
        _buy(msg.sender, msg.value, minTokensOut, true);
    }

    /// Deployer's launch buy — atomic with deployment, exempt from the cap.
    function buyFor(address beneficiary, uint256 minTokensOut)
        external
        payable
        nonReentrant
    {
        if (msg.sender != factory) revert NotFactory();
        _buy(beneficiary, msg.value, minTokensOut, false);
    }

    function _buy(
        address beneficiary,
        uint256 valueIn,
        uint256 minTokensOut,
        bool enforceCap
    ) private {
        if (graduated) revert AlreadyGraduated();
        if (valueIn == 0) revert ZeroAmount();

        uint256 room     = VIRTUAL_QUOTE + QUOTE_TARGET - quoteReserve;
        uint256 grossMax = Math.mulDiv(room, BPS, BPS - FEE_BPS);
        uint256 gross    = valueIn > grossMax ? grossMax : valueIn;
        uint256 refund   = valueIn - gross;

        uint256 fee     = (gross * FEE_BPS) / BPS;
        uint256 quoteIn = gross - fee;

        uint256 k           = quoteReserve * tokenReserve;
        uint256 newQuote    = quoteReserve + quoteIn;
        uint256 newTokenRes = Math.ceilDiv(k, newQuote);
        uint256 tokensOut   = tokenReserve - newTokenRes;

        if (tokensOut < minTokensOut) revert SlippageExceeded(tokensOut, minTokensOut);

        if (enforceCap && maxBuyPerWallet != 0) {
            uint256 total = purchased[beneficiary] + tokensOut;
            if (total > maxBuyPerWallet) revert WalletCapExceeded(total, maxBuyPerWallet);
            purchased[beneficiary] = total;
        }

        quoteReserve = newQuote;
        tokenReserve = newTokenRes;

        IERC20(address(token)).safeTransfer(beneficiary, tokensOut);
        _payFee(fee);
        if (refund > 0) _sendEth(beneficiary, refund);

        emit Bought(beneficiary, quoteIn, tokensOut, fee);

        if (quoteReserve >= VIRTUAL_QUOTE + QUOTE_TARGET) {
            _graduate();
        }
    }

    function sell(uint256 tokenAmount, uint256 minEthOut) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (tokenAmount == 0) revert ZeroAmount();

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 k           = quoteReserve * tokenReserve;
        uint256 newTokenRes = tokenReserve + tokenAmount;
        uint256 newQuote    = Math.ceilDiv(k, newTokenRes);
        uint256 quoteOut    = quoteReserve - newQuote;

        uint256 fee = (quoteOut * FEE_BPS) / BPS;
        uint256 net = quoteOut - fee;
        if (net < minEthOut) revert SlippageExceeded(net, minEthOut);

        quoteReserve = newQuote;
        tokenReserve = newTokenRes;

        _sendEth(msg.sender, net);
        _payFee(fee);

        emit Sold(msg.sender, tokenAmount, net, fee);
    }


    event MigratedToDex(address lpToken, uint256 ethIn, uint256 tokensIn, uint256 liquidity);

    error MigrationFailed();

    /// Moves the raise plus the remaining supply (and any accrued tax) into a
    /// Uniswap V2 pool. LP is burned. For taxed tokens the pair is registered
    /// on the token afterwards so post-graduation trades are taxed.
    function _graduate() private {
        graduated = true;

        uint256 ethForLp    = ethCollected();
        uint256 tokensForLp = token.balanceOf(address(this));

        emit Graduated(ethForLp, tokensForLp);

        if (address(router) == address(0) || ethForLp == 0 || tokensForLp == 0) return;

        // The router must be exempt: it holds tokens briefly between the
        // transferFrom and the pair deposit, and a tax there would seed the
        // pool short and trip the slippage guard.
        token.setExempt(address(router), true);

        IERC20(address(token)).forceApprove(address(router), tokensForLp);

        try router.addLiquidityETH{value: ethForLp}(
            address(token),
            tokensForLp,
            (tokensForLp * 9000) / BPS,
            (ethForLp * 9000) / BPS,
            BURN,
            block.timestamp
        ) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
            lpAmount = liquidity;
            _registerPair();
            emit MigratedToDex(lpToken, amountETH, amountToken, liquidity);
        } catch {
            revert MigrationFailed();
        }
    }

    /// Looks up the freshly created pair and tells the token about it, so the
    /// token can distinguish buys from sells. Never reverts — a missing pair
    /// means no post-graduation tax, which is far better than a stuck curve.
    function _registerPair() private {
        try router.factory() returns (address f) {
            try IUniswapV2Factory(f).getPair(address(token), router.WETH())
                returns (address pair)
            {
                if (pair != address(0)) {
                    lpToken = pair;
                    token.setDexPair(pair);
                }
            } catch {}
        } catch {}
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// Splits the trading fee between the referral NFT and the protocol.
    /// Never reverts on a bad NFT — trading must not be brickable.
    function _payFee(uint256 fee) private {
        if (fee == 0) return;

        uint256 refCut;
        if (address(referralNFT) != address(0) && referralBps != 0) {
            refCut = (fee * referralBps) / BPS;
            if (refCut > 0) {
                try referralNFT.credit{value: refCut}(referralId) {
                    // credited
                } catch {
                    refCut = 0; // fall through to protocol
                }
            }
        }

        _sendEth(feeRecipient, fee - refCut);
    }


    
}
