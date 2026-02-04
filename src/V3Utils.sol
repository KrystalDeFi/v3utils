// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./Common.sol";

/// @title v3Utils v1.0
/// @notice Utility functions for Uniswap V3 positions
/// This is a completely ownerless/stateless contract - does not hold any ERC20 or NFTs.
contract V3Utils is IERC721Receiver, Common {
    /// @notice Action which should be executed on provided NFT
    enum WhatToDo {
        CHANGE_RANGE,
        WITHDRAW_AND_COLLECT_AND_SWAP,
        COMPOUND_FEES
    }

    /// @notice Complete description of what should be executed on provided NFT - different fields are used depending on specified WhatToDo
    struct Instructions {
        // what action to perform on provided Uniswap v3 position
        WhatToDo whatToDo;
        // protocol to provide lp
        Nfpm.Protocol protocol;
        // target token for swaps (if this is address(0) no swaps are executed)
        address targetToken;
        // for removing liquidity slippage
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        // amountIn0 is used for swap and also as minAmount0 for decreased liquidity + collected fees
        uint256 amountIn0;
        // if token0 needs to be swapped to targetToken - set values
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data
        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if token1 needs to be swapped to targetToken - set values
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data
        // for creating new positions with CHANGE_RANGE
        int24 tickLower;
        int24 tickUpper;
        bool compoundFees;
        // remove liquidity amount for COMPOUND_FEES (in this case should be probably 0) / CHANGE_RANGE / WITHDRAW_AND_COLLECT_AND_SWAP
        uint128 liquidity;
        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // left over tokens will be sent to this address
        address recipient;
        // if tokenIn or tokenOut is WETH - unwrap
        bool unwrap;
        // protocol fees
        uint64 liquidityFeeX64;
        uint64 performanceFeeX64;
        uint64 gasFeeX64;
    }

    /// @notice Execute instruction by pulling approved NFT instead of direct safeTransferFrom call from owner
    /// @param tokenId Token to process
    /// @param instructions Instructions to execute
    function execute(INonfungiblePositionManager _nfpm, uint256 tokenId, Instructions calldata instructions)
        external
        whenNotPaused
    {
        // must be approved beforehand
        _nfpm.safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(instructions));
    }

    /// @notice ERC721 callback function. Called on safeTransferFrom and does manipulation as configured in encoded Instructions parameter.
    /// At the end the NFT (and any newly minted NFT) is returned to sender. The leftover tokens are sent to instructions.recipient.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        override
        whenNotPaused
        returns (bytes4)
    {
        // not allowed to send to itself
        if (from == address(this)) {
            revert SelfSend();
        }

        require(_isWhitelistedNfpm(msg.sender));
        INonfungiblePositionManager nfpm = INonfungiblePositionManager(msg.sender);

        Instructions memory instructions = abi.decode(data, (Instructions));

        Position memory position = _getPosition(nfpm, instructions.protocol, tokenId);

        uint256 amount0;
        uint256 amount1;
        {
            (uint256 feeAmount0, uint256 feeAmount1) = (0, 0);

            (amount0, amount1, feeAmount0, feeAmount1) = _decreaseLiquidityAndCollectFees(
                DecreaseAndCollectFeesParams(
                    nfpm,
                    instructions.recipient,
                    IERC20(position.token0),
                    IERC20(position.token1),
                    tokenId,
                    instructions.liquidity,
                    instructions.deadline,
                    instructions.amountRemoveMin0,
                    instructions.amountRemoveMin1,
                    instructions.compoundFees
                )
            );

            // deduct fees
            {
                DeductFeesParams memory _deductFeesParams = DeductFeesParams(
                    amount0 - feeAmount0, // only liquidity tokens, not including fees
                    amount1 - feeAmount1,
                    0,
                    instructions.gasFeeX64,
                    FeeType.GAS_FEE,
                    msg.sender,
                    tokenId,
                    instructions.recipient,
                    position.token0,
                    position.token1,
                    address(0)
                );
                uint256 gasFeeAmount0;
                uint256 gasFeeAmount1;
                if (instructions.gasFeeX64 > 0) {
                    (,,, gasFeeAmount0, gasFeeAmount1,) = _deductFees(_deductFeesParams, true);
                }

                _deductFeesParams.feeX64 = instructions.liquidityFeeX64;
                _deductFeesParams.feeType = FeeType.LIQUIDITY_FEE;
                uint256 liquidityFeeAmount0;
                uint256 liquidityFeeAmount1;
                if (instructions.liquidityFeeX64 > 0) {
                    (,,, liquidityFeeAmount0, liquidityFeeAmount1,) = _deductFees(_deductFeesParams, true);
                }

                _deductFeesParams.amount0 = feeAmount0;
                _deductFeesParams.amount1 = feeAmount1;
                _deductFeesParams.feeX64 = instructions.performanceFeeX64;
                _deductFeesParams.feeType = FeeType.PERFORMANCE_FEE;
                uint256 performanceFeeAmount0;
                uint256 performanceFeeAmount1;
                if (instructions.performanceFeeX64 > 0) {
                    (,,, performanceFeeAmount0, performanceFeeAmount1,) = _deductFees(_deductFeesParams, true);
                }

                amount0 -= (liquidityFeeAmount0 + gasFeeAmount0);
                amount1 -= (liquidityFeeAmount1 + gasFeeAmount1);

                // if compound fees, amount for next action is deducted from performance fees
                // otherwise, we exclude collected fees from the amounts
                if (instructions.compoundFees) {
                    amount0 -= performanceFeeAmount0;
                    amount1 -= performanceFeeAmount1;
                } else {
                    amount0 -= feeAmount0;
                    amount1 -= feeAmount1;
                    ReturnLeftoverTokensParams memory _returnLeftoverTokensParams;

                    _returnLeftoverTokensParams.to = instructions.recipient;
                    _returnLeftoverTokensParams.token0 = IERC20(position.token0);
                    _returnLeftoverTokensParams.token1 = IERC20(position.token1);
                    _returnLeftoverTokensParams.total0 = feeAmount0;
                    _returnLeftoverTokensParams.total1 = feeAmount1;
                    _returnLeftoverTokensParams.added0 = performanceFeeAmount0;
                    _returnLeftoverTokensParams.added1 = performanceFeeAmount1;
                    _returnLeftoverTokensParams.unwrap = instructions.unwrap;

                    _returnLeftoverTokens(_returnLeftoverTokensParams);
                }
            }
        }

        // check if enough tokens are available for swaps
        if (amount0 < instructions.amountIn0 || amount1 < instructions.amountIn1) {
            revert AmountError();
        }

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            SwapAndIncreaseLiquidityResult memory result;
            if (instructions.targetToken == position.token0) {
                result = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        instructions.protocol,
                        nfpm,
                        tokenId,
                        amount0,
                        amount1,
                        0,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(position.token1),
                        instructions.amountIn1,
                        instructions.amountOut1Min,
                        instructions.swapData1,
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        0,
                        0
                    ),
                    IERC20(position.token0),
                    IERC20(position.token1),
                    instructions.unwrap
                );
            } else if (instructions.targetToken == position.token1) {
                result = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        instructions.protocol,
                        nfpm,
                        tokenId,
                        amount0,
                        amount1,
                        0,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(position.token0),
                        0,
                        0,
                        "",
                        instructions.amountIn0,
                        instructions.amountOut0Min,
                        instructions.swapData0,
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        0,
                        0
                    ),
                    IERC20(position.token0),
                    IERC20(position.token1),
                    instructions.unwrap
                );
            } else {
                // no swap is done here
                result = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        instructions.protocol,
                        nfpm,
                        tokenId,
                        amount0,
                        amount1,
                        0,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        0,
                        0
                    ),
                    IERC20(position.token0),
                    IERC20(position.token1),
                    instructions.unwrap
                );
            }
            emit CompoundFees(address(nfpm), tokenId, result.liquidity, result.added0, result.added1);
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            SwapAndMintResult memory result;
            if (instructions.targetToken == position.token0) {
                result = _swapAndMint(
                    SwapAndMintParams(
                        instructions.protocol,
                        nfpm,
                        IERC20(position.token0),
                        IERC20(position.token1),
                        position.fee,
                        position.tickSpacing,
                        instructions.tickLower,
                        instructions.tickUpper,
                        0,
                        0,
                        amount0,
                        amount1,
                        0,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(position.token1),
                        instructions.amountIn1,
                        instructions.amountOut1Min,
                        instructions.swapData1,
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        position.deployer
                    ),
                    instructions.unwrap
                );
            } else if (instructions.targetToken == position.token1) {
                result = _swapAndMint(
                    SwapAndMintParams(
                        instructions.protocol,
                        nfpm,
                        IERC20(position.token0),
                        IERC20(position.token1),
                        position.fee,
                        position.tickSpacing,
                        instructions.tickLower,
                        instructions.tickUpper,
                        0,
                        0,
                        amount0,
                        amount1,
                        0,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(position.token0),
                        0,
                        0,
                        "",
                        instructions.amountIn0,
                        instructions.amountOut0Min,
                        instructions.swapData0,
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        position.deployer
                    ),
                    instructions.unwrap
                );
            } else {
                // no swap is done here
                result = _swapAndMint(
                    SwapAndMintParams(
                        instructions.protocol,
                        nfpm,
                        IERC20(position.token0),
                        IERC20(position.token1),
                        position.fee,
                        position.tickSpacing,
                        instructions.tickLower,
                        instructions.tickUpper,
                        0,
                        0,
                        amount0,
                        amount1,
                        0,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        position.deployer
                    ),
                    instructions.unwrap
                );
            }

            emit ChangeRange(msg.sender, tokenId, result.tokenId, result.liquidity, result.added0, result.added1);
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP) {
            uint256 targetAmount;
            if (position.token0 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _swap(
                    IERC20(position.token0),
                    IERC20(instructions.targetToken),
                    amount0,
                    instructions.amountOut0Min,
                    instructions.swapData0,
                    0
                );
                if (amountInDelta < amount0) {
                    _transferToken(
                        instructions.recipient, IERC20(position.token0), amount0 - amountInDelta, instructions.unwrap
                    );
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount0;
            }
            if (position.token1 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _swap(
                    IERC20(position.token1),
                    IERC20(instructions.targetToken),
                    amount1,
                    instructions.amountOut1Min,
                    instructions.swapData1,
                    1
                );
                if (amountInDelta < amount1) {
                    _transferToken(
                        instructions.recipient, IERC20(position.token1), amount1 - amountInDelta, instructions.unwrap
                    );
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount1;
            }

            // send complete target amount
            if (targetAmount != 0 && instructions.targetToken != address(0)) {
                _transferToken(
                    instructions.recipient, IERC20(instructions.targetToken), targetAmount, instructions.unwrap
                );
            }

            emit WithdrawAndCollectAndSwap(address(nfpm), tokenId, instructions.targetToken, targetAmount);
        } else {
            revert NotSupportedAction();
        }

        // return token to owner (this line guarantees that token is returned to originating owner)
        nfpm.transferFrom(address(this), from, tokenId);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to a newly minted position.
    /// Newly minted NFT and leftover tokens are returned to recipient
    function swapAndMint(SwapAndMintParams calldata params)
        external
        payable
        whenNotPaused
        returns (SwapAndMintResult memory result)
    {
        if (params.token0 == params.token1) {
            revert SameToken();
        }
        require(_isWhitelistedNfpm(address(params.nfpm)));

        // validate if amount2 is enough for action
        if (
            params.swapSourceToken != params.token0 && params.swapSourceToken != params.token1
                && params.amountIn0 + params.amountIn1 > params.amount2
        ) {
            revert AmountError();
        }
        _prepareSwap(
            params.token0, params.token1, params.swapSourceToken, params.amount0, params.amount1, params.amount2
        );
        SwapAndMintParams memory _params = params;

        DeductFeesEventData memory liquidityFeeEventData;
        DeductFeesEventData memory gasFeeEventData;

        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 feeAmount2;
        if (params.protocolFeeX64 > 0) {
            // since we do not have the tokenId here, we need to emit event later
            (,,, feeAmount0, feeAmount1, feeAmount2) = _deductFees(
                DeductFeesParams(
                    params.amount0,
                    params.amount1,
                    params.amount2,
                    params.protocolFeeX64,
                    FeeType.LIQUIDITY_FEE,
                    address(params.nfpm),
                    0,
                    params.recipient,
                    address(params.token0),
                    address(params.token1),
                    address(params.swapSourceToken)
                ),
                false
            );
            liquidityFeeEventData = DeductFeesEventData({
                token0: address(params.token0),
                token1: address(params.token1),
                token2: address(params.swapSourceToken),
                amount0: params.amount0,
                amount1: params.amount1,
                amount2: params.amount2,
                feeAmount0: feeAmount0,
                feeAmount1: feeAmount1,
                feeAmount2: feeAmount2,
                feeX64: params.protocolFeeX64,
                feeType: FeeType.LIQUIDITY_FEE
            });

            _params.amount0 -= feeAmount0;
            _params.amount1 -= feeAmount1;
            _params.amount2 -= feeAmount2;
        }
        if (params.gasFeeX64 > 0) {
            // since we do not have the tokenId here, we need to emit event later
            (,,, feeAmount0, feeAmount1, feeAmount2) = _deductFees(
                DeductFeesParams(
                    params.amount0,
                    params.amount1,
                    params.amount2,
                    params.gasFeeX64,
                    FeeType.GAS_FEE,
                    address(params.nfpm),
                    0,
                    params.recipient,
                    address(params.token0),
                    address(params.token1),
                    address(params.swapSourceToken)
                ),
                false
            );

            gasFeeEventData = DeductFeesEventData({
                token0: address(params.token0),
                token1: address(params.token1),
                token2: address(params.swapSourceToken),
                amount0: params.amount0,
                amount1: params.amount1,
                amount2: params.amount2,
                feeAmount0: feeAmount0,
                feeAmount1: feeAmount1,
                feeAmount2: feeAmount2,
                feeX64: params.gasFeeX64,
                feeType: FeeType.GAS_FEE
            });
            _params.amount0 -= feeAmount0;
            _params.amount1 -= feeAmount1;
            _params.amount2 -= feeAmount2;
        }

        result = _swapAndMint(_params, msg.value != 0);
        if (params.protocolFeeX64 > 0) {
            emit DeductFees(address(params.nfpm), result.tokenId, params.recipient, liquidityFeeEventData);
        }
        if (params.gasFeeX64 > 0) {
            emit DeductFees(address(params.nfpm), result.tokenId, params.recipient, gasFeeEventData);
        }
    }

    /// @notice Does 1 or 2 swaps from swapSourceToken to token0 and token1 and adds as much as possible liquidity to any existing position (no need to be position owner).
    // Sends any leftover tokens to recipient.
    function swapAndIncreaseLiquidity(SwapAndIncreaseLiquidityParams calldata params)
        external
        payable
        whenNotPaused
        returns (SwapAndIncreaseLiquidityResult memory result)
    {
        require(_isWhitelistedNfpm(address(params.nfpm)));
        address owner = params.nfpm.ownerOf(params.tokenId);
        require(owner == msg.sender);

        Position memory position = _getPosition(params.nfpm, params.protocol, params.tokenId);

        // validate if amount2 is enough for action
        if (
            address(params.swapSourceToken) != position.token0 && address(params.swapSourceToken) != position.token1
                && params.amountIn0 + params.amountIn1 > params.amount2
        ) {
            revert AmountError();
        }

        _prepareSwap(
            IERC20(position.token0),
            IERC20(position.token1),
            params.swapSourceToken,
            params.amount0,
            params.amount1,
            params.amount2
        );
        SwapAndIncreaseLiquidityParams memory _params = params;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 feeAmount2;
        if (params.protocolFeeX64 > 0) {
            (,,, feeAmount0, feeAmount1, feeAmount2) = _deductFees(
                DeductFeesParams(
                    params.amount0,
                    params.amount1,
                    params.amount2,
                    params.protocolFeeX64,
                    FeeType.LIQUIDITY_FEE,
                    address(params.nfpm),
                    params.tokenId,
                    params.recipient,
                    position.token0,
                    position.token1,
                    address(params.swapSourceToken)
                ),
                true
            );
            _params.amount0 -= feeAmount0;
            _params.amount1 -= feeAmount1;
            _params.amount2 -= feeAmount2;
        }
        if (params.gasFeeX64 > 0) {
            (,,, feeAmount0, feeAmount1, feeAmount2) = _deductFees(
                DeductFeesParams(
                    params.amount0,
                    params.amount1,
                    params.amount2,
                    params.gasFeeX64,
                    FeeType.GAS_FEE,
                    address(params.nfpm),
                    params.tokenId,
                    params.recipient,
                    position.token0,
                    position.token1,
                    address(params.swapSourceToken)
                ),
                true
            );
            _params.amount0 -= feeAmount0;
            _params.amount1 -= feeAmount1;
            _params.amount2 -= feeAmount2;
        }

        result = _swapAndIncrease(_params, IERC20(position.token0), IERC20(position.token1), msg.value != 0);
    }

    // needed for WETH unwrapping
    receive() external payable {}
}
