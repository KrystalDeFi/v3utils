// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWETH9} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

/**
 * @title NativeCurrency
 * @notice Converts between a chain's native currency and the token that represents it.
 * @dev Two models exist:
 *
 *  wrapped   - `weth` is a WETH9-style wrapper. Native is wrapped and unwrapped 1:1 through
 *              deposit()/withdraw(). Every chain this repo shipped on before Arc.
 *  enshrined - `weth` is an ERC20 *view* of the native asset, sharing one balance with it, and no
 *              wrapper exists to call. Arc is the case in point: USDC is the gas token, exposed at
 *              0x3600...0000 with 6 decimals against 18-decimal native. Converting is pure unit
 *              arithmetic on a balance that never moves.
 *
 * Which model applies is a property of the chain, so the caller supplies it from an immutable rather
 * than from storage - that keeps the whole feature inside the delegatecalled implementation and out
 * of the router. The scale is deliberately NOT configurable: it is fixed by the token's own decimals
 * against 18-decimal native, so it is derived here and cannot be set wrong.
 *
 * The conversion is asymmetric:
 *   native -> token divides and therefore truncates
 *   token -> native multiplies and is always exact
 * What the division drops is strictly under one token unit - a sub-1e-6 USDC sliver on Arc. Nothing
 * moves to drop it, so it stays in the executing contract's native balance rather than reverting the
 * whole call over it; see `toTokenUnits`.
 *
 * These are internal functions, so they inline into the adapter and `address(this)` is whoever is
 * executing - the router, under its delegatecall. That is the contract holding the funds, which is
 * what the balance checks below inspect.
 *
 * Shared by both adapters. `IWETH9` comes from v3-periphery (this repo has no v4-periphery); ABI-identical.
 */
library NativeCurrency {
    /// @notice Thrown when the representing token has more decimals than native.
    error UnsupportedNativeDecimals();
    /// @notice Thrown when no token is configured to represent native value.
    error ZeroNativeToken();
    /// @notice Thrown when a conversion would report more value than the contract actually holds.
    error InsufficientNativeBalance();

    /**
     * @notice Units of native currency per 1 smallest unit of `weth`.
     * @dev 1 for an 18-decimal token, 1e12 for Arc's 6-decimal USDC view.
     */
    function scaleOf(address weth) internal view returns (uint256) {
        uint8 tokenDecimals = IERC20Metadata(weth).decimals();
        if (tokenDecimals > 18) revert UnsupportedNativeDecimals();
        return 10 ** (18 - tokenDecimals);
    }

    /**
     * @notice Takes `value` of native currency and returns the same value in units of `weth`.
     * @dev Wrapped wraps it, unchanged from before this existed. Enshrined has nothing to wrap, so it
     *      only rescales, truncating a remainder the token view cannot represent. That remainder is not
     *      stranded by the truncation: the conversion moves nothing, so it is still part of the native
     *      balance, which the caller sweeps back by listing address(0) in sweepTokens and
     *      WITHDRAWER_ROLE can recover if they do not.
     */
    function toTokenUnits(address weth, bool enshrined, uint256 value) internal returns (uint256 tokenAmount) {
        // Both branches below already revert on a zero weth - a high-level call to a codeless address
        // fails its extcodesize check even when the callee returns nothing. This is for a named error.
        if (weth == address(0)) revert ZeroNativeToken();
        if (!enshrined) {
            IWETH9(weth).deposit{value: value}();
            return value;
        }
        // The wrapped path gets this check for free: deposit{value:} cannot send value the contract does
        // not hold. Enshrined conversion is pure arithmetic and moves nothing, so without this it would
        // report a delta nothing backs - passing amountOutMin and emitting a fictitious Swap.
        if (address(this).balance < value) revert InsufficientNativeBalance();
        // Truncates. A `value` under one token unit therefore converts to 0, which is honest rather than
        // lossy: this conversion moves nothing, so there is no value to lose - only a delta not to claim.
        tokenAmount = value / scaleOf(weth);
    }

    /**
     * @notice Takes `tokenAmount` in units of `weth` and returns the same value as native currency.
     * @dev Multiplying cannot leave a remainder, so unlike `toTokenUnits` nothing truncates here.
     */
    function toNativeUnits(address weth, bool enshrined, uint256 tokenAmount) internal returns (uint256) {
        if (weth == address(0)) revert ZeroNativeToken();
        if (!enshrined) {
            IWETH9(weth).withdraw(tokenAmount);
            return tokenAmount;
        }
        // enshrined: nothing to unwrap - the ERC20 balance IS the native balance. Mirrors withdraw()
        // reverting on a WETH balance the contract does not hold. balanceOf truncates downwards, so this
        // is the conservative form of `balance >= tokenAmount * scale`.
        if (IERC20Metadata(weth).balanceOf(address(this)) < tokenAmount) revert InsufficientNativeBalance();
        return tokenAmount * scaleOf(weth);
    }
}
