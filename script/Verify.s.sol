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
                libraryFlags("v3utilslinker"),
                " --rpc-url ",
                vm.envString("RPC_URL"),
                verifierFlags()
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
                "forge verify-contract ",
                Strings.toHexString(deploymentAddress),
                " src/StructHash.sol:StructHash",
                verifierFlags()
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
            string.concat(
                "forge verify-contract ", Strings.toHexString(deploymentAddress), " src/Nfpm.sol:Nfpm", verifierFlags()
            )
        );
    }

    function test() external {}
}

contract VerifyCommonLibScript is CommonScript {
    function run() external view {
        address deploymentAddress = getCommonLibDeploymentAddress();
        console.log("deployment address: ", deploymentAddress);
        console.log("\nrun script below to verify contract: \n");
        console.log(
            string.concat(
                "forge verify-contract ",
                Strings.toHexString(deploymentAddress),
                " src/CommonLib.sol:CommonLib",
                verifierFlags()
            )
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
                libraryFlags("linker"),
                verifierFlags()
            )
        );
    }

    function test() external {}
}

/// V3UtilsRouter and its modules, adapters and farm are plain CREATE with no linked libraries. `make verify-v3router`
/// passes V3ROUTER_DEPLOYED (`Name:address,Name:address`, read from the deploy broadcast) and this prints one
/// `forge verify-contract` per entry. AeroGaugeFarm is the only one with constructor args (AERO_GAUGE_FACTORY,
/// AERO_REWARD_TOKEN, AERO_COMPOUND_ENABLED, as deployed).
contract VerifyV3UtilsRouterScript is CommonScript {
    function run() external view {
        string[] memory entries = vm.split(vm.envString("V3ROUTER_DEPLOYED"), ",");
        for (uint256 i = 0; i < entries.length; i++) {
            string[] memory kv = vm.split(entries[i], ":");
            require(kv.length == 2, "V3ROUTER_DEPLOYED entry must be Name:address");
            console.log(_verifyCmd(vm.parseAddress(kv[1]), kv[0]));
        }
    }

    function _verifyCmd(address a, string memory name) internal view returns (string memory) {
        return string.concat(
            "forge verify-contract ",
            Strings.toHexString(a),
            " ",
            _path(name),
            ":",
            name,
            _constructorArgs(name),
            " --rpc-url ",
            vm.envString("RPC_URL"),
            verifierFlags()
        );
    }

    function _path(string memory name) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("V3UtilsRouter")) return "src/router/V3UtilsRouter.sol";
        if (h == keccak256("CoreMint") || h == keccak256("CoreModify")) {
            return string.concat("src/router/modules/", name, ".sol");
        }
        if (h == keccak256("AeroGaugeFarm")) return "src/router/farms/AeroGaugeFarm.sol";
        if (
            h == keccak256("UniV3Adapter") || h == keccak256("AlgebraV1Adapter") || h == keccak256("AerodromeAdapter")
                || h == keccak256("RamsesV3Adapter") || h == keccak256("AlgebraIntegralAdapter")
        ) return string.concat("src/router/adapters/", name, ".sol");
        revert(string.concat("unknown contract: ", name));
    }

    function _constructorArgs(string memory name) internal view returns (string memory) {
        if (keccak256(bytes(name)) != keccak256("AeroGaugeFarm")) return "";
        bytes memory args = abi.encode(
            vm.envAddress("AERO_GAUGE_FACTORY"),
            vm.envAddress("AERO_REWARD_TOKEN"),
            vm.envOr("AERO_COMPOUND_ENABLED", false)
        );
        return string.concat(" --constructor-args ", vm.toString(args));
    }

    function test() external {}
}
