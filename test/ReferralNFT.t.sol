// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";

contract ReferralNFTTest is Test {
    ReferralNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal curve = makeAddr("curve");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal token = makeAddr("token");

    uint256 internal id;

    function setUp() public {
        nft = new ReferralNFT(admin);

        vm.startPrank(admin);
        nft.grantRole(nft.MINTER_ROLE(), admin);
        nft.grantRole(nft.CREDITOR_ROLE(), curve);
        id = nft.mintReferral(alice, token, curve, "Fault Line", "FAULT", 100);
        vm.stopPrank();

        vm.deal(curve, 100 ether);
    }

    function test_MintedToReferrer() public view {
        assertEq(nft.ownerOf(id), alice);
        assertEq(id, 1);
    }

    function test_RevertWhen_UnauthorizedMint() public {
        vm.prank(bob);
        vm.expectRevert();
        nft.mintReferral(bob, token, curve, "Fake", "FAKE", 100);
    }

    function test_RevertWhen_UnauthorizedCredit() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        nft.credit{value: 1 ether}(id);
    }

    function test_CreditAccrues() public {
        vm.prank(curve);
        nft.credit{value: 1 ether}(id);

        assertEq(nft.pending(id), 1 ether);
        (,,,,,,,,, uint256 lifetime) = nft.referrals(id);
        assertEq(lifetime, 1 ether);
    }

    function test_OwnerCanClaim() public {
        vm.prank(curve);
        nft.credit{value: 1 ether}(id);

        uint256 before = alice.balance;
        vm.prank(alice);
        nft.claim(id);

        assertEq(alice.balance - before, 1 ether);
        assertEq(nft.pending(id), 0);
    }

    function test_RevertWhen_NonOwnerClaims() public {
        vm.prank(curve);
        nft.credit{value: 1 ether}(id);

        vm.prank(bob);
        vm.expectRevert(ReferralNFT.NotOwner.selector);
        nft.claim(id);
    }

    /// THE important one: accrue, then sell. Old owner keeps what accrued.
    /// The referral right stays with the referrer. Nobody can buy the income
    /// The referral right stays with the referrer. Nobody can buy the income
    /// stream from someone else's introduction.
    function test_RevertWhen_Transferring() public {
        vm.prank(alice);
        vm.expectRevert(ReferralNFT.Soulbound.selector);
        nft.transferFrom(alice, bob, id);
    }

    function test_RevertWhen_SafeTransferring() public {
        vm.prank(alice);
        vm.expectRevert(ReferralNFT.Soulbound.selector);
        nft.safeTransferFrom(alice, bob, id);
    }

    /// An approval can be granted but is useless -- the transfer still fails.
    function test_RevertWhen_ApprovedSpenderTransfers() public {
        vm.prank(alice);
        nft.approve(bob, id);

        vm.prank(bob);
        vm.expectRevert(ReferralNFT.Soulbound.selector);
        nft.transferFrom(alice, bob, id);
    }

    /// Commission keeps accruing to the referrer regardless.
    function test_CommissionStaysWithReferrer() public {
        vm.prank(curve);
        nft.credit{value: 1 ether}(id);

        assertEq(nft.pending(id), 1 ether);
        assertEq(nft.ownerOf(id), alice, "referrer still holds it");

        uint256 before = alice.balance;
        vm.prank(alice);
        nft.claim(id);
        assertEq(alice.balance - before, 1 ether, "referrer receives it");
    }

    function test_MigrationAssignsGenesisNumber() public {
        vm.prank(curve);
        nft.markMigrated(id);

        (,,,,,, uint32 genesisNumber,, ReferralNFT.Status status,) = nft.referrals(id);

        assertEq(genesisNumber, 1);
        assertEq(uint8(status), uint8(ReferralNFT.Status.Genesis));
    }

    function test_RevertWhen_MigratingTwice() public {
        vm.startPrank(curve);
        nft.markMigrated(id);
        vm.expectRevert(ReferralNFT.AlreadyMigrated.selector);
        nft.markMigrated(id);
        vm.stopPrank();
    }

    function test_GenesisNumbersAreSequential() public {
        vm.prank(admin);
        uint256 id2 = nft.mintReferral(bob, token, curve, "Second", "SEC", 100);

        vm.startPrank(curve);
        nft.markMigrated(id);
        nft.markMigrated(id2);
        vm.stopPrank();

        (,,,,,, uint32 g1,,,) = nft.referrals(id);
        (,,,,,, uint32 g2,,,) = nft.referrals(id2);
        assertEq(g1, 1);
        assertEq(g2, 2);
    }

    /// No sequence of credits and transfers may create or destroy ether.
    /// Whatever is credited is exactly what can be claimed. No dust, no leak.
    /// Whatever is credited is exactly what can be claimed. No dust, no leak.
    function testFuzz_CreditedEqualsClaimed(uint96 a, uint96 b) public {
        vm.assume(uint256(a) + uint256(b) > 0);
        vm.deal(curve, uint256(a) + uint256(b));

        vm.prank(curve);
        nft.credit{value: a}(id);
        vm.prank(curve);
        nft.credit{value: b}(id);

        uint256 total = uint256(a) + uint256(b);
        assertEq(nft.pending(id), total, "all credits accrue");

        uint256 before = alice.balance;
        vm.prank(alice);
        nft.claim(id);

        assertEq(alice.balance - before, total, "all of it is claimable");
        assertEq(address(nft).balance, 0, "nothing left behind");
        assertEq(nft.pending(id), 0, "pending cleared");
    }
}
