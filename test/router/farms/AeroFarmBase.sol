// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-core/libraries/FullMath.sol";
import {CoreMint} from "../../../src/router/modules/CoreMint.sol";
import {CoreModify} from "../../../src/router/modules/CoreModify.sol";
import {ICoreMint} from "../../../src/router/interfaces/ICoreMint.sol";
import {ICoreModify} from "../../../src/router/interfaces/ICoreModify.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {AerodromeAdapter} from "../../../src/router/adapters/AerodromeAdapter.sol";
import {AeroGaugeFarm} from "../../../src/router/farms/AeroGaugeFarm.sol";
import {
    PoolKey,
    MintParams,
    IncreaseParams,
    DecreaseParams,
    InputTokenParams,
    SwapParams,
    SwapAndMintParams,
    SwapAndIncreaseParams,
    DecreaseAndSwapParams,
    AdjustRangeParams,
    CompoundParams,
    HarvestParams
} from "../../../src/router/RouterTypes.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {CoreHarness} from "../mocks/CoreHarness.sol";
import {RouterTestBase} from "../RouterTestBase.sol";

/// @dev The new Aero CLGauge surface the tests drive directly (as the user would on the gauge).
interface ITestGauge {
    function setApprovalForAll(address operator, bool approved) external;
    function approveForClaim(address operator, bool approved) external;
    function withdraw(uint256 tokenId) external;
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
    function earned(address account, uint256[] calldata tokenIds) external view returns (uint256);
    function withdrawFrom(uint256 tokenId, address account) external;
    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external;
}

interface ITestGaugeFactory {
    function effectivePenaltyConfig(address gauge) external view returns (uint256 minStakeBlocks, uint256 penaltyRate);
}

interface ITestLeafVoter {
    function isActivated(address gauge) external view returns (bool);
}

interface ITestPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function gauge() external view returns (address);
}

interface ITestAeroNfpm {
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

/// @notice Shared fixture of the Aero gauge suites: the new Aero (MetaDEX03 Slipstream) NFPM on Base (or Optimism),
/// a router with CoreMint, CoreModify, the Aerodrome adapter and an `AeroGaugeFarm` registered, and a mock swap
/// router (fork swapRouter calldata is not available). Run with `FOUNDRY_EVM_VERSION=cancun`.
/// @dev `makeAddr("user")` is an EIP-7702 account on Base; every label here is distinct.
abstract contract AeroFarmBase is RouterTestBase {
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event TakeFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, IRouterErrors.TakeFeesEventData data
    );

    address internal constant NFPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address internal constant GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address internal constant LEAF_VOTER = 0x382409fad8503FbCdbB27A4211551fa03e884078;
    address internal constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address internal constant XAERO = 0xbdEaeA5205d16f34Cb40038052d91235D87B4C54;
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // Base and Optimism

    // Base: gauge A, WETH/USDC tickSpacing 50 (AERO is not a pool token)
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant GAUGE_A = 0x46a9dCa72D78366571bE583aa69C1DC16E6889fB;
    address internal constant POOL_A = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c;
    int24 internal constant TS_A = 50;
    // Base: AERO/USDC tickSpacing 1 has a pool but no gauge at the pinned block
    address internal constant POOL_NO_GAUGE = 0xb27460d0e2B4eC0fd2b2c29f0c2B29D4C045f863;
    int24 internal constant TS_NO_GAUGE = 1;

    // Optimism: USDC/WETH tickSpacing 100, rewards in xAERO
    address internal constant USDC_OP = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant GAUGE_OP = 0x8F6a9ea8304Fe2c16a6a11f31ABa71F2c526cFd9;
    address internal constant POOL_OP = 0xcA231D91eC00385a54e541f504617d2197f9B7c3;
    int24 internal constant TS_OP = 100;

    uint64 internal constant PERF_FEE_X64 = 1 << 62; // 25%

    address internal staker = makeAddr("aeroStaker");
    address internal attacker = makeAddr("aeroAttacker");

    CoreMint internal coreMint;
    CoreModify internal coreModify;
    address internal adapter;
    AeroGaugeFarm internal farm;
    MockSwapRouter internal swapper;

