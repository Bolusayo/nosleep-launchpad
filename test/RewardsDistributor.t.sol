// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract RewardsDistributorTest is Test {
    RewardsDistributor internal dist;
    ReferralNFT        internal nft;

    address internal admin    = makeAddr("admin");
    address internal curve    = makeAddr("curve");
    address internal treasury = makeAddr("treasury");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");

    uint256 internal idA;
    uint256 internal idB;
    address internal ETH;

    function setUp() public {
        vm.startPrank(admin);
        nft  = new ReferralNFT(admin);
        dist = new RewardsDistributor(admin, nft);

        nft.grantRole(nft.MINTER_ROLE(), admin);
        nft.grantRole(nft.CREDITOR_ROLE(), curve);
        dist.grantRole(dist.DEPOSITOR_ROLE(), treasury);

        idA = nft.mintReferral(alice, makeAddr("tokA"), curve, "A", "AAA", 100);
        idB = nft.mintReferral(bob,   makeAddr("tokB"), curve, "B", "BBB", 100);
        vm.stopPrank();

        vm.deal(treasury, 100 ether);
        ETH = dist.ETH();
    }

    function _graduate(uint256 id) internal {
        vm.prank(curve);
        nft.markMigrated(id);
    }

    function test_RevertWhen_EnrollingNonGenesis() public {
        vm.expectRevert(RewardsDistributor.NotGenesis.selector);
        dist.enroll(idA);
    }

    function test_EnrollIsPermissionless() public {
        _graduate(idA);

        // carol has no roles and doesn't own the NFT — still allowed.
        vm.prank(carol);
        dist.enroll(idA);

        assertTrue(dist.enrolled(idA));
        assertEq(dist.eligibleCount(), 1);
    }

    function test_RevertWhen_EnrollingTwice() public {
        _graduate(idA);
        dist.enroll(idA);

        vm.expectRevert(RewardsDistributor.AlreadyEnrolled.selector);
        dist.enroll(idA);
    }

    function test_EthSplitsEquallyBetweenHolders() public {
        _graduate(idA);
        _graduate(idB);
        dist.enroll(idA);
        dist.enroll(idB);

        vm.prank(treasury);
        dist.depositEth{value: 10 ether}();

        assertEq(dist.pending(ETH, idA), 5 ether);
        assertEq(dist.pending(ETH, idB), 5 ether);
    }

    function test_OwnerClaimsEth() public {
        _graduate(idA);
        dist.enroll(idA);

        vm.prank(treasury);
        dist.depositEth{value: 4 ether}();

        uint256 before = alice.balance;
        vm.prank(alice);
        dist.claim(ETH, idA);

        assertEq(alice.balance - before, 4 ether);
        assertEq(dist.pending(ETH, idA), 0);
    }

    function test_RevertWhen_NonOwnerClaims() public {
        _graduate(idA);
        dist.enroll(idA);

        vm.prank(treasury);
        dist.depositEth{value: 1 ether}();

        vm.prank(carol);
        vm.expectRevert(RewardsDistributor.NotOwner.selector);
        dist.claim(ETH, idA);
    }

    /// Selling the NFT hands future rewards to the buyer.
    function test_RewardsFollowNftOwnership() public {
        _graduate(idA);
        dist.enroll(idA);

        vm.prank(alice);
        nft.transferFrom(alice, carol, idA);

        vm.prank(treasury);
        dist.depositEth{value: 2 ether}();

        uint256 before = carol.balance;
        vm.prank(carol);
        dist.claim(ETH, idA);
        assertEq(carol.balance - before, 2 ether);
    }

    /// THE critical one: a late entrant must not claim earlier deposits.
    function test_LateEntrantCannotClaimPriorDeposits() public {
        _graduate(idA);
        dist.enroll(idA);

        vm.prank(treasury);
        dist.depositEth{value: 10 ether}();   // only A is eligible

        _graduate(idB);
        dist.enroll(idB);                      // B joins afterwards

        assertEq(dist.pending(ETH, idB), 0, "late entrant must start at zero");
        assertEq(dist.pending(ETH, idA), 10 ether);

        vm.prank(treasury);
        dist.depositEth{value: 10 ether}();    // now split two ways

        assertEq(dist.pending(ETH, idB), 5 ether);
        assertEq(dist.pending(ETH, idA), 15 ether);
    }

    function test_RevertWhen_DepositingWithNoHolders() public {
        vm.prank(treasury);
        vm.expectRevert(RewardsDistributor.NoEligibleHolders.selector);
        dist.depositEth{value: 1 ether}();
    }

    function test_RevertWhen_UnauthorizedDeposit() public {
        _graduate(idA);
        dist.enroll(idA);

        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert();
        dist.depositEth{value: 1 ether}();
    }

    /// No sequence of deposits may create or destroy value.
    function testFuzz_NoValueLeaks(uint96 a, uint96 b) public {
        uint256 x = bound(uint256(a), 2, 1_000 ether);
        uint256 y = bound(uint256(b), 2, 1_000 ether);
        vm.deal(treasury, x + y);

        _graduate(idA);
        _graduate(idB);
        dist.enroll(idA);
        dist.enroll(idB);

        vm.startPrank(treasury);
        dist.depositEth{value: x}();
        dist.depositEth{value: y}();
        vm.stopPrank();

        uint256 owed = dist.pending(ETH, idA) + dist.pending(ETH, idB);
        assertLe(owed, x + y, "cannot owe more than deposited");
        assertGe(owed, x + y - 2, "dust loss must be at most 1 wei per holder");
    }
}
