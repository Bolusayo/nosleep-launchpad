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
    function test_TransferSettlesToSeller() public {
        vm.prank(curve);
        nft.credit{value: 1 ether}(id);

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        // Alice's ether is preserved, not handed to Bob.
        assertEq(nft.pending(id), 0);
        assertEq(nft.claimable(alice), 1 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        nft.claimSettled();
        assertEq(alice.balance - before, 1 ether);
    }

    /// And Bob earns everything after the sale.
    function test_NewOwnerEarnsFutureCommissions() public {
        vm.prank(curve);
        nft.credit{value: 1 ether}(id);

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        vm.prank(curve);
        nft.credit{value: 2 ether}(id);

        assertEq(nft.pending(id), 2 ether);

        uint256 before = bob.balance;
        vm.prank(bob);
        nft.claim(id);
        assertEq(bob.balance - before, 2 ether);

        // Alice cannot touch the post-sale commission.
        assertEq(nft.claimable(alice), 1 ether);
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
    function testFuzz_NoValueLeaks(uint96 a, uint96 b) public {
        uint256 x = bound(uint256(a), 1, 1_000 ether);
        uint256 y = bound(uint256(b), 1, 1_000 ether);
        vm.deal(curve, x + y);

        vm.prank(curve);
        nft.credit{value: x}(id);

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        vm.prank(curve);
        nft.credit{value: y}(id);

        assertEq(nft.claimable(alice) + nft.pending(id), x + y);
        assertEq(address(nft).balance, x + y);
    }
}
