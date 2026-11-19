// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {INonfungiblePositionManager as INfpm} from "../../Nfpm.sol";
import {PoolKey, Position} from "../RouterTypes.sol";
import {AdapterBase} from "./AdapterBase.sol";

interface IAeroNfpm {
    function factory() external view returns (address);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @notice Adapter for Aerodrome / Velodrome Slipstream NFPMs: pools are keyed by `tickSpacing`, `positions()` slot 5
/// is the tickSpacing, and a mint passes `sqrtPriceX96 = 0` (the pool must already exist). `PoolKey.fee` is 0.
/// See `AdapterBase`.
contract AerodromeAdapter is AdapterBase {
    function _position(address nfpm, uint256 tokenId) internal view override returns (Position memory p) {
        (
            ,,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,,
        ) = IAeroNfpm(nfpm).positions(tokenId);
        p.key = PoolKey({token0: token0, token1: token1, fee: 0, tickSpacing: tickSpacing, deployer: address(0)});
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.liquidity = liquidity;
    }

    function pool(address nfpm, PoolKey calldata key) external payable onlyDelegateCall returns (address) {
        return ICLFactory(IAeroNfpm(nfpm).factory()).getPool(key.token0, key.token1, key.tickSpacing);
    }

    function mint(
        address nfpm,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        address recipient,
        uint256 deadline
    ) external payable onlyDelegateCall returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) {
        _approvePair(nfpm, key, amount0, amount1);
        (tokenId, liquidity, used0, used1) = INfpm(nfpm)
            .mint(
                INfpm.AerodromeMintParams({
                token0: key.token0,
                token1: key.token1,
                tickSpacing: key.tickSpacing,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: deadline,
                sqrtPriceX96: 0
            })
            );
        _resetApprovals(nfpm, key);
    }
}
