// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-periphery/interfaces/ISwapRouter.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {V3Utils} from "../../../src/V3Utils.sol";
import {Common} from "../../../src/Common.sol";
import {Nfpm, INonfungiblePositionManager as IKrystalNfpm} from "../../../src/Nfpm.sol";
import {CoreMint} from "../../../src/router/modules/CoreMint.sol";
import {ICoreMint} from "../../../src/router/interfaces/ICoreMint.sol";
import {UniV3Adapter} from "../../../src/router/adapters/UniV3Adapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {
    FeeType,
    PoolKey,
    MintParams,
    IncreaseParams,
    InputTokenParams,
    SwapParams,
    SwapAndMintParams,
    SwapAndIncreaseParams
} from "../../../src/router/RouterTypes.sol";
import {MockGauge} from "../mocks/CoreHarness.sol";
import {RouterTestBase} from "../RouterTestBase.sol";

/// @dev Farm stand-in for the `stake` flag (delegatecalled; config in immutables only): stakes into a MockGauge and
/// refuses pools when not `live`. Payable like `IFarm`, since it runs inside payable flows.
contract MockStakeFarm {
    error NoLiveFarm();

    MockGauge public immutable gauge;
    bool public immutable live;

    constructor(MockGauge gauge_, bool live_) {
        gauge = gauge_;
        live = live_;
    }

    function checkStakeable(address, PoolKey calldata) external payable {
        if (!live) revert NoLiveFarm();
    }

    function stake(address nfpm, uint256 tokenId, address account) external payable {
        IERC721(nfpm).approve(address(gauge), tokenId);
        gauge.deposit(nfpm, tokenId, account);
    }
}

