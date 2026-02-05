// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Common.s.sol";
import "../src/V3Automation.sol";
import "../src/V3Utils.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

// NOTE: This script is use when deploy transaction is made but initialization is not

interface IV3Initializer {
    function initialize(
        address _swapRouter,
        address admin,
        address withdrawer,
        address feeTaker,
        address[] calldata nfpms
    ) external;
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function ADMIN_ROLE() external view returns (bytes32);
}

contract V3AutomationGrantRoleScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address deploymentAddress = getV3AutomationDeploymentAddress();
        address multisig = vm.envAddress("MULTISIG");
        console.log("mutltisig :", multisig);
        console.log("deploymentAddress :", deploymentAddress);
        console.log("deployerAddress :", deployerAddress);

        // 0x84C4c905Fc18313f0A8e20855a067b7caaca5922;
        vm.startBroadcast(deployerPrivateKey);
        IV3Initializer v3automation = IV3Initializer(deploymentAddress);
        v3automation.grantRole(v3automation.OPERATOR_ROLE(), 0x4b82847C82087ea19418beD079966810f64f39f4);
        v3automation.grantRole(v3automation.OPERATOR_ROLE(), 0x9729585607568Dcbf1f5f3802AfBf5B221702932);
        v3automation.grantRole(v3automation.DEFAULT_ADMIN_ROLE(), multisig);
        v3automation.grantRole(v3automation.ADMIN_ROLE(), multisig);
        v3automation.revokeRole(v3automation.ADMIN_ROLE(), deployerAddress);
        v3automation.revokeRole(v3automation.DEFAULT_ADMIN_ROLE(), deployerAddress);

        vm.stopBroadcast();
    }

    function test() external {}
}

contract V3UtilsGrantRoleScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address deploymentAddress = getV3UtilsDeploymentAddress();
        address multisig = vm.envAddress("MULTISIG");
        console.log("mutltisig :", multisig);
        console.log("deploymentAddress :", deploymentAddress);
        console.log("deployerAddress :", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);
        // 0x84C4c905Fc18313f0A8e20855a067b7caaca5922;
        IV3Initializer v3utils = IV3Initializer(deploymentAddress);
        v3utils.grantRole(v3utils.DEFAULT_ADMIN_ROLE(), multisig);
        v3utils.grantRole(v3utils.ADMIN_ROLE(), multisig);
        v3utils.revokeRole(v3utils.ADMIN_ROLE(), deployerAddress);
        v3utils.revokeRole(v3utils.DEFAULT_ADMIN_ROLE(), deployerAddress);

        vm.stopBroadcast();
    }

    function test() external {}
}
