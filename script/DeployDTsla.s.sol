// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {dTSLA} from "src/dTSLA.sol";

contract DeployDTsla is Script {
    dTSLA dTsla;

    string constant alpacaMintSource = "./functions/sources/alpacaBalance.js";
    string constant alpacaRedeemSource =
        "./functions/sources/sellTslaAndSendUsdc.js";
    uint64 constant subId = 394;

    function run() public {
        string memory mintSource = vm.readFile(alpacaMintSource);
        string memory redeemSource = vm.readFile(alpacaRedeemSource);

        vm.startBroadcast();
        dTsla = new dTSLA(subId, mintSource, redeemSource);
        vm.stopBroadcast();

        console.log("Deployed dTsla at address: ", address(dTsla));
    }
}
