// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/aero/AeroFarmingRouter.sol";
import "../src/aero/AeroFarmingLogic.sol";

/// Plain CREATE (not CREATE2): per-chain init args differ anyway. `make verify-aerorouter` / `verify-aerologic` read
/// the addresses from this script's broadcast. Deploys the logic, then the router, then initializes it in the same
/// broadcast (the deployer EOA is tx.origin). Run via `make dryrun-aerorouter` / `make deploy-aerorouter`.
/// Env: shared keys (PRIVATE_KEY, WITHDRAWER, WETH, NATIVE_MODE) plus V3UTILS and the AERO_* keys in sample.env.
contract AeroFarmingRouterScript is Script {
    address internal constant BASE_AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = _required("AERO_ADMIN");
        address operator = _required("AERO_OPERATOR");
        address withdrawer = _required("WITHDRAWER");
        address v3utils = _required("V3UTILS");
        address gaugeFactory = _required("AERO_GAUGE_FACTORY");
        address rewardToken = _required("AERO_REWARD_TOKEN");
        bool compoundEnabled =
            block.chainid == 8453 ? vm.envBool("AERO_COMPOUND_ENABLED") : vm.envOr("AERO_COMPOUND_ENABLED", false);
        // the router's native wrapper: the chain's WETH9, or none (ERC20-only) where native is enshrined (Arc)
        uint256 nativeMode = vm.envOr("NATIVE_MODE", uint256(0));
        require(nativeMode <= 1, "NATIVE_MODE must be 0 (WRAPPED) or 1 (ENSHRINED)");
        address weth = nativeMode == 1 ? address(0) : vm.envAddress("WETH");
        address receipt = ILeafVoter(ICLGaugeFactory(gaugeFactory).leafVoter()).RECEIPT_TOKEN();
        if (block.chainid == 8453) {
            // claims pay the new AERO on Base (not the legacy 0x9401... AERO, not the xAERO receipt token); the
            // router has no reward-token setter, so a wrong one would strand every claim
            require(compoundEnabled, "AERO_COMPOUND_ENABLED must be true on Base");
            require(rewardToken == BASE_AERO, "AERO_REWARD_TOKEN must be the new AERO on Base");
            require(rewardToken != receipt, "AERO_REWARD_TOKEN must not be the leaf voter RECEIPT_TOKEN on Base");
        } else {
            require(!compoundEnabled, "AERO_COMPOUND_ENABLED must be false off Base");
            require(rewardToken == receipt, "AERO_REWARD_TOKEN must be the leaf voter RECEIPT_TOKEN");
        }
        // the logic reads its fee caps from V3Utils: fail here, not on the first harvest, if the getter is missing
        V3Utils(payable(v3utils)).getMaxFeeX64(Common.FeeType.PERFORMANCE_FEE);
        vm.startBroadcast(deployerPrivateKey);

        AeroFarmingLogic logic = new AeroFarmingLogic();
        AeroFarmingRouter router = new AeroFarmingRouter();
        router.initialize(
            admin, operator, withdrawer, address(logic), v3utils, gaugeFactory, rewardToken, compoundEnabled, weth
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
