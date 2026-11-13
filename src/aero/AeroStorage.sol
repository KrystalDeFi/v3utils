// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Config and flow state shared by AeroFarmingRouter and the AeroFarmingLogic it delegatecalls, kept in one
/// namespaced (ERC-7201 style) slot so the router and any future logic agree on it without inheriting a layout.
/// @dev Append new fields at the end only; never reorder or remove.
library AeroStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("krystal.aero.farming.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xa60701299f10d90e57575380a0b637f0f8f9045185f73ed32c1534362756f200;

    struct Layout {
        address v3utils;
        address gaugeFactory;
        address rewardToken; // AERO on Base, xAERO elsewhere
        bool compoundEnabled; // true only on Base
        address weth; // 0 => native disabled (Arc)
        address activeGauge; // non-zero only inside withdrawFrom (NFT receive guard)
        address automationAccount; // non-zero only inside executeAutomation
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
