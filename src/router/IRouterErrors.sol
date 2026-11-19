// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FeeType, InputTokenParams} from "./RouterTypes.sol";

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

    // ---- core (CoreBase: ledger, inputs, fees, swaps, custody)
    /// @dev A module, adapter or farm called directly instead of by DELEGATECALL from the router.
    error NotDelegateCall();
    /// @dev A token the call's ledger does not track.
    error NotTracked();
    /// @dev An input pull credited the router a different amount than declared (fee-on-transfer, surcharge).
    error TransferError();
    /// @dev `msg.value` does not equal the native inputs, or a swap asks for more than the call holds.
    error AmountError();
    /// @dev A token twice in the inputs, or a swap with `tokenIn == tokenOut`.
    error SameToken();
    /// @dev A fee above its type's cap.
    error TooMuchFee();
    error ZeroSwapRouter();
    error SwapFailed(bytes swapData, uint256 index);
    error SwapSlippage();
    /// @dev A non-zero approval the token refused.
    error ApproveFailed();
    /// @dev The position is staked in a farm that does not let the router unstake it.
    error FarmUnsupported();
    /// @dev Under `executeAutomation`, flow params that name a position other than the recorded target.
    error NotAutomation();

    /// @dev v4utils' event payload, so the backend's `TakeFees` decoding applies unchanged.
    struct TakeFeesEventData {
        InputTokenParams[] feeTokens;
        uint64 feeX64;
        FeeType feeType;
    }

    /// @notice Fees taken from a flow; `nfpm` is v4utils' `posm`.
    event TakeFees(address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, TakeFeesEventData data);
    /// @notice One swap step, with the balance deltas it produced (unit-converted amounts for native<->weth).
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
}
