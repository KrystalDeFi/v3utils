// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager as IUniNfpm} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {PoolKey, Position} from "../RouterTypes.sol";
import {IRouterErrors} from "../IRouterErrors.sol";

/// @notice What the Algebra / Aerodrome / Ramses adapters share: the delegatecall guard and the calls whose ABI is
/// the same on every NFPM (`increaseLiquidity`, `decreaseLiquidity`, `collect`). A concrete adapter supplies the
/// layout-specific parts: `_position`, `pool` and `mint`. Stateless, like `UniV3Adapter`: modules DELEGATECALL it, so
/// `address(this)` is the router. Every function is `payable` (see `IAdapter`).
abstract contract AdapterBase is IAdapter, IRouterErrors {
    using SafeERC20 for IERC20;

    /// @dev This contract's own address, to tell a direct call from a delegatecall.
    address private immutable _self = address(this);

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert NotDelegateCall();
        _;
    }

    /// @dev Decodes the protocol's `positions(tokenId)` into the neutral `Position`.
    function _position(address nfpm, uint256 tokenId) internal view virtual returns (Position memory);

    /// @dev Just the tokens of a position; overridden where `_position` costs a pool lookup.
    function _tokens(address nfpm, uint256 tokenId) internal view virtual returns (address, address) {
        PoolKey memory key = _position(nfpm, tokenId).key;
        return (key.token0, key.token1);
    }

    function position(address nfpm, uint256 tokenId) external payable onlyDelegateCall returns (Position memory) {
        return _position(nfpm, tokenId);
    }

    function increase(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        payable
        onlyDelegateCall
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        (address token0, address token1) = _tokens(nfpm, tokenId);
        IERC20(token0).forceApprove(nfpm, amount0);
        IERC20(token1).forceApprove(nfpm, amount1);
        (liquidity, used0, used1) = IUniNfpm(nfpm)
            .increaseLiquidity(
                IUniNfpm.IncreaseLiquidityParams({
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
        (amount0, amount1) = IUniNfpm(nfpm)
            .decreaseLiquidity(
                IUniNfpm.DecreaseLiquidityParams({
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
        (amount0, amount1) = IUniNfpm(nfpm)
            .collect(
                IUniNfpm.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
            );
    }

    /// @dev Approves the NFPM for exactly the amounts offered; paired with `_resetApprovals` after the mint.
    function _approvePair(address nfpm, PoolKey calldata key, uint256 amount0, uint256 amount1) internal {
        IERC20(key.token0).forceApprove(nfpm, amount0);
        IERC20(key.token1).forceApprove(nfpm, amount1);
    }

    function _resetApprovals(address nfpm, PoolKey calldata key) internal {
        IERC20(key.token0).forceApprove(nfpm, 0);
        IERC20(key.token1).forceApprove(nfpm, 0);
    }
}