/// @notice CoreMint on an Arbitrum fork: Uniswap v3 WETH/USDC 0.05%, real swaps through Uniswap's SwapRouter.
contract CoreMintTest is RouterTestBase {
    event SwapAndMint(
        address indexed nfpm, uint256 indexed tokenId, uint256 liquidity, uint256 amount0, uint256 amount1
    );
    event SwapAndIncrease(
        address indexed nfpm, uint256 indexed tokenId, uint256 liquidity, uint256 amount0, uint256 amount1
    );
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event TakeFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, IRouterErrors.TakeFeesEventData data
    );

    address internal constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address internal constant UNI_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant V3UTILS_DEPLOYED = 0xb4acbC082b5e7dEd571c98EE4257778a9D784B36;
    uint24 internal constant POOL_FEE = 500;

    // pool tick is -197975 at the pinned block: an in-range position, and one below the price (USDC only)
    int24 internal constant IN_LOWER = -198500;
    int24 internal constant IN_UPPER = -197500;
    int24 internal constant BELOW_LOWER = -199500;
    int24 internal constant BELOW_UPPER = -198500;

    uint64 internal constant PROTOCOL_FEE_X64 = 184467440737095516; // 1%
    uint64 internal constant GAS_FEE_X64 = 92233720368547758; // 0.5%

    // the standard two-input zap: WETH and USDC in, SWAP_USDC of the USDC swapped to WETH
    uint256 internal constant IN_WETH = 1 ether;
    uint256 internal constant IN_USDC = 5_000e6;
    uint256 internal constant SWAP_USDC = 1_000e6;

    address internal alice = makeAddr("cmAlice");
    address internal bob = makeAddr("cmBob");

    CoreMint internal coreMint;
    address internal adapter;

    function setUp() public {
        _forkArbitrum();
        _deployRouter(WETH);
        vm.prank(routerAdmin);
        router.setSwapRouter(UNI_SWAP_ROUTER);
        adapter = address(new UniV3Adapter());
        _register(NFPM, adapter, address(0));
        coreMint = new CoreMint();
        _registerModule(ICoreMint.swapAndMint.selector, address(coreMint));
        _registerModule(ICoreMint.swapAndIncrease.selector, address(coreMint));
    }

    // ------------------------------------------------------------------ helpers

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({token0: WETH, token1: USDC, fee: POOL_FEE, tickSpacing: 10, deployer: address(0)});
    }

    function _fee(uint256 amount, uint64 feeX64) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, feeX64, 2 ** 64);
    }

    /// @dev What is left of an input after the protocol and gas fees.
    function _net(uint256 amount) internal pure returns (uint256) {
        return amount - _fee(amount, PROTOCOL_FEE_X64) - _fee(amount, GAS_FEE_X64);
    }

    /// @dev Uniswap SwapRouter calldata that pays the router.
    function _swapData(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeCall(
            ISwapRouter.exactInputSingle,
            (ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: POOL_FEE,
                    recipient: address(router),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    function _step(address tokenIn, address tokenOut, uint256 amountIn, uint256 swapAmount)
        internal
        view
        returns (SwapParams memory)
    {
        return SwapParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: 0,
            swapData: _swapData(tokenIn, tokenOut, swapAmount)
        });
    }

    /// @dev A native<->WETH conversion step (no swapData).
    function _convert(address tokenIn, address tokenOut) internal pure returns (SwapParams memory) {
        return SwapParams({tokenIn: tokenIn, tokenOut: tokenOut, amountIn: 0, amountOutMin: 0, swapData: ""});
    }

    /// @dev What `amountIn` of `tokenIn` swaps to through the pool right now (dry run, state reverted).
    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).approve(UNI_SWAP_ROUTER, amountIn);
        out = ISwapRouter(UNI_SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.revertToState(snap);
    }

    function _mintParams(
        int24 lower,
        int24 upper,
        InputTokenParams[] memory inputs,
        SwapParams[] memory swaps,
        uint64 protocolFeeX64,
        uint64 gasFeeX64
    ) internal view returns (SwapAndMintParams memory p) {
        p.nfpm = NFPM;
        p.key = _key();
        p.mint = MintParams({tickLower: lower, tickUpper: upper, minLiquidity: 0, deadline: block.timestamp});
        p.inputTokens = inputs;
        p.swaps = swaps;
        p.protocolFeeX64 = protocolFeeX64;
        p.gasFeeX64 = gasFeeX64;
    }

    function _inputs2(address t0, uint256 a0, address t1, uint256 a1)
        internal
        pure
        returns (InputTokenParams[] memory inputs)
    {
        inputs = new InputTokenParams[](2);
        inputs[0] = InputTokenParams(t0, a0);
        inputs[1] = InputTokenParams(t1, a1);
    }

    function _inputs1(address t0, uint256 a0) internal pure returns (InputTokenParams[] memory inputs) {
        inputs = new InputTokenParams[](1);
        inputs[0] = InputTokenParams(t0, a0);
    }

    function _swaps1(SwapParams memory s0) internal pure returns (SwapParams[] memory swaps) {
        swaps = new SwapParams[](1);
        swaps[0] = s0;
    }

    function _mint(address who, SwapAndMintParams memory p, uint256 value)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        vm.prank(who);
        bytes memory ret = router.execute{value: value}(abi.encodeCall(ICoreMint.swapAndMint, (p)));
        (tokenId, liquidity) = abi.decode(ret, (uint256, uint128));
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20(token).balanceOf(who);
    }

    function _liquidityOf(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
    }

    /// @dev The router holds none of the flow's tokens and has no allowance left to the swap router or the NFPM.
    function _assertRouterClean(address[] memory tokens) internal view {
        for (uint256 i; i < tokens.length; i++) {
            assertEq(_bal(tokens[i], address(router)), 0, "router balance");
            if (tokens[i] != address(0)) {
                assertEq(IERC20(tokens[i]).allowance(address(router), UNI_SWAP_ROUTER), 0, "swap router allowance");
                assertEq(IERC20(tokens[i]).allowance(address(router), NFPM), 0, "nfpm allowance");
            }
        }
    }

    function _tokens3(address a, address b, address c) internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    /// @dev The `TakeFees` logs in `logs`, decoded.
    function _takeFeesLogs(Vm.Log[] memory logs)
        internal
        pure
        returns (IRouterErrors.TakeFeesEventData[] memory out, uint256[] memory tokenIds, uint256 n)
    {
        out = new IRouterErrors.TakeFeesEventData[](logs.length);
        tokenIds = new uint256[](logs.length);
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != TakeFees.selector) continue;
            tokenIds[n] = uint256(logs[i].topics[2]);
            out[n++] = abi.decode(logs[i].data, (IRouterErrors.TakeFeesEventData));
        }
    }

    /// @dev The first `Swap` log's amountOut.
    function _swapOut(Vm.Log[] memory logs) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == Swap.selector) {
                (, uint256 amountOut) = abi.decode(logs[i].data, (uint256, uint256));
                return amountOut;
            }
        }
        revert("no Swap log");
    }

    /// @dev amountOut of the first `Swap` log whose tokenIn is `tokenIn`.
    function _swapOutOf(Vm.Log[] memory logs, address tokenIn) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == Swap.selector && logs[i].topics[1] == bytes32(uint256(uint160(tokenIn)))) {
                (, uint256 amountOut) = abi.decode(logs[i].data, (uint256, uint256));
                return amountOut;
            }
        }
        revert("no Swap log");
    }

    /// @dev The SwapAndMint/SwapAndIncrease log's (amount0, amount1).
    function _used(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 used0, uint256 used1) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                (, used0, used1) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                return (used0, used1);
            }
        }
        revert("no flow log");
    }

    // ------------------------------------------------------------------ swapAndMint

    /// @dev Inputs WETH and USDC, one USDC->WETH swap: NFT to the user, router clean, fees match the math, one
    /// TakeFees per non-zero fee type, and the user's balances reconcile to the wei.
    function test_swapAndMint_twoInputsOneSwap() public {
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        SwapAndMintParams memory p = _mintParams(
            IN_LOWER,
            IN_UPPER,
            _inputs2(WETH, IN_WETH, USDC, IN_USDC),
            _swaps1(_step(USDC, WETH, SWAP_USDC, SWAP_USDC)),
            PROTOCOL_FEE_X64,
            GAS_FEE_X64
        );

        vm.recordLogs();
        (uint256 tokenId, uint128 liquidity) = _mint(alice, p, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(liquidity, 0, "liquidity");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT to the user");
        assertEq(_liquidityOf(tokenId), liquidity, "position liquidity");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));
        _assertInputFees(logs, 0);
        _assertLeftovers(logs, SwapAndMint.selector);
    }

    /// @dev Fees on the IN_WETH/IN_USDC inputs: fee-taker deltas equal the math, and exactly one TakeFees per
    /// non-zero fee type (protocol, then gas), tagged `tokenId`.
    function _assertInputFees(Vm.Log[] memory logs, uint256 tokenId) internal view {
        assertEq(_bal(WETH, routerFeeTaker), _inputFee(IN_WETH), "fee taker WETH");
        assertEq(_bal(USDC, routerFeeTaker), _inputFee(IN_USDC), "fee taker USDC");
        (IRouterErrors.TakeFeesEventData[] memory fees, uint256[] memory ids, uint256 n) = _takeFeesLogs(logs);
        assertEq(n, 2, "one TakeFees per non-zero fee type");
        assertEq(uint8(fees[0].feeType), uint8(FeeType.PROTOCOL_FEE));
        assertEq(fees[0].feeX64, PROTOCOL_FEE_X64);
        assertEq(fees[0].feeTokens[0].token, WETH);
        assertEq(fees[0].feeTokens[0].amount, _fee(IN_WETH, PROTOCOL_FEE_X64));
        assertEq(fees[0].feeTokens[1].token, USDC);
        assertEq(fees[0].feeTokens[1].amount, _fee(IN_USDC, PROTOCOL_FEE_X64));
        assertEq(uint8(fees[1].feeType), uint8(FeeType.GAS_FEE));
        assertEq(fees[1].feeX64, GAS_FEE_X64);
        assertEq(fees[1].feeTokens[0].amount, _fee(IN_WETH, GAS_FEE_X64));
        assertEq(fees[1].feeTokens[1].amount, _fee(IN_USDC, GAS_FEE_X64));
        assertEq(ids[0], tokenId, "TakeFees tokenId");
        assertEq(ids[1], tokenId, "TakeFees tokenId");
    }

    /// @dev The user got back exactly what fees, the SWAP_USDC swap and the position did not take.
    function _assertLeftovers(Vm.Log[] memory logs, bytes32 flowTopic) internal view {
        (uint256 used0, uint256 used1) = _used(logs, flowTopic);
        uint256 swapOut = _swapOut(logs);
        assertGt(swapOut, 0, "swap out");
        assertEq(_bal(WETH, alice), IN_WETH - _inputFee(IN_WETH) + swapOut - used0, "WETH leftover to the user");
        assertEq(_bal(USDC, alice), IN_USDC - _inputFee(IN_USDC) - SWAP_USDC - used1, "USDC leftover to the user");
    }

    function _inputFee(uint256 amount) internal pure returns (uint256) {
        return amount - _net(amount);
    }

    /// @dev The only input is ARB: ARB->WETH, then WETH->USDC with `amountIn == 0` (all the WETH the call holds).
    function test_swapAndMint_thirdTokenInput_multiHop() public {
        uint256 inArb = 2_000 ether;
        _dealAndApprove(ARB, alice, inArb);
        uint256 arbIn = _net(inArb);
        uint256 wethOut = _quote(ARB, WETH, arbIn);
        assertGt(wethOut, 0, "quote");

        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _step(ARB, WETH, arbIn, arbIn);
        swaps[1] = _step(WETH, USDC, 0, wethOut);
        SwapAndMintParams memory p =
            _mintParams(BELOW_LOWER, BELOW_UPPER, _inputs1(ARB, inArb), swaps, PROTOCOL_FEE_X64, GAS_FEE_X64);

        (uint256 tokenId, uint128 liquidity) = _mint(alice, p, 0);

        assertGt(liquidity, 0, "liquidity");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT to the user");
        _assertRouterClean(_tokens3(ARB, WETH, USDC));
        assertEq(_bal(ARB, routerFeeTaker), inArb - arbIn, "fees on the third token");
        assertEq(_bal(ARB, alice), 0, "all ARB spent");
        assertEq(_bal(WETH, alice), 0, "all WETH swapped on");
    }

    /// @dev Native in to a WETH/USDC position: native->WETH conversion, then a WETH->USDC swap, then the mint. The WETH
    /// the position does not take comes back to the native payer as native; the router's own WETH and native, seeded
    /// before the call, are untouched.
    function test_swapAndMint_nativeIn_unwrapLeftover() public {
        uint256 tokenId = _nativeMint(false);
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT to the user");
    }

    /// @dev The same native zap, staked: the farm runs inside a flow that carries `msg.value`.
    function test_swapAndMint_nativeIn_stake_viaFarm() public {
        MockGauge gauge = new MockGauge();
        _register(NFPM, adapter, address(new MockStakeFarm(gauge, true)));
        uint256 tokenId = _nativeMint(true);
        assertEq(gauge.stakedBy(NFPM, tokenId), alice, "staked for the caller");
    }

    function _nativeMint(bool stake) internal returns (uint256 tokenId) {
        uint256 inNative = 2 ether;
        uint256 swapWeth = 1 ether;
        vm.deal(alice, inNative);
        deal(WETH, address(router), 3 ether);
        vm.deal(address(router), 0.7 ether);

        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _convert(address(0), WETH);
        swaps[1] = _step(WETH, USDC, swapWeth, swapWeth);
        SwapAndMintParams memory p =
            _mintParams(IN_LOWER, IN_UPPER, _inputs1(address(0), inNative), swaps, PROTOCOL_FEE_X64, GAS_FEE_X64);
        p.stake = stake;

        vm.recordLogs();
        uint128 liquidity;
        (tokenId, liquidity) = _mint(alice, p, inNative);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(liquidity, 0, "liquidity");
        assertEq(_bal(WETH, address(router)), 3 ether, "router WETH unchanged");
        assertEq(address(router).balance, 0.7 ether, "router native unchanged");
        assertEq(_bal(USDC, address(router)), 0, "router USDC");
        assertEq(routerFeeTaker.balance, inNative - _net(inNative), "fees in native");
        (uint256 used0, uint256 used1) = _used(logs, SwapAndMint.selector);
        assertGt(_net(inNative) - swapWeth - used0, 0, "some WETH left over");
        assertEq(alice.balance, _net(inNative) - swapWeth - used0, "leftover WETH back as native");
        assertEq(_bal(WETH, alice), 0, "no WETH to a native payer");
        assertEq(_bal(USDC, alice), _swapOutOf(logs, WETH) - used1, "USDC leftover as USDC");
    }

    function test_swapAndMint_minLiquidity_reverts() public {
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        SwapAndMintParams memory p = _mintParams(
            IN_LOWER,
            IN_UPPER,
            _inputs2(WETH, IN_WETH, USDC, IN_USDC),
            _swaps1(_step(USDC, WETH, SWAP_USDC, SWAP_USDC)),
            PROTOCOL_FEE_X64,
            GAS_FEE_X64
        );

        uint256 snap = vm.snapshotState();
        (, uint128 liquidity) = _mint(alice, p, 0);
        vm.revertToState(snap);

        p.mint.minLiquidity = uint256(liquidity) + 1;
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.LiquiditySlippage.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndMint, (p)));

        p.mint.minLiquidity = liquidity;
        (, uint128 again) = _mint(alice, p, 0);
        assertEq(again, liquidity, "exact minLiquidity passes");
    }

    function test_swapAndMint_stake_noFarm_reverts() public {
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        SwapAndMintParams memory p =
            _mintParams(IN_LOWER, IN_UPPER, _inputs2(WETH, IN_WETH, USDC, IN_USDC), new SwapParams[](0), 0, 0);
        p.stake = true;
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.FarmUnsupported.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndMint, (p)));
    }

    /// @dev `stake == true` with a farm: the pool is checked before the mint, and the NFT is staked for the caller.
    function test_swapAndMint_stake_viaFarm() public {
        MockGauge gauge = new MockGauge();
        _register(NFPM, adapter, address(new MockStakeFarm(gauge, true)));
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        SwapAndMintParams memory p =
            _mintParams(IN_LOWER, IN_UPPER, _inputs2(WETH, IN_WETH, USDC, IN_USDC), new SwapParams[](0), 0, 0);
        p.stake = true;

        (uint256 tokenId,) = _mint(alice, p, 0);
        assertEq(IERC721(NFPM).ownerOf(tokenId), address(gauge), "staked");
        assertEq(gauge.stakedBy(NFPM, tokenId), alice, "staked for the caller");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));

        _register(NFPM, adapter, address(new MockStakeFarm(gauge, false)));
        vm.prank(alice);
        vm.expectRevert(MockStakeFarm.NoLiveFarm.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndMint, (p)));
    }

    function test_swapAndMint_unsupportedNfpm_reverts() public {
        SwapAndMintParams memory p =
            _mintParams(IN_LOWER, IN_UPPER, new InputTokenParams[](0), new SwapParams[](0), 0, 0);
        p.nfpm = makeAddr("notAnNfpm");
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.UnsupportedNfpm.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndMint, (p)));
    }

    function test_directCall_reverts() public {
        SwapAndMintParams memory p;
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        coreMint.swapAndMint(p);
    }

    // ------------------------------------------------------------------ swapAndIncrease

    /// @dev Alice's position, minted through the router (no fees, no swaps), with the router approved for her NFTs.
    function _aliceMints() internal returns (uint256 tokenId, uint128 liquidity) {
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        (tokenId, liquidity) = _mint(
            alice, _mintParams(IN_LOWER, IN_UPPER, _inputs2(WETH, IN_WETH, USDC, IN_USDC), new SwapParams[](0), 0, 0), 0
        );
        vm.prank(alice);
        IERC721(NFPM).setApprovalForAll(address(router), true);
    }

    function _increaseParams(uint256 tokenId, address who) internal returns (SwapAndIncreaseParams memory p) {
        _dealAndApprove(WETH, who, IN_WETH);
        _dealAndApprove(USDC, who, IN_USDC);
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.increase = IncreaseParams({minLiquidity: 0, deadline: block.timestamp});
        p.inputTokens = _inputs2(WETH, IN_WETH, USDC, IN_USDC);
        p.swaps = _swaps1(_step(USDC, WETH, SWAP_USDC, SWAP_USDC));
        p.protocolFeeX64 = PROTOCOL_FEE_X64;
        p.gasFeeX64 = GAS_FEE_X64;
    }

    /// @dev Review Focus 2: bob, though the router holds alice's NFPM approval, cannot act on her position; nothing
    /// moves.
    function test_notHolder_wallet_reverts() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, bob);

        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));

        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT stays with alice");
        assertEq(_liquidityOf(tokenId), liquidity, "position untouched");
        assertEq(_bal(WETH, bob), IN_WETH, "bob's WETH untouched");
        assertEq(_bal(USDC, bob), IN_USDC, "bob's USDC untouched");
    }

    /// @dev The holder succeeds: liquidity added, NFT back, fees on the inputs tagged with the tokenId, router clean.
    function test_swapAndIncrease_ownerOnly() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, alice);

        vm.recordLogs();
        vm.prank(alice);
        bytes memory ret = router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint128 added = abi.decode(ret, (uint128));

        assertGt(added, 0, "liquidity added");
        assertEq(_liquidityOf(tokenId), liquidity + added, "position liquidity");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back to alice");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));

        _assertInputFees(logs, tokenId);
        _assertLeftovers(logs, SwapAndIncrease.selector);
    }

    /// @dev Native in to an existing position: the position read, take, increase and put back all run inside a flow
    /// that carries `msg.value`. The WETH the position does not take comes back to the native payer as native.
    function test_swapAndIncrease_nativeIn() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        vm.deal(alice, IN_WETH);
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, alice);
        p.inputTokens[0] = InputTokenParams(address(0), IN_WETH);
        p.swaps = new SwapParams[](2);
        p.swaps[0] = _convert(address(0), WETH);
        p.swaps[1] = _step(USDC, WETH, SWAP_USDC, SWAP_USDC);
        uint256 wethBefore = _bal(WETH, alice);

        vm.recordLogs();
        vm.prank(alice);
        uint128 added =
            abi.decode(router.execute{value: IN_WETH}(abi.encodeCall(ICoreMint.swapAndIncrease, (p))), (uint128));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(added, 0, "liquidity added");
        assertEq(_liquidityOf(tokenId), liquidity + added, "position liquidity");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back to alice");
        _assertRouterClean(_tokens3(address(0), WETH, USDC));
        assertEq(routerFeeTaker.balance, _inputFee(IN_WETH), "native fees");
        (uint256 used0,) = _used(logs, SwapAndIncrease.selector);
        assertEq(alice.balance, _net(IN_WETH) + _swapOutOf(logs, USDC) - used0, "WETH leftover back as native");
        assertEq(_bal(WETH, alice), wethBefore, "no WETH to a native payer");
    }

    function test_swapAndIncrease_minLiquidity_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, alice);
        p.increase.minLiquidity = type(uint128).max;
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.LiquiditySlippage.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
    }

    // ------------------------------------------------------------------ Review Focus 1

    /// @dev Review Focus 1 end-to-end: WETH, USDC, ARB and native already in the router are neither swept to the
    /// caller nor spent by an `amountIn == 0` swap.
    function test_preexistingBalances_untouched() public {
        deal(WETH, address(router), 3 ether);
        deal(USDC, address(router), 7_000e6);
        deal(ARB, address(router), 500 ether);
        vm.deal(address(router), 0.7 ether);

        uint256 inArb = 1_000 ether;
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        _dealAndApprove(ARB, alice, inArb);
        InputTokenParams[] memory inputs = new InputTokenParams[](3);
        inputs[0] = InputTokenParams(WETH, IN_WETH);
        inputs[1] = InputTokenParams(USDC, IN_USDC);
        inputs[2] = InputTokenParams(ARB, inArb);
        uint256 arbIn = _net(inArb);
        SwapAndMintParams memory p =
            _mintParams(IN_LOWER, IN_UPPER, inputs, _swaps1(_step(ARB, WETH, 0, arbIn)), PROTOCOL_FEE_X64, GAS_FEE_X64);

        (uint256 tokenId,) = _mint(alice, p, 0);

        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT to the user");
        assertEq(_bal(WETH, address(router)), 3 ether, "router WETH unchanged");
        assertEq(_bal(USDC, address(router)), 7_000e6, "router USDC unchanged");
        assertEq(_bal(ARB, address(router)), 500 ether, "router ARB unchanged");
        assertEq(address(router).balance, 0.7 ether, "router native unchanged");
        assertEq(_bal(ARB, alice), 0, "only the call's ARB was swapped");
    }

    // ------------------------------------------------------------------ parity

    /// @dev Same inputs, fees and swap through V3Utils (deployed from this repo's source: the production address
    /// has no code at the pinned block) and through the router, from the same state: equal fees, liquidity within
    /// 0.01%.
    function test_parity_swapAndMint_vsV3Utils() public {
        assertEq(V3UTILS_DEPLOYED.code.length, 0, "deployed V3Utils absent at the pinned block");
        uint256 snap = vm.snapshotState();

        (uint128 legacyLiquidity, uint256 legacyFeeWeth, uint256 legacyFeeUsdc) = _legacyMint();
        vm.revertToState(snap);

        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        (, uint128 liquidity) = _mint(
            alice,
            _mintParams(
                IN_LOWER,
                IN_UPPER,
                _inputs2(WETH, IN_WETH, USDC, IN_USDC),
                _swaps1(_step(USDC, WETH, SWAP_USDC, SWAP_USDC)),
                PROTOCOL_FEE_X64,
                GAS_FEE_X64
            ),
            0
        );

        assertEq(_bal(WETH, routerFeeTaker), legacyFeeWeth, "WETH fee parity");
        assertEq(_bal(USDC, routerFeeTaker), legacyFeeUsdc, "USDC fee parity");
        assertApproxEqRel(liquidity, legacyLiquidity, 1e14, "liquidity within 0.01%");
    }

    function _legacyMint() internal returns (uint128 liquidity, uint256 feeWeth, uint256 feeUsdc) {
        address owner = makeAddr("v3uOwner");
        address legacyFeeTaker = makeAddr("v3uFeeTaker");
        address[] memory nfpms = new address[](1);
        nfpms[0] = NFPM;
        vm.startPrank(owner, owner);
        V3Utils v3utils = new V3Utils();
        v3utils.initialize(UNI_SWAP_ROUTER, owner, legacyFeeTaker, WETH, Common.NativeMode.WRAPPED, nfpms);
        vm.stopPrank();

        deal(WETH, alice, IN_WETH);
        deal(USDC, alice, IN_USDC);
        bytes memory swapData = abi.encodeCall(
            ISwapRouter.exactInputSingle,
            (ISwapRouter.ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: POOL_FEE,
                    recipient: address(v3utils),
                    deadline: block.timestamp,
                    amountIn: SWAP_USDC,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );
        Common.SwapAndMintParams memory lp;
        lp.protocol = Nfpm.Protocol.UNI_V3;
        lp.nfpm = IKrystalNfpm(NFPM);
        lp.token0 = IERC20(WETH);
        lp.token1 = IERC20(USDC);
        lp.fee = POOL_FEE;
        lp.tickSpacing = 10;
        lp.tickLower = IN_LOWER;
        lp.tickUpper = IN_UPPER;
        lp.protocolFeeX64 = PROTOCOL_FEE_X64;
        lp.gasFeeX64 = GAS_FEE_X64;
        lp.amount0 = IN_WETH;
        lp.amount1 = IN_USDC;
        lp.recipient = alice;
        lp.deadline = block.timestamp;
        lp.swapSourceToken = IERC20(USDC);
        lp.amountIn0 = SWAP_USDC;
        lp.swapData0 = swapData;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(v3utils), IN_WETH);
        IERC20(USDC).approve(address(v3utils), IN_USDC);
        Common.SwapAndMintResult memory r = v3utils.swapAndMint(lp);
        vm.stopPrank();

        assertEq(IERC721(NFPM).ownerOf(r.tokenId), alice, "legacy NFT to the user");
        liquidity = r.liquidity;
        feeWeth = _bal(WETH, legacyFeeTaker);
        feeUsdc = _bal(USDC, legacyFeeTaker);
    }
}
