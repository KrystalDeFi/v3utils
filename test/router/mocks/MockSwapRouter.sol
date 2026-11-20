// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Swap router stand-in. Pays `amountOut` of `tokenOut` to the caller from a balance the test dealt it.
/// Native `tokenIn` (address(0)) is paid by `msg.value`.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    error Rejected();

    /// @dev Pulls the caller's full allowance of `tokenIn`.
    function swap(address tokenIn, address tokenOut, uint256 amountOut) external payable {
        if (tokenIn != address(0)) {
            uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev Pulls only `amountIn` of `tokenIn`, leaving any extra allowance in place.
    function swapExact(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external payable {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev Pulls more than the caller approved (and so fails), to show the approval is exact.
    function swapGreedy(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
    }

    /// @dev Pulls the caller's full allowance of `tokenIn` and pays `amountOut` of native back, as an aggregator
    /// route ending in native does (from a native balance the test dealt it).
    function swapToNative(address tokenIn, uint256 amountOut) external {
        uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        (bool ok, bytes memory ret) = msg.sender.call{value: amountOut}("");
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function fail() external pure {
        revert Rejected();
    }
}
