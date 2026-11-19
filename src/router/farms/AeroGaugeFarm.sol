// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "../RouterTypes.sol";
import {RouterStorage} from "../RouterStorage.sol";
import {IRouterErrors} from "../IRouterErrors.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {AeroGauge, IAeroCLGauge} from "./AeroGauge.sol";

/// @notice Farm for new Aero (MetaDEX03) CL gauges, ported from PR #64's `AeroFarmingLogic`. The router never becomes
/// the recorded staker: `depositFor` keeps the user as the gauge's depositor, and the router unstakes and claims with the
/// gauge approvals the user grants (`setApprovalForAll` for `withdrawFrom`, `approveForClaim` for `claimEmissions`).
/// @dev Stateless: per-chain config is immutable and the router and modules DELEGATECALL it, so it runs as the router;
/// the only storage it touches is `RouterStorage.expectedNft` around `withdrawFrom`. The gauge is always derived from
/// the position or the pool key (`AeroGauge`), never taken from calldata. Every function is `payable` (see `IFarm`).
///
/// Emissions: with `approveForClaim`, `withdrawFrom` pays the stake's emissions to the router; the flows track the
/// reward token in their ledger, so they reach the account. An unstake inside the gauge's penalty window
/// (`effectivePenaltyConfig`) forfeits emissions, as on the gauge itself.
contract AeroGaugeFarm is IFarm, IRouterErrors {
    /// @notice The CL gauge factory every derived gauge must come from.
    address public immutable gaugeFactory;
    /// @notice Whether staked rewards may be compounded (AERO on Base; xAERO elsewhere cannot be).
    bool public immutable compoundEnabled;
    /// @dev AERO on Base, xAERO elsewhere.
    address private immutable _rewardToken;
    /// @dev This contract's own address, to tell a direct call from a delegatecall.
    address private immutable _self = address(this);

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert NotDelegateCall();
        _;
    }

    constructor(address gaugeFactory_, address rewardToken_, bool compoundEnabled_) {
        if (gaugeFactory_ == address(0) || rewardToken_ == address(0)) revert ZeroAddress();
        gaugeFactory = gaugeFactory_;
        _rewardToken = rewardToken_;
        compoundEnabled = compoundEnabled_;
    }

    // ---------------------------------------------------------------- capabilities

    /// @inheritdoc IFarm
    /// @dev False, never a revert, when the position's pool has no gauge of `gaugeFactory`: wallet positions in
    /// gauge-less pools keep working behind the holder check.
    function isStakedBy(address nfpm, uint256 tokenId, address account) external payable returns (bool) {
        address gauge = AeroGauge.findOfToken(gaugeFactory, nfpm, tokenId);
        return gauge != address(0) && IAeroCLGauge(gauge).stakedContains(account, tokenId);
    }

    function canUnstake() external payable returns (bool) {
        return true;
    }

    /// @dev Aero adds liquidity only to an unstaked position (take, increase, restake).
    function canIncreaseStaked() external payable returns (bool) {
        return false;
    }

    /// @dev Staked liquidity's trading fees go to the gauge's voters.
    function earnsTradingFees() external payable returns (bool) {
        return false;
    }

    function canCompound() external payable returns (bool) {
        return compoundEnabled;
    }

    function rewardToken() external payable returns (address) {
        return _rewardToken;
    }

    /// @inheritdoc IFarm
    /// @dev `InvalidGauge()` without a gauge of `gaugeFactory` for the pool, `GaugeNotLive()` when it is killed.
    function checkStakeable(address nfpm, PoolKey calldata key) external payable {
        address gauge = AeroGauge.ofPool(gaugeFactory, nfpm, key.token0, key.token1, key.tickSpacing);
        AeroGauge.requireLive(gaugeFactory, gauge);
    }

    // ---------------------------------------------------------------- custody and rewards

    /// @inheritdoc IFarm
    /// @dev Into the position's gauge, which must be live (`GaugeNotLive()`), with `account` as the depositor.
    function stake(address nfpm, uint256 tokenId, address account) external payable onlyDelegateCall {
        address gauge = AeroGauge.ofToken(gaugeFactory, nfpm, tokenId);
        AeroGauge.requireLive(gaugeFactory, gauge);
        IERC721(nfpm).approve(gauge, tokenId);
        IAeroCLGauge(gauge).depositFor(tokenId, account);
    }

    /// @inheritdoc IFarm
    /// @dev `withdrawFrom` returns the NFT by `safeTransferFrom(gauge, router)`, so the expected-NFT record names it
    /// for exactly that transfer. Works on a killed gauge too, so a full withdraw always gets out.
    function unstake(address nfpm, uint256 tokenId, address account) external payable onlyDelegateCall {
        address gauge = AeroGauge.ofToken(gaugeFactory, nfpm, tokenId);
        RouterStorage.Layout storage s = RouterStorage.layout();
        s.expectedNft = keccak256(abi.encode(nfpm, gauge, tokenId));
        IAeroCLGauge(gauge).withdrawFrom(tokenId, account);
        s.expectedNft = bytes32(0);
    }

    /// @inheritdoc IFarm
    /// @dev `claimEmissions(account, router, [tokenId])` (needs the account's `approveForClaim`); returns the reward
    /// the router received. The position stays staked.
    function claim(address nfpm, uint256 tokenId, address account)
        external
        payable
        onlyDelegateCall
        returns (uint256 amount)
    {
        address gauge = AeroGauge.ofToken(gaugeFactory, nfpm, tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 before = IERC20(_rewardToken).balanceOf(address(this));
        IAeroCLGauge(gauge).claimEmissions(account, address(this), ids);
        amount = IERC20(_rewardToken).balanceOf(address(this)) - before;
    }

    /// @dev Never: `canIncreaseStaked` is false.
    function increaseStaked(address, uint256, uint256, uint256, uint256)
        external
        payable
        returns (uint128, uint256, uint256)
    {
        revert FarmUnsupported();
    }
}
