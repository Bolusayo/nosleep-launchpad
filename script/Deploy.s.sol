// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BondingCurve} from "../src/BondingCurve.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        BondingCurve curve = new BondingCurve(
            "Fault Line",   // name
            "FAULT",        // ticker
            1_000_000_000,  // 1B supply
            me,             // creator
            me,             // fee recipient
            200             // 2% anti-snipe cap
        );

        vm.stopBroadcast();

        console.log("Curve: ", address(curve));
        console.log("Token: ", address(curve.token()));
    }
}
