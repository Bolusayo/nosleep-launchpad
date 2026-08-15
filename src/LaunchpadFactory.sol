// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {ReferralNFT} from "./ReferralNFT.sol";
import {CurveDeployer} from "./CurveDeployer.sol";

/// @notice Entry point for the launchpad. One transaction deploys the token,
///         its curve, the referral NFT, and the creator's launch buy.
contract LaunchpadFactory is Ownable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;

    ReferralNFT public immutable referralNFT;
    address     public immutable router;
    CurveDeployer public immutable curveDeployer;

    uint256 public deployFee = 0.002 ether;
    uint16  public referralCommissionBps = 1_000; // 10% of the 2% trade fee
    address public feeRecipient;

    struct Launch {
        address curve;
        address token;
        address creator;
        uint256 referralId; // 0 = no referrer
        uint64  createdAt;
    }

    Launch[] public launches;
    mapping(address => uint256) public launchIdByToken;

    /// token => off-chain metadata URI (IPFS hash, https URL, or data URI).
    /// Set once at launch by the creator. Empty means none was provided.
    mapping(address => string) public metadataURI;


    event TokenLaunched(
        address indexed creator,
        address indexed token,
        address curve,
        uint256 referralId,
        uint256 devBuy
    );
    event DeployFeeUpdated(uint256 fee);
    event FeeRecipientUpdated(address recipient);

    error InsufficientFee(uint256 sent, uint256 required);
    error SendFailed();

    constructor(
        address owner_,
        address feeRecipient_,
        ReferralNFT nft,
        address router_,
        CurveDeployer deployer_
    ) Ownable(owner_) {
        feeRecipient  = feeRecipient_;
        referralNFT   = nft;
        router        = router_;
        curveDeployer = deployer_;
    }

    struct LaunchParams {
        string  name;
        string  symbol;
        uint256 maxSupply;
        uint256 capBps;
        address referrer;
        uint256 minTokensOut;
        uint16  buyTaxBps;
        uint16  sellTaxBps;
        uint32  taxDurationDays;
        address marketing;
        uint16  liquidityBps;
        uint16  burnBps;
        uint16  marketingBps;
        uint16  dividendBps;
        string  metadata;
    }

    function createToken(LaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (address curveAddr, address tokenAddr, uint256 referralId)
    {
        if (msg.value < deployFee) revert InsufficientFee(msg.value, deployFee);
        uint256 devBuy = msg.value - deployFee;

        BondingCurve curve = curveDeployer.deploy(CurveDeployer.Args({
            name: p.name,
            symbol: p.symbol,
            maxSupply: p.maxSupply,
            creator: msg.sender,
            feeRecipient: feeRecipient,
            capBps: p.capBps,
            router: router,
            launchpad: address(this),
            buyTaxBps: p.buyTaxBps,
            sellTaxBps: p.sellTaxBps,
            taxDurationDays: p.taxDurationDays,
            marketing: p.marketing,
            liquidityBps: p.liquidityBps,
            burnBps: p.burnBps,
            marketingBps: p.marketingBps,
            dividendBps: p.dividendBps
        }));

        curveAddr = address(curve);
        tokenAddr = address(curve.token());

        if (p.referrer != address(0) && p.referrer != msg.sender) {
            referralId = referralNFT.mintReferral(
                p.referrer,
                tokenAddr,
                curveAddr,
                p.name,
                p.symbol,
                referralCommissionBps
            );
        }

        if (referralId != 0) {
            referralNFT.grantRole(referralNFT.CREDITOR_ROLE(), curveAddr);
            curve.setReferral(referralNFT, referralId, referralCommissionBps);
        }

        launches.push(Launch({
            curve: curveAddr,
            token: tokenAddr,
            creator: msg.sender,
            referralId: referralId,
            createdAt: uint64(block.timestamp)
        }));
        launchIdByToken[tokenAddr] = launches.length - 1;

        if (bytes(p.metadata).length > 0) {
            metadataURI[tokenAddr] = p.metadata;
        }

        _send(feeRecipient, deployFee);

        if (devBuy > 0) {
            curve.buyFor{value: devBuy}(msg.sender, p.minTokensOut);
        }

        emit TokenLaunched(msg.sender, tokenAddr, curveAddr, referralId, devBuy);
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    /// Paginated read for the Explore page. Newest first.
    function getLaunches(uint256 offset, uint256 limit)
        external
        view
        returns (Launch[] memory page)
    {
        uint256 total = launches.length;
        if (offset >= total) return new Launch[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new Launch[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = launches[total - 1 - i];
        }
    }

    function setDeployFee(uint256 fee) external onlyOwner {
        deployFee = fee;
        emit DeployFeeUpdated(fee);
    }

    function setFeeRecipient(address r) external onlyOwner {
        feeRecipient = r;
        emit FeeRecipientUpdated(r);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert SendFailed();
    }
}
