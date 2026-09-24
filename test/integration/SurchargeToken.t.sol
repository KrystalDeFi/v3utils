// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../IntegrationTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Models the tax mechanics of ArgusTaxToken, live on Arc at
///         0xeCe5cA8bf9220718E5727754026757512212cb3c. Three branches, matching its `_update`:
///
///  - BUY  (`from == mainPool`): the pool sends `value`, the recipient is credited `value - tax`
///    and the rest is skimmed to the token. So a collect/decrease delivers LESS than the NFPM
///    reports.
///  - SELL (`to == mainPool`): the pool receives the FULL `value` - a v3 pool re-reads its own
///    balance and reverts if short - and the tax is taken as a SURCHARGE from whatever the payer
///    has left, clamped to that remainder. So a mint/increase costs the payer MORE than the NFPM
///    reports, and a payer holding exactly the amount being sold pays nothing.
///  - anything else: untaxed. Note this means a plain wallet -> contract pull is clean, which is
///    why v3utils' exact-credit guard in CommonLib._pull never fires on this token.
contract MockSurchargeToken is ERC20 {
    address public mainPool;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    mapping(address => bool) public isExempt;

    constructor(uint16 _buyTaxBps, uint16 _sellTaxBps) ERC20("Surcharge", "SUR") {
        buyTaxBps = _buyTaxBps;
        sellTaxBps = _sellTaxBps;
    }

    function setMainPool(address pool) external {
        mainPool = pool;
    }

    function setExempt(address account, bool value) external {
        isExempt[account] = value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 value) internal override {
        if (mainPool == address(0) || isExempt[from] || isExempt[to]) {
            super._transfer(from, to, value);
        } else if (from == mainPool) {
            uint256 tax = (value * buyTaxBps) / 10000;
            if (tax != 0) {
                super._transfer(from, address(this), tax);
                super._transfer(from, to, value - tax);
            } else {
                super._transfer(from, to, value);
            }
        } else if (to == mainPool) {
            super._transfer(from, to, value);
            uint256 surcharge = (value * sellTaxBps) / 10000;
            uint256 remaining = balanceOf(from);
            if (surcharge > remaining) {
                surcharge = remaining;
            }
            if (surcharge != 0) {
                super._transfer(from, address(this), surcharge);
            }
        } else {
            super._transfer(from, to, value);
        }
    }
}

interface IUniV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniV3PoolMin {
    function initialize(uint160 sqrtPriceX96) external;
    function token0() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IUniV3PoolSwap {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Mirrors SwapRouter02's payment model: the pool is paid by the PAYER, from inside the
///         swap callback, using the allowance the payer granted this router. That is what makes a
///         surcharge land on the payer (v3utils) rather than on the router.
contract MockV3SwapRouter {
    address public immutable pool;

    uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    constructor(address _pool) {
        pool = _pool;
    }

    function swapExactIn(address tokenIn, bool zeroForOne, uint256 amountIn, address recipient) external {
        IUniV3PoolSwap(pool).swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encode(msg.sender, tokenIn)
        );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == pool, "unexpected callback");
        (address payer, address tokenIn) = abi.decode(data, (address, address));
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        IERC20(tokenIn).transferFrom(payer, pool, owed);
    }
}

