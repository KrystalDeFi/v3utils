// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Common.s.sol";

contract V3UtilsScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        createXFactory.deployCreate2(salt, type(V3Utils).creationCode);

        vm.stopBroadcast();
    }

    // To ignore from test coverage
    function test() external {}
}
