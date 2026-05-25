// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Common.s.sol";
import "../src/V3Automation.sol";

/// @notice Deploys V3Automation v6 (with AUTO_ENTER support + EIP-712 domain v6.0).
/// Run AFTER StructHash + V3Utils are deployed (or already exist on the chain) and
/// AFTER the v5 V3Automation is left in place for in-flight orders.
///
/// Env vars (all required):
///   PRIVATE_KEY              — deployer key
///   SWAP_ROUTER              — krystal/uniswap universal router for this chain
///   ADMIN                    — receives ADMIN_ROLE
///   WITHDRAWER               — receives WITHDRAWER_ROLE
///   FEE_TAKER                — fee accumulation address
///   WETH                     — chain's WETH9
///   NFPM_WHITELIST           — comma-separated NFPM addresses
///   OPERATORS                — comma-separated operator EOAs (executes orders)
///
/// The CREATE2 salt is "V6" so the deployed address won't collide with the v5
/// deployment (which keeps serving in-flight v5 orders).
contract V3AutomationV6Script is CommonScript {
    bytes32 internal constant V6_SALT = bytes32("V3AutomationV6");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address admin = vm.envAddress("ADMIN");
        address withdrawer = vm.envAddress("WITHDRAWER");
        address feeTaker = vm.envAddress("FEE_TAKER");
        address weth = vm.envAddress("WETH");
        address[] memory nfpms = vm.envAddress("NFPM_WHITELIST", ",");
        address[] memory operators = vm.envAddress("OPERATORS", ",");

        vm.startBroadcast(deployerPrivateKey);

        V3Automation v3automation = new V3Automation{salt: V6_SALT}();
        console.log("V3Automation v6 deployed at:", address(v3automation));

        v3automation.initialize(swapRouter, admin, feeTaker, weth, nfpms);
        console.log("V3Automation v6 initialized");

        bytes32 operatorRole = v3automation.OPERATOR_ROLE();
        for (uint256 i = 0; i < operators.length; i++) {
            v3automation.grantRole(operatorRole, operators[i]);
            console.log("OPERATOR_ROLE granted to:", operators[i]);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("Next steps:");
        console.log("  1. Update libs/contracts/krystalvault Go bindings (abi_gen.sh).");
        console.log("  2. Flip backend ChainConfig.AutomationContractV6 to:", address(v3automation));
        console.log("  3. Set chain's AutoEnter SignatureVersion to 6.0.");
        console.log("  4. Leave the v5 contract running until all v5 orders drain.");
    }

    // Excluded from forge coverage.
    function test() external {}
}
