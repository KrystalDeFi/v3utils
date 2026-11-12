// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroFarmingCore.sol";

/// @notice ABI of the operator path served by AeroFarmingHelper's fallback (implemented by AeroAutomationModule).
/// Call it on the helper proxy address, never on the module itself.
interface IAeroAutomation {
    function executeOrder(AeroFarmingCore.OrderParams calldata p) external returns (uint256 tokenIdAfter);
    function cancelOrder(bytes32 hash, bytes calldata signature) external;
    function isOrderCancelled(address actor, bytes32 hash) external view returns (bool);
    function domainSeparator() external view returns (bytes32);
    function hashOrder(bytes calldata order) external view returns (bytes32 digest);
}
