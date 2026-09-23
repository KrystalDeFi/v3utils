// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/V3Automation.sol";
import "../src/V3Utils.sol";
import "../src/CommonLib.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

abstract contract CommonScript is Script {
    address krystalRouter;
    address admin;
    bytes32 salt;
    address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Builds the verifier flags for `forge verify-contract`, sourced from env so the same
    // scripts work across explorers (e.g. blockscout for chains Etherscan doesn't support).
    // Defaults to etherscan when VERIFIER is unset. VERIFIER_URL is optional (Etherscan can
    // infer it from the chain id, Blockscout needs the instance's /api/ endpoint).
    // VERIFIER_API_KEY unifies the key for both verifiers (falls back to ETHERSCAN_API_KEY);
    // `--etherscan-api-key` is forge's universal key flag regardless of the verifier.
    function verifierFlags() internal view returns (string memory) {
        string memory verifier = vm.envOr("VERIFIER", string("etherscan"));
        string memory verifierUrl = vm.envOr("VERIFIER_URL", string(""));
        string memory apiKey = vm.envOr("VERIFIER_API_KEY", vm.envOr("ETHERSCAN_API_KEY", string("")));
        string memory flags = string.concat(" --verifier ", verifier);
        if (bytes(verifierUrl).length > 0) {
            flags = string.concat(flags, " --verifier-url ", verifierUrl);
        }
        if (bytes(apiKey).length > 0) {
            flags = string.concat(flags, " --etherscan-api-key ", apiKey);
        }
        return flags;
    }

    // Builds `--libraries` flags for `forge verify-contract` from foundry.toml's `libraries`, the same
    // list the deploy links against - so a re-pinned library address can never be picked up by one
    // and missed by the other. Entries are already in forge's `path:Name:address` form. Requires
    // fs_permissions read access on foundry.toml, which the linker profiles grant.
    function libraryFlags(string memory profile) internal view returns (string memory) {
        string[] memory libraries =
            vm.parseTomlStringArray(vm.readFile("foundry.toml"), string.concat(".profile.", profile, ".libraries"));
        string memory flags = "";
        for (uint256 i = 0; i < libraries.length; i++) {
            flags = string.concat(flags, " --libraries ", libraries[i]);
        }
        return flags;
    }

    // Native-asset model for the target chain. Chains with a normal WETH9 wrapper set neither var,
    // so both default to the wrapped 1:1 model and their existing .env blocks keep working as-is.
    // nativeMode: 0 = WRAPPED, 1 = ENSHRINED (ERC20 view of native, e.g. Arc's USDC at 0x3600...).
    // nativeScale is not configured: the contract derives it from IERC20Metadata(WETH).decimals().
    function nativeMode() internal view returns (uint8) {
        uint256 mode = vm.envOr("NATIVE_MODE", uint256(0));
        // bound before the cast: uint8(256) would silently read back as WRAPPED
        require(mode <= 1, "NATIVE_MODE must be 0 (WRAPPED) or 1 (ENSHRINED)");
        return uint8(mode);
    }

    function getV3UtilsDeploymentAddress() internal view returns (address) {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(type(V3Utils).creationCode)), factory);
    }

    function getV3AutomationDeploymentAddress() internal view returns (address) {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(type(V3Automation).creationCode)), factory);
    }

    function getStructHashDeploymentAddress() internal view returns (address) {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(type(StructHash).creationCode)), factory);
    }

    function getCommonLibDeploymentAddress() internal view returns (address) {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(type(CommonLib).creationCode)), factory);
    }

    function getNfpmDeploymentAddress() internal view returns (address) {
        return Create2.computeAddress(salt, keccak256(abi.encodePacked(type(Nfpm).creationCode)), factory);
    }

    constructor() {
        salt = keccak256(bytes(vm.envString("SALT_SEED")));
        krystalRouter = vm.envAddress("KRYSTAL_ROUTER");
        admin = vm.envAddress("WITHDRAWER"); // for now, admin is the withdrawer
    }

    // To ignore from test coverage
    function testCommon() external {}
}
