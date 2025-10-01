// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { INonfungiblePositionManager as IUniV3NonfungiblePositionManager } from 'v3-periphery/interfaces/INonfungiblePositionManager.sol';

interface INonfungiblePositionManager is IUniV3NonfungiblePositionManager {
    /// @notice mintParams for algebra v1
    struct AlgebraV1MintParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        AlgebraV1MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice mintParams for aerodrome
    struct AerodromeMintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    function mint(
        AerodromeMintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice mintParams for Ramses v3
    struct RamsesV3MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new position wrapped in a NFT
    /// @dev Call this when the pool does exist and is initialized. Note that if the pool is created but not initialized
    /// a method does not exist, i.e. the pool is assumed to be initialized.
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata
    /// @return tokenId The ID of the token that represents the minted position
    /// @return liquidity The amount of liquidity for this position
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function mint(
        RamsesV3MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice mintParams for algebra integral
    struct AlgebraIntegralMintParams {
        address token0;
        address token1;
        address deployer;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        AlgebraIntegralMintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

library Nfpm {
    enum Protocol {
        UNI_V3,
        ALGEBRA_V1,
        RAMSES_V3,
        AERODROME,
        ALGEBRA_INTEGRAL
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
        address deployer;
    }

    function mint(
        INonfungiblePositionManager nfpm,
        Protocol protocol,
        MintParams memory params
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (protocol == Protocol.UNI_V3) {
            return mintUniv3(
                nfpm,
                IUniV3NonfungiblePositionManager.MintParams(
                    params.token0,
                    params.token1,
                    params.fee,
                    params.tickLower,
                    params.tickUpper,
                    params.amount0Desired,
                    params.amount1Desired,
                    params.amount0Min,
                    params.amount1Min,
                    params.recipient,
                    params.deadline
                )
            );
        } else if (protocol == Protocol.ALGEBRA_V1) {
            return mintAlgebraV1(
                nfpm,
                INonfungiblePositionManager.AlgebraV1MintParams(
                    params.token0,
                    params.token1,
                    params.tickLower,
                    params.tickUpper,
                    params.amount0Desired,
                    params.amount1Desired,
                    params.amount0Min,
                    params.amount1Min,
                    params.recipient,
                    params.deadline
                )
            );
        } else if (protocol == Protocol.RAMSES_V3) {
            return mintRamsesV3(
                nfpm,
                INonfungiblePositionManager.RamsesV3MintParams(
                    params.token0,
                    params.token1,
                    params.tickSpacing,
                    params.tickLower,
                    params.tickUpper,
                    params.amount0Desired,
                    params.amount1Desired,
                    params.amount0Min,
                    params.amount1Min,
                    params.recipient,
                    params.deadline
                )
            );
        } else if (protocol == Protocol.AERODROME) {
            return mintAerodrome(
                nfpm,
                INonfungiblePositionManager.AerodromeMintParams(
                    params.token0,
                    params.token1,
                    params.tickSpacing,
                    params.tickLower,
                    params.tickUpper,
                    params.amount0Desired,
                    params.amount1Desired,
                    params.amount0Min,
                    params.amount1Min,
                    params.recipient,
                    params.deadline,
                    params.sqrtPriceX96
                )
            );
        } else if (protocol == Protocol.ALGEBRA_INTEGRAL) {
            return mintAlgebraIntegral(
                nfpm,
                INonfungiblePositionManager.AlgebraIntegralMintParams(
                    params.token0,
                    params.token1,
                    params.deployer,
                    params.tickLower,
                    params.tickUpper,
                    params.amount0Desired,
                    params.amount1Desired,
                    params.amount0Min,
                    params.amount1Min,
                    params.recipient,
                    params.deadline
                )
            );
        } else {
            revert('unsupported protocol');
        }
    }

    function mintUniv3(
        INonfungiblePositionManager nfpm,
        INonfungiblePositionManager.MintParams memory params
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
        return nfpm.mint(params);
    }

    function mintAlgebraV1(
        INonfungiblePositionManager nfpm,
        INonfungiblePositionManager.AlgebraV1MintParams memory params
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
        return nfpm.mint(params);
    }

    function mintAerodrome(
        INonfungiblePositionManager nfpm,
        INonfungiblePositionManager.AerodromeMintParams memory params
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
        return nfpm.mint(params);
    }

    function mintRamsesV3(
        INonfungiblePositionManager nfpm,
        INonfungiblePositionManager.RamsesV3MintParams memory params
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // mint is done to address(this) because it is not a safemint and safeTransferFrom needs to be done manually afterwards
        return nfpm.mint(params);
    }

    function mintAlgebraIntegral(
        INonfungiblePositionManager nfpm,
        INonfungiblePositionManager.AlgebraIntegralMintParams memory params
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        return nfpm.mint(params);
    }

    function decreaseLiquidity(
        INonfungiblePositionManager nfpm,
        IUniV3NonfungiblePositionManager.DecreaseLiquidityParams memory params
    ) external returns (uint256 amount0, uint256 amount1) {
        return nfpm.decreaseLiquidity(params);
    }

    function collect(
        INonfungiblePositionManager nfpm,
        IUniV3NonfungiblePositionManager.CollectParams memory params
    ) external returns (uint256 amount0, uint256 amount1) {
        return nfpm.collect(params);
    }

    function getPosition(
        INonfungiblePositionManager nfpm,
        Protocol protocol,
        uint256 tokenId
    )
        external
        returns (
            address token0,
            address token1,
            address deployer,
            uint24 fee,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity
        )
    {
        (bool success, bytes memory data) = address(nfpm).call(abi.encodeWithSignature('positions(uint256)', tokenId));
        if (!success) {
            revert('getPosition failed');
        }

        if (protocol == Protocol.UNI_V3) {
            (, , token0, token1, fee, tickLower, tickUpper, liquidity, , , , ) = abi.decode(
                data,
                (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
            );
        } else if (protocol == Protocol.ALGEBRA_V1) {
            (, , token0, token1, tickLower, tickUpper, liquidity, , , , ) = abi.decode(
                data,
                (uint96, address, address, address, int24, int24, uint128, uint256, uint256, uint128, uint128)
            );
        } else if (protocol == Protocol.RAMSES_V3) {
            (token0, token1, tickSpacing, tickLower, tickUpper, liquidity, , , , ) = abi.decode(
                data,
                (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
            );
        } else if (protocol == Protocol.AERODROME) {
            (, , token0, token1, tickSpacing, tickLower, tickUpper, liquidity, , , , ) = abi.decode(
                data,
                (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
            );
        } else if (protocol == Protocol.ALGEBRA_INTEGRAL) {
            (, , token0, token1, deployer, tickLower, tickUpper, liquidity, , , , ) = abi.decode(
                data,
                (uint88, address, address, address, address, int24, int24, uint128, uint256, uint256, uint128, uint128)
            );
        } else {
            revert('invalid protocol');
        }
    }
}
