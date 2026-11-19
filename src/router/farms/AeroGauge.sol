// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IRouterErrors} from "../IRouterErrors.sol";

/// @dev New Aero (MetaDEX03) CLGauge: the router acts on a depositor's stake with the gauge approvals that depositor
/// grants (`setApprovalForAll` for `withdrawFrom`, `approveForClaim` for `claimEmissions`).
interface IAeroCLGauge {
    function depositFor(uint256 tokenId, address recipient) external;
    function withdrawFrom(uint256 tokenId, address account) external;
    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external;
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
    function nft() external view returns (address);
}

interface IAeroGaugeFactory {
    function isGauge(address gauge) external view returns (bool);
    function leafVoter() external view returns (address);
}

interface IAeroLeafVoter {
    function isActivated(address gauge) external view returns (bool);
}

interface IAeroCLPool {
    function gauge() external view returns (address);
}

interface IAeroPoolFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @dev Aero CL position manager: `positions` slot 5 is the tickSpacing.
interface IAeroPositions {
    function factory() external view returns (address);

    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

/// @notice Resolves the gauge of an Aero CL pool or position (ported from PR #64's `AeroGauge`, with the gauge factory
/// and the NFPM passed in). No flow takes a gauge from its caller: a gauge is tied to one pool, so it is always derived
/// (position -> pool -> gauge) and must be one of `gaugeFactory`'s gauges for `nfpm`.
library AeroGauge {
    /// @dev The gauge of `nfpm`'s pool (token0, token1, tickSpacing), or zero when there is no such pool, the pool has
    /// no gauge, or its gauge is not one of `gaugeFactory`'s gauges for `nfpm`. Never reverts on a missing gauge.
    function find(address gaugeFactory, address nfpm, address token0, address token1, int24 tickSpacing)
        internal
        view
        returns (address gauge)
    {
        address pool = IAeroPoolFactory(IAeroPositions(nfpm).factory()).getPool(token0, token1, tickSpacing);
        if (pool == address(0)) return address(0);
        gauge = IAeroCLPool(pool).gauge();
        if (gauge == address(0) || !IAeroGaugeFactory(gaugeFactory).isGauge(gauge)) return address(0);
        if (IAeroCLGauge(gauge).nft() != nfpm) return address(0);
    }

    /// @dev `find`, reverting `InvalidGauge()` when there is no gauge.
    function ofPool(address gaugeFactory, address nfpm, address token0, address token1, int24 tickSpacing)
        internal
        view
        returns (address gauge)
    {
        gauge = find(gaugeFactory, nfpm, token0, token1, tickSpacing);
        if (gauge == address(0)) revert IRouterErrors.InvalidGauge();
    }

    /// @dev The gauge of position `tokenId`'s pool, or zero (see `find`).
    function findOfToken(address gaugeFactory, address nfpm, uint256 tokenId) internal view returns (address) {
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = IAeroPositions(nfpm).positions(tokenId);
        return find(gaugeFactory, nfpm, token0, token1, tickSpacing);
    }

    /// @dev `findOfToken`, reverting `InvalidGauge()` when there is no gauge.
    function ofToken(address gaugeFactory, address nfpm, uint256 tokenId) internal view returns (address gauge) {
        gauge = findOfToken(gaugeFactory, nfpm, tokenId);
        if (gauge == address(0)) revert IRouterErrors.InvalidGauge();
    }

    /// @dev Reverts `GaugeNotLive()` unless the voter runs `gauge` (not killed).
    function requireLive(address gaugeFactory, address gauge) internal view {
        if (!IAeroLeafVoter(IAeroGaugeFactory(gaugeFactory).leafVoter()).isActivated(gauge)) {
            revert IRouterErrors.GaugeNotLive();
        }
    }
}
