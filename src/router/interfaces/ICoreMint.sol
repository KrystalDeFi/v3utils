// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SwapAndMintParams, SwapAndIncreaseParams} from "../RouterTypes.sol";

/// @notice The CoreMint module's flows: open a position, or add to one, from any input tokens. Users reach them
/// through `V3UtilsRouter.execute(abi.encodeCall(ICoreMint.<flow>, (params)))`.
interface ICoreMint {
    /// @notice A position minted; `amount0`/`amount1` are what the NFPM took into it.
    event SwapAndMint(
        address indexed nfpm, uint256 indexed tokenId, uint256 liquidity, uint256 amount0, uint256 amount1
    );
    /// @notice Liquidity added to an existing position; `amount0`/`amount1` are what the NFPM took into it.
    event SwapAndIncrease(
        address indexed nfpm, uint256 indexed tokenId, uint256 liquidity, uint256 amount0, uint256 amount1
    );

    /// @notice Pulls `inputTokens` from the caller, takes the protocol and gas fees on them, runs `swaps`, mints a
    /// `key` position on `nfpm` from everything the call then holds of the pool's tokens, and sends the NFT to the
    /// caller (`stake == false`) or stakes it for the caller in the NFPM's farm (`stake == true`). Everything else
    /// the call holds is returned to the caller.
    function swapAndMint(SwapAndMintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity);

    /// @notice Same as `swapAndMint`, adding to the caller's existing position `tokenId` instead. The position is
    /// taken from the caller (NFPM approval to the router needed) and given back.
    function swapAndIncrease(SwapAndIncreaseParams calldata params) external payable returns (uint128 liquidity);
}
