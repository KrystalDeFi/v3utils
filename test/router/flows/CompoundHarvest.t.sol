// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    uint256 internal constant SEED_WETH = 3 ether;
    uint256 internal constant SEED_USDC = 7_000e6;

    /// @dev Puts WETH and USDC on the router that no flow may touch.
    function _seedRouter() internal {
        deal(WETH, address(router), SEED_WETH);
        deal(USDC, address(router), SEED_USDC);
    }

    function _assertSeedUntouched() internal view {
        assertEq(_bal(WETH, address(router)), SEED_WETH, "router WETH unchanged");
        assertEq(_bal(USDC, address(router)), SEED_USDC, "router USDC unchanged");
        assertEq(IERC20(WETH).allowance(address(router), NFPM), 0, "nfpm allowance");
        assertEq(IERC20(USDC).allowance(address(router), NFPM), 0, "nfpm allowance");
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
        _seedRouter();

        vm.recordLogs();
        uint128 added = _compound(alice, _compoundParams(tokenId, new SwapParams[](0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(added, 0, "liquidity added");
        assertEq(_liquidityOf(tokenId), liquidity + added, "position grew by the return value");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back in the wallet");
        _assertSeedUntouched();

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

    /// @dev An `amountIn == 0` swap of the WETH fees, with WETH and USDC already on the router: only the call's own
    /// fees are swapped and added (alice's leftover is the net fees less what the NFPM took), the router keeps its seed.
    function test_compound_withSwap_routerBalancesUntouched() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        (uint256 fee0, uint256 fee1) = _earned(tokenId);
        uint256 net0 = _net10(fee0);
        uint256 net1 = _net10(fee1);
        uint256 weth0 = _bal(WETH, alice);
        uint256 usdc0 = _bal(USDC, alice);
        _seedRouter();

        vm.recordLogs();
        uint128 added = _compound(alice, _compoundParams(tokenId, _swaps1(_step(WETH, USDC, 0, net0 / 2))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_liquidityOf(tokenId), liquidity + added);
        _assertSeedUntouched();
        uint256 swapped = _swapOut(logs);
        // WETH: net fees, half swapped away, rest (less what the NFPM took) back; USDC: net fees + swap output
        assertLe(_bal(WETH, alice) - weth0, net0 - net0 / 2, "WETH back is within the call's own fees");
        assertLe(_bal(USDC, alice) - usdc0, net1 + swapped, "USDC back is within the call's own fees");
        (, uint256 a0, uint256 a1) = _compoundLog(logs);
        assertEq(_bal(WETH, alice) - weth0, net0 - net0 / 2 - a0, "WETH leftover");
        assertEq(_bal(USDC, alice) - usdc0, net1 + swapped - a1, "USDC leftover");
    }

    function _compoundLog(Vm.Log[] memory logs) internal pure returns (uint128 l, uint256 a0, uint256 a1) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == CompoundFees.selector) {
                return abi.decode(logs[i].data, (uint128, uint256, uint256));
            }
        }
        revert("no CompoundFees");
    }

    /// @dev No fees earned: nothing to add, the call succeeds with liquidity unchanged (an AUTO_COMPOUND bot must not
    /// fail on a quiet position); a `minLiquidity` above the 0 added still reverts.
    function test_compound_noFees_noop() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _seedRouter();
        uint256 weth0 = _bal(WETH, alice);
        assertEq(_compound(alice, _compoundParams(tokenId, new SwapParams[](0))), 0, "nothing added");
        assertEq(_liquidityOf(tokenId), liquidity, "liquidity unchanged");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back");
        assertEq(_bal(WETH, alice), weth0, "nothing paid out");
        _assertSeedUntouched();

        CompoundParams memory p = _compoundParams(tokenId, new SwapParams[](0));
        p.increase.minLiquidity = 1;
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.LiquiditySlippage.selector);
        router.execute(abi.encodeCall(ICoreModify.compound, (p)));
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
        _seedRouter();

        vm.recordLogs();
        uint256 out = _harvest(alice, _harvestParams(tokenId, USDC, _swaps1(_step(WETH, USDC, 0, netWeth))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(out, 0);
        assertEq(out, _bal(USDC, alice) - usdc0, "amountOut is the user's delta");
        assertEq(out, _net10(fee1) + _swapOut(logs), "reconciles");
        assertEq(_bal(WETH, alice), weth0, "WETH all swapped");
        _assertSeedUntouched();
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

    /// @dev destToken 0 with swaps ending in a WETH -> native conversion: amountOut is the native the account got.
    function test_harvest_nativeDest_amountOutIsNativeDelta() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        (uint256 fee0,) = _earned(tokenId);
        uint256 native0 = alice.balance;
        _seedRouter();
        vm.deal(address(router), 0.7 ether);

        vm.recordLogs();
        uint256 out = _harvest(alice, _harvestParams(tokenId, address(0), _swaps1(_convert(WETH, address(0)))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(out, _net10(fee0), "all net WETH fees unwrapped");
        assertEq(out, alice.balance - native0, "amountOut is the native delta");
        assertEq(address(router).balance, 0.7 ether, "router native unchanged");
        assertEq(_bal(WETH, address(router)), SEED_WETH, "router WETH unchanged");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != Harvest.selector) continue;
            (address token, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
            assertEq(token, address(0));
            assertEq(amount, out, "event amount");
        }
    }

    /// @dev No fees earned: a non-pool destToken needs no swap, so there is nothing to convert and no revert.
    function test_harvest_destTokenNoSwaps_noFees_succeeds() public {
        (uint256 tokenId,) = _aliceMints();
        assertEq(_harvest(alice, _harvestParams(tokenId, ARB, new SwapParams[](0))), 0);
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice);
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
