// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {INonfungiblePositionManager as INfpm} from "../../Nfpm.sol";
import {PoolKey, Position} from "../RouterTypes.sol";
import {AdapterBase} from "./AdapterBase.sol";

interface IAlgebraV1Nfpm {
    function factory() external view returns (address);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IAlgebraV1Factory {
    function poolByPair(address tokenA, address tokenB) external view returns (address);
}

interface IAlgebraV1Pool {
    function tickSpacing() external view returns (int24);
}

/// @notice Adapter for Algebra V1 NFPMs (Camelot V3, QuickSwap V3): no fee and no tickSpacing in the mint or in
/// `positions()`; the pool comes from `poolByPair` and its tickSpacing from the pool. `PoolKey.fee` is 0 (the fee is
/// dynamic). See `AdapterBase`.
contract AlgebraV1Adapter is AdapterBase {
    function _position(address nfpm, uint256 tokenId) internal view override returns (Position memory p) {
        (,, address token0, address token1, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            IAlgebraV1Nfpm(nfpm).positions(tokenId);
        address pool_ = IAlgebraV1Factory(IAlgebraV1Nfpm(nfpm).factory()).poolByPair(token0, token1);
        p.key = PoolKey({
            token0: token0,
            token1: token1,
            fee: 0,
            tickSpacing: IAlgebraV1Pool(pool_).tickSpacing(),
            deployer: address(0)
        });
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.liquidity = liquidity;
    }

    function pool(address nfpm, PoolKey calldata key) external payable onlyDelegateCall returns (address) {
        return IAlgebraV1Factory(IAlgebraV1Nfpm(nfpm).factory()).poolByPair(key.token0, key.token1);
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
                INfpm.AlgebraV1MintParams({
                token0: key.token0,
                token1: key.token1,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: deadline
            })
            );
        _resetApprovals(nfpm, key);
    }
}
