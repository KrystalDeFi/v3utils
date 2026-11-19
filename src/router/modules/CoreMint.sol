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
///   7. emit the events: `TakeFees` (deferred to here on a mint, so it carries the minted tokenId), then the flow's.
contract CoreMint is ICoreMint, CoreBase {
    /// @dev What a mint or increase did: the position, its added liquidity and what the NFPM took.
    struct Added {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    /// @inheritdoc ICoreMint
    /// @dev The fees are transferred at step 2, before the mint; their `TakeFees` events are emitted after it, with
    /// the minted tokenId (as V3Utils does), since a v3-style NFPM keeps its next id private.
    /// With `stake`, the NFPM's farm checks the pool before anything moves (`FarmUnsupported()` if there is no farm;
    /// the farm's own error, e.g. no or dead gauge, otherwise) and stakes the minted NFT for the caller; its reward
    /// token is tracked in the ledger, so anything the farm pays the router reaches the caller.
    function swapAndMint(SwapAndMintParams calldata params)
        external
        payable
        onlyDelegateCall
        returns (uint256 tokenId, uint128 liquidity)
    {
        address nfpm = params.nfpm;
        address adapter = _adapter(nfpm);
        address account = msg.sender;
        address reward = params.key.token0;
        if (params.stake) reward = _rewardOf(_checkStakeable(nfpm, params.key), reward);

        Ledger memory l =
            _open(_candidates(params.inputTokens, params.swaps, params.key.token0, params.key.token1, reward));
        _takeInputs(params.inputTokens);
        TakeFeesEventData[2] memory fees =
            _chargeInputFees(l, params.inputTokens, params.protocolFeeX64, params.gasFeeX64);
        _swaps(l, params.swaps);
        Added memory a = _mint(l, adapter, params);
        if (a.liquidity < params.mint.minLiquidity) revert LiquiditySlippage();
        _putBack(nfpm, a.tokenId, account, params.stake);
        _close(l, account);

        _emitFees(nfpm, a.tokenId, account, fees[0]);
        _emitFees(nfpm, a.tokenId, account, fees[1]);
        emit SwapAndMint(nfpm, a.tokenId, a.liquidity, a.amount0, a.amount1);
        return (a.tokenId, a.liquidity);
    }

    /// @inheritdoc ICoreMint
    /// @dev `NotPositionHolder()` unless the account holds the position (in its wallet or staked), before anything
    /// moves. A staked position whose farm adds in place (`canIncreaseStaked`) stays where it is and the increase goes
    /// through `farm.increaseStaked`; any other position is taken (a farm that cannot unstake reverts
    /// `FarmUnsupported()`) and put back where it came from. For a staked position the farm's reward token is tracked,
    /// so emissions an unstake pays the router reach the account.
    function swapAndIncrease(SwapAndIncreaseParams calldata params)
        external
        payable
        onlyDelegateCall
        returns (uint128 liquidity)
    {
        address nfpm = params.nfpm;
        address account = _account(nfpm, params.tokenId);
        PoolKey memory key = _positionKey(nfpm, params.tokenId);
        address farm = _stakedIn(nfpm, params.tokenId, account);
        bool inPlace = farm != address(0) && _farmFlag(farm, abi.encodeCall(IFarm.canIncreaseStaked, ()));
        if (farm != address(0) && !inPlace && !_farmFlag(farm, abi.encodeCall(IFarm.canUnstake, ()))) {
            revert FarmUnsupported();
        }

        Ledger memory l =
            _open(_candidates(params.inputTokens, params.swaps, key.token0, key.token1, _rewardOf(farm, key.token0)));
        if (!inPlace) _bring(nfpm, params.tokenId, account, farm);
        _takeInputs(params.inputTokens);
        {
            TakeFeesEventData[2] memory fees =
                _chargeInputFees(l, params.inputTokens, params.protocolFeeX64, params.gasFeeX64);
            _emitFees(nfpm, params.tokenId, account, fees[0]);
            _emitFees(nfpm, params.tokenId, account, fees[1]);
        }
        _swaps(l, params.swaps);
        Added memory a = _increase(l, params, key, inPlace ? farm : address(0));
        if (a.liquidity < params.increase.minLiquidity) revert LiquiditySlippage();
        if (!inPlace) _putBack(nfpm, a.tokenId, account, farm != address(0));
        _close(l, account);

        emit SwapAndIncrease(nfpm, a.tokenId, a.liquidity, a.amount0, a.amount1);
        return a.liquidity;
    }

    // ---------------------------------------------------------------- steps

    /// @dev Every token the flow can touch: the inputs, both legs of every swap, the pool's tokens and `reward` (the
    /// farm's reward token, or a pool token when no farm is involved).
    function _candidates(
        InputTokenParams[] calldata inputs,
        SwapParams[] calldata swaps,
        address token0,
        address token1,
        address reward
    ) private pure returns (address[] memory c) {
        uint256 n = inputs.length;
        c = new address[](n + 2 * swaps.length + 3);
        for (uint256 i; i < n; i++) {
            c[i] = inputs[i].token;
        }
        for (uint256 i; i < swaps.length; i++) {
            c[n + 2 * i] = swaps[i].tokenIn;
            c[n + 2 * i + 1] = swaps[i].tokenOut;
        }
        c[c.length - 3] = token0;
        c[c.length - 2] = token1;
        c[c.length - 1] = reward;
    }

    /// @dev PROTOCOL_FEE, then GAS_FEE, each on the full input amounts; returns the two `TakeFees` payloads for the
    /// flow to emit once it knows the tokenId. `_takeInputs` has already required the router be credited exactly
    /// these amounts, so they are what the call holds.
    function _chargeInputFees(
        Ledger memory l,
        InputTokenParams[] calldata inputs,
        uint64 protocolFeeX64,
        uint64 gasFeeX64
    ) private returns (TakeFeesEventData[2] memory fees) {
        uint256 n = inputs.length;
        address[] memory tokens = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; i++) {
            tokens[i] = inputs[i].token;
            amounts[i] = inputs[i].amount;
        }
        fees[0] = _chargeFees(l, tokens, amounts, protocolFeeX64, FeeType.PROTOCOL_FEE);
        fees[1] = _chargeFees(l, tokens, amounts, gasFeeX64, FeeType.GAS_FEE);
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

    /// @dev Adds everything the call holds of the pool's tokens to the position: router-held through the adapter, or
    /// staked in place through `inPlaceFarm` when that is set.
    function _increase(Ledger memory l, SwapAndIncreaseParams calldata params, PoolKey memory key, address inPlaceFarm)
        private
        returns (Added memory a)
    {
        uint256 amount0 = _held(l, key.token0);
        uint256 amount1 = _held(l, key.token1);
        uint256 deadline = params.increase.deadline;
        bytes memory ret = inPlaceFarm == address(0)
            ? _delegate(
                _adapter(params.nfpm),
                abi.encodeCall(IAdapter.increase, (params.nfpm, params.tokenId, amount0, amount1, deadline))
            )
            : _delegate(
                inPlaceFarm,
                abi.encodeCall(IFarm.increaseStaked, (params.nfpm, params.tokenId, amount0, amount1, deadline))
            );
        a.tokenId = params.tokenId;
        (a.liquidity, a.amount0, a.amount1) = abi.decode(ret, (uint128, uint256, uint256));
    }

    /// @dev The pool key of `nfpm`'s position `tokenId`, read through its adapter (`UnsupportedNfpm()` if none).
    function _positionKey(address nfpm, uint256 tokenId) private returns (PoolKey memory) {
        return abi.decode(_delegate(_adapter(nfpm), abi.encodeCall(IAdapter.position, (nfpm, tokenId))), (Position)).key;
    }

    /// @dev Requires a farm for `nfpm` (`FarmUnsupported()` otherwise) that accepts `key`'s pool; returns it.
    function _checkStakeable(address nfpm, PoolKey calldata key) private returns (address farm) {
        farm = _farm(nfpm);
        if (farm == address(0)) revert FarmUnsupported();
        _delegate(farm, abi.encodeCall(IFarm.checkStakeable, (nfpm, key)));
    }
}
