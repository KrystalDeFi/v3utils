// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/pool/IUniswapV3PoolImmutables.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {AdapterBase} from "./AdapterBase.sol";
import {PoolKey, Position} from "../RouterTypes.sol";

/// @notice Adapter for Uniswap-v3-style NFPMs (Uniswap v3, Pancake v3, Sushi v3 and other forks that keep the
/// periphery ABI). Stateless: modules DELEGATECALL it, so `address(this)` is the router and the tokens are the
/// router's. `mint` approves the NFPM for exactly the amounts offered and resets to 0 afterwards (see `AdapterBase`
/// for the shared increase/decrease/collect and the delegatecall guard).
contract UniV3Adapter is AdapterBase {
    function _position(address nfpm, uint256 tokenId) internal view override returns (Position memory p) {
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            INonfungiblePositionManager(nfpm).positions(tokenId);
        address pool_ = IUniswapV3Factory(INonfungiblePositionManager(nfpm).factory()).getPool(token0, token1, fee);
        p.key = PoolKey({
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: IUniswapV3PoolImmutables(pool_).tickSpacing(),
            deployer: address(0)
        });
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.liquidity = liquidity;
    }

    function _tokens(address nfpm, uint256 tokenId) internal view override returns (address token0, address token1) {
        (,, token0, token1,,,,,,,,) = INonfungiblePositionManager(nfpm).positions(tokenId);
    }

    function pool(address nfpm, PoolKey calldata key) external payable onlyDelegateCall returns (address) {
        return IUniswapV3Factory(INonfungiblePositionManager(nfpm).factory()).getPool(key.token0, key.token1, key.fee);
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
        (tokenId, liquidity, used0, used1) = INonfungiblePositionManager(nfpm)
            .mint(
                INonfungiblePositionManager.MintParams({
                token0: key.token0,
                token1: key.token1,
                fee: key.fee,
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
