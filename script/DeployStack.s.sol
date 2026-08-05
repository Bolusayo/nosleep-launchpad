// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";

contract DeployStack is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        ReferralNFT nft = new ReferralNFT(me);
        LaunchpadFactory factory = new LaunchpadFactory(me, me, nft);

        nft.grantRole(nft.MINTER_ROLE(), address(factory));

        vm.stopBroadcast();

        console.log("ReferralNFT:      ", address(nft));
        console.log("LaunchpadFactory: ", address(factory));
    }
}

