// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Common.s.sol";
import "../src/V3Automation.sol";

// NOTE: This script is use when deploy transaction is made but initialization is not

interface IV3Initializer {
    function initialize(address _swapRouter, address admin, address withdrawer, address feeTaker, address[] calldata nfpms) external;
    function grantRole(bytes32 role, address account) external;
    function OPERATOR_ROLE() external view returns (bytes32);
    function ADMIN_ROLE() external view returns (bytes32);
}

contract V3AutomationGrantRoleScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deploymentAddress = 0x6a07438804d0d8e557607D864b7903CB948fabAF;
        // 0x84C4c905Fc18313f0A8e20855a067b7caaca5922;

        vm.startBroadcast(deployerPrivateKey);
        IV3Initializer v3automation = IV3Initializer(deploymentAddress);
        v3automation.grantRole(v3automation.OPERATOR_ROLE(), 0x4b82847C82087ea19418beD079966810f64f39f4);
        v3automation.grantRole(v3automation.OPERATOR_ROLE(), 0x9729585607568Dcbf1f5f3802AfBf5B221702932);
        v3automation.grantRole(v3automation.ADMIN_ROLE(), 0x9A99252A76f7B40Cbf2002a8dB2977C85fA306DF);

        vm.stopBroadcast();
    }

    function test() external {}
}