contract SurchargeTokenTest is IntegrationTestBase {
    IUniV3Factory constant FACTORY = IUniV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    uint24 constant FEE = 3000;
    int24 constant TICK_LOWER = -60;
    int24 constant TICK_UPPER = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    MockSurchargeToken sur;
    address pool;
    address user = address(0xBEEF);

    /// @dev Deliberately lopsided: WETH is the binding side, so a large SUR remainder is left over
    ///      for `_returnLeftoverTokens` to refund - which is exactly what the surcharge eats into.
    uint256 constant SUR_IN = 10 ether;
    uint256 constant WETH_IN = 1 ether;

    function setUp() external {
        _setupBase();

        sur = new MockSurchargeToken(100, 100); // 1% buy, 1% sell - same as ARGUS
        pool = FACTORY.createPool(address(sur), address(WETH_ERC20), FEE);
        IUniV3PoolMin(pool).initialize(SQRT_PRICE_1_1);
        sur.setMainPool(pool);

        sur.mint(user, SUR_IN);
        _writeTokenBalance(user, address(WETH_ERC20), WETH_IN);

        vm.startPrank(user);
        sur.approve(address(v3utils), type(uint256).max);
        WETH_ERC20.approve(address(v3utils), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Pool ordering is address-sorted, so which of (SUR, WETH) is token0 is not knowable
    ///      up front. Everything below is expressed in pool order.
    function _poolOrder()
        internal
        view
        returns (IERC20 token0, IERC20 token1, uint256 amount0, uint256 amount1)
    {
        if (IUniV3PoolMin(pool).token0() == address(sur)) {
            return (IERC20(address(sur)), WETH_ERC20, SUR_IN, WETH_IN);
        }
        return (WETH_ERC20, IERC20(address(sur)), WETH_IN, SUR_IN);
    }

    function _mintParams() internal view returns (Common.SwapAndMintParams memory) {
        return _mintParamsWith(SUR_IN, WETH_IN);
    }

    function _mintParamsWith(uint256 surAmount, uint256 wethAmount)
        internal
        view
        returns (Common.SwapAndMintParams memory)
    {
        bool surIsToken0 = IUniV3PoolMin(pool).token0() == address(sur);
        IERC20 token0 = surIsToken0 ? IERC20(address(sur)) : WETH_ERC20;
        IERC20 token1 = surIsToken0 ? WETH_ERC20 : IERC20(address(sur));
        uint256 amount0 = surIsToken0 ? surAmount : wethAmount;
        uint256 amount1 = surIsToken0 ? wethAmount : surAmount;
        return Common.SwapAndMintParams(
            Nfpm.Protocol.UNI_V3,
            NPM,
            token0,
            token1,
            FEE,
            0, // tickSpacing - unused for uni v3
            TICK_LOWER,
            TICK_UPPER,
            0, // protocolFeeX64 - no fees, to isolate the accounting
            0, // gasFeeX64
            amount0,
            amount1,
            0, // amount2
            user,
            block.timestamp,
            IERC20(address(0)), // no swap
            0,
            0,
            "",
            0,
            0,
            "",
            0, // amountAddMin0
            0, // amountAddMin1
            address(0) // poolDeployer
        );
    }

    /// The surcharge is taken from v3utils AFTER the NFPM has reported how much it consumed, so
    /// `total - added` overstates what v3utils still holds. Refunding the reported remainder then
    /// asks for more than the balance.
    function testSwapAndMintRefundsRemainderAfterSurcharge() public {
        // Build params first: _mintParams reads the pool, and that external call would otherwise
        // consume the prank.
        Common.SwapAndMintParams memory params = _mintParams();

        vm.prank(user);
        Common.SwapAndMintResult memory result = v3utils.swapAndMint(params);

        assertGt(result.liquidity, 0, "position should have been minted");

        // v3utils is a pass-through: it must never retain either token.
        assertEq(sur.balanceOf(address(v3utils)), 0, "v3utils retained SUR");
        assertEq(WETH_ERC20.balanceOf(address(v3utils)), 0, "v3utils retained WETH");

        // The user paid the surcharge out of their own remainder, so they get back everything
        // except what the pool took and what the token skimmed.
        uint256 surAdded = IUniV3PoolMin(pool).token0() == address(sur) ? result.added0 : result.added1;
        uint256 surcharge = (surAdded * 100) / 10000;
        assertEq(sur.balanceOf(user), SUR_IN - surAdded - surcharge, "user SUR refund is wrong");
    }

    /// Same accounting gap on the increase path: `_swapAndIncrease` refunds `total - added` while
    /// the surcharge has already been taken out of this contract's balance.
    function testSwapAndIncreaseRefundsRemainderAfterSurcharge() public {
        Common.SwapAndMintParams memory mintParams = _mintParams();
        vm.prank(user);
        Common.SwapAndMintResult memory minted = v3utils.swapAndMint(mintParams);

        // Fund a second, identical round and add it to the position just created.
        sur.mint(user, SUR_IN);
        _writeTokenBalance(user, address(WETH_ERC20), WETH_IN);
        uint256 surBefore = sur.balanceOf(user);

        (,, uint256 amount0, uint256 amount1) = _poolOrder();
        Common.SwapAndIncreaseLiquidityParams memory params = Common.SwapAndIncreaseLiquidityParams(
            Nfpm.Protocol.UNI_V3,
            NPM,
            minted.tokenId,
            amount0,
            amount1,
            0, // amount2
            user,
            block.timestamp,
            IERC20(address(0)), // no swap
            0,
            0,
            "",
            0,
            0,
            "",
            0, // amountAddMin0
            0, // amountAddMin1
            0, // protocolFeeX64
            0 // gasFeeX64
        );

        vm.prank(user);
        Common.SwapAndIncreaseLiquidityResult memory result = v3utils.swapAndIncreaseLiquidity(params);

        assertGt(result.liquidity, 0, "liquidity should have been added");
        assertEq(sur.balanceOf(address(v3utils)), 0, "v3utils retained SUR");
        assertEq(WETH_ERC20.balanceOf(address(v3utils)), 0, "v3utils retained WETH");

        uint256 surAdded = IUniV3PoolMin(pool).token0() == address(sur) ? result.added0 : result.added1;
        uint256 surcharge = (surAdded * 100) / 10000;
        assertEq(sur.balanceOf(user), surBefore - surAdded - surcharge, "user SUR refund is wrong");
    }

    /// The withdraw path is the mirror image: the pool pays out, the token skims 1% on the way,
    /// and the nfpm still reports the gross figure. Everything downstream - fees, leftovers, the
    /// final payout - is then sized against tokens this contract never received.
    function testWithdrawAndCollectDeliversWhatWasActuallyReceived() public {
        Common.SwapAndMintParams memory mintParams = _mintParams();
        vm.prank(user);
        Common.SwapAndMintResult memory minted = v3utils.swapAndMint(mintParams);

        uint256 surUserBefore = sur.balanceOf(user);
        uint256 surPoolBefore = sur.balanceOf(pool);

        V3Utils.Instructions memory instructions = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            Nfpm.Protocol.UNI_V3,
            address(0), // targetToken - no swaps
            0, // amountRemoveMin0
            0, // amountRemoveMin1
            0, // amountIn0
            0, // amountOut0Min
            "",
            0, // amountIn1
            0, // amountOut1Min
            "",
            TICK_LOWER,
            TICK_UPPER,
            false, // compoundFees
            minted.liquidity,
            0, // amountAddMin0
            0, // amountAddMin1
            block.timestamp,
            user,
            false, // unwrap
            0, // liquidityFeeX64
            0, // performanceFeeX64
            0 // gasFeeX64
        );

        vm.startPrank(user);
        NPM.approve(address(v3utils), minted.tokenId);
        v3utils.execute(NPM, minted.tokenId, instructions);
        vm.stopPrank();

        assertEq(sur.balanceOf(address(v3utils)), 0, "v3utils retained SUR");
        assertEq(WETH_ERC20.balanceOf(address(v3utils)), 0, "v3utils retained WETH");

        // Of everything the pool paid out, the token skimmed 1%; the user receives the rest.
        uint256 paidOut = surPoolBefore - sur.balanceOf(pool);
        assertGt(paidOut, 0, "pool should have paid out SUR");
        assertEq(sur.balanceOf(user) - surUserBefore, paidOut - paidOut / 100, "user SUR payout is wrong");
    }

    /// A griefer can donate dust straight to v3utils. The surcharge is then drawn from that dust
    /// instead of from the caller's remainder, so the measured spend exceeds the amount that was
    /// pulled in - and `total - spent` must not underflow on it.
    function testDonatedDustDoesNotBreakRefundMath() public {
        uint256 surAmount = 1 ether;
        uint256 wethAmount = 10 ether; // SUR is the binding side, so almost nothing is left over

        sur.mint(user, surAmount);
        _writeTokenBalance(user, address(WETH_ERC20), wethAmount);
        sur.mint(address(v3utils), 1e15); // the donation

        Common.SwapAndMintParams memory params = _mintParamsWith(surAmount, wethAmount);

        vm.prank(user);
        Common.SwapAndMintResult memory result = v3utils.swapAndMint(params);

        assertGt(result.liquidity, 0, "position should have been minted");
        // The donation is not the caller's, so it must not be swept out to them either.
        assertLe(sur.balanceOf(address(v3utils)), 1e15, "v3utils paid out donated dust");
    }

    /// @dev Deep full-range liquidity, so the zap's own swap barely moves the price.
    function _seedDeepLiquidity() internal {
        uint256 seed = 100 ether;
        sur.mint(user, seed);
        _writeTokenBalance(user, address(WETH_ERC20), seed);

        Common.SwapAndMintParams memory params = _mintParamsWith(seed, seed);
        params.tickLower = -887220;
        params.tickUpper = 887220;

        vm.prank(user);
        v3utils.swapAndMint(params);
    }

    /// The zap's swap leg is measured by balance delta, so the surcharge is inside `amountInDelta`.
    /// Donated dust lets that delta exceed the amount that was pulled in, and `amount - delta` must
    /// not underflow: a griefer could otherwise DoS every zap through this pool for a few wei.
    function testDonatedDustDoesNotBreakSwapLegMath() public {
        _seedDeepLiquidity();

        MockV3SwapRouter router = new MockV3SwapRouter(pool);

        // initialize() pins msg.sender against the tx.origin captured at construction, so deploy
        // and initialize have to run under one broadcast - same as _setupBase does.
        vm.startBroadcast(TEST_OWNER_ACCOUNT);
        V3Utils zapper = new V3Utils();
        zapper.initialize(
            address(router),
            TEST_OWNER_ACCOUNT,
            TEST_OWNER_ACCOUNT,
            address(WETH_ERC20),
            Common.NativeMode.WRAPPED,
            _getNfpms()
        );
        vm.stopBroadcast();

        bool surIsToken0 = IUniV3PoolMin(pool).token0() == address(sur);
        uint256 surAmount = 1 ether;
        uint256 amountIn = 0.995 ether; // leftover is under 1% of the swap, so the surcharge outruns it

        address zapUser = address(0xCAFE);
        sur.mint(zapUser, surAmount);
        sur.mint(address(zapper), 1e16); // the donation the surcharge will draw on

        vm.prank(zapUser);
        sur.approve(address(zapper), type(uint256).max);

        Common.SwapAndMintParams memory params = _mintParamsWith(0, 0);
        params.token0 = surIsToken0 ? IERC20(address(sur)) : WETH_ERC20;
        params.token1 = surIsToken0 ? WETH_ERC20 : IERC20(address(sur));
        params.amount0 = surIsToken0 ? surAmount : 0;
        params.amount1 = surIsToken0 ? 0 : surAmount;
        params.recipient = zapUser;
        params.swapSourceToken = IERC20(address(sur));
        // Swapping all the SUR away leaves only the other token, so the target range has to be a
        // one-sided range on the side that needs exactly that token.
        if (surIsToken0) {
            params.amountIn1 = amountIn; // token0 -> token1
            params.tickLower = -6000;
            params.tickUpper = -3000;
        } else {
            params.amountIn0 = amountIn; // token1 -> token0
            params.tickLower = 3000;
            params.tickUpper = 6000;
        }
        params.swapData0 = surIsToken0
            ? bytes("")
            : abi.encodeCall(MockV3SwapRouter.swapExactIn, (address(sur), false, amountIn, address(zapper)));
        params.swapData1 = surIsToken0
            ? abi.encodeCall(MockV3SwapRouter.swapExactIn, (address(sur), true, amountIn, address(zapper)))
            : bytes("");

        vm.prank(zapUser);
        Common.SwapAndMintResult memory result = zapper.swapAndMint(params);

        assertGt(result.liquidity, 0, "position should have been minted");
    }

    /// The third-token swap-source branch has the same griefing exposure the token0/token1 branches
    /// were fixed for, just wearing a different error. `amountInDelta` is measured, so donated dust
    /// of the source token inflates it past `amount2` and the zap reverts with AmountError. The
    /// entry points already bound amountIn0 + amountIn1 by amount2 on the REQUESTED amounts
    /// (V3Utils.sol:440 and :554), so re-checking the MEASURED spend here buys nothing and only
    /// hands an attacker a denial of service for the price of a few wei.
    function testDonatedDustDoesNotBreakThirdTokenSwapSource() public {
        _seedDeepLiquidity();

        // Target a real, unrelated pool so SUR is genuinely a third token here.
        uint24 targetFee = 500;
        address targetPool = FACTORY.getPool(address(WETH_ERC20), address(USDC), targetFee);
        require(targetPool != address(0), "target pool missing at this fork block");
        (, int24 spotTick,,,,,) = IUniV3PoolMin(targetPool).slot0();
        int24 tickLower = ((spotTick - 1000) / 10) * 10;
        int24 tickUpper = ((spotTick + 1000) / 10) * 10;

        MockV3SwapRouter router = new MockV3SwapRouter(pool);
        vm.startBroadcast(TEST_OWNER_ACCOUNT);
        V3Utils zapper = new V3Utils();
        zapper.initialize(
            address(router),
            TEST_OWNER_ACCOUNT,
            TEST_OWNER_ACCOUNT,
            address(WETH_ERC20),
            Common.NativeMode.WRAPPED,
            _getNfpms()
        );
        vm.stopBroadcast();

        address zapUser = address(0xD00D);
        uint256 surAmount = 1 ether;
        uint256 usdcAmount = 2000e6;

        sur.mint(zapUser, surAmount);
        _writeTokenBalance(zapUser, address(USDC), usdcAmount);
        sur.mint(address(zapper), 1e15); // the donation

        vm.startPrank(zapUser);
        sur.approve(address(zapper), type(uint256).max);
        USDC.approve(address(zapper), type(uint256).max);
        vm.stopPrank();

        // WETH sorts below USDC.e, so token0 is WETH - the side funded by swapping the third token.
        Common.SwapAndMintParams memory params = _mintParamsWith(0, 0);
        params.token0 = WETH_ERC20;
        params.token1 = USDC;
        params.fee = targetFee;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.amount0 = 0;
        params.amount1 = usdcAmount;
        params.amount2 = surAmount;
        params.recipient = zapUser;
        params.swapSourceToken = IERC20(address(sur));
        params.amountIn0 = surAmount; // all of the third token goes to the token0 leg
        params.swapData0 = abi.encodeCall(
            MockV3SwapRouter.swapExactIn,
            (address(sur), IUniV3PoolMin(pool).token0() == address(sur), surAmount, address(zapper))
        );

        vm.prank(zapUser);
        Common.SwapAndMintResult memory result = zapper.swapAndMint(params);

        assertGt(result.liquidity, 0, "position should have been minted");
    }

    function _withdraw(Common.SwapAndMintResult memory minted, uint256 removeMin0, uint256 removeMin1) internal {
        V3Utils.Instructions memory instructions = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            Nfpm.Protocol.UNI_V3,
            address(0), // targetToken - no swaps
            removeMin0,
            removeMin1,
            0,
            0,
            "",
            0,
            0,
            "",
            TICK_LOWER,
            TICK_UPPER,
            false, // compoundFees
            minted.liquidity,
            0,
            0,
            block.timestamp,
            user,
            false, // unwrap
            0,
            0,
            0
        );

        // Approval is a separate call on purpose: it must not sit between a vm.expectRevert and
        // the call being asserted on.
        vm.prank(user);
        v3utils.execute(NPM, minted.tokenId, instructions);
    }

    function _approveNft(uint256 tokenId) internal {
        vm.prank(user);
        NPM.approve(address(v3utils), tokenId);
    }

    /// `amountRemoveMin` is the caller's floor on what they get back. The nfpm checks it inside
    /// decreaseLiquidity against the GROSS amounts the pool computed, but the skim happens later,
    /// during collect - so the floor is verified against a number the caller never receives.
    /// Measuring the collect made these withdrawals succeed instead of reverting, which turned a
    /// visible failure into a silent short fill; the floor has to be re-checked against what landed.
    function testWithdrawEnforcesRemoveMinAgainstWhatArrives() public {
        Common.SwapAndMintParams memory mintParams = _mintParams();
        vm.prank(user);
        Common.SwapAndMintResult memory minted = v3utils.swapAndMint(mintParams);

        bool surIsToken0 = IUniV3PoolMin(pool).token0() == address(sur);

        // Dry run with no floor, to learn what the pool pays out and what actually lands.
        uint256 snap = vm.snapshotState();
        uint256 poolBefore = sur.balanceOf(pool);
        uint256 userBefore = sur.balanceOf(user);
        _approveNft(minted.tokenId);
        _withdraw(minted, 0, 0);
        uint256 gross = poolBefore - sur.balanceOf(pool);
        uint256 net = sur.balanceOf(user) - userBefore;
        vm.revertToState(snap);

        assertLt(net, gross, "token should have skimmed on the way out");

        // A floor above what lands, but still within what the nfpm reports as removed - so the
        // nfpm's own check passes and only ours can catch it.
        uint256 floor = net + 1;
        assertLe(floor, gross, "floor must sit between net and gross for this to test anything");

        _approveNft(minted.tokenId); // the snapshot revert undid it

        vm.expectRevert(Common.SlippageError.selector);
        _withdraw(minted, surIsToken0 ? floor : 0, surIsToken0 ? 0 : floor);
    }

    function _deployZapper(address router) internal returns (V3Utils zapper) {
        vm.startBroadcast(TEST_OWNER_ACCOUNT);
        zapper = new V3Utils();
        zapper.initialize(
            router,
            TEST_OWNER_ACCOUNT,
            TEST_OWNER_ACCOUNT,
            address(WETH_ERC20),
            Common.NativeMode.WRAPPED,
            _getNfpms()
        );
        vm.stopBroadcast();
    }

    /// The entry-point bound on `amountIn0 + amountIn1` is checked against the PRE-fee `amount2`,
    /// but fees are then deducted from it. With a third-token source and a nonzero fee, the
    /// requested swap inputs can exceed the post-fee amount that actually belongs to the caller -
    /// and any donated balance of the source token silently covers the difference, minting the
    /// caller value they never provided. The requested spend has to be re-bounded post-fee, the way
    /// the token0/token1 branches already do it.
    function testThirdTokenSourceCannotSpendBeyondPostFeeAmount() public {
        _seedDeepLiquidity();

        uint24 targetFee = 500;
        address targetPool = FACTORY.getPool(address(WETH_ERC20), address(USDC), targetFee);
        require(targetPool != address(0), "target pool missing at this fork block");
        (, int24 spotTick,,,,,) = IUniV3PoolMin(targetPool).slot0();

        MockV3SwapRouter router = new MockV3SwapRouter(pool);
        V3Utils zapper = _deployZapper(address(router));

        address zapUser = address(0xFEED);
        uint256 surAmount = 1 ether;
        uint256 usdcAmount = 2000e6;
        uint256 donation = 0.05 ether; // comfortably more than the fee, so the leak is reachable

        sur.mint(zapUser, surAmount);
        _writeTokenBalance(zapUser, address(USDC), usdcAmount);
        sur.mint(address(zapper), donation);

        vm.startPrank(zapUser);
        sur.approve(address(zapper), type(uint256).max);
        USDC.approve(address(zapper), type(uint256).max);
        vm.stopPrank();

        Common.SwapAndMintParams memory params = _mintParamsWith(0, 0);
        params.token0 = WETH_ERC20;
        params.token1 = USDC;
        params.fee = targetFee;
        params.tickLower = ((spotTick - 1000) / 10) * 10;
        params.tickUpper = ((spotTick + 1000) / 10) * 10;
        params.amount0 = 0;
        params.amount1 = usdcAmount;
        params.amount2 = surAmount;
        params.recipient = zapUser;
        params.swapSourceToken = IERC20(address(sur));
        params.protocolFeeX64 = 184467440737095520; // 1% of 2^64 - shrinks amount2 after the entry check
        // Ask to swap the whole PRE-fee amount, which is more than remains after the fee.
        params.amountIn0 = surAmount;
        params.swapData0 = abi.encodeCall(
            MockV3SwapRouter.swapExactIn,
            (address(sur), IUniV3PoolMin(pool).token0() == address(sur), surAmount, address(zapper))
        );

        vm.prank(zapUser);
        vm.expectRevert(Common.AmountError.selector);
        zapper.swapAndMint(params);
    }
}
