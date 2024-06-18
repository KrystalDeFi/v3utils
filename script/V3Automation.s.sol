// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Common.s.sol";

contract BeforeV3AutomationScript is CommonScript {
    function run() external {
        address libraryAddress = getStructHashDeploymentAddress();
        try vm.envAddress("STRUCT_HASH_ADDRESS") {
            if (vm.envAddress("STRUCT_HASH_ADDRESS") != libraryAddress) {
                console.log("wrong STRUCT_HASH_ADDRESS:");
                console.log("set `STRUCT_HASH_ADDRESS=", toHexString(libraryAddress));
                revert();
            }
            console.log("STRUCT_HASH_ADDRESS set!");
        } catch {
            console.log(string(abi.encodePacked("env STRUCT_HASH_ADDRESS not set. set `STRUCT_HASH_ADDRESS=", toHexString(libraryAddress), "`first")));
            revert();
        }
    }

    function test() external {}

}

contract V3AutomationScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        V3Automation v3automation = new V3Automation{
            salt: salt
        }();
        vm.stopBroadcast();
    }

    function test() external {}
}
