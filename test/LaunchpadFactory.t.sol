// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";

contract LaunchpadFactoryTest is Test {
    LaunchpadFactory internal factory;
    ReferralNFT      internal nft;

    address internal admin    = makeAddr("admin");
    address internal protocol = makeAddr("protocol");
    address internal creator  = makeAddr("creator");
    address internal referrer = makeAddr("referrer");
    address internal trader   = makeAddr("trader");

    uint256 internal constant FEE = 0.002 ether;

    function setUp() public {
        vm.startPrank(admin);
        nft     = new ReferralNFT(admin);
        factory = new LaunchpadFactory(admin, protocol, nft);

        // The factory mints NFTs and grants each curve the right to credit them.
        nft.grantRole(nft.MINTER_ROLE(), address(factory));
        nft.grantRole(nft.DEFAULT_ADMIN_ROLE(), address(factory));
        vm.stopPrank();

        vm.deal(creator, 100 ether);
        vm.deal(trader,  100 ether);
    }

    function _params(address ref)
        internal
        pure
        returns (LaunchpadFactory.LaunchParams memory)
    {
        return LaunchpadFactory.LaunchParams({
            name: "Fault Line",
            symbol: "FAULT",
            maxSupply: 1_000_000_000,
            capBps: 200,
            referrer: ref,
            minTokensOut: 0
        });
    }

    function test_LaunchWithoutReferrer() public {
        vm.prank(creator);
        (address curveAddr, address tokenAddr, uint256 refId) =
            factory.createToken{value: FEE}(_params(address(0)));

        assertEq(refId, 0);
        assertEq(protocol.balance, FEE);
        assertEq(factory.launchCount(), 1);
        assertEq(MemeToken(tokenAddr).totalSupply(), 1_000_000_000 * 1e18);
        assertEq(BondingCurve(curveAddr).creator(), creator);
    }

    function test_DevBuyIsAtomicAndCapExempt() public {
        // 2% cap on an 800M curve supply = 16M tokens.
        // A 1 ETH dev buy far exceeds that, and must still succeed.
        vm.prank(creator);
        (address curveAddr, address tokenAddr, ) =
            factory.createToken{value: FEE + 1 ether}(_params(address(0)));

        uint256 bal = MemeToken(tokenAddr).balanceOf(creator);
        assertGt(bal, BondingCurve(curveAddr).maxBuyPerWallet());
        assertEq(protocol.balance, FEE + 0.02 ether); // deploy fee + 2% trade fee
    }

    function test_RevertWhen_FeeTooLow() public {
        vm.prank(creator);
        vm.expectRevert();
        factory.createToken{value: 0.001 ether}(_params(address(0)));
    }

    function test_SelfReferralIgnored() public {
        vm.prank(creator);
        (, , uint256 refId) = factory.createToken{value: FEE}(_params(creator));
        assertEq(refId, 0, "must not mint an NFT to yourself");
    }

    function test_ReferralNftMintedToReferrer() public {
        vm.prank(creator);
        (, , uint256 refId) = factory.createToken{value: FEE}(_params(referrer));

        assertEq(refId, 1);
        assertEq(nft.ownerOf(refId), referrer);
    }

    /// The full path: launch with a referrer, trade, referrer accrues 10% of fees.
    function test_ReferrerEarnsFromTrades() public {
        LaunchpadFactory.LaunchParams memory p = _params(referrer);
        p.capBps = 0; // testing fee flow, not the cap

        vm.prank(creator);
        (address curveAddr, , uint256 refId) =
            factory.createToken{value: FEE}(p);

        uint256 protocolBefore = protocol.balance;

        vm.prank(trader);
        BondingCurve(curveAddr).buy{value: 1 ether}(0);

        // 2% of 1 ETH = 0.02 fee. 10% of that = 0.002 to the referrer.
        assertEq(nft.pending(refId), 0.002 ether);
        assertEq(protocol.balance - protocolBefore, 0.018 ether);

        // And the referrer can actually withdraw it.
        uint256 before = referrer.balance;
        vm.prank(referrer);
        nft.claim(refId);
        assertEq(referrer.balance - before, 0.002 ether);
    }

    function test_FeesFollowNftToNewOwner() public {
        LaunchpadFactory.LaunchParams memory p = _params(referrer);
        p.capBps = 0; // testing fee flow, not the cap

        vm.prank(creator);
        (address curveAddr, , uint256 refId) =
            factory.createToken{value: FEE}(p);

        address buyer = makeAddr("nftBuyer");
        vm.prank(referrer);
        nft.transferFrom(referrer, buyer, refId);

        vm.prank(trader);
        BondingCurve(curveAddr).buy{value: 1 ether}(0);

        assertEq(nft.pending(refId), 0.002 ether);

        uint256 before = buyer.balance;
        vm.prank(buyer);
        nft.claim(refId);
        assertEq(buyer.balance - before, 0.002 ether);
    }

    function test_GetLaunchesReturnsNewestFirst() public {
        vm.startPrank(creator);
        factory.createToken{value: FEE}(_params(address(0)));

        LaunchpadFactory.LaunchParams memory p = _params(address(0));
        p.symbol = "SECOND";
        factory.createToken{value: FEE}(p);
        vm.stopPrank();

        LaunchpadFactory.Launch[] memory page = factory.getLaunches(0, 10);
        assertEq(page.length, 2);
        assertEq(MemeToken(page[0].token).symbol(), "SECOND");
    }
}
