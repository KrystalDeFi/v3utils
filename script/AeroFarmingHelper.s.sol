// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/aero/AeroFarmingHelper.sol";
import "../src/aero/AeroAutomationModule.sol";

/// Plain CREATE (not CREATE2): per-chain init args differ anyway. Take addresses from the real broadcast.
contract AeroFarmingHelperScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        AeroAutomationModule module = new AeroAutomationModule();
        AeroFarmingHelper impl = new AeroFarmingHelper();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                AeroFarmingHelper.initialize,
                (
                    vm.envAddress("ADMIN"),
                    vm.envAddress("OPERATOR"),
                    vm.envAddress("WITHDRAWER"),
                    vm.envAddress("V3UTILS"),
                    vm.envAddress("GAUGE_FACTORY"),
                    vm.envAddress("REWARD_TOKEN"),
                    vm.envBool("COMPOUND_ENABLED"),
                    vm.envAddress("NATIVE_WETH"),
                    vm.envAddress("STRUCT_HASH"),
                    address(module)
                )
            )
        );

        vm.stopBroadcast();

        console.log("AeroAutomationModule:", address(module));
        console.log("AeroFarmingHelper implementation:", address(impl));
        console.log("AeroFarmingHelper proxy:", address(proxy));
    }

    // To ignore from test coverage
    function test() external {}
}
