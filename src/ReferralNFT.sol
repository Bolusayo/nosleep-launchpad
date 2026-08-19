// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Non-transferable referral rights. The referrer earns the commission
///         stream from the project they introduced, for as long as it trades
///         on the curve.
///
/// Soulbound by design. An affiliate commission -- you introduce someone, you
/// earn a share of what they generate -- is an ordinary commercial
/// arrangement. Making the right to that commission freely tradeable is what
/// turns it into something a buyer might acquire purely for the income it
/// produces from someone else's work, and that is a materially different
/// instrument. Until counsel says otherwise, the right stays with the person
/// who earned it: minting works, transfers do not.
contract ReferralNFT is ERC721, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant CREDITOR_ROLE = keccak256("CREDITOR_ROLE");

    enum Status {
        BondingCurve,
        Migrated,
        Genesis
    }

    struct Referral {
        address token;
        address curve;
        string name;
        string ticker;
        uint64 launchDate;
        uint64 migrationDate;
        uint32 genesisNumber; // 0 until migrated
        uint16 commissionBps;
        Status status;
        uint256 lifetimeCommissions;
    }

    uint256 public nextId = 1;
    uint32 public nextGenesisNumber = 1;

    mapping(uint256 => Referral) public referrals;

    /// Commission accrued to the NFT but not yet claimed.
    mapping(uint256 => uint256) public pending;
    /// Commission settled to a past owner at the moment they sold.
    mapping(address => uint256) public claimable;

    event ReferralMinted(uint256 indexed id, address indexed to, address token);
    event Credited(uint256 indexed id, uint256 amount);
    event Settled(uint256 indexed id, address indexed from, uint256 amount);
    event Claimed(address indexed who, uint256 amount);
    event GraduatedToGenesis(uint256 indexed id, uint32 genesisNumber);

    error NotOwner();
    error NothingToClaim();
    error AlreadyMigrated();
    error SendFailed();
    error Soulbound();

    constructor(address admin) ERC721("No Sleep Referral", "NSREF") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(CREDITOR_ROLE, MINTER_ROLE);
    }

    function mintReferral(
        address to,
        address token,
        address curve,
        string calldata name_,
        string calldata ticker_,
        uint16 commissionBps
    ) external onlyRole(MINTER_ROLE) returns (uint256 id) {
        id = nextId++;
        referrals[id] = Referral({
            token: token,
            curve: curve,
            name: name_,
            ticker: ticker_,
            launchDate: uint64(block.timestamp),
            migrationDate: 0,
            genesisNumber: 0,
            commissionBps: commissionBps,
            status: Status.BondingCurve,
            lifetimeCommissions: 0
        });
        _safeMint(to, id);
        emit ReferralMinted(id, to, token);
    }

    /// Called by a curve with ETH attached. Must never revert on the
    /// happy path — a revert here would brick trading on that token.
    function credit(uint256 id) external payable onlyRole(CREDITOR_ROLE) {
        pending[id] += msg.value;
        referrals[id].lifetimeCommissions += msg.value;
        emit Credited(id, msg.value);
    }

    /// Marks a project migrated and assigns its permanent Genesis number.
    function markMigrated(uint256 id) external onlyRole(CREDITOR_ROLE) {
        Referral storage r = referrals[id];
        if (r.status != Status.BondingCurve) revert AlreadyMigrated();
        r.status = Status.Genesis;
        r.migrationDate = uint64(block.timestamp);
        r.genesisNumber = nextGenesisNumber++;
        emit GraduatedToGenesis(id, r.genesisNumber);
    }

    function claim(uint256 id) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        uint256 amount = pending[id];
        if (amount == 0) revert NothingToClaim();
        pending[id] = 0;
        _send(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function claimSettled() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        _send(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// Every mint, transfer and burn flows through here.
    ///
    /// Minting (from == 0) is allowed. Everything else is not: transfers are
    /// blocked to keep the commission with the referrer, and burning is
    /// blocked because the curve credits `pending[id]` without checking
    /// ownership -- a burned id would keep accruing ETH that nobody could
    /// ever claim.
    function _update(address to, uint256 id, address auth) internal override returns (address) {
        address from = _ownerOf(id);

        if (from != address(0)) revert Soulbound();

        // Retained but currently unreachable: with transfers blocked, `from`
        // is always zero here. Kept so that restoring transferability is a
        // one-line change rather than a rewrite, should counsel allow it.
        if (from != address(0) && pending[id] > 0) {
            uint256 amount = pending[id];
            pending[id] = 0;
            claimable[from] += amount;
            emit Settled(id, from, amount);
        }
        return super._update(to, id, auth);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SendFailed();
    }

    function supportsInterface(bytes4 iid) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(iid);
    }
}
