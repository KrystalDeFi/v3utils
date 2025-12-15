// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Common.s.sol";

contract BeforeV3AutomationScript is CommonScript {
    function run() external {
        address structHashAddress = getStructHashDeploymentAddress();
        try vm.envAddress("STRUCT_HASH_ADDRESS") {
            if (vm.envAddress("STRUCT_HASH_ADDRESS") != structHashAddress) {
                console.log("wrong STRUCT_HASH_ADDRESS:", toHexString(vm.envAddress("STRUCT_HASH_ADDRESS")));
                console.log("set `STRUCT_HASH_ADDRESS=", toHexString(structHashAddress));
                revert();
            }
            console.log("STRUCT_HASH_ADDRESS set!");
        } catch {
            console.log(
                string(
                    abi.encodePacked(
                        "env STRUCT_HASH_ADDRESS not set. set `STRUCT_HASH_ADDRESS=",
                        toHexString(structHashAddress),
                        "`first"
                    )
                )
            );
            revert();
        }

        address nfpmAddress = getNfpmDeploymentAddress();
        try vm.envAddress("NFPM_LIB_ADDRESS") {
            if (vm.envAddress("NFPM_LIB_ADDRESS") != nfpmAddress) {
                console.log("wrong NFPM_LIB_ADDRESS:", toHexString(vm.envAddress("NFPM_LIB_ADDRESS")));
                console.log("set `NFPM_LIB_ADDRESS=", toHexString(nfpmAddress));
                revert();
            }
            console.log("NFPM_LIB_ADDRESS set!");
        } catch {
            console.log(
                string(
                    abi.encodePacked(
                        "env NFPM_LIB_ADDRESS not set. set `NFPM_LIB_ADDRESS=", toHexString(nfpmAddress), "`first"
                    )
                )
            );
            revert();
        }
    }

    function test() external {}
}

contract V3AutomationScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        V3Automation v3automation = new V3Automation{salt: salt}();
        vm.stopBroadcast();
    }

    // To ignore from test coverage
    function test() external {}
}
