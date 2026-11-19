// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Errors shared by the router and the code it delegatecalls (so a module's revert decodes against one ABI).
interface IRouterErrors {
    // ---- initialize and config
    /// @dev `initialize` from anyone but the deploying tx.origin.
    error NotInitializer();
    error AlreadyInitialized();
    error ZeroAddress();
    /// @dev A native mode other than WRAPPED (0) / ENSHRINED (1), or an ENSHRINED token with more than 18 decimals.
    error InvalidNativeConfig();
    /// @dev A non-zero module, adapter or farm with no code.
    error InvalidTarget();
    /// @dev A frozen setter after `lock()`, or a fee cap raised after it.
    error Locked();

    // ---- dispatch
    /// @dev No module registered for the selector.
    error UnknownSelector();
    /// @dev No adapter registered for the NFPM.
    error UnsupportedNfpm();
    /// @dev The account neither holds the NFT nor has it staked in the NFPM's farm.
    error NotPositionHolder();

    // ---- orders
    error WrongChainId();
    error WrongPositionManager();
    error InvalidSignature();
    error OrderCancelled();

    // ---- receiving
    error UnexpectedNft();
    error UnexpectedNative();
    error NativeTransferFailed();
}
