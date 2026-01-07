// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Strings.sol";
import "./Common.s.sol";

contract VerifyV3UtilsScript is CommonScript {
    function run() external view {
        address deploymentAddress = getV3UtilsDeploymentAddress();
        console.log("deployment address: ", deploymentAddress);
        console.log("\nrun script below to verify contract: \n");
        console.log(
            string.concat(
                "forge verify-contract ",
                Strings.toHexString(deploymentAddress),
                " src/V3Utils.sol:V3Utils",
                " --libraries src/Nfpm.sol:Nfpm:",
                vm.envString("NFPM_LIB_ADDRESS"),
                " --rpc-url ", vm.envString("RPC_URL")
            )
        );
    }

    // To ignore from test coverage
    function test() external {}
}

contract VerifyStructHashScript is CommonScript {
    function run() external view {
        address deploymentAddress = getStructHashDeploymentAddress();
        console.log("deployment address: ", deploymentAddress);
        console.log("\nrun script below to verify contract: \n");
        console.log(
            string.concat(
                "forge verify-contract ", Strings.toHexString(deploymentAddress), " src/StructHash.sol:StructHash"
            )
        );
    }

    function test() external {}
}

contract VerifyNfpmScript is CommonScript {
    function run() external view {
        address deploymentAddress = getNfpmDeploymentAddress();
        console.log("deployment address: ", deploymentAddress);
        console.log("\nrun script below to verify contract: \n");
        console.log(
            string.concat("forge verify-contract ", Strings.toHexString(deploymentAddress), " src/Nfpm.sol:Nfpm")
        );
    }

    function test() external {}
}

contract VerifyV3AutomationScript is CommonScript {
    function run() external view {
        address deploymentAddress = getV3AutomationDeploymentAddress();
        console.log("deployment address: ", deploymentAddress);
        console.log("\nrun script below to verify contract: \n");
        console.log(
            string.concat(
                "forge verify-contract ",
                Strings.toHexString(deploymentAddress),
                " src/V3Automation.sol:V3Automation",
                " --libraries src/StructHash.sol:StructHash:",
                vm.envString("STRUCT_HASH_ADDRESS"),
                " --libraries src/Nfpm.sol:Nfpm:",
                vm.envString("NFPM_LIB_ADDRESS")
            )
        );
    }

    function test() external {}
}
