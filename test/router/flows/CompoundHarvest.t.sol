// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {CoreModify} from "../../../src/router/modules/CoreModify.sol";
import {ICoreModify} from "../../../src/router/interfaces/ICoreModify.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {FeeType, SwapParams, IncreaseParams, CompoundParams, HarvestParams} from "../../../src/router/RouterTypes.sol";
import {UniV3FlowBase} from "./UniV3FlowBase.sol";

/// @notice CoreModify compound/harvest of an unstaked position's trading fees, on an Arbitrum fork.
contract CompoundHarvestTest is UniV3FlowBase {
    event CompoundFees(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event Harvest(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount);

    uint64 internal constant PERF_FEE_X64 = 1844674407370955161; // 10%

    address internal trader = makeAddr("chTrader");
    CoreModify internal coreModify;

    function setUp() public override {
        super.setUp();
        coreModify = new CoreModify();
        _registerModule(ICoreModify.compound.selector, address(coreModify));
        _registerModule(ICoreModify.harvest.selector, address(coreModify));
    }

    // ------------------------------------------------------------------ helpers

    function _churn() internal {
        uint256 usdcOut = _poolSwap(trader, WETH, USDC, 100 ether);
        _poolSwap(trader, USDC, WETH, usdcOut);
    }

    /// @dev What a collect yields now (dry run as alice, state reverted).
    function _earned(uint256 tokenId) internal returns (uint256 fee0, uint256 fee1) {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        (fee0, fee1) = INonfungiblePositionManager(NFPM)
            .collect(INonfungiblePositionManager.CollectParams(tokenId, alice, type(uint128).max, type(uint128).max));
        vm.revertToState(snap);
    }

    function _net10(uint256 amount) internal pure returns (uint256) {
        return amount - _fee(amount, PERF_FEE_X64);
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

    function _harvestParams(uint256 tokenId, address destToken, SwapParams[] memory swaps)
        internal
        pure
        returns (HarvestParams memory)
    {
        return HarvestParams({
            nfpm: NFPM, tokenId: tokenId, swaps: swaps, destToken: destToken, performanceFeeX64: PERF_FEE_X64
        });
    }

    function _compound(address who, CompoundParams memory p) internal returns (uint128) {
        vm.prank(who);
        return abi.decode(router.execute(abi.encodeCall(ICoreModify.compound, (p))), (uint128));
    }

    function _harvest(address who, HarvestParams memory p) internal returns (uint256) {
        vm.prank(who);
        return abi.decode(router.execute(abi.encodeCall(ICoreModify.harvest, (p))), (uint256));
    }

    // ------------------------------------------------------------------ compound

    function test_compound_tradingFees_increasesLiquidity_performanceFee() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        (uint256 fee0, uint256 fee1) = _earned(tokenId);
        assertGt(fee0, 0, "fees in WETH");
        assertGt(fee1, 0, "fees in USDC");
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);

        vm.recordLogs();
        uint128 added = _compound(alice, _compoundParams(tokenId, new SwapParams[](0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(added, 0, "liquidity added");
        assertEq(_liquidityOf(tokenId), liquidity + added, "position grew by the return value");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back in the wallet");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));

        (IRouterErrors.TakeFeesEventData[] memory fees, uint256[] memory ids, uint256 n) = _takeFeesLogs(logs);
        assertEq(n, 1, "one fee");
        assertEq(uint8(fees[0].feeType), uint8(FeeType.PERFORMANCE_FEE));
        assertEq(fees[0].feeX64, PERF_FEE_X64);
        assertEq(ids[0], tokenId);
        assertEq(fees[0].feeTokens[0].amount, _fee(fee0, PERF_FEE_X64), "fee on WETH");
        assertEq(fees[0].feeTokens[1].amount, _fee(fee1, PERF_FEE_X64), "fee on USDC");
        assertEq(_bal(WETH, routerFeeTaker), _fee(fee0, PERF_FEE_X64), "taker WETH");
        assertEq(_bal(USDC, routerFeeTaker), _fee(fee1, PERF_FEE_X64), "taker USDC");

        _assertCompoundLog(
            logs, tokenId, added, _net10(fee0) - (_bal(WETH, alice) - weth0), _net10(fee1) - (_bal(USDC, alice) - usdc0)
        );
    }

    /// @dev The CompoundFees log names the position, its new liquidity and what the NFPM took (net fees less leftover).
    function _assertCompoundLog(Vm.Log[] memory logs, uint256 tokenId, uint128 added, uint256 used0, uint256 used1)
        internal
        pure
    {
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != CompoundFees.selector) continue;
            found = true;
            assertEq(logs[i].topics[2], bytes32(tokenId));
            (uint128 l, uint256 a0, uint256 a1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
            assertEq(l, added, "event liquidity");
            assertEq(a0, used0, "event amount0");
            assertEq(a1, used1, "event amount1");
        }
        assertTrue(found, "CompoundFees emitted");
    }

    function test_compound_withSwap_usesAllFees() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        (uint256 fee0,) = _earned(tokenId);
        uint256 half = _net10(fee0) / 2;
        uint128 added = _compound(alice, _compoundParams(tokenId, _swaps1(_step(WETH, USDC, half, half))));
        assertEq(_liquidityOf(tokenId), liquidity + added);
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));
    }

    function test_compound_minLiquidity_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        CompoundParams memory p = _compoundParams(tokenId, new SwapParams[](0));
        p.increase.minLiquidity = type(uint128).max;
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.LiquiditySlippage.selector);
        router.execute(abi.encodeCall(ICoreModify.compound, (p)));
    }

    function test_compound_notHolder_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(ICoreModify.compound, (_compoundParams(tokenId, new SwapParams[](0)))));
    }

    // ------------------------------------------------------------------ harvest

    function test_harvest_tradingFees_toDestToken() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        (uint256 fee0, uint256 fee1) = _earned(tokenId);
        uint256 netWeth = _net10(fee0);
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);
        deal(USDC, address(router), 7_000e6);

        vm.recordLogs();
        uint256 out = _harvest(alice, _harvestParams(tokenId, USDC, _swaps1(_step(WETH, USDC, 0, netWeth))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(out, 0);
        assertEq(out, _bal(USDC, alice) - usdc0, "amountOut is the user's delta");
        assertEq(out, _net10(fee1) + _swapOut(logs), "reconciles");
        assertEq(_bal(WETH, alice), weth0, "WETH all swapped");
        assertEq(_bal(USDC, address(router)), 7_000e6, "router balance untouched");
        assertEq(_liquidityOf(tokenId), liquidity, "no liquidity removed");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back");
        (IRouterErrors.TakeFeesEventData[] memory fees,, uint256 n) = _takeFeesLogs(logs);
        assertEq(n, 1);
        assertEq(uint8(fees[0].feeType), uint8(FeeType.PERFORMANCE_FEE));
        assertEq(_bal(WETH, routerFeeTaker), _fee(fee0, PERF_FEE_X64));

        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != Harvest.selector) continue;
            found = true;
            (address token, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
            assertEq(token, USDC);
            assertEq(amount, out);
        }
        assertTrue(found, "Harvest emitted");
    }

    /// @dev destToken a pool token: no swap needed, both net fees go out, amountOut is that token's share.
    function test_harvest_poolTokenDest_noSwaps() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        (uint256 fee0, uint256 fee1) = _earned(tokenId);
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);
        uint256 out = _harvest(alice, _harvestParams(tokenId, WETH, new SwapParams[](0)));
        assertEq(out, _net10(fee0));
        assertEq(_bal(WETH, alice) - weth0, _net10(fee0));
        assertEq(_bal(USDC, alice) - usdc0, _net10(fee1));
    }

    function test_harvest_zeroDest_noSwaps() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        (uint256 fee0, uint256 fee1) = _earned(tokenId);
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);
        uint256 out = _harvest(alice, _harvestParams(tokenId, address(0), new SwapParams[](0)));
        assertEq(out, 0);
        assertEq(_bal(WETH, alice) - weth0, _net10(fee0));
        assertEq(_bal(USDC, alice) - usdc0, _net10(fee1));
    }

    function test_harvest_destTokenNoSwaps_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.MissingSwapData.selector);
        router.execute(abi.encodeCall(ICoreModify.harvest, (_harvestParams(tokenId, ARB, new SwapParams[](0)))));
    }

    function test_harvest_notHolder_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(ICoreModify.harvest, (_harvestParams(tokenId, WETH, new SwapParams[](0)))));
    }

    // ------------------------------------------------------------------ entry contract

    function test_msgValue_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        vm.deal(alice, 1 ether);
        bytes memory c = abi.encodeCall(ICoreModify.compound, (_compoundParams(tokenId, new SwapParams[](0))));
        bytes memory h = abi.encodeCall(ICoreModify.harvest, (_harvestParams(tokenId, WETH, new SwapParams[](0))));
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        router.execute{value: 1}(c);
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        router.execute{value: 1}(h);
        vm.prank(alice);
        router.execute(c);
        vm.prank(alice);
        router.execute(h);
        assertEq(alice.balance, 1 ether);
    }

    function test_directCall_reverts() public {
        CompoundParams memory c;
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        coreModify.compound(c);
        HarvestParams memory h;
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        coreModify.harvest(h);
    }
}
