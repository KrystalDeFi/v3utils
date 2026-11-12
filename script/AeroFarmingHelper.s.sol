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
        address admin = _required("ADMIN");
        address operator = _required("OPERATOR");
        address withdrawer = _required("WITHDRAWER");
        address v3utils = _required("V3UTILS");
        address gaugeFactory = _required("GAUGE_FACTORY");
        address structHash = _required("STRUCT_HASH");
        vm.startBroadcast(deployerPrivateKey);

        AeroAutomationModule module = new AeroAutomationModule();
        AeroFarmingHelper impl = new AeroFarmingHelper();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                AeroFarmingHelper.initialize,
                (
                    admin,
                    operator,
                    withdrawer,
                    v3utils,
                    gaugeFactory,
                    vm.envAddress("REWARD_TOKEN"),
                    vm.envBool("COMPOUND_ENABLED"),
                    vm.envAddress("NATIVE_WETH"),
                    structHash,
                    address(module)
                )
            )
        );

        vm.stopBroadcast();

        console.log("AeroAutomationModule:", address(module));
        console.log("AeroFarmingHelper implementation:", address(impl));
        console.log("AeroFarmingHelper proxy:", address(proxy));
    }

    function _required(string memory key) internal view returns (address a) {
        a = vm.envAddress(key);
        require(a != address(0), string.concat(key, " must be non-zero"));
    }

    // To ignore from test coverage
    function test() external {}
}
