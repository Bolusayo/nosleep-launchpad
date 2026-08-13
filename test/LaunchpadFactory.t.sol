// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {MockV2Router} from "../src/mocks/MockV2Router.sol";

contract LaunchpadFactoryTest is Test {
    LaunchpadFactory internal factory;
    ReferralNFT      internal nft;
    MockV2Router internal router;

    address internal admin    = makeAddr("admin");
    address internal protocol = makeAddr("protocol");
    address internal creator  = makeAddr("creator");
    address internal referrer = makeAddr("referrer");
    address internal trader   = makeAddr("trader");

    uint256 internal constant FEE = 0.002 ether;
    uint256 internal QT;
    
    function setUp() public {
        router = new MockV2Router();

        vm.startPrank(admin);
        nft     = new ReferralNFT(admin);
        factory = new LaunchpadFactory(admin, protocol, nft, address(router));
        
        
        // The factory mints NFTs and grants each curve the right to credit them.
        nft.grantRole(nft.MINTER_ROLE(), address(factory));
        nft.grantRole(nft.DEFAULT_ADMIN_ROLE(), address(factory));
        vm.stopPrank();

        QT = new BondingCurve("x", "X", 1_000_000_000, creator, protocol, 0, address(router), 0, 0, 0, address(0), 0, 0, 0, 0).QUOTE_TARGET();

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
            minTokensOut: 0,
            buyTaxBps: 0,
            sellTaxBps: 0,
            taxDurationDays: 0,
            marketing: address(0),
            liquidityBps: 0,
            burnBps: 0,
            marketingBps: 0,
            dividendBps: 0
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
        // A dev buy far exceeding that must still succeed.
        uint256 devBuy = QT / 2;
        uint256 fee    = (devBuy * 200) / 10_000; // 2% trade fee

        vm.prank(creator);
        (address curveAddr, address tokenAddr, ) =
            factory.createToken{value: FEE + devBuy}(_params(address(0)));

        uint256 bal = MemeToken(tokenAddr).balanceOf(creator);
        assertGt(bal, BondingCurve(curveAddr).maxBuyPerWallet());
        assertEq(protocol.balance, FEE + fee); // deploy fee + trade fee
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

        uint256 spend  = QT / 10;
        uint256 fee    = (spend * 200) / 10_000;   // 2% trade fee
        uint256 refCut = (fee * 1000) / 10_000;    // 10% of the fee

        vm.prank(trader);
        BondingCurve(curveAddr).buy{value: spend}(0);

        assertEq(nft.pending(refId), refCut);
        assertEq(protocol.balance - protocolBefore, fee - refCut);

        uint256 before = referrer.balance;
        vm.prank(referrer);
        nft.claim(refId);
        assertEq(referrer.balance - before, refCut);
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

        uint256 spend  = QT / 10;
        uint256 fee    = (spend * 200) / 10_000;   // 2% trade fee
        uint256 refCut = (fee * 1000) / 10_000;    // 10% of the fee

        vm.prank(trader);
        BondingCurve(curveAddr).buy{value: spend}(0);

        assertEq(nft.pending(refId), refCut);

        uint256 before = buyer.balance;
        vm.prank(buyer);
        nft.claim(refId);
        assertEq(buyer.balance - before, refCut);
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
