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
import {INonfungiblePositionManager as IKrystalNfpm} from "../../../src/Nfpm.sol";
import {CoreMint} from "../../../src/router/modules/CoreMint.sol";
import {ICoreMint} from "../../../src/router/interfaces/ICoreMint.sol";
import {UniV3Adapter} from "../../../src/router/adapters/UniV3Adapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {
    PoolKey,
    MintParams,
    InputTokenParams,
    SwapParams,
    SwapAndMintParams
} from "../../../src/router/RouterTypes.sol";
import {RouterTestBase} from "../RouterTestBase.sol";

/// @notice Shared fixture of the flow suites on an Arbitrum fork: Uniswap v3 WETH/USDC 0.05%, real swaps through
/// Uniswap's SwapRouter, the UniV3 adapter and CoreMint registered, and helpers for params, swaps, fees and logs.
abstract contract UniV3FlowBase is RouterTestBase {
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

    function setUp() public virtual {
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

    // ------------------------------------------------------------------ params and swaps

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

    /// @dev Swaps `amountIn` of `tokenIn` through the pool as `who` (dealt and paid to `who`).
    function _poolSwap(address who, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        deal(tokenIn, who, amountIn);
        vm.startPrank(who);
        IERC20(tokenIn).approve(UNI_SWAP_ROUTER, amountIn);
        out = ISwapRouter(UNI_SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: who,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.stopPrank();
    }

    /// @dev What `amountIn` of `tokenIn` swaps to through the pool right now (dry run, state reverted).
    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _poolSwap(address(this), tokenIn, tokenOut, amountIn);
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

    /// @dev Alice's in-range position, minted through the router (no fees, no swaps), with the router approved for
    /// her NFTs.
    function _aliceMints() internal returns (uint256 tokenId, uint128 liquidity) {
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        (tokenId, liquidity) = _mint(
            alice, _mintParams(IN_LOWER, IN_UPPER, _inputs2(WETH, IN_WETH, USDC, IN_USDC), new SwapParams[](0), 0, 0), 0
        );
        vm.prank(alice);
        IERC721(NFPM).setApprovalForAll(address(router), true);
    }

    // ------------------------------------------------------------------ reads and assertions

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

    // ------------------------------------------------------------------ legacy V3Utils (parity)

    /// @dev V3Utils deployed from this repo's source (the production address has no code at the pinned block),
    /// whitelisting NFPM, with its own fee taker.
    function _deployLegacy() internal returns (V3Utils v3utils, address legacyFeeTaker) {
        assertEq(V3UTILS_DEPLOYED.code.length, 0, "deployed V3Utils absent at the pinned block");
        address owner = makeAddr("v3uOwner");
        legacyFeeTaker = makeAddr("v3uFeeTaker");
        address[] memory nfpms = new address[](1);
        nfpms[0] = NFPM;
        vm.startPrank(owner, owner);
        v3utils = new V3Utils();
        v3utils.initialize(UNI_SWAP_ROUTER, owner, legacyFeeTaker, WETH, Common.NativeMode.WRAPPED, nfpms);
        vm.stopPrank();
    }

    function _legacyNfpm() internal pure returns (IKrystalNfpm) {
        return IKrystalNfpm(NFPM);
    }
}
