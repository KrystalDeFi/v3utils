// SPDX-License-Identifier: UNLICENSED

import "./Common.s.sol";

contract StructHashScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address deploymentAddress = getStructHashDeploymentAddress();
        console.logAddress(deploymentAddress);
        vm.stopBroadcast();
    }

    function test() external {}
}
