// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Router state shared with the modules, adapters and farms it delegatecalls, in one ERC-7201 slot.
/// @dev Append-only: never reorder, retype or remove a field. Router-own state (roles, pause, reentrancy, cancelled
/// orders) lives in the router's regular storage and is never written by delegatecalled code.
library RouterStorage {
    /// @dev `nativeMode` values.
    uint8 internal constant NATIVE_WRAPPED = 0;
    uint8 internal constant NATIVE_ENSHRINED = 1;

    /// @dev keccak256(abi.encode(uint256(keccak256("krystal.v3utils.router.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x19744948ee10c565edd62fbd8291524ef5cd0cbad04a228710f08bf914160e00;

    /// @custom:storage-location erc7201:krystal.v3utils.router.storage
    struct Layout {
        // ---- config
        address swapRouter;
        address feeTaker;
        /// @dev The token that represents native value on this chain.
        address weth;
        /// @dev NATIVE_WRAPPED (0) or NATIVE_ENSHRINED (1).
        uint8 nativeMode;
        /// @dev Units of native per smallest unit of `weth`: 1 when WRAPPED, 10 ** (18 - decimals) when ENSHRINED.
        uint256 nativeScale;
        /// @dev Keyed by `uint8(FeeType)`.
        mapping(uint8 => uint64) maxFeeX64;
        // ---- registries
        mapping(bytes4 => address) module;
        mapping(address => address) adapter;
        mapping(address => address) farm;
        bool locked;
        // ---- per-call flow state (always cleared before the call returns)
        /// @dev The order's account while `executeAutomation` runs; zero otherwise.
        address automationAccount;
        /// @dev keccak256(abi.encode(nfpm, tokenId)) of the automated position while `executeAutomation` runs.
        bytes32 automationTarget;
        /// @dev keccak256(abi.encode(nfpm, from, tokenId)) of the one NFT the router may receive by safeTransferFrom.
        bytes32 expectedNft;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
