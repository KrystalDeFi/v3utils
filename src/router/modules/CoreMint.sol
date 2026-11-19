// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {
    FeeType,
    InputTokenParams,
    PoolKey,
    Position,
    SwapParams,
    SwapAndMintParams,
    SwapAndIncreaseParams
} from "../RouterTypes.sol";
import {ICoreMint} from "../interfaces/ICoreMint.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {CoreBase} from "../base/CoreBase.sol";

/// @notice Zap-in flows: `swapAndMint` opens a position and `swapAndIncrease` adds to one, from any input tokens.
/// Runs only by DELEGATECALL from the router (`msg.sender` is the user, `address(this)` the router).
/// @dev Every flow reads top to bottom in the pipeline order of spec §6.6:
///   1. open the ledger, take the inputs (and, for increase, the position);
///   2. take PROTOCOL_FEE then GAS_FEE on the inputs;
///   3. run the swaps;
///   4. mint or increase with everything the call holds of the pool's tokens (`minLiquidity` checked);
///   5. put the position back (wallet, or the farm when staked);
///   6. sweep what the call holds to the account;
///   7. emit the flow event.
contract CoreMint is ICoreMint, CoreBase {
    /// @dev What a mint or increase did: the position, its added liquidity and what the NFPM took.
    struct Added {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    /// @inheritdoc ICoreMint
    /// @dev The fees are taken before the mint, so their `TakeFees` events carry `tokenId` 0: a v3-style NFPM keeps
    /// its next id private, so (unlike v4utils' `nextTokenId()`) the id is not known yet. The `SwapAndMint` event
    /// in the same transaction carries the minted id.
    /// With `stake`, the NFPM's farm checks the pool before anything moves (`FarmUnsupported()` if there is no farm)
    /// and stakes the minted NFT for the caller.
    function swapAndMint(SwapAndMintParams calldata params)
        external
        payable
        onlyDelegateCall
        returns (uint256 tokenId, uint128 liquidity)
    {
        address nfpm = params.nfpm;
        address adapter = _adapter(nfpm);
        address account = msg.sender;
        if (params.stake) _checkStakeable(nfpm, params.key);

        Ledger memory l = _open(_candidates(params.inputTokens, params.swaps, params.key.token0, params.key.token1));
        _takeInputs(params.inputTokens);
        _takeInputFees(l, nfpm, 0, account, params.inputTokens, params.protocolFeeX64, params.gasFeeX64);
        _swaps(l, params.swaps);
        Added memory a = _mint(l, adapter, params);
        if (a.liquidity < params.mint.minLiquidity) revert LiquiditySlippage();
        _putBack(nfpm, a.tokenId, account, params.stake);
        _close(l, account);

        emit SwapAndMint(nfpm, a.tokenId, a.liquidity, a.amount0, a.amount1);
        return (a.tokenId, a.liquidity);
    }

    /// @inheritdoc ICoreMint
    /// @dev The position is taken (`NotPositionHolder()` unless the account holds it, before anything moves) and
    /// put back where it came from.
    function swapAndIncrease(SwapAndIncreaseParams calldata params)
        external
        payable
        onlyDelegateCall
        returns (uint128 liquidity)
    {
        address nfpm = params.nfpm;
        address account = _account(nfpm, params.tokenId);
        PoolKey memory key = _positionKey(nfpm, params.tokenId);

        Ledger memory l = _open(_candidates(params.inputTokens, params.swaps, key.token0, key.token1));
        bool staked = _take(nfpm, params.tokenId, account);
        _takeInputs(params.inputTokens);
        _takeInputFees(l, nfpm, params.tokenId, account, params.inputTokens, params.protocolFeeX64, params.gasFeeX64);
        _swaps(l, params.swaps);
        Added memory a = _increase(l, params, key);
        if (a.liquidity < params.increase.minLiquidity) revert LiquiditySlippage();
        _putBack(nfpm, a.tokenId, account, staked);
        _close(l, account);

        emit SwapAndIncrease(nfpm, a.tokenId, a.liquidity, a.amount0, a.amount1);
        return a.liquidity;
    }

    // ---------------------------------------------------------------- steps

    /// @dev Every token the flow can touch: the inputs, both legs of every swap, and the pool's tokens.
    function _candidates(
        InputTokenParams[] calldata inputs,
        SwapParams[] calldata swaps,
        address token0,
        address token1
    ) private pure returns (address[] memory c) {
        uint256 n = inputs.length;
        c = new address[](n + 2 * swaps.length + 2);
        for (uint256 i; i < n; i++) {
            c[i] = inputs[i].token;
        }
        for (uint256 i; i < swaps.length; i++) {
            c[n + 2 * i] = swaps[i].tokenIn;
            c[n + 2 * i + 1] = swaps[i].tokenOut;
        }
        c[c.length - 2] = token0;
        c[c.length - 1] = token1;
    }

    /// @dev PROTOCOL_FEE, then GAS_FEE, each on the full input amounts. `_takeInputs` has already required the router
    /// be credited exactly these amounts, so they are what the call holds.
    function _takeInputFees(
        Ledger memory l,
        address nfpm,
        uint256 tokenId,
        address account,
        InputTokenParams[] calldata inputs,
        uint64 protocolFeeX64,
        uint64 gasFeeX64
    ) private {
        uint256 n = inputs.length;
        address[] memory tokens = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; i++) {
            tokens[i] = inputs[i].token;
            amounts[i] = inputs[i].amount;
        }
        _takeFees(l, nfpm, tokenId, account, tokens, amounts, protocolFeeX64, FeeType.PROTOCOL_FEE);
        _takeFees(l, nfpm, tokenId, account, tokens, amounts, gasFeeX64, FeeType.GAS_FEE);
    }

    /// @dev Mints to the router from everything the call holds of the pool's tokens.
    function _mint(Ledger memory l, address adapter, SwapAndMintParams calldata params)
        private
        returns (Added memory a)
    {
        bytes memory ret = _delegate(
            adapter,
            abi.encodeCall(
                IAdapter.mint,
                (
                    params.nfpm,
                    params.key,
                    params.mint.tickLower,
                    params.mint.tickUpper,
                    _held(l, params.key.token0),
                    _held(l, params.key.token1),
                    address(this),
                    params.mint.deadline
                )
            )
        );
        (a.tokenId, a.liquidity, a.amount0, a.amount1) = abi.decode(ret, (uint256, uint128, uint256, uint256));
    }

    /// @dev Adds everything the call holds of the pool's tokens to the router-held position.
    function _increase(Ledger memory l, SwapAndIncreaseParams calldata params, PoolKey memory key)
        private
        returns (Added memory a)
    {
        bytes memory ret = _delegate(
            _adapter(params.nfpm),
            abi.encodeCall(
                IAdapter.increase,
                (params.nfpm, params.tokenId, _held(l, key.token0), _held(l, key.token1), params.increase.deadline)
            )
        );
        a.tokenId = params.tokenId;
        (a.liquidity, a.amount0, a.amount1) = abi.decode(ret, (uint128, uint256, uint256));
    }

    /// @dev The pool key of `nfpm`'s position `tokenId`, read through its adapter (`UnsupportedNfpm()` if none).
    function _positionKey(address nfpm, uint256 tokenId) private returns (PoolKey memory) {
        return abi.decode(_delegate(_adapter(nfpm), abi.encodeCall(IAdapter.position, (nfpm, tokenId))), (Position)).key;
    }

    /// @dev Requires a farm for `nfpm` (`FarmUnsupported()` otherwise) that accepts `key`'s pool.
    function _checkStakeable(address nfpm, PoolKey calldata key) private {
        address farm = _farm(nfpm);
        if (farm == address(0)) revert FarmUnsupported();
        _delegate(farm, abi.encodeCall(IFarm.checkStakeable, (nfpm, key)));
    }
}
