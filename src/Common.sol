// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-periphery/interfaces/external/IWETH9.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "v3-core/libraries/FullMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./Nfpm.sol";
import "./CommonLib.sol";

abstract contract Common is AccessControl, Pausable {
    using Address for address;

    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // error types
    error SelfSend();
    error NotSupportedAction();
    error NotSupportedProtocol();
    error SameToken();
    error AmountError();
    error SlippageError();
    error TransferError();
    error EtherSendFailed();
    error TooMuchEtherSent();
    error NoEtherToken();
    error NativeDustNotAllowed();
    error InvalidNativeConfig();
    error TooMuchFee();
    error GetPositionFailed();
    error NoFees();
    error SwapFailed(bytes swapData, uint256 index);

    struct DeductFeesEventData {
        address token0;
        address token1;
        address token2;
        uint256 amount0;
        uint256 amount1;
        uint256 amount2;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 feeAmount2;
        uint64 feeX64;
        FeeType feeType;
    }

    // events
    event CompoundFees(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event DeductFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, DeductFeesEventData data
    );
    event ChangeRange(
        address indexed nfpm,
        uint256 indexed tokenId,
        uint256 newTokenId,
        uint256 newLiquidity,
        uint256 token0Added,
        uint256 token1Added
    );
    event WithdrawAndCollectAndSwap(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount);
    event SwapAndMint(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event SwapAndIncreaseLiquidity(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    EnumerableSet.AddressSet private _whitelistedNfpm;

    address public swapRouter;
    address public FEE_TAKER;
    address private _initializer;

    /// @notice How native value relates to the `WETH` token on this chain.
    /// WRAPPED:   `WETH` is a WETH9-style wrapper; native is wrapped/unwrapped 1:1 via deposit/withdraw.
    /// ENSHRINED: `WETH` is an ERC20 *view* of the native asset sharing one balance with it, with no
    ///            wrapper to call (e.g. Arc's USDC at 0x3600..., 6 decimals against 18-decimal native).
    enum NativeMode {
        WRAPPED,
        ENSHRINED
    }

    /// @notice The token that represents native value on this chain.
    address public WETH;
    /// @notice Which native model this deployment runs.
    /// @dev internal rather than public: a public getter is bytecode V3Utils cannot spare.
    NativeMode internal nativeMode;
    /// @notice Units of native currency per 1 smallest unit of `WETH`. Always 1 when WRAPPED; 1e12 on Arc.
    uint256 internal nativeScale;

    mapping(FeeType => uint64) private _maxFeeX64;

    constructor() {
        _maxFeeX64[FeeType.GAS_FEE] = 5534023222112865280; // 30%
        _maxFeeX64[FeeType.LIQUIDITY_FEE] = 5534023222112865280; // 30%
        _maxFeeX64[FeeType.PERFORMANCE_FEE] = 5902958103587057000; // 32% = 30% gas for auto compound + 2% protocol fee
        _initializer = tx.origin;
    }

    bool private _initialized = false;

    function initialize(
        address router,
        address admin,
        address feeTaker,
        address _weth,
        NativeMode _nativeMode,
        address[] calldata whitelistedNfpms
    ) public virtual {
        require(!_initialized);
        require(msg.sender == _initializer);

        if (_weth == address(0)) {
            revert InvalidNativeConfig();
        }
        // nativeScale is not a free parameter: it is fixed by how many decimals the ERC20 view has
        // against 18-decimal native. Deriving it from the token itself means it cannot be set wrong -
        // an unset value would otherwise be indistinguishable from a genuine 18-decimal enshrined
        // asset, and initialize is one-shot with no setter.
        if (_nativeMode == NativeMode.WRAPPED) {
            nativeScale = 1;
        } else {
            uint8 tokenDecimals = IERC20Metadata(_weth).decimals();
            if (tokenDecimals > 18) {
                revert InvalidNativeConfig();
            }
            nativeScale = 10 ** (18 - tokenDecimals);
        }

        _grantRole(ADMIN_ROLE, admin);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WITHDRAWER_ROLE, admin);
        swapRouter = router;
        FEE_TAKER = feeTaker;
        WETH = _weth;
        nativeMode = _nativeMode;
        for (uint256 i = 0; i < whitelistedNfpms.length; i++) {
            EnumerableSet.add(_whitelistedNfpm, whitelistedNfpms[i]);
        }

        _initialized = true;
    }

    enum FeeType {
        GAS_FEE,
        LIQUIDITY_FEE,
        PERFORMANCE_FEE
    }

    struct SwapAndMintParams {
        Nfpm.Protocol protocol;
        INonfungiblePositionManager nfpm;
        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint64 protocolFeeX64;
        uint64 gasFeeX64;
        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        uint256 amount2;
        address recipient; // recipient of tokens
        uint256 deadline;
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        IERC20 swapSourceToken;
        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        address poolDeployer; // only for algebra integral
    }

    /// @notice Params for swapAndIncreaseLiquidity() function
    struct SwapAndIncreaseLiquidityParams {
        Nfpm.Protocol protocol;
        INonfungiblePositionManager nfpm;
        uint256 tokenId;
        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        uint256 amount2;
        address recipient; // recipient of leftover tokens
        uint256 deadline;
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        IERC20 swapSourceToken;
        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        uint64 protocolFeeX64;
        uint64 gasFeeX64;
    }

    struct ReturnLeftoverTokensParams {
        address to;
        IERC20 token0;
        IERC20 token1;
        uint256 total0;
        uint256 total1;
        uint256 added0;
        uint256 added1;
        bool unwrap;
    }

    struct DecreaseAndCollectFeesParams {
        INonfungiblePositionManager nfpm;
        address userAddress;
        IERC20 token0;
        IERC20 token1;
        uint256 tokenId;
        uint128 liquidity;
        uint256 deadline;
        uint256 token0Min;
        uint256 token1Min;
        bool compoundFees;
    }

    struct DeductFeesParams {
        uint256 amount0;
        uint256 amount1;
        uint256 amount2;
        uint64 feeX64;
        FeeType feeType;
        // readonly params for emitting events
        address nfpm;
        uint256 tokenId;
        address userAddress;
        address token0;
        address token1;
        address token2;
    }

    struct Position {
        address token0;
        address token1;
        address deployer;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /**
     * @notice Withdraws erc20 token balance
     * @param tokens Addresses of erc20 tokens to withdraw
     * @param to Address to send to
     */
    function withdrawERC20(IERC20[] calldata tokens, address to) external onlyRole(WITHDRAWER_ROLE) {
        uint256 count = tokens.length;
        for (uint256 i = 0; i < count; ++i) {
            uint256 balance = tokens[i].balanceOf(address(this));
            if (balance > 0) {
                SafeERC20.safeTransfer(tokens[i], to, balance);
            }
        }
    }

    /**
     * @notice Withdraws native token balance
     * @param to Address to send to
     */
    function withdrawNative(address to) external onlyRole(WITHDRAWER_ROLE) {
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            // `call` rather than `transfer`: the 2300 gas stipend is not enough on chains that do extra
            // work on a native transfer (Arc enforces the USDC blocklist at runtime and emits EIP-7708
            // Transfer logs), nor for Safe/multisig recipients.
            (bool sent,) = to.call{value: nativeBalance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        }
    }

    /**
     * @notice Withdraws erc721 token balance
     * @param nfpm Addresses of erc721 tokens to withdraw
     * @param tokenId tokenId of erc721 tokens to withdraw
     * @param to Address to send to
     */
    function withdrawERC721(INonfungiblePositionManager nfpm, uint256 tokenId, address to)
        external
        onlyRole(WITHDRAWER_ROLE)
    {
        nfpm.transferFrom(address(this), to, tokenId);
    }

    // checks if required amounts are provided and are exact - takes in any provided native value
    // if less or more provided reverts
    // checks if required amounts are provided and are exact - takes in any provided native value
    // if less or more provided reverts
    function _prepareSwap(
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) internal {
        CommonLib.prepareSwap(_nativeConfig(), token0, token1, otherToken, amount0, amount1, amountOther);
    }

    struct SwapAndMintResult {
        uint256 tokenId;
        uint128 liquidity;
        uint256 added0;
        uint256 added1;
    }
    // swap and mint logic

    function _swapAndMint(SwapAndMintParams memory params, bool unwrap)
        internal
        returns (SwapAndMintResult memory result)
    {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(params, unwrap);

        // What the nfpm REPORTS it added is not what the add COST us. A token that charges a
        // surcharge on a transfer to the pool debits this contract for more than `added`, so
        // `total - added` overstates what is still here. Refunds are computed from the balance
        // that actually moved; otherwise we promise the recipient tokens we no longer hold.
        uint256 spent0;
        uint256 spent1;
        {
            uint256 balanceBefore0 = _selfBalance(params.token0);
            uint256 balanceBefore1 = _selfBalance(params.token1);

            (result.tokenId, result.liquidity, result.added0, result.added1) = Nfpm.mint(
                params.nfpm,
                params.protocol,
                Nfpm.MintParams(
                    address(params.token0),
                    address(params.token1),
                    params.fee,
                    params.tickSpacing,
                    params.tickLower,
                    params.tickUpper,
                    total0,
                    total1,
                    params.amountAddMin0,
                    params.amountAddMin1,
                    address(this), // is sent to real recipient afterwards
                    params.deadline,
                    0,
                    params.poolDeployer
                )
            );

            spent0 = balanceBefore0 - _selfBalance(params.token0);
            spent1 = balanceBefore1 - _selfBalance(params.token1);
        }

        params.nfpm.transferFrom(address(this), params.recipient, result.tokenId);
        emit SwapAndMint(address(params.nfpm), result.tokenId, result.liquidity, result.added0, result.added1);

        _returnLeftoverTokens(
            ReturnLeftoverTokensParams(
                params.recipient, params.token0, params.token1, total0, total1, spent0, spent1, unwrap
            )
        );
    }

    struct SwapAndIncreaseLiquidityResult {
        uint128 liquidity;
        uint256 added0;
        uint256 added1;
        uint256 feeAmount0;
        uint256 feeAmount1;
    }
    // swap and increase logic

    function _swapAndIncrease(SwapAndIncreaseLiquidityParams memory params, IERC20 token0, IERC20 token1, bool unwrap)
        internal
        returns (SwapAndIncreaseLiquidityResult memory result)
    {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(
            SwapAndMintParams(
                params.protocol,
                params.nfpm,
                token0,
                token1,
                0,
                0,
                0,
                0,
                0,
                0,
                params.amount0,
                params.amount1,
                params.amount2,
                params.recipient,
                params.deadline,
                params.swapSourceToken,
                params.amountIn0,
                params.amountOut0Min,
                params.swapData0,
                params.amountIn1,
                params.amountOut1Min,
                params.swapData1,
                params.amountAddMin0,
                params.amountAddMin1,
                address(0)
            ),
            unwrap
        );
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams =
            IUniV3NonfungiblePositionManager.IncreaseLiquidityParams(
                params.tokenId, total0, total1, params.amountAddMin0, params.amountAddMin1, params.deadline
            );

        // See _swapAndMint: measure what the add actually cost rather than trusting what the nfpm
        // reports it added, so a surcharge token cannot leave the refund short.
        uint256 spent0;
        uint256 spent1;
        {
            uint256 balanceBefore0 = _selfBalance(token0);
            uint256 balanceBefore1 = _selfBalance(token1);

            (result.liquidity, result.added0, result.added1) = params.nfpm.increaseLiquidity(increaseLiquidityParams);

            spent0 = balanceBefore0 - _selfBalance(token0);
            spent1 = balanceBefore1 - _selfBalance(token1);
        }

        emit SwapAndIncreaseLiquidity(
            address(params.nfpm), params.tokenId, result.liquidity, result.added0, result.added1
        );
        _returnLeftoverTokens(
            ReturnLeftoverTokensParams(params.recipient, token0, token1, total0, total1, spent0, spent1, unwrap)
        );
    }

    // swaps available tokens and prepares max amounts to be added to nfpm
    function _swapAndPrepareAmounts(SwapAndMintParams memory params, bool unwrap)
        internal
        returns (uint256 total0, uint256 total1)
    {
        if (params.swapSourceToken == params.token0) {
            if (params.amount0 < params.amountIn1) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) =
                _swap(params.token0, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1, 1);
            // amountInDelta is measured, so it covers any surcharge the swap drew on top of
            // amountIn - including one drawn from a balance donated to this contract. Clamp
            // rather than underflow; a few donated wei must not brick every zap through the pool.
            total0 = params.amount0 > amountInDelta ? params.amount0 - amountInDelta : 0;
            total1 = params.amount1 + amountOutDelta;
        } else if (params.swapSourceToken == params.token1) {
            if (params.amount1 < params.amountIn0) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) =
                _swap(params.token1, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0, 0);
            // see above
            total1 = params.amount1 > amountInDelta ? params.amount1 - amountInDelta : 0;
            total0 = params.amount0 + amountOutDelta;
        } else if (address(params.swapSourceToken) != address(0)) {
            // Bound the REQUESTED spend against amount2, the way the two branches above bound theirs
            // against amount0/amount1. The entry-point check does not cover this: it runs against
            // the PRE-fee amount2 and the fees are taken out afterwards, so without this a caller
            // could ask to swap more than remains theirs and have a donated balance of the source
            // token quietly make up the difference. Requested amounts are used deliberately - a
            // measured figure here would be donation-sensitive and hand back the DoS.
            if (params.amountIn0 + params.amountIn1 > params.amount2) {
                revert AmountError();
            }
            (uint256 amountInDelta0, uint256 amountOutDelta0) = _swap(
                params.swapSourceToken, params.token0, params.amountIn0, params.amountOut0Min, params.swapData0, 0
            );
            (uint256 amountInDelta1, uint256 amountOutDelta1) = _swap(
                params.swapSourceToken, params.token1, params.amountIn1, params.amountOut1Min, params.swapData1, 1
            );
            total0 = params.amount0 + amountOutDelta0;
            total1 = params.amount1 + amountOutDelta1;

            // Measured again, so the same reasoning as the two branches above applies: the deltas
            // include any surcharge the swaps drew on top of amountIn, and a donated balance is
            // fair game for that surcharge. Re-checking the MEASURED spend against amount2 here
            // would only hand an attacker a DoS - the entry points already bound
            // amountIn0 + amountIn1 by amount2 on the REQUESTED amounts, which is the invariant
            // that actually protects the caller. Clamp the remainder instead.
            uint256 spentSource = amountInDelta0 + amountInDelta1;
            uint256 leftOver = params.amount2 > spentSource ? params.amount2 - spentSource : 0;

            if (leftOver != 0) {
                _transferToken(params.recipient, params.swapSourceToken, leftOver, unwrap);
            }
        } else {
            total0 = params.amount0;
            total1 = params.amount1;
        }

        if (total0 != 0) {
            _safeResetAndApprove(params.token0, address(params.nfpm), total0);
        }
        if (total1 != 0) {
            _safeResetAndApprove(params.token1, address(params.nfpm), total1);
        }
    }

    // returns leftover token balances
    function _returnLeftoverTokens(ReturnLeftoverTokensParams memory params) internal {
        // `added` is measured, not reported, so it can exceed `total`: a surcharge token draws its
        // fee from whatever this contract holds, and anyone may donate a balance for it to draw on.
        // Nothing is owed back in that case - do not underflow on the griefer's dust.
        uint256 left0 = params.total0 > params.added0 ? params.total0 - params.added0 : 0;
        uint256 left1 = params.total1 > params.added1 ? params.total1 - params.added1 : 0;

        // return leftovers
        if (left0 != 0) {
            _transferToken(params.to, params.token0, left0, params.unwrap);
        }
        if (left1 != 0) {
            _transferToken(params.to, params.token1, left1, params.unwrap);
        }
    }

    // transfers token (or delivers it as native value when it is the token representing native)
    // callers may pass a zero token address here; that is safe because initialize rejects a zero
    // WETH, so the equality below cannot match on it
    function _transferToken(address to, IERC20 token, uint256 amount, bool unwrap) internal {
        IWETH9 weth = _getWeth9();
        if (address(weth) == address(token) && unwrap) {
            _sendNative(to, amount);
        } else {
            SafeERC20.safeTransfer(token, to, amount);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns token amounts deltas after swap
    //
    // NOTE for ENSHRINED native chains (e.g. Arc): the deltas below are measured with `balanceOf`, and
    // there the native balance and its ERC20 view are one and the same balance. Two consequences:
    //  1. native value arriving at `receive()` during the router call also moves
    //     `tokenOut.balanceOf(address(this))`, inflating amountOutDelta and weakening the amountOutMin
    //     check. This is the same donation griefing already reachable via a plain ERC20 transfer on
    //     every chain - the enshrined model just adds a second channel to it.
    //  2. that ERC20 view truncates below one unit. Merely holding dust is harmless - adding an exact
    //     multiple of nativeScale never shifts the truncated floor - but native moving in a
    //     non-multiple of nativeScale during the measured window makes a delta read off by one unit.
    //     An ERC20 transfer of this token always moves an exact multiple, so the only way in is a raw
    //     native transfer; `_receiveNative` rejecting a non-exact msg.value closes the path this
    //     contract controls. Do not relax that guard without revisiting this accounting.
    function _swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory swapData,
        uint256 index
    ) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        return CommonLib.swap(swapRouter, tokenIn, tokenOut, amountIn, amountOutMin, swapData, index);
    }

    // decreases liquidity from uniswap v3 position
    function _decreaseLiquidity(
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 deadline,
        uint256 token0Min,
        uint256 token1Min
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity != 0) {
            (amount0, amount1) = Nfpm.decreaseLiquidity(
                nfpm,
                IUniV3NonfungiblePositionManager.DecreaseLiquidityParams(
                    tokenId, liquidity, token0Min, token1Min, deadline
                )
            );
        }
    }

    function _decreaseLiquidityAndCollectFees(DecreaseAndCollectFeesParams memory params)
        internal
        returns (uint256 collectedAmount0, uint256 collectedAmount1, uint256 feeAmount0, uint256 feeAmount1)
    {
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            params.nfpm, params.tokenId, params.liquidity, params.deadline, params.token0Min, params.token1Min
        );

        // `decreaseLiquidity` only credits tokensOwed - `collect` is what actually moves tokens -
        // and a token that skims on a transfer OUT of the pool delivers less than the nfpm reports.
        // Measure what arrived, so fees, refunds and the final payout are all sized against tokens
        // this contract really holds rather than against the gross figure.
        uint256 balanceBefore0 = _selfBalance(params.token0);
        uint256 balanceBefore1 = _selfBalance(params.token1);

        Nfpm.collect(
            params.nfpm,
            IUniV3NonfungiblePositionManager.CollectParams(
                params.tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );

        collectedAmount0 = _selfBalance(params.token0) - balanceBefore0;
        collectedAmount1 = _selfBalance(params.token1) - balanceBefore1;

        // The principal from `decreaseLiquidity` is a gross figure too, so it can exceed what the
        // collect delivered. Clamp it rather than underflowing: the shortfall is borne by the
        // principal (it came out of the position), and only the excess above it counts as fees.
        uint256 principal0 = amount0 > collectedAmount0 ? collectedAmount0 : amount0;
        uint256 principal1 = amount1 > collectedAmount1 ? collectedAmount1 : amount1;
        feeAmount0 = collectedAmount0 - principal0;
        feeAmount1 = collectedAmount1 - principal1;

        // decreaseLiquidity already checked token0Min/token1Min, but against the GROSS amounts the
        // pool computed - and the skim happens afterwards, in collect. Left there, the caller's
        // floor is verified against a number they never receive: measuring the collect makes these
        // withdrawals succeed rather than revert, which would turn a visible failure into a silent
        // short fill. Re-check the floor against what actually landed.
        if (params.liquidity != 0 && (principal0 < params.token0Min || principal1 < params.token1Min)) {
            revert SlippageError();
        }
    }

    /// @dev Single call site for the balance reads the delta measurements rely on. Written inline,
    ///      each of the twelve measurement points emitted its own staticcall and ABI encoding -
    ///      1,075 bytes in total, which was enough on its own to push V3Utils past the EIP-170
    ///      limit. Keep the reads funnelled through here; do not inline them back.
    function _selfBalance(IERC20 token) private view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function _getWeth9() internal view returns (IWETH9 weth) {
        return IWETH9(WETH);
    }

    /// @dev Packs the native-asset model for CommonLib, which cannot read this contract's storage.
    function _nativeConfig() internal view returns (CommonLib.NativeConfig memory) {
        return CommonLib.NativeConfig(WETH, nativeScale, nativeMode == NativeMode.ENSHRINED);
    }

    /// @dev Sends `tokenAmount`, denominated in units of `WETH`, to `to` as native currency.
    /// Unlike `_receiveNative` this direction is always exact, so it cannot strand dust.
    function _sendNative(address to, uint256 tokenAmount) internal {
        CommonLib.sendNative(_nativeConfig(), to, tokenAmount);
    }

    function _getPosition(INonfungiblePositionManager nfpm, Nfpm.Protocol protocol, uint256 tokenId)
        internal
        returns (Position memory position)
    {
        (
            position.token0,
            position.token1,
            position.deployer,
            position.fee,
            position.tickSpacing,
            position.tickLower,
            position.tickUpper,
            position.liquidity
        ) = Nfpm.getPosition(nfpm, protocol, tokenId);
    }

    /**
     * @notice calculate fee
     * @param emitEvent: whether to emit event or not. Since swap and mint have not had token id yet.
     * we need to emit event latter
     */
    function _deductFees(DeductFeesParams memory params, bool emitEvent)
        internal
        returns (
            uint256 amount0Left,
            uint256 amount1Left,
            uint256 amount2Left,
            uint256 feeAmount0,
            uint256 feeAmount1,
            uint256 feeAmount2
        )
    {
        uint256 Q64 = 2 ** 64;
        if (params.feeX64 > _maxFeeX64[params.feeType]) {
            revert TooMuchFee();
        }

        // to save gas, we always need to check if fee exists before deductFees
        if (params.feeX64 == 0) {
            revert NoFees();
        }

        if (params.amount0 > 0) {
            feeAmount0 = FullMath.mulDiv(params.amount0, params.feeX64, Q64);
            amount0Left = params.amount0 - feeAmount0;
            if (feeAmount0 > 0) {
                SafeERC20.safeTransfer(IERC20(params.token0), FEE_TAKER, feeAmount0);
            }
        }
        if (params.amount1 > 0) {
            feeAmount1 = FullMath.mulDiv(params.amount1, params.feeX64, Q64);
            amount1Left = params.amount1 - feeAmount1;
            if (feeAmount1 > 0) {
                SafeERC20.safeTransfer(IERC20(params.token1), FEE_TAKER, feeAmount1);
            }
        }
        if (params.amount2 > 0) {
            feeAmount2 = FullMath.mulDiv(params.amount2, params.feeX64, Q64);
            amount2Left = params.amount2 - feeAmount2;
            if (feeAmount2 > 0) {
                SafeERC20.safeTransfer(IERC20(params.token2), FEE_TAKER, feeAmount2);
            }
        }

        if (emitEvent) {
            emit DeductFees(
                address(params.nfpm),
                params.tokenId,
                params.userAddress,
                DeductFeesEventData(
                    params.token0,
                    params.token1,
                    params.token2,
                    params.amount0,
                    params.amount1,
                    params.amount2,
                    feeAmount0,
                    feeAmount1,
                    feeAmount2,
                    params.feeX64,
                    params.feeType
                )
            );
        }
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setMaxFeeX64(FeeType feeType, uint64 feex64) external onlyRole(ADMIN_ROLE) {
        _maxFeeX64[feeType] = feex64;
    }

    function getMaxFeeX64(FeeType feeType) external view returns (uint64) {
        return _maxFeeX64[feeType];
    }

    /// @dev some tokens require allowance == 0 to approve new amount
    /// but some tokens does not allow approve amount = 0
    /// we try to set allowance = 0 before approve new amount. if it revert means that
    /// the token not allow to approve 0, which means the following line code will work properly
    function _safeResetAndApprove(IERC20 token, address _spender, uint256 _value) internal {
        /// @dev omitted approve(0) result because it might fail and does not break the flow
        address(token).call(abi.encodeWithSelector(token.approve.selector, _spender, 0));

        /// @dev value for approval after reset must greater than 0
        require(_value > 0);
        _safeApprove(token, _spender, _value);
    }

    function _safeApprove(IERC20 token, address _spender, uint256 _value) internal {
        CommonLib.safeApprove(token, _spender, _value);
    }

    function _isWhitelistedNfpm(address nfpm) internal view returns (bool) {
        return EnumerableSet.contains(_whitelistedNfpm, nfpm);
    }

    function setWhitelistNfpm(address[] calldata nfpms, bool isWhitelist) external onlyRole(ADMIN_ROLE) {
        uint256 length = nfpms.length;
        for (uint256 i = 0; i < length; i++) {
            if (isWhitelist) {
                EnumerableSet.add(_whitelistedNfpm, nfpms[i]);
            } else {
                EnumerableSet.remove(_whitelistedNfpm, nfpms[i]);
            }
        }
    }

    function setFeeTaker(address feeTaker) external onlyRole(ADMIN_ROLE) {
        FEE_TAKER = feeTaker;
    }
}
