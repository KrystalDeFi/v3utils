// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {V3Utils} from "../../../src/V3Utils.sol";
import {Nfpm} from "../../../src/Nfpm.sol";
import {IAutomationFlows} from "../../../src/router/V3UtilsRouter.sol";
import {CoreModify} from "../../../src/router/modules/CoreModify.sol";
import {ICoreModify} from "../../../src/router/interfaces/ICoreModify.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {
    FeeType,
    MintParams,
    DecreaseParams,
    SwapParams,
    DecreaseAndSwapParams,
    AdjustRangeParams
} from "../../../src/router/RouterTypes.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {UniV3FlowBase} from "./UniV3FlowBase.sol";

/// @notice CoreModify on an Arbitrum fork (unstaked positions): decreaseAndSwap and adjustRange on alice's Uniswap
/// v3 WETH/USDC position, with trading fees earned from real pool swaps.
contract CoreModifyTest is UniV3FlowBase {
    event DecreaseAndSwap(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, address token, uint256 amount
    );
    event AdjustRange(
        address indexed nfpm,
        uint256 indexed tokenId,
        uint256 newTokenId,
        uint256 liquidity,
        uint256 added0,
        uint256 added1
    );

    uint64 internal constant PERF_FEE_X64 = 1844674407370955161; // 10%

    // a wider in-range target for adjustRange
    int24 internal constant WIDE_LOWER = -199000;
    int24 internal constant WIDE_UPPER = -197000;

    address internal trader = makeAddr("cmTrader");

    CoreModify internal coreModify;

    /// @dev What a position yields, split as the flows split it: earned fees (first collect) and principal.
    struct Split {
        uint256 fee0;
        uint256 fee1;
        uint256 principal0;
        uint256 principal1;
    }

    function setUp() public override {
        super.setUp();
        coreModify = new CoreModify();
        _registerModule(ICoreModify.decreaseAndSwap.selector, address(coreModify));
        _registerModule(ICoreModify.adjustRange.selector, address(coreModify));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Round-trips 100 WETH through the pool, so in-range positions earn fees in both tokens.
    function _churn() internal {
        uint256 usdcOut = _poolSwap(trader, WETH, USDC, 100 ether);
        _poolSwap(trader, USDC, WETH, usdcOut);
    }

    /// @dev Dry run on the NFPM, as alice (state reverted): the fees a collect yields now, then the principal of
    /// removing `liquidity`.
    function _split(uint256 tokenId, uint128 liquidity) internal returns (Split memory s) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        (s.fee0, s.fee1) = INonfungiblePositionManager(NFPM)
            .collect(INonfungiblePositionManager.CollectParams(tokenId, alice, type(uint128).max, type(uint128).max));
        if (liquidity != 0) {
            INonfungiblePositionManager(NFPM)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, block.timestamp)
                );
            (s.principal0, s.principal1) = INonfungiblePositionManager(NFPM)
                .collect(
                    INonfungiblePositionManager.CollectParams(tokenId, alice, type(uint128).max, type(uint128).max)
                );
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// @dev Earned fees net of PERFORMANCE_FEE (and GAS_FEE when `withGas`).
    function _netFees(uint256 amount, bool withGas) internal pure returns (uint256) {
        return amount - _fee(amount, PERF_FEE_X64) - (withGas ? _fee(amount, GAS_FEE_X64) : 0);
    }

    function _decreaseParams(uint256 tokenId, uint128 liquidity, address destToken, SwapParams[] memory swaps)
        internal
        view
        returns (DecreaseAndSwapParams memory p)
    {
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.decrease = DecreaseParams({liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        p.swaps = swaps;
        p.destToken = destToken;
        p.protocolFeeX64 = PROTOCOL_FEE_X64;
        p.performanceFeeX64 = PERF_FEE_X64;
        p.gasFeeX64 = GAS_FEE_X64;
    }

    function _adjustParams(uint256 tokenId, int24 lower, int24 upper, SwapParams[] memory swaps, bool compoundFees)
        internal
        view
        returns (AdjustRangeParams memory p)
    {
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.swaps = swaps;
        p.mint = MintParams({tickLower: lower, tickUpper: upper, minLiquidity: 0, deadline: block.timestamp});
        p.compoundFees = compoundFees;
        p.protocolFeeX64 = PROTOCOL_FEE_X64;
        p.performanceFeeX64 = PERF_FEE_X64;
        p.gasFeeX64 = GAS_FEE_X64;
    }

    function _decrease(address who, DecreaseAndSwapParams memory p) internal returns (uint256 amountOut) {
        vm.prank(who);
        amountOut = abi.decode(router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (p))), (uint256));
    }

    function _adjust(address who, AdjustRangeParams memory p) internal returns (uint256 newTokenId, uint128 liquidity) {
        vm.prank(who);
        (newTokenId, liquidity) =
            abi.decode(router.execute(abi.encodeCall(ICoreModify.adjustRange, (p))), (uint256, uint128));
    }

    /// @dev Asserts the i-th TakeFees log: type, rate, tokenId and the fee on (amount0, amount1) of (WETH, USDC).
    function _assertFee(
        Vm.Log[] memory logs,
        uint256 i,
        FeeType t,
        uint64 feeX64,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) internal pure {
        (IRouterErrors.TakeFeesEventData[] memory fees, uint256[] memory ids,) = _takeFeesLogs(logs);
        assertEq(uint8(fees[i].feeType), uint8(t), "fee type");
        assertEq(fees[i].feeX64, feeX64, "fee rate");
        assertEq(ids[i], tokenId, "fee tokenId");
        assertEq(fees[i].feeTokens.length, 2, "fee tokens");
        assertEq(fees[i].feeTokens[0].token, WETH);
        assertEq(fees[i].feeTokens[0].amount, _fee(amount0, feeX64), "fee on token0");
        assertEq(fees[i].feeTokens[1].token, USDC);
        assertEq(fees[i].feeTokens[1].amount, _fee(amount1, feeX64), "fee on token1");
    }

    function _feeCount(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        (,, n) = _takeFeesLogs(logs);
    }

    /// @dev The AdjustRange log's (newTokenId, liquidity, added0, added1).
    function _adjustLog(Vm.Log[] memory logs) internal pure returns (uint256 id, uint256 liq, uint256 a0, uint256 a1) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == AdjustRange.selector) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        revert("no AdjustRange log");
    }

    /// @dev The first Swap log's amountIn.
    function _swapIn(Vm.Log[] memory logs) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == Swap.selector) {
                (uint256 amountIn,) = abi.decode(logs[i].data, (uint256, uint256));
                return amountIn;
            }
        }
        revert("no Swap log");
    }

    function _ticksOf(uint256 tokenId) internal view returns (int24 lower, int24 upper) {
        (,,,,, lower, upper,,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
    }

    // ------------------------------------------------------------------ decreaseAndSwap

    /// @dev Half the liquidity out, no swaps: the NFT stays in the wallet with the rest; fees on the earned fees
    /// (PERFORMANCE) and on the principal (PROTOCOL, GAS), in that order; the user gets the rest to the wei.
    function test_decrease_partial_keepsNftInWallet() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        uint128 half = liquidity / 2;
        Split memory s = _split(tokenId, half);
        assertGt(s.fee0, 0, "fees earned in WETH");
        assertGt(s.fee1, 0, "fees earned in USDC");
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);

        vm.recordLogs();
        uint256 amountOut = _decrease(alice, _decreaseParams(tokenId, half, USDC, new SwapParams[](0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back in the wallet");
        assertEq(_liquidityOf(tokenId), liquidity - half, "rest of the liquidity stays");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));

        assertEq(_feeCount(logs), 3, "PERFORMANCE, PROTOCOL, GAS");
        _assertFee(logs, 0, FeeType.PERFORMANCE_FEE, PERF_FEE_X64, tokenId, s.fee0, s.fee1);
        _assertFee(logs, 1, FeeType.PROTOCOL_FEE, PROTOCOL_FEE_X64, tokenId, s.principal0, s.principal1);
        _assertFee(logs, 2, FeeType.GAS_FEE, GAS_FEE_X64, tokenId, s.principal0, s.principal1);

        assertEq(_bal(WETH, alice) - weth0, _netFees(s.fee0, false) + _net(s.principal0), "WETH to the user");
        assertEq(_bal(USDC, alice) - usdc0, _netFees(s.fee1, false) + _net(s.principal1), "USDC to the user");
        assertEq(amountOut, _bal(USDC, alice) - usdc0, "amountOut is the USDC delta");
        assertEq(
            _bal(WETH, routerFeeTaker),
            _fee(s.fee0, PERF_FEE_X64) + _fee(s.principal0, PROTOCOL_FEE_X64) + _fee(s.principal0, GAS_FEE_X64),
            "fee taker WETH"
        );
    }

    /// @dev Full withdraw into USDC, with USDC and WETH already in the router: `amountOut` is what the user received
    /// (v4utils GHSA-m36p), not the router's USDC balance, and the router keeps its own balances. (The swap's calldata
    /// fixes its amount, so this does not show what `amountIn == 0` resolves to: CoreBase's
    /// `test_preexistingBalances_untouched` and `test_adjustRange_notCompounding_returnsFeesBeforeSwaps` do.)
    function test_decrease_full_toDestToken_amountOutIsDelta() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        deal(USDC, address(router), 7_000e6);
        deal(WETH, address(router), 3 ether);
        Split memory s = _split(tokenId, liquidity);
        uint256 netWeth = _netFees(s.fee0, false) + _net(s.principal0);
        assertGt(netWeth, 0, "WETH to swap");
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);

        vm.recordLogs();
        uint256 amountOut =
            _decrease(alice, _decreaseParams(tokenId, liquidity, USDC, _swaps1(_step(WETH, USDC, 0, netWeth))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(amountOut, 0, "amountOut");
        assertEq(amountOut, _bal(USDC, alice) - usdc0, "amountOut is the user's USDC delta");
        assertEq(_bal(WETH, alice), weth0, "all the call's WETH swapped");
        assertEq(_bal(USDC, address(router)), 7_000e6, "router USDC unchanged");
        assertEq(_bal(WETH, address(router)), 3 ether, "router WETH unchanged");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "empty NFT to the wallet");
        assertEq(_liquidityOf(tokenId), 0, "fully withdrawn");
        assertEq(amountOut, _netFees(s.fee1, false) + _net(s.principal1) + _swapOut(logs), "USDC reconciles");

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != DecreaseAndSwap.selector) continue;
            found = true;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(NFPM))), "event nfpm");
            assertEq(logs[i].topics[2], bytes32(tokenId), "event tokenId");
            (uint128 removed, address token, uint256 amount) = abi.decode(logs[i].data, (uint128, address, uint256));
            assertEq(removed, liquidity, "event liquidity");
            assertEq(token, USDC, "event token");
            assertEq(amount, amountOut, "event amount");
        }
        assertTrue(found, "DecreaseAndSwap emitted");
    }

    /// @dev `liquidity: 0` only collects: PERFORMANCE_FEE then GAS_FEE on the earned fees (as v4utils), no PROTOCOL_FEE,
    /// and the position keeps its liquidity and stays in the wallet.
    function test_decrease_zeroLiquidity_collectsFeesOnly_performanceFee() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        Split memory s = _split(tokenId, 0);
        assertGt(s.fee0, 0, "fees earned in WETH");
        assertGt(s.fee1, 0, "fees earned in USDC");
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);

        vm.recordLogs();
        uint256 amountOut = _decrease(alice, _decreaseParams(tokenId, 0, WETH, new SwapParams[](0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_feeCount(logs), 2, "PERFORMANCE and GAS only");
        _assertFee(logs, 0, FeeType.PERFORMANCE_FEE, PERF_FEE_X64, tokenId, s.fee0, s.fee1);
        _assertFee(logs, 1, FeeType.GAS_FEE, GAS_FEE_X64, tokenId, s.fee0, s.fee1);
        assertEq(_bal(WETH, alice) - weth0, _netFees(s.fee0, true), "net WETH fees");
        assertEq(_bal(USDC, alice) - usdc0, _netFees(s.fee1, true), "net USDC fees");
        assertEq(amountOut, _netFees(s.fee0, true), "amountOut is the WETH delta");
        assertEq(_liquidityOf(tokenId), liquidity, "liquidity untouched");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back in the wallet");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));
    }

    function test_decrease_notHolder_reverts() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(
            abi.encodeCall(
                ICoreModify.decreaseAndSwap, (_decreaseParams(tokenId, liquidity, USDC, new SwapParams[](0)))
            )
        );
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT stays with alice");
        assertEq(_liquidityOf(tokenId), liquidity, "position untouched");
    }

    // ------------------------------------------------------------------ adjustRange

    /// @dev Not compounding: the net earned fees go to the user before the swaps (v4utils GHSA-v6cm). The swap router
    /// here pulls its whole allowance, so the `amountIn == 0` WETH swap shows exactly what the call held: the net
    /// principal, never the fees. The new USDC-only range then takes no WETH, so the user's WETH is the net fees.
    function test_adjustRange_notCompounding_returnsFeesBeforeSwaps() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        Split memory s = _split(tokenId, liquidity);
        assertGt(s.fee0, 0, "fees earned in WETH");

        MockSwapRouter greedy = new MockSwapRouter();
        uint256 usdcOut = 1_000e6;
        deal(USDC, address(greedy), usdcOut);
        vm.prank(routerAdmin);
        router.setSwapRouter(address(greedy));
        SwapParams memory step = SwapParams({
            tokenIn: WETH,
            amountIn: 0,
            tokenOut: USDC,
            amountOutMin: 0,
            swapData: abi.encodeCall(MockSwapRouter.swap, (WETH, USDC, usdcOut))
        });
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);

        vm.recordLogs();
        (uint256 newTokenId,) = _adjust(alice, _adjustParams(tokenId, BELOW_LOWER, BELOW_UPPER, _swaps1(step), false));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_swapIn(logs), _net(s.principal0), "the swap saw only the net principal");
        assertEq(_bal(WETH, alice) - weth0, _netFees(s.fee0, false), "net WETH fees to the user");
        (,, uint256 added0, uint256 added1) = _adjustLog(logs);
        assertEq(added0, 0, "USDC-only range");
        assertEq(
            _bal(USDC, alice) - usdc0,
            _netFees(s.fee1, false) + _net(s.principal1) + usdcOut - added1,
            "net USDC fees plus the mint's leftover"
        );
        assertEq(IERC721(NFPM).ownerOf(newTokenId), alice, "new NFT to the wallet");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));
    }

    /// @dev Compounding into a wider range: a new NFT with the old one's fees and principal (net of fees) in it, the
    /// old NFT back empty, fees PERFORMANCE / PROTOCOL / GAS tagged with the old tokenId, leftovers to the user.
    function test_adjustRange_newRange_oldNftReturnedEmpty() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        Split memory s = _split(tokenId, liquidity);
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);

        vm.recordLogs();
        (uint256 newTokenId, uint128 newLiquidity) =
            _adjust(alice, _adjustParams(tokenId, WIDE_LOWER, WIDE_UPPER, new SwapParams[](0), true));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(newTokenId != tokenId, "a new position");
        assertGt(newLiquidity, 0, "new liquidity");
        assertEq(_liquidityOf(newTokenId), newLiquidity, "new position liquidity");
        (int24 lower, int24 upper) = _ticksOf(newTokenId);
        assertEq(lower, WIDE_LOWER, "new lower tick");
        assertEq(upper, WIDE_UPPER, "new upper tick");
        assertEq(IERC721(NFPM).ownerOf(newTokenId), alice, "new NFT to the old one's place");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "old NFT back to the wallet");
        assertEq(_liquidityOf(tokenId), 0, "old NFT empty");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));

        assertEq(_feeCount(logs), 3, "PERFORMANCE, PROTOCOL, GAS");
        _assertFee(logs, 0, FeeType.PERFORMANCE_FEE, PERF_FEE_X64, tokenId, s.fee0, s.fee1);
        _assertFee(logs, 1, FeeType.PROTOCOL_FEE, PROTOCOL_FEE_X64, tokenId, s.principal0, s.principal1);
        _assertFee(logs, 2, FeeType.GAS_FEE, GAS_FEE_X64, tokenId, s.principal0, s.principal1);

        _assertCompounded(logs, s, newTokenId, newLiquidity, weth0, usdc0);
    }

    /// @dev The AdjustRange log names the new position, and the user got back exactly what the fees and the new
    /// position did not take of the net fees and principal.
    function _assertCompounded(
        Vm.Log[] memory logs,
        Split memory s,
        uint256 newTokenId,
        uint128 newLiquidity,
        uint256 weth0,
        uint256 usdc0
    ) internal view {
        (uint256 loggedId, uint256 loggedLiquidity, uint256 added0, uint256 added1) = _adjustLog(logs);
        assertEq(loggedId, newTokenId, "event newTokenId");
        assertEq(loggedLiquidity, newLiquidity, "event liquidity");
        assertEq(_bal(WETH, alice) - weth0, _netFees(s.fee0, false) + _net(s.principal0) - added0, "WETH leftover");
        assertEq(_bal(USDC, alice) - usdc0, _netFees(s.fee1, false) + _net(s.principal1) - added1, "USDC leftover");
    }

    function test_adjustRange_minLiquidity_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        AdjustRangeParams memory p = _adjustParams(tokenId, WIDE_LOWER, WIDE_UPPER, new SwapParams[](0), true);
        p.mint.minLiquidity = type(uint128).max;
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.LiquiditySlippage.selector);
        router.execute(abi.encodeCall(ICoreModify.adjustRange, (p)));
    }

    // ------------------------------------------------------------------ entry contract

    /// @dev `executeAutomation` calls these flows by the selectors of `IAutomationFlows`.
    function test_selectors_matchAutomationFlows() public pure {
        assertEq(ICoreModify.decreaseAndSwap.selector, IAutomationFlows.decreaseAndSwap.selector, "decreaseAndSwap");
        assertEq(ICoreModify.adjustRange.selector, IAutomationFlows.adjustRange.selector, "adjustRange");
    }

    /// @dev Neither flow takes native: value with an otherwise valid call reverts, and the same call without succeeds.
    function test_msgValue_reverts() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        vm.deal(alice, 1 ether);
        bytes memory decreaseCall = abi.encodeCall(
            ICoreModify.decreaseAndSwap, (_decreaseParams(tokenId, liquidity / 2, USDC, new SwapParams[](0)))
        );
        bytes memory adjustCall = abi.encodeCall(
            ICoreModify.adjustRange, (_adjustParams(tokenId, WIDE_LOWER, WIDE_UPPER, new SwapParams[](0), true))
        );

        vm.prank(alice);
        vm.expectRevert(bytes(""));
        router.execute{value: 1}(decreaseCall);
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        router.execute{value: 1}(adjustCall);

        vm.prank(alice);
        router.execute(decreaseCall);
        vm.prank(alice);
        router.execute(adjustCall);
        assertEq(alice.balance, 1 ether, "value kept by the caller");
    }

    function test_directCall_reverts() public {
        DecreaseAndSwapParams memory d;
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        coreModify.decreaseAndSwap(d);
        AdjustRangeParams memory a;
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        coreModify.adjustRange(a);
    }

    // ------------------------------------------------------------------ parity

    /// @dev The same half withdraw (after fees accrue), same fee rates, through V3Utils' WITHDRAW_AND_COLLECT_AND_SWAP
    /// and through the router, from the same state: equal fees and equal proceeds to the wei.
    function test_parity_decrease_vsV3Utils() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        uint128 half = liquidity / 2;
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);
        uint256 snap = vm.snapshotState();

        (V3Utils v3utils, address legacyFeeTaker) = _deployLegacy();
        V3Utils.Instructions memory ins;
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        ins.protocol = Nfpm.Protocol.UNI_V3;
        ins.targetToken = USDC;
        ins.liquidity = half;
        ins.deadline = block.timestamp;
        ins.recipient = alice;
        ins.liquidityFeeX64 = PROTOCOL_FEE_X64;
        ins.performanceFeeX64 = PERF_FEE_X64;
        ins.gasFeeX64 = GAS_FEE_X64;
        vm.startPrank(alice);
        IERC721(NFPM).approve(address(v3utils), tokenId);
        v3utils.execute(_legacyNfpm(), tokenId, ins);
        vm.stopPrank();
        uint256[4] memory legacy = [
            _bal(WETH, legacyFeeTaker), _bal(USDC, legacyFeeTaker), _bal(WETH, alice) - weth0, _bal(USDC, alice) - usdc0
        ];
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "legacy NFT back");
        assertEq(_liquidityOf(tokenId), liquidity - half, "legacy liquidity left");
        vm.revertToState(snap);

        _decrease(alice, _decreaseParams(tokenId, half, USDC, new SwapParams[](0)));

        assertGt(legacy[0], 0, "legacy WETH fees");
        assertEq(_bal(WETH, routerFeeTaker), legacy[0], "WETH fee parity");
        assertEq(_bal(USDC, routerFeeTaker), legacy[1], "USDC fee parity");
        assertEq(_bal(WETH, alice) - weth0, legacy[2], "WETH proceeds parity");
        assertEq(_bal(USDC, alice) - usdc0, legacy[3], "USDC proceeds parity");
        assertEq(_liquidityOf(tokenId), liquidity - half, "liquidity left parity");
    }
}
