// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {PoolKey} from "../RouterTypes.sol";

/// @notice Farm, at most one per NFPM. The router and modules DELEGATECALL it (so it runs as the router); a farm
/// keeps no storage of its own beyond `RouterStorage` (e.g. `expectedNft` around a `safeTransferFrom` back in).
/// @dev Every function is `payable`: a DELEGATECALL keeps the payable flow's `msg.value`, so a non-payable function's
/// callvalue check would revert every flow that carries native. A farm never spends `msg.value`.
interface IFarm {
    /// @notice Whether `account` has `tokenId` staked in this farm. A yes/no check rather than a holder lookup,
    /// because new Aero CLGauges only expose `stakedContains(depositor, tokenId)`.
    function isStakedBy(address nfpm, uint256 tokenId, address account) external payable returns (bool);

    function canUnstake() external payable returns (bool);

    function canIncreaseStaked() external payable returns (bool);

    /// @notice Whether staked positions still earn trading fees (false for Aero gauges, which take them).
    function earnsTradingFees() external payable returns (bool);

    /// @notice Whether `compound` may add this farm's rewards back into a staked position (false where the reward
    /// cannot be swapped into the pool, e.g. xAERO off Base).
    function canCompound() external payable returns (bool);

    /// @notice The token `claim` pays, and an unstake may pay (swept to the account by the flow's ledger).
    function rewardToken() external payable returns (address);

    /// @notice Reverts unless `key`'s pool on `nfpm` has a live farm.
    function checkStakeable(address nfpm, PoolKey calldata key) external payable;

    /// @notice Stakes the router-held `tokenId` for `account`.
    function stake(address nfpm, uint256 tokenId, address account) external payable;

    /// @notice Unstakes `account`'s `tokenId` into the router.
    function unstake(address nfpm, uint256 tokenId, address account) external payable;

    /// @notice Claims `account`'s rewards on `tokenId` to the router.
    function claim(address nfpm, uint256 tokenId, address account) external payable returns (uint256 amount);

    /// @notice Adds liquidity to a position while it stays staked.
    function increaseStaked(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        payable
        returns (uint128 liquidity, uint256 used0, uint256 used1);
}
