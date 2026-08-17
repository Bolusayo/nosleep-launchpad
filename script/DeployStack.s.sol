// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {MockV2Router} from "../src/mocks/MockV2Router.sol";
import {CurveDeployer} from "../src/CurveDeployer.sol";
import {SplitterDeployer} from "../src/SplitterDeployer.sol";

contract DeployStack is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        MockV2Router router = new MockV2Router();
        ReferralNFT nft = new ReferralNFT(me);

        CurveDeployer deployer = new CurveDeployer();
        SplitterDeployer splitterDeployer = new SplitterDeployer();
        LaunchpadFactory factory =
            new LaunchpadFactory(me, me, nft, address(router), deployer, address(splitterDeployer));
        deployer.setFactory(address(factory));

        nft.grantRole(nft.MINTER_ROLE(), address(factory));

        vm.stopBroadcast();

        console.log("ReferralNFT:      ", address(nft));
        console.log("LaunchpadFactory: ", address(factory));
        console.log("MockV2Router:     ", address(router));
        console.log("CurveDeployer:    ", address(deployer));
        console.log("SplitterDeployer: ", address(splitterDeployer));
    }
}

