// SPDX-License-Identifier: UNLICENSED

import "./Common.s.sol";

contract NfpmScript is CommonScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address deploymentAddress = Create2.deploy(0, salt, type(Nfpm).creationCode);
        console.logAddress(deploymentAddress);
        vm.stopBroadcast();
    }

    function test() external {}
}
