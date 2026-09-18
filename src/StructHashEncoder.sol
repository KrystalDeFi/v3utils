// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
pragma abicoder v2;

import "./StructHash.sol";

/// @notice Pure-view wrapper that exposes the StructHash.Order struct as a public
/// ABI signature. Existence purpose: `abigen` consumes a contract ABI to generate
/// Go struct types — without an external function carrying the Order, the bindings
/// would only see the library-internal _hash and not produce StructHashOrder types.
///
/// The `encode` function is intentionally a no-op view that returns the abi-encoded
/// input. Backend (sig_helper_v6.BuildSignatureParams) pulls this method's input
/// shape from the generated bindings and uses it to abi.encode an Order to bytes
/// for executeAutoEnter's abiEncodedUserOrder parameter.
contract StructHashEncoder {
    function encode(StructHash.Order calldata order) external pure returns (bytes memory) {
        return abi.encode(order);
    }

    function encodeRebalanceConfig(StructHash.RebalanceConfig calldata cfg)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(cfg);
    }

    function encodeAutoCompoundConfig(StructHash.AutoCompoundConfig calldata cfg)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(cfg);
    }

    function encodeAutoExitConfig(StructHash.AutoExitConfig calldata cfg)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(cfg);
    }

    function encodeAutoHarvestConfig(StructHash.AutoHarvestConfig calldata cfg)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(cfg);
    }
}
