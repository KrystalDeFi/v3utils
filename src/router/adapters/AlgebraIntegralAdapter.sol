// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {INonfungiblePositionManager as INfpm} from "../../Nfpm.sol";
import {PoolKey, Position} from "../RouterTypes.sol";
import {AdapterBase} from "./AdapterBase.sol";

interface IIntegralNfpm {
    function factory() external view returns (address);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint88 nonce,
            address operator,
            address token0,
            address token1,
            address deployer,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IIntegralFactory {
    function poolByPair(address tokenA, address tokenB) external view returns (address);

    function customPoolByPair(address deployer, address tokenA, address tokenB) external view returns (address);
}

interface IIntegralPool {
    function tickSpacing() external view returns (int24);
}

/// @notice Adapter for Algebra Integral NFPMs: a pool is identified by its `deployer` (address(0) for the default
/// pool, otherwise a custom-pool deployer), and `positions()` slot 5 is that deployer. `PoolKey.fee` is 0 (dynamic).
/// See `AdapterBase`.
contract AlgebraIntegralAdapter is AdapterBase {
    function _position(address nfpm, uint256 tokenId) internal view override returns (Position memory p) {
        (,, address token0, address token1, address deployer, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            IIntegralNfpm(nfpm).positions(tokenId);
        address pool_ = _pool(nfpm, token0, token1, deployer);
        p.key = PoolKey({
            token0: token0, token1: token1, fee: 0, tickSpacing: IIntegralPool(pool_).tickSpacing(), deployer: deployer
        });
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.liquidity = liquidity;
    }

    function _tokens(address nfpm, uint256 tokenId) internal view override returns (address token0, address token1) {
        (,, token0, token1,,,,,,,,) = IIntegralNfpm(nfpm).positions(tokenId);
    }

    function pool(address nfpm, PoolKey calldata key) external payable onlyDelegateCall returns (address) {
        return _pool(nfpm, key.token0, key.token1, key.deployer);
    }

    function _pool(address nfpm, address token0, address token1, address deployer) private view returns (address) {
        IIntegralFactory factory = IIntegralFactory(IIntegralNfpm(nfpm).factory());
        return deployer == address(0)
            ? factory.poolByPair(token0, token1)
            : factory.customPoolByPair(deployer, token0, token1);
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
                INfpm.AlgebraIntegralMintParams({
                token0: key.token0,
                token1: key.token1,
                deployer: key.deployer,
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
