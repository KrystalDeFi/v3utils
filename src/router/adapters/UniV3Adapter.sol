// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/pool/IUniswapV3PoolImmutables.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {PoolKey, Position} from "../RouterTypes.sol";
import {IRouterErrors} from "../IRouterErrors.sol";

/// @notice Adapter for Uniswap-v3-style NFPMs (Uniswap v3, Pancake v3, Sushi v3 and other forks that keep the
/// periphery ABI). Stateless: modules DELEGATECALL it, so `address(this)` is the router and the tokens are the
/// router's. `mint` and `increase` approve the NFPM for exactly the amounts offered and reset to 0 afterwards.
/// Every function is `payable` (see `IAdapter`): it runs inside payable flows by DELEGATECALL, which keeps `msg.value`.
contract UniV3Adapter is IAdapter, IRouterErrors {
    using SafeERC20 for IERC20;

    /// @dev This contract's own address, to tell a direct call from a delegatecall.
    address private immutable _self = address(this);

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert NotDelegateCall();
        _;
    }

    function position(address nfpm, uint256 tokenId) external payable onlyDelegateCall returns (Position memory p) {
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
        IERC20(key.token0).forceApprove(nfpm, amount0);
        IERC20(key.token1).forceApprove(nfpm, amount1);
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
        IERC20(key.token0).forceApprove(nfpm, 0);
        IERC20(key.token1).forceApprove(nfpm, 0);
    }

    function increase(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        payable
        onlyDelegateCall
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        (,, address token0, address token1,,,,,,,,) = INonfungiblePositionManager(nfpm).positions(tokenId);
        IERC20(token0).forceApprove(nfpm, amount0);
        IERC20(token1).forceApprove(nfpm, amount1);
        (liquidity, used0, used1) = INonfungiblePositionManager(nfpm)
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline
            })
            );
        IERC20(token0).forceApprove(nfpm, 0);
        IERC20(token1).forceApprove(nfpm, 0);
    }

    function decrease(
        address nfpm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external payable onlyDelegateCall returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = INonfungiblePositionManager(nfpm)
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
            );
    }

    function collect(address nfpm, uint256 tokenId)
        external
        payable
        onlyDelegateCall
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = INonfungiblePositionManager(nfpm)
            .collect(
                INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
            );
    }
}
