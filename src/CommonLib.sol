// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/interfaces/external/IWETH9.sol";

/**
 * @title CommonLib
 * @notice The heavy, self-contained parts of `Common`, compiled into a CREATE2-deployed library
 * rather than into every contract that inherits it.
 *
 * @dev V3Utils sits at the EIP-170 limit, so this exists to move code out of it. These are `external`
 * library functions, so they are reached by DELEGATECALL and run in the caller's context: storage,
 * balance, `msg.sender` and `msg.value` are all the caller's. That is what lets them approve, pull
 * and send the caller's tokens exactly as the inlined versions did.
 *
 * Because a library cannot declare state, whatever these need from `Common`'s storage is passed in.
 *
 * Like `Nfpm` and `StructHash`, this is deployed to a pinned CREATE2 address and linked through
 * `foundry.toml`, so it is excluded from `forge fmt` - reformatting changes the metadata hash and
 * therefore the address.
 */
library CommonLib {
    error SlippageError();
    error SwapFailed(bytes swapData, uint256 index);
    error TransferError();
    error TooMuchEtherSent();
    error NoEtherToken();
    error NativeDustNotAllowed();
    error EtherSendFailed();

    /// @notice Native-asset model of the chain, as resolved by `Common.initialize`.
    /// @param weth the token representing native value
    /// @param scale units of native per 1 smallest unit of `weth`; 1 on a WETH9 chain
    /// @param enshrined true when `weth` is an ERC20 view of native with no wrapper to call
    struct NativeConfig {
        address weth;
        uint256 scale;
        bool enshrined;
    }

    /// @notice Swap through the configured aggregator using off-chain built calldata.
    /// @dev Slippage is enforced on the measured balance delta, so partial fills are tolerated.
    function swap(
        address swapRouter,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory swapData,
        uint256 index
    ) external returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (amountIn != 0 && swapData.length != 0 && address(tokenOut) != address(0)) {
            uint256 balanceInBefore = tokenIn.balanceOf(address(this));
            uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

            // approve needed amount
            safeApprove(tokenIn, swapRouter, amountIn);
            // execute swap
            (bool success,) = swapRouter.call(swapData);
            if (!success) {
                revert SwapFailed(swapData, index);
            }

            // reset approval
            safeApprove(tokenIn, swapRouter, 0);

            uint256 balanceInAfter = tokenIn.balanceOf(address(this));
            uint256 balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            if (amountOutDelta < amountOutMin) {
                revert SlippageError();
            }
        }
    }

    /// @notice Checks the required amounts are provided and exact, taking in any native value sent.
    /// @dev Reverts if less or more is provided, and for fee-on-transfer tokens.
    function prepareSwap(
        NativeConfig memory native,
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) external {
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 amountAddedOther;

        // take in ether sent, credited in units of the native-representing token
        if (msg.value != 0) {
            uint256 credited = receiveNative(native, msg.value);

            if (native.weth == address(token0)) {
                amountAdded0 = credited;
                if (amountAdded0 > amount0) {
                    revert TooMuchEtherSent();
                }
            } else if (native.weth == address(token1)) {
                amountAdded1 = credited;
                if (amountAdded1 > amount1) {
                    revert TooMuchEtherSent();
                }
            } else if (native.weth == address(otherToken)) {
                amountAddedOther = credited;
                if (amountAddedOther > amountOther) {
                    revert TooMuchEtherSent();
                }
            } else {
                revert NoEtherToken();
            }
        }

        // get missing tokens (fails if not enough provided)
        _pull(token0, amount0, amountAdded0);
        _pull(token1, amount1, amountAdded1);
        if (address(otherToken) != address(0) && token0 != otherToken && token1 != otherToken) {
            _pull(otherToken, amountOther, amountAddedOther);
        }
    }

    /// @dev Pulls the shortfall of `token` from the caller of the outer call, rejecting any token
    /// that does not credit the exact amount (fee-on-transfer).
    function _pull(IERC20 token, uint256 amount, uint256 alreadyAdded) private {
        if (amount <= alreadyAdded) {
            return;
        }
        uint256 missing = amount - alreadyAdded;
        uint256 balanceBefore = token.balanceOf(address(this));
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), missing);
        if (token.balanceOf(address(this)) - balanceBefore != missing) {
            revert TransferError();
        }
    }

    /// @notice Takes native value in and returns it denominated in units of `native.weth`.
    /// @dev Wrapped wraps 1:1. Enshrined has nothing to wrap - native and the ERC20 view share one
    /// balance - so only the unit changes, and a remainder the view cannot represent is rejected
    /// rather than stranded where only WITHDRAWER_ROLE could recover it.
    function receiveNative(NativeConfig memory native, uint256 value) public returns (uint256 tokenAmount) {
        if (!native.enshrined) {
            IWETH9(native.weth).deposit{value: value}();
            return value;
        }
        tokenAmount = value / native.scale;
        if (tokenAmount * native.scale != value) {
            revert NativeDustNotAllowed();
        }
    }

    /// @notice Sends `tokenAmount`, denominated in units of `native.weth`, as native value.
    /// @dev Unlike `receiveNative` this direction is exact, so it needs no dust guard.
    function sendNative(NativeConfig memory native, address to, uint256 tokenAmount) public {
        if (!native.enshrined) {
            IWETH9(native.weth).withdraw(tokenAmount);
        }
        // enshrined: nothing to unwrap - the ERC20 balance IS the native balance
        (bool sent,) = to.call{value: tokenAmount * native.scale}("");
        if (!sent) {
            revert EtherSendFailed();
        }
    }

    /// @notice Approves `_spender`, tolerating tokens that do not return a bool or reject approve(0).
    function safeApprove(IERC20 token, address _spender, uint256 _value) public {
        (bool success, bytes memory returnData) =
            address(token).call(abi.encodeWithSelector(token.approve.selector, _spender, _value));
        if (_value == 0) {
            // some token does not allow approve(0) so we skip check for this case
            return;
        }
        require(success && (returnData.length == 0 || abi.decode(returnData, (bool))), "SA");
    }
}
