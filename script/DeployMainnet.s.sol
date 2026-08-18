// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ReferralNFT} from "../src/ReferralNFT.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {CurveDeployer} from "../src/CurveDeployer.sol";
import {SplitterDeployer} from "../src/SplitterDeployer.sol";

contract DeployMainnet is Script {
    // Uniswap V2 Router02 on Robinhood Chain mainnet (chainId 4663).
    // Verified against Uniswap's official deployments doc, on-chain bytecode,
    // and a live WETH() call before being hardcoded here. Do not edit without
    // re-verifying — see chat history / runbook for the verification steps.
    address constant ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        require(block.chainid == 4663, "DeployMainnet: wrong chain, expected Robinhood Chain mainnet (4663)");

        vm.startBroadcast(pk);

        ReferralNFT nft = new ReferralNFT(me);

        CurveDeployer deployer = new CurveDeployer();
        SplitterDeployer splitterDeployer = new SplitterDeployer();
        LaunchpadFactory factory = new LaunchpadFactory(me, me, nft, ROUTER, deployer, address(splitterDeployer));
        deployer.setFactory(address(factory));

        nft.grantRole(nft.MINTER_ROLE(), address(factory));

        // Deploy locked. createToken() is permissionless, so an unlocked
        // factory on mainnet is a live financial product anyone can launch on
        // and anyone can put money into -- before audit, before legal review,
        // with no pause and no rescue function anywhere in the system.
        //
        // Nobody pays 1000 ETH to launch. To run a test:
        //   cast send $FACTORY "setDeployFee(uint256)" 2000000000000000 ...
        //   ... launch, test ...
        //   cast send $FACTORY "setDeployFee(uint256)" 1000000000000000000000 ...
        //
        // Remove this line only when the audit and legal review are done.
        factory.setDeployFee(1000 ether);

        vm.stopBroadcast();

        console.log("ReferralNFT:      ", address(nft));
        console.log("LaunchpadFactory: ", address(factory));
        console.log("Router (real):    ", ROUTER);
        console.log("CurveDeployer:    ", address(deployer));
        console.log("");
        console.log("FACTORY IS LOCKED: deployFee = 1000 ETH.");
        console.log("Owner and feeRecipient are both:", me);
        console.log("SplitterDeployer: ", address(splitterDeployer));
    }
}
