// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/aero/AeroFarmingRouter.sol";
import "../src/aero/AeroFarmingLogic.sol";

/// Plain CREATE (not CREATE2): per-chain init args differ anyway. Take addresses from the real broadcast.
/// Deploys the logic, then the router, then initializes it in the same broadcast (the deployer EOA is tx.origin).
contract AeroFarmingRouterScript is Script {
    address internal constant BASE_AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;

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
        address receipt = ILeafVoter(ICLGaugeFactory(gaugeFactory).leafVoter()).RECEIPT_TOKEN();
        if (block.chainid == 8453) {
            // claims pay the new AERO on Base (not the legacy 0x9401... AERO, not the xAERO receipt token); the
            // router has no reward-token setter, so a wrong one would strand every claim
            require(compoundEnabled, "COMPOUND_ENABLED must be true on Base");
            require(rewardToken == BASE_AERO, "REWARD_TOKEN must be the new AERO on Base");
            require(rewardToken != receipt, "REWARD_TOKEN must not be the leaf voter RECEIPT_TOKEN on Base");
        } else {
            require(!compoundEnabled, "COMPOUND_ENABLED must be false off Base");
            require(rewardToken == receipt, "REWARD_TOKEN must be the leaf voter RECEIPT_TOKEN");
        }
        // the logic reads its fee caps from V3Utils: fail here, not on the first harvest, if the getter is missing
        V3Utils(payable(v3utils)).getMaxFeeX64(Common.FeeType.PERFORMANCE_FEE);
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