    /// @dev Forks Base (or Optimism with `onOp`), deploys and wires the router; the farm pays AERO and compounds on
    /// Base, pays xAERO and does not compound on Optimism.
    function _setUpAero(bool onOp) internal {
        if (onOp) _forkOp();
        else _forkBase();
        _deployRouter(WETH);
        adapter = address(new AerodromeAdapter());
        farm = new AeroGaugeFarm(GAUGE_FACTORY, onOp ? XAERO : AERO, !onOp);
        _register(NFPM, adapter, address(farm));
        coreMint = new CoreMint();
        coreModify = new CoreModify();
        _registerModule(ICoreMint.swapAndMint.selector, address(coreMint));
        _registerModule(ICoreMint.swapAndIncrease.selector, address(coreMint));
        _registerModule(ICoreModify.decreaseAndSwap.selector, address(coreModify));
        _registerModule(ICoreModify.adjustRange.selector, address(coreModify));
        _registerModule(ICoreModify.compound.selector, address(coreModify));
        _registerModule(ICoreModify.harvest.selector, address(coreModify));
        swapper = new MockSwapRouter();
        vm.prank(routerAdmin);
        router.setSwapRouter(address(swapper));
    }

    // ------------------------------------------------------------------ setup helpers

    /// @dev `who` lets the router unstake (`setApprovalForAll`) and, with `claim`, claim (`approveForClaim`).
    function _approveGauge(address who, address gauge, bool claim) internal {
        vm.startPrank(who);
        ITestGauge(gauge).setApprovalForAll(address(router), true);
        ITestGauge(gauge).approveForClaim(address(router), claim);
        vm.stopPrank();
    }

    function _key(address token0, address token1, int24 ts) internal pure returns (PoolKey memory) {
        return PoolKey({token0: token0, token1: token1, fee: 0, tickSpacing: ts, deployer: address(0)});
    }

