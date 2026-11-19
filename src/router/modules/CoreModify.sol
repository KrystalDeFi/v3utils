// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FeeType, MintParams, Position, SwapParams, DecreaseAndSwapParams, AdjustRangeParams} from "../RouterTypes.sol";
import {ICoreModify} from "../interfaces/ICoreModify.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {CoreBase} from "../base/CoreBase.sol";

/// @notice Flows on an existing position: `decreaseAndSwap` withdraws part or all of it (or only its fees) and swaps
/// the proceeds, `adjustRange` moves it to a new range. Runs only by DELEGATECALL from the router, for the account
/// `_account` resolves (the caller, or the order's account under `executeAutomation`). Neither flow takes native, so
/// neither is payable: value sent with them reverts.
/// @dev Every flow reads top to bottom in the pipeline order of spec §6.6:
///   1. read the position, open the ledger, take the position (wallet or farm, §6.4);
///   2. collect the earned fees and take PERFORMANCE_FEE on them; then remove liquidity, collect the principal and
///      take PROTOCOL_FEE then GAS_FEE on it. Earned fees and principal are told apart by collecting twice (fees
///      first), as v4utils does, and each amount is the call's balance delta, never an NFPM-reported figure;
///   3. run the swaps;
///   4. mint (adjustRange);
///   5. put the position(s) back;
///   6. sweep what the call holds to the account;
///   7. emit the flow's event. `TakeFees` is emitted as each fee is taken, tagged with the position's tokenId.
contract CoreModify is ICoreModify, CoreBase {
    /// @dev The position a flow acts on, and for whom.
    struct Target {
        address nfpm;
        uint256 tokenId;
        address account;
        address adapter;
        address token0;
        address token1;
    }

    /// @dev What a mint did: the new position, its liquidity and what the NFPM took.
    struct Minted {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    /// @inheritdoc ICoreModify
    /// @dev `decrease.liquidity` above the position's is clamped to it (as v4utils), so `type(uint128).max` means
    /// "everything". GAS_FEE goes on the earned fees only for a fees-only call (`liquidity == 0`), else on the principal
    /// (v4utils). A withdraw that leaves the position with no liquidity sends the NFT to the wallet, even when it came
    /// from a farm (§6.4); otherwise it goes back where it came from.
    function decreaseAndSwap(DecreaseAndSwapParams calldata params)
        external
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        (Target memory t, Position memory pos) = _target(params.nfpm, params.tokenId);
        Ledger memory l = _open(_candidates(params.swaps, t.token0, t.token1, params.destToken));
        bool staked = _take(t.nfpm, t.tokenId, t.account);

        uint128 liquidity = params.decrease.liquidity;
        _collectFees(l, t, params.performanceFeeX64, liquidity == 0 ? params.gasFeeX64 : 0);
        if (liquidity > pos.liquidity) liquidity = pos.liquidity;
        if (liquidity != 0) {
            _withdraw(
                l,
                t,
                liquidity,
                params.decrease.amount0Min,
                params.decrease.amount1Min,
                params.decrease.deadline,
                params.protocolFeeX64,
                params.gasFeeX64
            );
        }
        _swaps(l, params.swaps);
        // GHSA-m36p (v4utils): what the account receives of destToken is the call's delta, read before the sweep
        amountOut = _held(l, params.destToken);

        _putBack(t.nfpm, t.tokenId, t.account, staked && liquidity < pos.liquidity);
        _close(l, t.account);

        emit DecreaseAndSwap(t.nfpm, t.tokenId, liquidity, params.destToken, amountOut);
    }

    /// @inheritdoc ICoreModify
    /// @dev Without `compoundFees` the net earned fees go to the account before the swaps, so the swaps, `amountIn == 0`
    /// ones included, only ever see the principal (v4utils GHSA-v6cm). The principal is removed with no amount
    /// minimums (as v4utils); `mint.minLiquidity` is the flow's slippage bound, and `mint.deadline` serves both.
    function adjustRange(AdjustRangeParams calldata params)
        external
        onlyDelegateCall
        returns (uint256 newTokenId, uint128 liquidity)
    {
        (Target memory t, Position memory pos) = _target(params.nfpm, params.tokenId);
        Ledger memory l = _open(_candidates(params.swaps, t.token0, t.token1, t.token0));
        bool staked = _take(t.nfpm, t.tokenId, t.account);

        uint256[] memory fees = _collectFees(l, t, params.performanceFeeX64, 0);
        if (!params.compoundFees) {
            _pay(l, t.token0, t.account, fees[0]);
            _pay(l, t.token1, t.account, fees[1]);
        }
        if (pos.liquidity != 0) {
            _withdraw(l, t, pos.liquidity, 0, 0, params.mint.deadline, params.protocolFeeX64, params.gasFeeX64);
        }
        _swaps(l, params.swaps);
        Minted memory m = _mint(l, t, pos, params.mint);
        if (m.liquidity < params.mint.minLiquidity) revert LiquiditySlippage();

        _putBack(t.nfpm, m.tokenId, t.account, staked);
        _putBack(t.nfpm, t.tokenId, t.account, false);
        _close(l, t.account);

        emit AdjustRange(t.nfpm, t.tokenId, m.tokenId, m.liquidity, m.amount0, m.amount1);
        return (m.tokenId, m.liquidity);
    }

    // ---------------------------------------------------------------- steps

    /// @dev The account, adapter and position for `(nfpm, tokenId)`: `NotAutomation()` for another target under
    /// `executeAutomation`, `UnsupportedNfpm()` without an adapter.
    function _target(address nfpm, uint256 tokenId) private returns (Target memory t, Position memory pos) {
        t.nfpm = nfpm;
        t.tokenId = tokenId;
        t.account = _account(nfpm, tokenId);
        t.adapter = _adapter(nfpm);
        pos = abi.decode(_delegate(t.adapter, abi.encodeCall(IAdapter.position, (nfpm, tokenId))), (Position));
        t.token0 = pos.key.token0;
        t.token1 = pos.key.token1;
    }

    /// @dev Every token the flow can touch: both legs of every swap, the pool's tokens, and `extra` (the destToken).
    function _candidates(SwapParams[] calldata swaps, address token0, address token1, address extra)
        private
        pure
        returns (address[] memory c)
    {
        uint256 n = 2 * swaps.length;
        c = new address[](n + 3);
        for (uint256 i; i < swaps.length; i++) {
            c[2 * i] = swaps[i].tokenIn;
            c[2 * i + 1] = swaps[i].tokenOut;
        }
        c[n] = token0;
        c[n + 1] = token1;
        c[n + 2] = extra;
    }

    /// @dev Collects what the position owes (its earned fees, before any decrease) and takes PERFORMANCE_FEE, then
    /// GAS_FEE, on it. Returns the collected amounts net of both fees.
    function _collectFees(Ledger memory l, Target memory t, uint64 performanceFeeX64, uint64 gasFeeX64)
        private
        returns (uint256[] memory net)
    {
        net = _collect(l, t);
        uint256[] memory perf = _fees(l, t, net, performanceFeeX64, FeeType.PERFORMANCE_FEE);
        uint256[] memory gas = _fees(l, t, net, gasFeeX64, FeeType.GAS_FEE);
        net[0] -= perf[0] + gas[0];
        net[1] -= perf[1] + gas[1];
    }

    /// @dev Removes `liquidity` (the NFPM checks the minimums and the deadline), collects the principal, and takes
    /// PROTOCOL_FEE, then GAS_FEE, on it.
    function _withdraw(
        Ledger memory l,
        Target memory t,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        uint64 protocolFeeX64,
        uint64 gasFeeX64
    ) private {
        _delegate(
            t.adapter,
            abi.encodeCall(IAdapter.decrease, (t.nfpm, t.tokenId, liquidity, amount0Min, amount1Min, deadline))
        );
        uint256[] memory principal = _collect(l, t);
        _fees(l, t, principal, protocolFeeX64, FeeType.PROTOCOL_FEE);
        _fees(l, t, principal, gasFeeX64, FeeType.GAS_FEE);
    }

    /// @dev Collects everything the position owes and returns what the call received of (token0, token1).
    function _collect(Ledger memory l, Target memory t) private returns (uint256[] memory amounts) {
        uint256 before0 = _held(l, t.token0);
        uint256 before1 = _held(l, t.token1);
        _delegate(t.adapter, abi.encodeCall(IAdapter.collect, (t.nfpm, t.tokenId)));
        amounts = new uint256[](2);
        amounts[0] = _held(l, t.token0) - before0;
        amounts[1] = _held(l, t.token1) - before1;
    }

    /// @dev Takes `feeX64` of `amounts` of (token0, token1), labelled `feeType`, tagged with the position.
    function _fees(Ledger memory l, Target memory t, uint256[] memory amounts, uint64 feeX64, FeeType feeType)
        private
        returns (uint256[] memory taken)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = t.token0;
        tokens[1] = t.token1;
        taken = _takeFees(l, t.nfpm, t.tokenId, t.account, tokens, amounts, feeX64, feeType);
    }

    /// @dev Mints `m`'s range of the position's pool to the router from everything the call holds of its tokens.
    function _mint(Ledger memory l, Target memory t, Position memory pos, MintParams calldata m)
        private
        returns (Minted memory a)
    {
        bytes memory ret = _delegate(
            t.adapter,
            abi.encodeCall(
                IAdapter.mint,
                (
                    t.nfpm,
                    pos.key,
                    m.tickLower,
                    m.tickUpper,
                    _held(l, t.token0),
                    _held(l, t.token1),
                    address(this),
                    m.deadline
                )
            )
        );
        (a.tokenId, a.liquidity, a.amount0, a.amount1) = abi.decode(ret, (uint256, uint128, uint256, uint256));
    }
}
