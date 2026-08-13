// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReferralNFT} from "./ReferralNFT.sol";

/// @notice Central payout layer for the No Sleep ecosystem.
///         Products deposit here; Genesis NFT holders claim.
contract RewardsDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    address public constant ETH = address(0);
    uint256 private constant PRECISION = 1e27;

    ReferralNFT public immutable nft;

    /// Every asset ever deposited, so enrolment can snapshot each one.
    address[] public assets;
    mapping(address => bool) public knownAsset;

    /// asset => cumulative reward per NFT, scaled by PRECISION
    mapping(address => uint256) public accPerNft;

    /// asset => tokenId => accumulator already accounted for
    mapping(address => mapping(uint256 => uint256)) public rewardDebt;

    uint256 public eligibleCount;
    mapping(uint256 => bool) public enrolled;

    event Enrolled(uint256 indexed tokenId);
    event Deposited(address indexed asset, uint256 amount, uint256 perNft);
    event Claimed(uint256 indexed tokenId, address indexed asset, address indexed to, uint256 amount);

    error NoEligibleHolders();
    error NotGenesis();
    error AlreadyEnrolled();
    error NotEnrolled();
    error NotOwner();
    error NothingToClaim();
    error SendFailed();

    constructor(address admin, ReferralNFT nft_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        nft = nft_;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    /// Permissionless: Genesis status is read from the NFT contract.
    /// Debt starts at the current accumulator for every asset seen so far,
    /// so a late entrant cannot claim rewards deposited before it joined.
    function enroll(uint256 tokenId) external {
        if (enrolled[tokenId]) revert AlreadyEnrolled();

        (, , , , , , uint32 genesisNumber, , ReferralNFT.Status status, ) = nft.referrals(tokenId);
        if (status != ReferralNFT.Status.Genesis || genesisNumber == 0) revert NotGenesis();

        enrolled[tokenId] = true;
        eligibleCount    += 1;

        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = assets[i];
            rewardDebt[a][tokenId] = accPerNft[a];
        }

        emit Enrolled(tokenId);
    }

    function _track(address asset) private {
        if (!knownAsset[asset]) {
            knownAsset[asset] = true;
            assets.push(asset);
        }
    }

    function depositEth() external payable onlyRole(DEPOSITOR_ROLE) {
        if (eligibleCount == 0) revert NoEligibleHolders();
        _track(ETH);

        uint256 perNft = (msg.value * PRECISION) / eligibleCount;
        accPerNft[ETH] += perNft;
        emit Deposited(ETH, msg.value, perNft);
    }

    function depositToken(address asset, uint256 amount) external onlyRole(DEPOSITOR_ROLE) {
        if (eligibleCount == 0) revert NoEligibleHolders();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _track(asset);

        uint256 perNft = (amount * PRECISION) / eligibleCount;
        accPerNft[asset] += perNft;
        emit Deposited(asset, amount, perNft);
    }

    function pending(address asset, uint256 tokenId) public view returns (uint256) {
        if (!enrolled[tokenId]) return 0;
        uint256 acc  = accPerNft[asset];
        uint256 debt = rewardDebt[asset][tokenId];
        if (acc <= debt) return 0;
        return (acc - debt) / PRECISION;
    }

    function claim(address asset, uint256 tokenId) external nonReentrant {
        if (!enrolled[tokenId]) revert NotEnrolled();
        address owner = nft.ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner();

        uint256 amount = pending(asset, tokenId);
        if (amount == 0) revert NothingToClaim();

        rewardDebt[asset][tokenId] = accPerNft[asset];
        _pay(asset, owner, amount);

        emit Claimed(tokenId, asset, owner, amount);
    }

    function claimAll(uint256 tokenId) external nonReentrant {
        if (!enrolled[tokenId]) revert NotEnrolled();
        address owner = nft.ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner();

        uint256 paid;
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = assets[i];
            uint256 amount = pending(a, tokenId);
            if (amount == 0) continue;

            rewardDebt[a][tokenId] = accPerNft[a];
            _pay(a, owner, amount);
            paid += 1;

            emit Claimed(tokenId, a, owner, amount);
        }
        if (paid == 0) revert NothingToClaim();
    }

    function _pay(address asset, address to, uint256 amount) private {
        if (asset == ETH) {
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert SendFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}