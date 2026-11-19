// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {DecreaseAndSwapParams, AdjustRangeParams, CompoundParams, HarvestParams} from "../RouterTypes.sol";

/// @notice The CoreModify module's flows on an existing position: withdraw (partly or fully) and swap the proceeds,
/// move the liquidity to a new range, compound the trading fees into the position, or harvest them. Users reach them
/// through `V3UtilsRouter.execute(abi.encodeCall(ICoreModify.<flow>, (params)))`; the operator runs the same functions
/// through `executeAutomation` (AUTO_EXIT, AUTO_ADJUST, AUTO_COMPOUND, AUTO_HARVEST), so each takes exactly one params
/// struct and is not payable.
interface ICoreModify {
    /// @notice `liquidity` removed from the position (0 for a fees-only collect); `amount` of `token` (the
    /// `destToken`) went to the account.
    event DecreaseAndSwap(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, address token, uint256 amount
    );
    /// @notice The position `tokenId` moved to the new position `newTokenId` with `liquidity`; `added0`/`added1`
    /// are what the NFPM took into it.
    event AdjustRange(
        address indexed nfpm,
        uint256 indexed tokenId,
        uint256 newTokenId,
        uint256 liquidity,
        uint256 added0,
        uint256 added1
    );

    /// @notice Takes the account's position, collects its earned fees (PERFORMANCE_FEE on them, plus GAS_FEE when
    /// `decrease.liquidity == 0`), removes `decrease.liquidity` (clamped to the position's) and collects it
    /// (PROTOCOL_FEE and GAS_FEE on that principal), runs `swaps`, and pays everything the call holds to the account.
    /// The NFT goes back where it came from; a withdraw that leaves it with no liquidity sends it to the wallet.
    /// @return amountOut What the account receives of `destToken`: the call's own `destToken` balance delta.
    function decreaseAndSwap(DecreaseAndSwapParams calldata params) external returns (uint256 amountOut);

    /// @notice The position `tokenId` took `liquidity` from its own trading fees (`amount0`/`amount1` used).
    event CompoundFees(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    /// @notice The account received `amount` of `token` (the `destToken`) from the position's trading fees.
    event Harvest(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount);

    /// @notice Takes the account's position, collects its earned fees (PERFORMANCE_FEE on them) and, unless
    /// `compoundFees`, pays them to the account before anything else; then removes all its liquidity (PROTOCOL_FEE and
    /// GAS_FEE on that principal), runs `swaps`, and mints `mint`'s range from everything the call holds of the pool's
    /// tokens (`minLiquidity` checked). The new NFT goes where the old one came from; the old, empty NFT goes to the
    /// wallet. Leftovers go to the account.
    function adjustRange(AdjustRangeParams calldata params) external returns (uint256 newTokenId, uint128 liquidity);

    /// @notice Collects the position's trading fees, takes PERFORMANCE_FEE, runs `swaps`, and adds everything the call
    /// holds of the pool's tokens to the same position (`increase.minLiquidity` checked); leftovers go to the account. A
    /// position with no fees to add is left as it is (liquidity 0 returned).
    function compound(CompoundParams calldata params) external returns (uint128 liquidity);

    /// @notice Collects the position's trading fees, takes PERFORMANCE_FEE, runs `swaps` and pays the account. No
    /// liquidity is removed. `MissingSwapData()` when `destToken` is neither zero nor a pool token, the net fees are
    /// not zero and `swaps` is empty.
    /// @return amountOut What the account receives of `destToken` (0 for the zero address).
    function harvest(HarvestParams calldata params) external returns (uint256 amountOut);
}
