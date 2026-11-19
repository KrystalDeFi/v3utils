// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {PoolKey} from "../RouterTypes.sol";

/// @notice Farm, at most one per NFPM. The router and modules DELEGATECALL it (so it runs as the router); a farm
/// keeps no storage of its own beyond `RouterStorage` (e.g. `expectedNft` around a `safeTransferFrom` back in).
interface IFarm {
    /// @notice Whether `account` has `tokenId` staked in this farm. A yes/no check rather than a holder lookup,
    /// because new Aero CLGauges only expose `stakedContains(depositor, tokenId)`.
    function isStakedBy(address nfpm, uint256 tokenId, address account) external returns (bool);

    function canUnstake() external returns (bool);

    function canIncreaseStaked() external returns (bool);

    /// @notice Whether staked positions still earn trading fees (false for Aero gauges, which take them).
    function earnsTradingFees() external returns (bool);

    function rewardToken() external returns (address);

    /// @notice Reverts unless `key`'s pool on `nfpm` has a live farm.
    function checkStakeable(address nfpm, PoolKey calldata key) external;

    /// @notice Stakes the router-held `tokenId` for `account`.
    function stake(address nfpm, uint256 tokenId, address account) external;

    /// @notice Unstakes `account`'s `tokenId` into the router.
    function unstake(address nfpm, uint256 tokenId, address account) external;

    /// @notice Claims `account`'s rewards on `tokenId` to the router.
    function claim(address nfpm, uint256 tokenId, address account) external returns (uint256 amount);

    /// @notice Adds liquidity to a position while it stays staked.
    function increaseStaked(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        returns (uint128 liquidity, uint256 used0, uint256 used1);
}
