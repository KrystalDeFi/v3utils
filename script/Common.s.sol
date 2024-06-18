// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/V3Automation.sol";
import "../src/V3Utils.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

abstract contract CommonScript is Script {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    address krystalRouter;
    address admin;
    address withdrawer;
    bytes32 salt;
    address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = value;
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        return string(buffer);
    }

    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), 20);
    }

    function getV3UtilsDeploymentAddress() internal view returns(address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(V3Utils).creationCode
                )
            ),
            factory
        );
    }

    function getV3AutomationDeploymentAddress() internal view returns(address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(V3Automation).creationCode
                )
            ),
            factory
        );
    }

    function getStructHashDeploymentAddress() internal view returns(address) {
        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(StructHash).creationCode
                )
            ),
            factory
        );
    }

    constructor() {
        salt = keccak256(bytes(vm.envString("SALT_SEED")));
        krystalRouter = vm.envAddress("KRYSTAL_ROUTER");
        admin = vm.envAddress("WITHDRAWER"); // for now, admin is the withdrawer
        withdrawer = vm.envAddress("WITHDRAWER");
    }

    function testCommon() external {}
}
