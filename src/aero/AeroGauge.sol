// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./IAero.sol";
import "./IAeroFarmingLogic.sol";
import "./AeroStorage.sol";

/// @notice Resolves the gauge of an Aero CL pool or position. No flow takes a gauge from its caller: a gauge is tied
/// to one pool, so it is always derived (position -> pool -> gauge). Compiled into both the router (operator path)
/// and the logic (user flows), so both derive it the same way.
library AeroGauge {
    /// @dev The gauge of pool (token0, token1, tickSpacing) of the gauge factory's position manager, and that position
    /// manager. Reverts InvalidGauge if there is no such pool or its gauge is not one of the factory's.
    function ofPool(address token0, address token1, int24 tickSpacing)
        internal
        view
        returns (address gauge, address nfpm)
    {
        ICLGaugeFactory f = ICLGaugeFactory(AeroStorage.layout().gaugeFactory);
        nfpm = f.nft();
        address pool = ICLFactory(IAeroNfpm(nfpm).factory()).getPool(token0, token1, tickSpacing);
        if (pool == address(0)) revert IAeroFarmingLogic.InvalidGauge();
        gauge = ICLPool(pool).gauge();
        if (!f.isGauge(gauge) || ICLGauge(gauge).nft() != nfpm) revert IAeroFarmingLogic.InvalidGauge();
    }

    /// @dev The gauge of position `tokenId`'s pool, and the position manager.
    function ofToken(uint256 tokenId) internal view returns (address gauge, address nfpm) {
        address n = ICLGaugeFactory(AeroStorage.layout().gaugeFactory).nft();
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = IAeroNfpm(n).positions(tokenId);
        return ofPool(token0, token1, tickSpacing);
    }
}
