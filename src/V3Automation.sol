// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Common.sol";
import "./EIP712.sol";

contract V3Automation is Pausable, Common, EIP712 {
    event CancelOrder(address user, bytes order, bytes signature);

    // Auto-enter events (v6.0)
    event AutoEnterExecuted(
        bytes32 indexed orderHash,
        address indexed signer,
        uint256 indexed mintedTokenId,
        address nfpm,
        address sourceToken,
        uint256 sourceAmount,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event FollowUpExecuted(
        bytes32 indexed parentOrderHash, uint8 followUpIndex, uint256 indexed mintedTokenId, Action indexed action
    );

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    mapping(bytes32 => bool) _cancelledOrder;

    // Auto-enter storage (v6.0). Keyed by the EIP-712 typed-data digest of the parent
    // AUTO_ENTER order. Populated by executeAutoEnter, consumed by executeFollowUp.
    mapping(bytes32 => uint256) internal _mintedTokenIds;
    mapping(bytes32 => address) internal _mintedSigner;
    // One-shot guard: an AUTO_ENTER order digest may be executed at most once.
    // Without this a valid signature could be replayed to pull sourceAmount and
    // mint again until the signer's allowance/balance is exhausted.
    mapping(bytes32 => bool) internal _executedAutoEnter;

    constructor() EIP712("V3AutomationOrder", "6.0") {}

    function initialize(
        address _swapRouter,
        address admin,
        address feeTaker,
        address _weth,
        address[] calldata whitelistedNfpms
    ) public override {
        super.initialize(_swapRouter, admin, feeTaker, _weth, whitelistedNfpms);
        _grantRole(OPERATOR_ROLE, admin);
    }

    enum Action {
        AUTO_ADJUST,
        AUTO_EXIT,
        AUTO_COMPOUND,
        AUTO_HARVEST,
        AUTO_ENTER
    }

    struct ExecuteAutoEnterParams {
        Nfpm.Protocol protocol;
        INonfungiblePositionManager nfpm;
        address signer; // expected signer; cross-checked against recovered address
        address sourceToken;
        uint256 sourceAmount; // actual amount to pull this execution; <= order.action.sourceAmount
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        int24 tickSpacing;
        address poolDeployer;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        uint256 deadline;
        uint64 gasFeeX64;
        uint64 protocolFeeX64;
        bytes abiEncodedUserOrder;
        bytes orderSignature;
    }

    struct ExecuteFollowUpParams {
        bytes parentOrder;
        bytes parentSignature;
        uint8 followUpIndex;
        bytes followUpConfigEncoded;
        ExecuteParams execute;
    }

    struct ExecuteState {
        address token0;
        address token1;
        address deployer;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        // amount0 and amount1 in position (including fees)
        uint256 amount0;
        uint256 amount1;
        // feeAmount0 and feeAmount1 in position
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint128 liquidity;
    }

    struct ExecuteParams {
        Action action;
        Nfpm.Protocol protocol;
        INonfungiblePositionManager nfpm;
        uint256 tokenId;
        uint128 liquidity; // liquidity the calculations are based on
        // target token for swaps (if this is address(0) no swaps are executed)
        address targetToken;
        uint256 amountIn0;
        // if token0 needs to be swapped to targetToken - set values
        uint256 amountOut0Min;
        bytes swapData0;
        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if token1 needs to be swapped to targetToken - set values
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 deadline; // for uniswap operations - operator promises fair value
        uint64 gasFeeX64; // amount of tokens to be used as gas fee
        uint64 liquidityFeeX64; // amount of tokens to be used as liquidity fee
        uint64 performanceFeeX64; // amount of tokens to be used as performance fee
        // for mint new range
        int24 newTickLower;
        int24 newTickUpper;
        // compound fee to new position or not
        bool compoundFees;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // abi encoded order
        bytes abiEncodedUserOrder;
        bytes orderSignature;
    }

    function execute(ExecuteParams calldata params) public payable onlyRole(OPERATOR_ROLE) whenNotPaused {
        require(_isWhitelistedNfpm(address(params.nfpm)));
        address positionOwner = params.nfpm.ownerOf(params.tokenId);
        _validateOrder(params.abiEncodedUserOrder, params.orderSignature, positionOwner);
        _execute(params, positionOwner);
    }

    function _execute(ExecuteParams calldata params, address positionOwner) internal {
        params.nfpm.transferFrom(positionOwner, address(this), params.tokenId);

        ExecuteState memory state;

        Position memory position = _getPosition(params.nfpm, params.protocol, params.tokenId);

        state.token0 = position.token0;
        state.token1 = position.token1;
        state.fee = position.fee;
        state.tickSpacing = position.tickSpacing;
        state.tickLower = position.tickLower;
        state.tickUpper = position.tickUpper;
        state.liquidity = position.liquidity;
        state.deployer = position.deployer;

        require(state.liquidity != params.liquidity || params.liquidity != 0);

        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) = _decreaseLiquidityAndCollectFees(
            DecreaseAndCollectFeesParams(
                params.nfpm,
                positionOwner,
                IERC20(state.token0),
                IERC20(state.token1),
                params.tokenId,
                params.liquidity,
                params.deadline,
                params.amountRemoveMin0,
                params.amountRemoveMin1,
                params.compoundFees
            )
        );

        // deduct fees
        {
            uint256 gasFeeAmount0;
            uint256 gasFeeAmount1;
            if (params.gasFeeX64 > 0) {
                (,,, gasFeeAmount0, gasFeeAmount1,) = _deductFees(
                    DeductFeesParams(
                        state.amount0 - state.feeAmount0, // only liquidity tokens, not including fees
                        state.amount1 - state.feeAmount1,
                        0,
                        params.gasFeeX64,
                        FeeType.GAS_FEE,
                        address(params.nfpm),
                        params.tokenId,
                        positionOwner,
                        state.token0,
                        state.token1,
                        address(0)
                    ),
                    true
                );
            }
            uint256 liquidityFeeAmount0;
            uint256 liquidityFeeAmount1;
            if (params.liquidityFeeX64 > 0) {
                (,,, liquidityFeeAmount0, liquidityFeeAmount1,) = _deductFees(
                    DeductFeesParams(
                        state.amount0 - state.feeAmount0, // only liquidity tokens, not including fees
                        state.amount1 - state.feeAmount1,
                        0,
                        params.liquidityFeeX64,
                        FeeType.LIQUIDITY_FEE,
                        address(params.nfpm),
                        params.tokenId,
                        positionOwner,
                        state.token0,
                        state.token1,
                        address(0)
                    ),
                    true
                );
            }
            uint256 performanceFeeAmount0;
            uint256 performanceFeeAmount1;
            if (params.performanceFeeX64 > 0) {
                (,,, performanceFeeAmount0, performanceFeeAmount1,) = _deductFees(
                    DeductFeesParams(
                        state.feeAmount0, // only fees
                        state.feeAmount1, // only fees
                        0,
                        params.performanceFeeX64,
                        FeeType.PERFORMANCE_FEE,
                        address(params.nfpm),
                        params.tokenId,
                        positionOwner,
                        state.token0,
                        state.token1,
                        address(0)
                    ),
                    true
                );
            }

            state.amount0 = state.amount0 - gasFeeAmount0 - liquidityFeeAmount0;
            state.amount1 = state.amount1 - gasFeeAmount1 - liquidityFeeAmount1;

            // if compound fees, amount for next action is deducted from performance fees
            // otherwise, we exclude collected fees from the amounts
            if (params.compoundFees) {
                state.amount0 -= performanceFeeAmount0;
                state.amount1 -= performanceFeeAmount1;
            } else {
                state.amount0 -= state.feeAmount0;
                state.amount1 -= state.feeAmount1;
                _returnLeftoverTokens(
                    ReturnLeftoverTokensParams({
                        to: positionOwner,
                        token0: IERC20(state.token0),
                        token1: IERC20(state.token1),
                        total0: state.feeAmount0,
                        total1: state.feeAmount1,
                        added0: performanceFeeAmount0,
                        added1: performanceFeeAmount1,
                        unwrap: false
                    })
                );
            }
        }

        if (params.action == Action.AUTO_ADJUST) {
            require(state.tickLower != params.newTickLower || state.tickUpper != params.newTickUpper);
            SwapAndMintResult memory result;
            if (params.targetToken == state.token0) {
                result = _swapAndMint(
                    SwapAndMintParams(
                        params.protocol,
                        params.nfpm,
                        IERC20(state.token0),
                        IERC20(state.token1),
                        state.fee,
                        state.tickSpacing,
                        params.newTickLower,
                        params.newTickUpper,
                        0,
                        0,
                        state.amount0,
                        state.amount1,
                        0,
                        positionOwner,
                        params.deadline,
                        IERC20(state.token1),
                        params.amountIn1,
                        params.amountOut1Min,
                        params.swapData1,
                        0,
                        0,
                        bytes(""),
                        params.amountAddMin0,
                        params.amountAddMin1,
                        state.deployer
                    ),
                    false
                );
            } else if (params.targetToken == state.token1) {
                result = _swapAndMint(
                    SwapAndMintParams(
                        params.protocol,
                        params.nfpm,
                        IERC20(state.token0),
                        IERC20(state.token1),
                        state.fee,
                        state.tickSpacing,
                        params.newTickLower,
                        params.newTickUpper,
                        0,
                        0,
                        state.amount0,
                        state.amount1,
                        0,
                        positionOwner,
                        params.deadline,
                        IERC20(state.token0),
                        0,
                        0,
                        bytes(""),
                        params.amountIn0,
                        params.amountOut0Min,
                        params.swapData0,
                        params.amountAddMin0,
                        params.amountAddMin1,
                        state.deployer
                    ),
                    false
                );
            } else {
                // Rebalance without swap
                result = _swapAndMint(
                    SwapAndMintParams(
                        params.protocol,
                        params.nfpm,
                        IERC20(state.token0),
                        IERC20(state.token1),
                        state.fee,
                        state.tickSpacing,
                        params.newTickLower,
                        params.newTickUpper,
                        0,
                        0,
                        state.amount0,
                        state.amount1,
                        0,
                        positionOwner,
                        params.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        bytes(""),
                        0,
                        0,
                        bytes(""),
                        params.amountAddMin0,
                        params.amountAddMin1,
                        state.deployer
                    ),
                    false
                );
            }
            emit ChangeRange(
                address(params.nfpm), params.tokenId, result.tokenId, result.liquidity, result.added0, result.added1
            );
        } else if (params.action == Action.AUTO_EXIT || params.action == Action.AUTO_HARVEST) {
            uint256 targetAmount;
            if (state.token0 != params.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _swap(
                    IERC20(state.token0),
                    IERC20(params.targetToken),
                    state.amount0,
                    params.amountOut0Min,
                    params.swapData0,
                    0
                );
                if (amountInDelta < state.amount0) {
                    _transferToken(positionOwner, IERC20(state.token0), state.amount0 - amountInDelta, false);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += state.amount0;
            }
            if (state.token1 != params.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _swap(
                    IERC20(state.token1),
                    IERC20(params.targetToken),
                    state.amount1,
                    params.amountOut1Min,
                    params.swapData1,
                    1
                );
                if (amountInDelta < state.amount1) {
                    _transferToken(positionOwner, IERC20(state.token1), state.amount1 - amountInDelta, false);
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += state.amount1;
            }

            // send complete target amount
            if (targetAmount != 0 && params.targetToken != address(0)) {
                _transferToken(positionOwner, IERC20(params.targetToken), targetAmount, false);
            }
        } else if (params.action == Action.AUTO_COMPOUND) {
            if (params.targetToken == state.token0) {
                _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        params.protocol,
                        params.nfpm,
                        params.tokenId,
                        state.amount0,
                        state.amount1,
                        0,
                        positionOwner,
                        params.deadline,
                        IERC20(state.token1),
                        params.amountIn1,
                        params.amountOut1Min,
                        params.swapData1,
                        0,
                        0,
                        bytes(""),
                        params.amountAddMin0,
                        params.amountAddMin1,
                        0,
                        0
                    ),
                    IERC20(state.token0),
                    IERC20(state.token1),
                    false
                );
            } else if (params.targetToken == state.token1) {
                _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        params.protocol,
                        params.nfpm,
                        params.tokenId,
                        state.amount0,
                        state.amount1,
                        0,
                        positionOwner,
                        params.deadline,
                        IERC20(state.token0),
                        0,
                        0,
                        bytes(""),
                        params.amountIn0,
                        params.amountOut0Min,
                        params.swapData0,
                        params.amountAddMin0,
                        params.amountAddMin1,
                        0,
                        0
                    ),
                    IERC20(state.token0),
                    IERC20(state.token1),
                    false
                );
            } else {
                // compound without swap
                _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        params.protocol,
                        params.nfpm,
                        params.tokenId,
                        state.amount0,
                        state.amount1,
                        0,
                        positionOwner,
                        params.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        bytes(""),
                        0,
                        0,
                        bytes(""),
                        params.amountAddMin0,
                        params.amountAddMin1,
                        0,
                        0
                    ),
                    IERC20(state.token0),
                    IERC20(state.token1),
                    false
                );
            }
        } else {
            revert NotSupportedAction();
        }

        params.nfpm.transferFrom(address(this), positionOwner, params.tokenId);
    }

    function _validateOrder(bytes memory abiEncodedUserOrder, bytes memory orderSignature, address actor)
        internal
        view
    {
        address userAddress = _recover(abiEncodedUserOrder, orderSignature);
        require(userAddress == actor);
        require(!_cancelledOrder[keccak256(orderSignature)]);
    }

    function cancelOrder(bytes calldata abiEncodedUserOrder, bytes calldata orderSignature) external {
        _validateOrder(abiEncodedUserOrder, orderSignature, msg.sender);
        _cancelledOrder[keccak256(orderSignature)] = true;
        emit CancelOrder(msg.sender, abiEncodedUserOrder, orderSignature);
    }

    function isOrderCancelled(bytes calldata orderSignature) external view returns (bool) {
        return _cancelledOrder[keccak256(orderSignature)];
    }

    /// @notice Mints a new position when an auto-enter order's condition fires. Pulls source
    /// tokens from the signer, swaps + mints inside this contract, and transfers the NFT to
    /// the signer. Operator-gated.
    function executeAutoEnter(ExecuteAutoEnterParams calldata p)
        external
        payable
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        require(_isWhitelistedNfpm(address(p.nfpm)));

        // Recover and cross-check signer
        address recovered = _recover(p.abiEncodedUserOrder, p.orderSignature);
        require(recovered == p.signer);

        // Cancellation check (signature-based to match cancelOrder()'s key)
        require(!_cancelledOrder[keccak256(p.orderSignature)]);

        // One-shot replay guard. Key = EIP-712 typed-data digest of the parent
        // order; mark consumed before pulling any funds so a repeated call with
        // the same signature reverts here rather than minting again.
        bytes32 orderDigest = _hashTypedDataV4(StructHash._hash(p.abiEncodedUserOrder));
        require(!_executedAutoEnter[orderDigest]);
        _executedAutoEnter[orderDigest] = true;

        // Decode order + cross-check params against signed values
        StructHash.Order memory order = abi.decode(p.abiEncodedUserOrder, (StructHash.Order));
        require(keccak256(bytes(order.orderType)) == keccak256(bytes("ORDER_TYPE_AUTO_ENTER")));

        StructHash.AutoEnterConfig memory cfg = order.config.autoEnterConfig;
        StructHash.AutoEnterAction memory act = cfg.action;
        StructHash.PoolSelection memory ps = cfg.poolSelection;

        // v1: only static pool selection is permitted on-chain
        require(ps.mode == 0);
        // Bind execution to the signed order. The operator chooses swap legs, but
        // the pool/manager/protocol and target must match what the user signed —
        // a whitelisted-NFPM check alone would let an operator redirect the same
        // signature to a different manager with matching pool params.
        require(order.nfpmAddress == address(p.nfpm));
        require(ps.poolManagerOrNfpm == address(p.nfpm));
        require(ps.protocol == 0); // 0 == UNI_V3 in the signed cross-repo vocabulary; v4/pancake belong on V4UtilsRouter
        // Bind the mint branch too: _buildAutoEnterSwapMintParams forwards
        // p.protocol into _swapAndMint, which selects the Nfpm.mint variant.
        // The signed selection is UNI_V3, so the execution protocol must be too.
        require(p.protocol == Nfpm.Protocol.UNI_V3);
        require(ps.hooks == address(0)); // v3 pools have no hooks
        require(ps.filterHash == bytes32(0)); // static mode carries no dynamic filter
        require(act.sourceToken == p.sourceToken);
        require(p.sourceAmount > 0 && p.sourceAmount <= act.sourceAmount);
        require(p.tickLower == act.tickLower && p.tickUpper == act.tickUpper);
        require(p.fee == ps.fee && p.tickSpacing == ps.tickSpacing);
        require(p.gasFeeX64 == uint64(act.gasFeeX64));
        require(p.protocolFeeX64 == uint64(act.protocolFeeX64));
        require(uint64(block.timestamp) <= uint64(order.signatureTime) + act.deadlineWindowSeconds);

        // Pull source token from the signer (the user). For WETH source, msg.value
        // may be supplied and gets wrapped here so the user can pay with native ETH
        // and skip the prior wrap step. Any pre-existing WETH balance is also pulled
        // up to (p.sourceAmount - msg.value).
        {
            address weth = WETH;
            uint256 needed = p.sourceAmount;
            if (act.sourceToken == weth && msg.value > 0) {
                if (msg.value > needed) {
                    revert TooMuchEtherSent();
                }
                IWETH9(weth).deposit{value: msg.value}();
                needed -= msg.value;
            } else if (msg.value != 0) {
                // ETH attached but source isn't WETH — refuse rather than silently
                // leaving ETH stuck.
                revert NoEtherToken();
            }
            if (needed > 0) {
                uint256 balanceBefore = IERC20(act.sourceToken).balanceOf(address(this));
                SafeERC20.safeTransferFrom(IERC20(act.sourceToken), p.signer, address(this), needed);
                uint256 balanceAfter = IERC20(act.sourceToken).balanceOf(address(this));
                if (balanceAfter - balanceBefore != needed) {
                    revert TransferError(); // fee-on-transfer tokens not supported
                }
            }
        }

        // Deduct fees from the source amount. The remaining amount funds the swap+mint.
        uint256 effectiveAmount = _deductAutoEnterFees(p, ps, act);

        SwapAndMintResult memory result =
            _swapAndMint(_buildAutoEnterSwapMintParams(p, ps, effectiveAmount), false);

        // Persist for follow-up authorization (orderDigest computed above).
        _mintedTokenIds[orderDigest] = result.tokenId;
        _mintedSigner[orderDigest] = p.signer;

        emit AutoEnterExecuted(
            orderDigest,
            p.signer,
            result.tokenId,
            address(p.nfpm),
            p.sourceToken,
            p.sourceAmount,
            result.liquidity,
            result.added0,
            result.added1
        );
    }

    function _deductAutoEnterFees(
        ExecuteAutoEnterParams calldata p,
        StructHash.PoolSelection memory ps,
        StructHash.AutoEnterAction memory act
    ) internal returns (uint256 effectiveAmount) {
        effectiveAmount = p.sourceAmount;
        if (p.protocolFeeX64 > 0) {
            (,,,,, uint256 feeAmount2) = _deductFees(
                DeductFeesParams(
                    0,
                    0,
                    effectiveAmount,
                    p.protocolFeeX64,
                    FeeType.LIQUIDITY_FEE,
                    address(p.nfpm),
                    0,
                    p.signer,
                    ps.token0,
                    ps.token1,
                    act.sourceToken
                ),
                true
            );
            effectiveAmount -= feeAmount2;
        }
        if (p.gasFeeX64 > 0) {
            (,,,,, uint256 feeAmount2) = _deductFees(
                DeductFeesParams(
                    0,
                    0,
                    effectiveAmount,
                    p.gasFeeX64,
                    FeeType.GAS_FEE,
                    address(p.nfpm),
                    0,
                    p.signer,
                    ps.token0,
                    ps.token1,
                    act.sourceToken
                ),
                true
            );
            effectiveAmount -= feeAmount2;
        }
    }

    function _buildAutoEnterSwapMintParams(
        ExecuteAutoEnterParams calldata p,
        StructHash.PoolSelection memory ps,
        uint256 effectiveAmount
    ) internal pure returns (SwapAndMintParams memory) {
        // _swapAndPrepareAmounts treats amount2 as a *third* (non-pool) token to
        // zap in via both swap legs; it ignores amount2 when swapSourceToken is
        // token0/token1 and instead reads amount0/amount1. So when the source
        // token is one of the pool tokens the funding must sit in amount0/amount1,
        // not amount2 — otherwise the mint runs with zero input (or reverts).
        uint256 amount0;
        uint256 amount1;
        uint256 amount2;
        if (p.sourceToken == ps.token0) {
            amount0 = effectiveAmount;
        } else if (p.sourceToken == ps.token1) {
            amount1 = effectiveAmount;
        } else {
            amount2 = effectiveAmount;
        }
        return SwapAndMintParams({
            protocol: p.protocol,
            nfpm: p.nfpm,
            token0: IERC20(ps.token0),
            token1: IERC20(ps.token1),
            fee: p.fee,
            tickSpacing: p.tickSpacing,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            protocolFeeX64: 0, // already deducted above
            gasFeeX64: 0, // already deducted above
            amount0: amount0,
            amount1: amount1,
            amount2: amount2,
            recipient: p.signer,
            deadline: p.deadline,
            swapSourceToken: IERC20(p.sourceToken),
            amountIn0: p.amountIn0,
            amountOut0Min: p.amountOut0Min,
            swapData0: p.swapData0,
            amountIn1: p.amountIn1,
            amountOut1Min: p.amountOut1Min,
            swapData1: p.swapData1,
            amountAddMin0: p.amountAddMin0,
            amountAddMin1: p.amountAddMin1,
            poolDeployer: p.poolDeployer
        });
    }

    /// @notice Executes a pre-authorized follow-up automation against the NFT minted by a
    /// prior executeAutoEnter call. Authorization derives from the parent order's signature
    /// — no separate per-follow-up signature is required.
    function executeFollowUp(ExecuteFollowUpParams calldata p)
        external
        payable
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        require(_isWhitelistedNfpm(address(p.execute.nfpm)));

        bytes32 parentDigest = _hashTypedDataV4(StructHash._hash(p.parentOrder));
        require(!_cancelledOrder[keccak256(p.parentSignature)]);

        uint256 mintedTokenId = _mintedTokenIds[parentDigest];
        require(mintedTokenId != 0);
        require(p.execute.tokenId == mintedTokenId);

        address parentSigner = _recover(p.parentOrder, p.parentSignature);
        require(parentSigner == _mintedSigner[parentDigest]);

        StructHash.Order memory parent = abi.decode(p.parentOrder, (StructHash.Order));
        StructHash.FollowUpTemplate[] memory followUps = parent.config.autoEnterConfig.followUps;
        require(p.followUpIndex < followUps.length);
        StructHash.FollowUpTemplate memory tmpl = followUps[p.followUpIndex];

        require(keccak256(p.followUpConfigEncoded) == tmpl.templateConfigHash);
        require(_followUpActionMatch(tmpl.followUpType, p.execute.action));

        // NFT must still be at the parent signer for _execute's transferFrom to succeed.
        require(p.execute.nfpm.ownerOf(p.execute.tokenId) == parentSigner);

        _execute(p.execute, parentSigner);

        emit FollowUpExecuted(parentDigest, p.followUpIndex, mintedTokenId, p.execute.action);
    }

    function _followUpActionMatch(uint8 followUpType, Action action) internal pure returns (bool) {
        // Tagged switch — followUpType integers are stable cross-repo (see plan
        // §2.6's FollowUpType enum). Do not renumber without a version bump.
        if (followUpType == 1) {
            return action == Action.AUTO_COMPOUND;
        } else if (followUpType == 2) {
            return action == Action.AUTO_ADJUST;
        } else if (followUpType == 3) {
            return action == Action.AUTO_EXIT;
        } else if (followUpType == 4) {
            return action == Action.AUTO_HARVEST;
        }
        return false;
    }

    receive() external payable {}
}
