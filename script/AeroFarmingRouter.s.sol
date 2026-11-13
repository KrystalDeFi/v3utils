// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/aero/AeroFarmingRouter.sol";
import "../src/aero/AeroFarmingLogic.sol";

/// Plain CREATE (not CREATE2): per-chain init args differ anyway. Take addresses from the real broadcast.
/// Deploys the logic, then the router, then initializes it in the same broadcast (the deployer EOA is tx.origin).
contract AeroFarmingRouterScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = _required("ADMIN");
        address operator = _required("OPERATOR");
        address withdrawer = _required("WITHDRAWER");
        address v3utils = _required("V3UTILS");
        address gaugeFactory = _required("GAUGE_FACTORY");
        address rewardToken = _required("REWARD_TOKEN");
        bool compoundEnabled =
            block.chainid == 8453 ? vm.envBool("COMPOUND_ENABLED") : vm.envOr("COMPOUND_ENABLED", false);
        if (block.chainid == 8453) {
            require(compoundEnabled, "COMPOUND_ENABLED must be true on Base");
        } else {
            address receipt = ILeafVoter(ICLGaugeFactory(gaugeFactory).leafVoter()).RECEIPT_TOKEN();
            require(rewardToken == receipt, "REWARD_TOKEN must be the leaf voter RECEIPT_TOKEN");
        }
        vm.startBroadcast(deployerPrivateKey);

        AeroFarmingLogic logic = new AeroFarmingLogic();
        AeroFarmingRouter router = new AeroFarmingRouter();
        router.initialize(
            admin,
            operator,
            withdrawer,
            address(logic),
            v3utils,
            gaugeFactory,
            rewardToken,
            compoundEnabled,
            vm.envAddress("NATIVE_WETH")
        );

        vm.stopBroadcast();

        console.log("AeroFarmingLogic:", address(logic));
        console.log("AeroFarmingRouter:", address(router));
    }

    function _required(string memory key) internal view returns (address a) {
        a = vm.envAddress(key);
        require(a != address(0), string.concat(key, " must be non-zero"));
    }

    // To ignore from test coverage
    function test() external {}
}
