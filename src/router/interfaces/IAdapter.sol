// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {PoolKey, Position} from "../RouterTypes.sol";

/// @notice Protocol adapter, one per NFPM. Modules DELEGATECALL it (so it runs as the router, on the router's
/// tokens) and pass the NFPM in; an adapter keeps no storage of its own.
/// @dev `mint` and `increase` approve the NFPM for exactly `amount0`/`amount1` and reset the allowance to 0 after.
interface IAdapter {
    /// @notice The position `tokenId` of `nfpm`, decoded into the protocol-neutral `Position`.
    function position(address nfpm, uint256 tokenId) external returns (Position memory);

    /// @notice The pool `key` resolves to on `nfpm`'s factory.
    function pool(address nfpm, PoolKey calldata key) external returns (address);

    function mint(
        address nfpm,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        address recipient,
        uint256 deadline
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1);

    function increase(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        returns (uint128 liquidity, uint256 used0, uint256 used1);

    /// @notice Removes `liquidity`; the amounts become owed to the position, and `collect` takes them.
    function decrease(
        address nfpm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects everything owed to the position (principal and fees) to the router.
    function collect(address nfpm, uint256 tokenId) external returns (uint256 amount0, uint256 amount1);
}