    /// @dev A range of `half` tick spacings either side of the pool's current tick.
    function _range(address pool, int24 ts, int24 half) internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,,,) = ITestPool(pool).slot0();
        int24 base = (tick / ts) * ts;
        lower = base - half * ts;
        upper = base + half * ts;
    }

    function _mintParams(PoolKey memory key, address pool, uint256 a0, uint256 a1, bool stake)
        internal
        returns (SwapAndMintParams memory p)
    {
        (int24 lower, int24 upper) = _range(pool, key.tickSpacing, 10);
        _dealAndApprove(key.token0, staker, a0);
        _dealAndApprove(key.token1, staker, a1);
        p.nfpm = NFPM;
        p.key = key;
        p.mint = MintParams({tickLower: lower, tickUpper: upper, minLiquidity: 0, deadline: block.timestamp});
        p.inputTokens = new InputTokenParams[](2);
        p.inputTokens[0] = InputTokenParams(key.token0, a0);
        p.inputTokens[1] = InputTokenParams(key.token1, a1);
        p.stake = stake;
    }

    function _mint(address who, SwapAndMintParams memory p) internal returns (uint256 tokenId) {
        vm.prank(who);
        bytes memory ret = router.execute(abi.encodeCall(ICoreMint.swapAndMint, (p)));
        (tokenId,) = abi.decode(ret, (uint256, uint128));
    }

    /// @dev The staker's WETH/USDC position staked in gauge A, past the gauge's penalty window so it has emissions.
    function _stakedA() internal returns (uint256 tokenId) {
        tokenId = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, true));
        _pastPenalty(GAUGE_A);
    }

    /// @dev Rolls past the gauge's minimum stake blocks (an earlier unstake forfeits the emissions).
    function _pastPenalty(address gauge) internal {
        (uint256 minStakeBlocks,) = ITestGaugeFactory(GAUGE_FACTORY).effectivePenaltyConfig(gauge);
        vm.roll(block.number + minStakeBlocks + 1000);
        vm.warp(block.timestamp + 2 * (minStakeBlocks + 1000));
    }

    /// @dev The voter reports `gauge` dead (killed).
    function _killGauge(address gauge) internal {
        vm.mockCall(LEAF_VOTER, abi.encodeCall(ITestLeafVoter.isActivated, (gauge)), abi.encode(false));
    }

    // ------------------------------------------------------------------ flow calls

    function _decrease(address who, uint256 tokenId, uint128 liquidity, address destToken)
        internal
        returns (uint256 amountOut)
    {
        DecreaseAndSwapParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.decrease = DecreaseParams({liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        p.destToken = destToken;
        vm.prank(who);
        amountOut = abi.decode(router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (p))), (uint256));
    }

    function _adjustParams(uint256 tokenId, address pool, int24 ts) internal view returns (AdjustRangeParams memory p) {
        (int24 lower, int24 upper) = _range(pool, ts, 5);
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.mint = MintParams({tickLower: lower, tickUpper: upper, minLiquidity: 0, deadline: block.timestamp});
    }

    function _harvestParams(uint256 tokenId, address destToken, SwapParams[] memory swaps)
        internal
        pure
        returns (HarvestParams memory)
    {
        return HarvestParams({
            nfpm: NFPM, tokenId: tokenId, swaps: swaps, destToken: destToken, performanceFeeX64: PERF_FEE_X64
        });
    }

    function _harvest(address who, HarvestParams memory p) internal returns (uint256 amountOut) {
        vm.prank(who);
        amountOut = abi.decode(router.execute(abi.encodeCall(ICoreModify.harvest, (p))), (uint256));
    }

    function _compoundParams(uint256 tokenId, SwapParams[] memory swaps) internal view returns (CompoundParams memory) {
        return CompoundParams({
            nfpm: NFPM,
            tokenId: tokenId,
            swaps: swaps,
            increase: IncreaseParams({minLiquidity: 0, deadline: block.timestamp}),
            performanceFeeX64: PERF_FEE_X64
        });
    }

    function _compound(address who, CompoundParams memory p) internal returns (uint128 liquidity) {
        vm.prank(who);
        liquidity = abi.decode(router.execute(abi.encodeCall(ICoreModify.compound, (p))), (uint128));
    }

    /// @dev A mock-router swap step paying `amountOut` of `tokenOut` for exactly `amountIn` of `tokenIn`.
    function _mockStep(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        internal
        returns (SwapParams memory)
    {
        deal(tokenOut, address(swapper), IERC20(tokenOut).balanceOf(address(swapper)) + amountOut);
        return SwapParams({
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokenOut: tokenOut,
            amountOutMin: amountOut,
            swapData: abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountOut))
        });
    }

    // ------------------------------------------------------------------ reads and assertions

    function _bal(address token, address who) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }

    function _liq(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = ITestAeroNfpm(NFPM).positions(tokenId);
    }

    function _earned(address gauge, address who, uint256 tokenId) internal view returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        return ITestGauge(gauge).earned(who, ids);
    }

    function _fee(uint256 amount, uint64 feeX64) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, feeX64, 2 ** 64);
    }

    function _assertStaked(address gauge, address who, uint256 tokenId) internal view {
        assertTrue(ITestGauge(gauge).stakedContains(who, tokenId), "staked for the account");
        assertEq(IERC721(NFPM).ownerOf(tokenId), gauge, "NFT in the gauge");
    }

    /// @dev The router holds none of `tokens`, no NFT, and has no allowance left to the NFPM or the swap router.
    function _assertRouterClean(address[] memory tokens) internal view {
        for (uint256 i; i < tokens.length; i++) {
            assertEq(_bal(tokens[i], address(router)), 0, "router balance");
            assertEq(IERC20(tokens[i]).allowance(address(router), NFPM), 0, "nfpm allowance");
            assertEq(IERC20(tokens[i]).allowance(address(router), address(swapper)), 0, "swap allowance");
        }
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0, "router NFTs");
        assertEq(address(router).balance, 0, "router native");
    }

    function _tokens3(address a, address b, address c) internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    function _noSwaps() internal pure returns (SwapParams[] memory) {
        return new SwapParams[](0);
    }
}
