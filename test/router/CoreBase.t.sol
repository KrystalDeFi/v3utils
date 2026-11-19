// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V3UtilsRouter} from "../../src/router/V3UtilsRouter.sol";
import {IRouterErrors} from "../../src/router/IRouterErrors.sol";
import {
    FeeType,
    AutoAction,
    InputTokenParams,
    SwapParams,
    AdjustRangeParams,
    MintParams
} from "../../src/router/RouterTypes.sol";
import {StructHash} from "../../src/StructHash.sol";
import {CoreHarness, MockGauge, MockCustodyFarm} from "./mocks/CoreHarness.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {
    MockToken,
    MockFeeOnTransferToken,
    MockNoZeroApproveToken,
    MockWETH,
    MockEnshrinedNative
} from "./mocks/MockERC20.sol";
import {MockERC721} from "./mocks/MockModule.sol";

contract CoreBaseTest is Test {
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event TakeFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, IRouterErrors.TakeFeesEventData data
    );

    uint64 constant PROTOCOL_CAP = 5534023222112865280;
    uint64 constant GAS_CAP = 5534023222112865280;
    uint64 constant QUARTER_X64 = 2 ** 62;

    V3UtilsRouter router;
    CoreHarness harness;
    MockSwapRouter swapper;
    MockWETH weth;
    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;

    address deployer = makeAddr("coreDeployer");
    address admin = makeAddr("coreAdmin");
    address operator = makeAddr("coreOperator");
    address withdrawer = makeAddr("coreWithdrawer");
    address feeTaker = makeAddr("coreFeeTaker");
    address alice;
    uint256 aliceKey;
    address bob = makeAddr("coreBob");

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("coreAlice");
        harness = new CoreHarness();
        swapper = new MockSwapRouter();
        weth = new MockWETH();
        tokenA = new MockToken("A", 18);
        tokenB = new MockToken("B", 18);
        tokenC = new MockToken("C", 6);
        router = _deployRouter(address(weth), 0);
        tokenB.mint(address(swapper), 1e30);
        tokenC.mint(address(swapper), 1e30);
        vm.deal(alice, 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _deployRouter(address weth_, uint8 mode) internal returns (V3UtilsRouter r) {
        vm.prank(deployer, deployer);
        r = new V3UtilsRouter();
        vm.prank(deployer, deployer);
        r.initialize(admin, operator, withdrawer, address(swapper), feeTaker, weth_, mode);
        bytes4[10] memory sels = [
            CoreHarness.flow.selector,
            CoreHarness.receiveAndClose.selector,
            CoreHarness.heldOf.selector,
            CoreHarness.trackedOf.selector,
            CoreHarness.takeFees.selector,
            CoreHarness.takeAndPutBack.selector,
            CoreHarness.adjustRange.selector,
            CoreHarness.adapterOf.selector,
            CoreHarness.farmOf.selector,
            CoreHarness.delegateTo.selector
        ];
        vm.startPrank(admin);
        for (uint256 i; i < sels.length; i++) {
            r.setModule(sels[i], address(harness));
        }
        r.setAutoSelector(uint8(AutoAction.AUTO_ADJUST), CoreHarness.adjustRange.selector);
        vm.stopPrank();
    }

    function _addrs(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _inputs() internal pure returns (InputTokenParams[] memory r) {
        r = new InputTokenParams[](0);
    }

    function _inputs(address t, uint256 amt) internal pure returns (InputTokenParams[] memory r) {
        r = new InputTokenParams[](1);
        r[0] = InputTokenParams(t, amt);
    }

    function _inputs(address t0, uint256 a0, address t1, uint256 a1)
        internal
        pure
        returns (InputTokenParams[] memory r)
    {
        r = new InputTokenParams[](2);
        r[0] = InputTokenParams(t0, a0);
        r[1] = InputTokenParams(t1, a1);
    }

    function _swaps() internal pure returns (SwapParams[] memory r) {
        r = new SwapParams[](0);
    }

    function _swaps(SwapParams memory s0) internal pure returns (SwapParams[] memory r) {
        r = new SwapParams[](1);
        r[0] = s0;
    }

    function _swaps(SwapParams memory s0, SwapParams memory s1) internal pure returns (SwapParams[] memory r) {
        r = new SwapParams[](2);
        r[0] = s0;
        r[1] = s1;
    }

    /// @dev A step through MockSwapRouter.swap: pulls the full (exact) allowance and pays `payout` of `tokenOut`.
    function _step(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, uint256 payout)
        internal
        pure
        returns (SwapParams memory)
    {
        return SwapParams(
            tokenIn, amountIn, tokenOut, minOut, abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, payout))
        );
    }

    function _flow(
        V3UtilsRouter r,
        address caller,
        uint256 value,
        address[] memory candidates,
        InputTokenParams[] memory inputs,
        SwapParams[] memory swaps
    ) internal returns (address[] memory tokens, uint256[] memory held) {
        vm.prank(caller);
        bytes memory ret = r.execute{value: value}(abi.encodeCall(CoreHarness.flow, (candidates, inputs, swaps)));
        (tokens, held) = abi.decode(ret, (address[], uint256[]));
    }

    function _approve(MockToken t, address owner, uint256 amount) internal {
        t.mint(owner, amount);
        vm.prank(owner);
        t.approve(address(router), amount);
    }

    // ------------------------------------------------------------------ ledger

    function test_ledger_heldIsDeltaOnly() public {
        tokenA.mint(address(router), 7);
        _approve(tokenA, alice, 5);

        vm.prank(alice);
        bytes memory ret = router.execute(
            abi.encodeCall(CoreHarness.receiveAndClose, (_addrs(address(tokenA)), address(tokenA), alice, 5, bob))
        );
        assertEq(abi.decode(ret, (uint256)), 5, "held is the call's delta");
        assertEq(tokenA.balanceOf(bob), 5, "close sends the delta");
        assertEq(tokenA.balanceOf(address(router)), 7, "pre-existing balance stays");
    }

    function test_ledger_openDedupesAndSkipsCodeless_heldUntrackedReverts() public {
        address codeless = makeAddr("coreCodeless");
        address[] memory candidates = new address[](6);
        candidates[0] = address(tokenA);
        candidates[1] = address(tokenA);
        candidates[2] = address(0);
        candidates[3] = codeless;
        candidates[4] = address(tokenB);
        candidates[5] = address(0);
        bytes memory ret = router.execute(abi.encodeCall(CoreHarness.trackedOf, (candidates)));
        address[] memory tracked = abi.decode(ret, (address[]));
        assertEq(tracked.length, 3);
        assertEq(tracked[0], address(tokenA));
        assertEq(tracked[1], address(0));
        assertEq(tracked[2], address(tokenB));

        vm.expectRevert(IRouterErrors.NotTracked.selector);
        router.execute(abi.encodeCall(CoreHarness.heldOf, (_addrs(address(tokenA)), address(tokenB))));
        vm.expectRevert(IRouterErrors.NotTracked.selector);
        router.execute(abi.encodeCall(CoreHarness.heldOf, (_addrs(address(tokenA)), codeless)));
    }

    /// Review Focus 1.
    function test_preexistingBalances_untouched() public {
        tokenA.mint(address(router), 7);
        vm.deal(address(router), 3 ether);
        _approve(tokenA, alice, 5);

        address[] memory candidates = _addrs(address(tokenA), address(tokenB), address(0));
        (, uint256[] memory held) = _flow(
            router,
            alice,
            0,
            candidates,
            _inputs(address(tokenA), 5),
            _swaps(_step(address(tokenA), 0, address(tokenB), 10, 10))
        );
        assertEq(held[0], 0, "A held after swap");
        assertEq(held[1], 10, "B held after swap");
        assertEq(held[2], 0, "native held");
        assertEq(tokenA.balanceOf(address(swapper)), 5, "swap consumed only the call's A");
        assertEq(tokenB.balanceOf(alice), 10, "close returned the call's B");
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(alice.balance, 10 ether, "no native swept to the caller");
        assertEq(tokenA.balanceOf(address(router)), 7, "router A unchanged");
        assertEq(address(router).balance, 3 ether, "router native unchanged");
        assertEq(tokenB.balanceOf(address(router)), 0);

        // an explicit amountIn above what the call holds would dip into the router's own A
        _approve(tokenA, alice, 5);
        SwapParams[] memory greedy = _swaps(_step(address(tokenA), 6, address(tokenB), 0, 10));
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.AmountError.selector);
        router.execute(abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(tokenA), 5), greedy)));

        // a native step above the call's native likewise
        greedy = _swaps(_step(address(0), 1 ether, address(tokenB), 0, 10));
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.AmountError.selector);
        router.execute{value: 0.5 ether}(
            abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(0), 0.5 ether), greedy))
        );
    }

    // ------------------------------------------------------------------ inputs

    /// Review Focus 3.
    function test_feeOnTransferInput_reverts() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken(100); // 1%
        fot.mint(alice, 100 ether);
        vm.prank(alice);
        fot.approve(address(router), 100 ether);

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.TransferError.selector);
        router.execute(
            abi.encodeCall(CoreHarness.flow, (_addrs(address(fot)), _inputs(address(fot), 100 ether), _swaps()))
        );
    }

    /// Review Focus 4.
    function test_msgValueMismatch_reverts() public {
        address[] memory candidates = _addrs(address(0));
        bytes memory noNative = abi.encodeCall(CoreHarness.flow, (candidates, _inputs(), _swaps()));
        bytes memory oneEther = abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(0), 1 ether), _swaps()));

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.AmountError.selector);
        router.execute{value: 1 ether}(noNative);

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.AmountError.selector);
        router.execute{value: 2 ether}(oneEther);

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.AmountError.selector);
        router.execute{value: 0}(oneEther);
    }

    /// Review Focus 4.
    function test_unusedNative_refunded() public {
        vm.deal(address(router), 2 ether); // stray native is not part of the refund
        (, uint256[] memory held) = _flow(
            router,
            alice,
            1 ether,
            _addrs(address(0), address(tokenB)),
            _inputs(address(0), 1 ether),
            _swaps(_step(address(0), 0.4 ether, address(tokenB), 10, 10))
        );
        assertEq(held[0], 0.6 ether);
        assertEq(address(swapper).balance, 0.4 ether, "swap got exactly amountIn as value");
        assertEq(alice.balance, 9.6 ether, "unused 0.6 refunded");
        assertEq(tokenB.balanceOf(alice), 10);
        assertEq(address(router).balance, 2 ether);
    }

    /// Review Focus 5.
    function test_duplicateInputOrSelfSwap_reverts() public {
        _approve(tokenA, alice, 2);
        address[] memory candidates = _addrs(address(tokenA), address(0));

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.SameToken.selector);
        router.execute(
            abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(tokenA), 1, address(tokenA), 1), _swaps()))
        );

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.SameToken.selector);
        router.execute{value: 2}(
            abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(0), 1, address(0), 1), _swaps()))
        );

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.SameToken.selector);
        router.execute(
            abi.encodeCall(
                CoreHarness.flow,
                (candidates, _inputs(address(tokenA), 2), _swaps(_step(address(tokenA), 0, address(tokenA), 0, 0)))
            )
        );
    }

    // ------------------------------------------------------------------ fees

    /// @dev Calldata for alice bringing 100 A, 40 B and 4 ether, with fees taken on those amounts (funds her first).
    function _feeData(uint64 feeX64, FeeType t) internal returns (bytes memory) {
        _approve(tokenA, alice, 100);
        _approve(tokenB, alice, 40);
        address[] memory tokens = _addrs(address(tokenA), address(tokenB), address(0));
        InputTokenParams[] memory inputs = new InputTokenParams[](3);
        inputs[0] = InputTokenParams(address(tokenA), 100);
        inputs[1] = InputTokenParams(address(tokenB), 40);
        inputs[2] = InputTokenParams(address(0), 4 ether);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100;
        amounts[1] = 40;
        amounts[2] = 4 ether;
        return abi.encodeCall(CoreHarness.takeFees, (tokens, inputs, tokens, amounts, feeX64, t));
    }

    function test_takeFees_capsAndEvent() public {
        address nfpm = harness.FEE_NFPM();
        vm.deal(alice, 100 ether);

        bytes memory data = _feeData(PROTOCOL_CAP + 1, FeeType.PROTOCOL_FEE);
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.TooMuchFee.selector);
        router.execute{value: 4 ether}(data);
        data = _feeData(GAS_CAP + 1, FeeType.GAS_FEE);
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.TooMuchFee.selector);
        router.execute{value: 4 ether}(data);

        data = _feeData(QUARTER_X64, FeeType.PROTOCOL_FEE);
        vm.recordLogs();
        vm.prank(alice);
        uint256[] memory taken = abi.decode(router.execute{value: 4 ether}(data), (uint256[]));
        assertEq(taken[0], 25);
        assertEq(taken[1], 10);
        assertEq(taken[2], 1 ether);
        assertEq(tokenA.balanceOf(feeTaker), 25);
        assertEq(tokenB.balanceOf(feeTaker), 10);
        assertEq(feeTaker.balance, 1 ether);
        assertEq(tokenA.balanceOf(alice), 75 + 200, "rest closed to alice (plus the two reverted approvals' mints)");
        assertEq(alice.balance, 100 ether - 1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != TakeFees.selector) continue;
            found++;
            assertEq(logs[i].emitter, address(router));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(nfpm))));
            assertEq(uint256(logs[i].topics[2]), harness.FEE_TOKEN_ID());
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(alice))));
            IRouterErrors.TakeFeesEventData memory d = abi.decode(logs[i].data, (IRouterErrors.TakeFeesEventData));
            assertEq(d.feeTokens.length, 3);
            assertEq(d.feeTokens[0].token, address(tokenA));
            assertEq(d.feeTokens[0].amount, 25);
            assertEq(d.feeTokens[1].token, address(tokenB));
            assertEq(d.feeTokens[1].amount, 10);
            assertEq(d.feeTokens[2].token, address(0));
            assertEq(d.feeTokens[2].amount, 1 ether);
            assertEq(d.feeX64, QUARTER_X64);
            assertEq(uint8(d.feeType), uint8(FeeType.PROTOCOL_FEE));
        }
        assertEq(found, 1, "one TakeFees");

        // fee 0: nothing moves, nothing is emitted
        address[] memory tokens = _addrs(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.recordLogs();
        bytes memory ret = router.execute(
            abi.encodeCall(CoreHarness.takeFees, (tokens, _inputs(), tokens, amounts, 0, FeeType.PROTOCOL_FEE))
        );
        taken = abi.decode(ret, (uint256[]));
        assertEq(taken.length, 1);
        assertEq(taken[0], 0);
        assertEq(vm.getRecordedLogs().length, 0, "fee 0 emits nothing");
        assertEq(tokenA.balanceOf(feeTaker), 25);
    }

    /// Fees are scoped to the ledger: a fee larger than what the call holds can not dip into the router's balance.
    function test_takeFees_cannotSpendPreexisting() public {
        tokenA.mint(address(router), 1000);
        _approve(tokenA, alice, 10);
        address[] memory tokens = _addrs(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100; // claims 100, the call holds 10: a 25% fee (25) needs more than the call has

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.AmountError.selector);
        router.execute(
            abi.encodeCall(
                CoreHarness.takeFees,
                (tokens, _inputs(address(tokenA), 10), tokens, amounts, QUARTER_X64, FeeType.PROTOCOL_FEE)
            )
        );
        assertEq(tokenA.balanceOf(address(router)), 1000, "router A unchanged");
        assertEq(tokenA.balanceOf(feeTaker), 0);

        // a fee token outside the ledger
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.NotTracked.selector);
        router.execute(
            abi.encodeCall(
                CoreHarness.takeFees,
                (tokens, _inputs(address(tokenA), 10), _addrs(address(tokenB)), amounts, QUARTER_X64, FeeType.GAS_FEE)
            )
        );

        // the same fee within what the call holds goes through
        amounts[0] = 10;
        vm.prank(alice);
        router.execute(
            abi.encodeCall(
                CoreHarness.takeFees,
                (tokens, _inputs(address(tokenA), 10), tokens, amounts, QUARTER_X64, FeeType.PROTOCOL_FEE)
            )
        );
        assertEq(tokenA.balanceOf(feeTaker), 2);
        assertEq(tokenA.balanceOf(alice), 8);
        assertEq(tokenA.balanceOf(address(router)), 1000, "router A unchanged");
    }

    // ------------------------------------------------------------------ swaps

    function test_swaps_sequenceMultiHop_andSlippage() public {
        _approve(tokenA, alice, 100);
        address[] memory candidates = _addrs(address(tokenA), address(tokenB), address(tokenC));

        vm.expectEmit(true, true, false, true, address(router));
        emit Swap(address(tokenA), address(tokenB), 100, 50);
        vm.expectEmit(true, true, false, true, address(router));
        emit Swap(address(tokenB), address(tokenC), 50, 20);
        (, uint256[] memory held) = _flow(
            router,
            alice,
            0,
            candidates,
            _inputs(address(tokenA), 100),
            _swaps(
                _step(address(tokenA), 0, address(tokenB), 50, 50), _step(address(tokenB), 0, address(tokenC), 20, 20)
            )
        );
        assertEq(held[0], 0);
        assertEq(held[1], 0);
        assertEq(held[2], 20);
        assertEq(tokenC.balanceOf(alice), 20, "ends with C only");
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(tokenB.balanceOf(alice), 0);

        _approve(tokenA, alice, 100);
        SwapParams[] memory s = _swaps(
            _step(address(tokenA), 0, address(tokenB), 50, 50), _step(address(tokenB), 0, address(tokenC), 21, 20)
        );
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.SwapSlippage.selector);
        router.execute(abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(tokenA), 100), s)));
    }

    function test_swaps_exactApprovalReset_andFailures() public {
        address[] memory candidates = _addrs(address(tokenA), address(tokenB));

        // the router approves exactly amountIn and resets to 0; what the swap did not take returns to the caller
        _approve(tokenA, alice, 100);
        SwapParams memory partial_ = SwapParams(
            address(tokenA),
            80,
            address(tokenB),
            0,
            abi.encodeCall(MockSwapRouter.swapExact, (address(tokenA), 30, address(tokenB), 9))
        );
        vm.expectEmit(true, true, false, true, address(router));
        emit Swap(address(tokenA), address(tokenB), 30, 9);
        _flow(router, alice, 0, candidates, _inputs(address(tokenA), 100), _swaps(partial_));
        assertEq(tokenA.allowance(address(router), address(swapper)), 0, "allowance reset");
        assertEq(tokenA.balanceOf(alice), 70);
        assertEq(tokenB.balanceOf(alice), 9);

        // pulling more than amountIn fails: the approval is exact
        _approve(tokenA, alice, 100);
        bytes memory greedyData = abi.encodeCall(MockSwapRouter.swapGreedy, (address(tokenA), 81));
        SwapParams memory greedy = SwapParams(address(tokenA), 80, address(tokenB), 0, greedyData);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRouterErrors.SwapFailed.selector, greedyData, 0));
        router.execute(abi.encodeCall(CoreHarness.flow, (candidates, _inputs(address(tokenA), 100), _swaps(greedy))));

        // a failing call reports its index
        bytes memory failData = abi.encodeCall(MockSwapRouter.fail, ());
        SwapParams memory failing = SwapParams(address(tokenB), 0, address(tokenA), 0, failData);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRouterErrors.SwapFailed.selector, failData, 1));
        router.execute(
            abi.encodeCall(
                CoreHarness.flow,
                (
                    candidates,
                    _inputs(address(tokenA), 100),
                    _swaps(_step(address(tokenA), 0, address(tokenB), 0, 5), failing)
                )
            )
        );

        // tokenOut must be tracked, or its output would be stranded in the router
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.NotTracked.selector);
        router.execute(
            abi.encodeCall(
                CoreHarness.flow,
                (candidates, _inputs(address(tokenA), 100), _swaps(_step(address(tokenA), 0, address(tokenC), 0, 5)))
            )
        );

        // a token that reverts on approve(0) still swaps
        MockNoZeroApproveToken nza = new MockNoZeroApproveToken();
        nza.mint(alice, 10);
        vm.prank(alice);
        nza.approve(address(router), 10);
        _flow(
            router,
            alice,
            0,
            _addrs(address(nza), address(tokenB)),
            _inputs(address(nza), 10),
            _swaps(_step(address(nza), 0, address(tokenB), 3, 3))
        );
        assertEq(nza.balanceOf(address(swapper)), 10);
        assertEq(tokenB.balanceOf(alice), 9 + 3);

        // no swap router configured
        vm.prank(admin);
        router.setSwapRouter(address(0));
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.ZeroSwapRouter.selector);
        router.execute(
            abi.encodeCall(
                CoreHarness.flow,
                (candidates, _inputs(address(tokenA), 100), _swaps(_step(address(tokenA), 0, address(tokenB), 0, 5)))
            )
        );
    }

    function test_swaps_nativeConversion_wrappedAndEnshrined() public {
        bytes memory failData = abi.encodeCall(MockSwapRouter.fail, ());

        // WRAPPED: native -> weth and weth -> native move 1:1 through deposit/withdraw; swapData is never called
        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(address(router), 1 ether));
        vm.deal(address(router), 2 ether);
        SwapParams memory wrap = SwapParams(address(0), 0.4 ether, address(weth), 0.4 ether, failData);
        SwapParams memory unwrap = SwapParams(address(weth), 0.1 ether, address(0), 0.1 ether, failData);
        vm.expectEmit(true, true, false, true, address(router));
        emit Swap(address(0), address(weth), 0.4 ether, 0.4 ether);
        vm.expectEmit(true, true, false, true, address(router));
        emit Swap(address(weth), address(0), 0.1 ether, 0.1 ether);
        (, uint256[] memory held) = _flow(
            router,
            alice,
            1 ether,
            _addrs(address(0), address(weth)),
            _inputs(address(0), 1 ether),
            _swaps(wrap, unwrap)
        );
        assertEq(held[0], 0.7 ether);
        assertEq(held[1], 0.3 ether);
        // a native payer's held weth comes back as native
        assertEq(alice.balance, 10 ether);
        assertEq(weth.balanceOf(alice), 0);
        assertEq(address(router).balance, 2 ether, "router native unchanged");
        assertEq(weth.balanceOf(address(router)), 1 ether, "router weth unchanged");

        // ENSHRINED (6-decimal view): conversions are unit arithmetic on one balance; swapData is never called
        MockEnshrinedNative usdc = new MockEnshrinedNative(6);
        V3UtilsRouter arc = _deployRouter(address(usdc), 1);
        vm.deal(address(arc), 5 ether);
        uint256 aliceBefore = alice.balance;
        SwapParams memory toToken = SwapParams(address(0), 0, address(usdc), 1e6, failData);
        SwapParams memory toNative = SwapParams(address(usdc), 0, address(0), 1 ether, failData);
        vm.expectEmit(true, true, false, true, address(arc));
        emit Swap(address(0), address(usdc), 1 ether, 1e6);
        vm.expectEmit(true, true, false, true, address(arc));
        emit Swap(address(usdc), address(0), 1e6, 1 ether);
        (, held) = _flow(
            arc,
            alice,
            1 ether,
            _addrs(address(0), address(usdc)),
            _inputs(address(0), 1 ether),
            _swaps(toToken, toNative)
        );
        // both views report the call's one ether; close pays it once
        assertEq(held[0], 1 ether);
        assertEq(held[1], 1e6);
        assertEq(alice.balance, aliceBefore, "the call's ether returned once");
        assertEq(address(arc).balance, 5 ether, "pre-existing native unchanged, no double pay");
    }

    /// An aggregator step whose output is native pays the router mid-flow (the router accepts native from anyone while
    /// a flow runs); the ledger credits only that to the caller. Outside a flow the same sender is still refused, and
    /// the router's own native is untouched either way.
    function test_swaps_nativeOutputFromSwapRouter() public {
        vm.deal(address(swapper), 5 ether);
        vm.deal(address(router), 2 ether);
        _approve(tokenA, alice, 100);
        uint256 aliceBefore = alice.balance;
        SwapParams memory s = SwapParams(
            address(tokenA),
            0,
            address(0),
            1 ether,
            abi.encodeCall(MockSwapRouter.swapToNative, (address(tokenA), 1 ether))
        );
        vm.expectEmit(true, true, false, true, address(router));
        emit Swap(address(tokenA), address(0), 100, 1 ether);
        (, uint256[] memory held) =
            _flow(router, alice, 0, _addrs(address(tokenA), address(0)), _inputs(address(tokenA), 100), _swaps(s));
        assertEq(held[0], 0, "tokenA all swapped");
        assertEq(held[1], 1 ether, "native output held by the call");
        assertEq(alice.balance, aliceBefore + 1 ether, "the user receives the native output");
        assertEq(address(router).balance, 2 ether, "router native unchanged");
        assertEq(tokenA.balanceOf(address(swapper)), 100);

        // outside a flow, the swap router (not weth) cannot send native
        vm.prank(address(swapper));
        (bool sent, bytes memory ret) = address(router).call{value: 1}("");
        assertFalse(sent);
        assertEq(ret, abi.encodeWithSelector(IRouterErrors.UnexpectedNative.selector));
    }

    /// ENSHRINED: `weth`'s start is the pre-existing native rounded UP to `weth` units, so `held(weth) * scale` never
    /// exceeds the call's own native. Router dust P = scale - 1 wei, msg.value = 2 * scale, and the call spends 1 wei:
    /// with `weth` closed first, a floor-rounded start would pay 2 * scale through `weth` (1 wei of it the router's
    /// dust). The ceil start pays scale through `weth` and the remaining scale - 1 as native.
    function test_enshrined_dustNeverReleased_wethFirstClose() public {
        MockEnshrinedNative usdc = new MockEnshrinedNative(6);
        uint256 scale = 1e12;
        V3UtilsRouter arc = _deployRouter(address(usdc), 1);
        vm.deal(address(arc), scale - 1);
        address[] memory candidates = _addrs(address(usdc), address(0), address(tokenB));

        // nothing spent: the call's 2 * scale comes back, the dust stays
        uint256 aliceBefore = alice.balance;
        (, uint256[] memory held) = _flow(arc, alice, 2 * scale, candidates, _inputs(address(0), 2 * scale), _swaps());
        assertEq(held[0], 1, "held(weth): one whole unit not shared with the dust; the rest pays as native");
        assertEq(alice.balance, aliceBefore, "call's native returned");
        assertEq(address(arc).balance, scale - 1, "dust unchanged");

        // 1 wei spent: only 2 * scale - 1 may come back
        (, held) = _flow(
            arc,
            alice,
            2 * scale,
            candidates,
            _inputs(address(0), 2 * scale),
            _swaps(_step(address(0), 1, address(tokenB), 0, 0))
        );
        assertEq(held[0], 1, "held(weth) * scale <= the call's own native");
        assertEq(alice.balance, aliceBefore - 1, "the call's remaining native returned, no more");
        assertEq(address(arc).balance, scale - 1, "dust never released");
    }

    /// A registered NFPM answers ERC20 `approve`, so it can never be a ledger token (and so never a swap leg).
    function test_open_rejectsRegisteredNfpm() public {
        MockERC721 nfpm = new MockERC721();
        nfpm.mint(alice, 9);
        router.execute(abi.encodeCall(CoreHarness.trackedOf, (_addrs(address(nfpm)))));
        vm.prank(admin);
        router.setAdapter(address(nfpm), address(harness));

        vm.expectRevert(IRouterErrors.InvalidToken.selector);
        router.execute(abi.encodeCall(CoreHarness.trackedOf, (_addrs(address(tokenA), address(nfpm)))));

        // a swap step naming it as tokenIn (with amountIn = its tokenId) is rejected before any approve
        SwapParams memory s = _step(address(nfpm), 9, address(tokenB), 0, 0);
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.InvalidToken.selector);
        router.execute(abi.encodeCall(CoreHarness.flow, (_addrs(address(nfpm), address(tokenB)), _inputs(), _swaps(s))));
        assertEq(nfpm.getApproved(9), address(0));
    }

    /// Native is tracked whenever the call brings value, even when the flow forgot to list it.
    function test_open_addsNativeWhenValueSent() public {
        vm.deal(address(router), 3 ether);
        (address[] memory tokens, uint256[] memory held) =
            _flow(router, alice, 1 ether, _addrs(address(tokenA)), _inputs(address(0), 1 ether), _swaps());
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(tokenA));
        assertEq(tokens[1], address(0));
        assertEq(held[1], 1 ether);
        assertEq(alice.balance, 10 ether, "value refunded");
        assertEq(address(router).balance, 3 ether);

        // without value, native is not added
        (tokens,) = _flow(router, alice, 0, _addrs(address(tokenA)), _inputs(), _swaps());
        assertEq(tokens.length, 1);
    }

    /// WRAPPED, native payer: `_close` unwraps exactly the call's held weth and pays it, with the call's native, as
    /// native. The router's own weth and native stay put.
    function test_close_nativePayer_wethReturnedAsNative() public {
        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(address(router), 1 ether));
        vm.deal(address(router), 2 ether);
        SwapParams memory wrap = _step(address(0), 0.4 ether, address(weth), 0, 0);

        (, uint256[] memory held) =
            _flow(router, alice, 1 ether, _addrs(address(0), address(weth)), _inputs(address(0), 1 ether), _swaps(wrap));
        assertEq(held[0], 0.6 ether, "held native before close");
        assertEq(held[1], 0.4 ether, "held weth before close");
        assertEq(alice.balance, 10 ether, "all of the call's value back as native");
        assertEq(weth.balanceOf(alice), 0, "no weth to a native payer");
        assertEq(weth.balanceOf(address(router)), 1 ether, "router weth unchanged");
        assertEq(address(router).balance, 2 ether, "router native unchanged");
    }

    /// WRAPPED, no value: the call's weth comes back as weth; the router's own weth and native stay put.
    function test_close_noValue_wethStaysWeth() public {
        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(address(router), 1 ether));
        vm.deal(address(router), 2 ether);
        vm.prank(alice);
        weth.deposit{value: 0.5 ether}();
        vm.prank(alice);
        weth.approve(address(router), 0.5 ether);

        _flow(router, alice, 0, _addrs(address(0), address(weth)), _inputs(address(weth), 0.5 ether), _swaps());
        assertEq(weth.balanceOf(alice), 0.5 ether, "weth back as weth");
        assertEq(alice.balance, 9.5 ether, "no native to a non-native payer");
        assertEq(weth.balanceOf(address(router)), 1 ether, "router weth unchanged");
        assertEq(address(router).balance, 2 ether, "router native unchanged");
    }

    // ------------------------------------------------------------------ custody

    function test_take_wallet_and_notHolder() public {
        MockERC721 nfpm = new MockERC721();
        nfpm.mint(alice, 1);
        vm.prank(alice);
        nfpm.setApprovalForAll(address(router), true);

        vm.prank(alice);
        bytes memory ret = router.execute(abi.encodeCall(CoreHarness.takeAndPutBack, (address(nfpm), 1)));
        (bool staked, address heldBy) = abi.decode(ret, (bool, address));
        assertFalse(staked);
        assertEq(heldBy, address(router), "taken into the router");
        assertEq(nfpm.ownerOf(1), alice, "put back to the wallet");

        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(CoreHarness.takeAndPutBack, (address(nfpm), 1)));

        // with a farm registered that does not have it staked by bob, still not bob's
        MockGauge gauge = new MockGauge();
        address farm = address(new MockCustodyFarm(gauge, true));
        vm.prank(admin);
        router.setFarm(address(nfpm), farm);
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(CoreHarness.takeAndPutBack, (address(nfpm), 1)));
    }

    function test_take_staked_unstakesAndRestakes() public {
        MockERC721 nfpm = new MockERC721();
        MockGauge gauge = new MockGauge();
        nfpm.mint(alice, 2);
        vm.startPrank(alice);
        nfpm.approve(address(gauge), 2);
        gauge.deposit(address(nfpm), 2, alice);
        vm.stopPrank();
        address farm = address(new MockCustodyFarm(gauge, true));
        vm.prank(admin);
        router.setFarm(address(nfpm), farm);

        vm.prank(alice);
        bytes memory ret = router.execute(abi.encodeCall(CoreHarness.takeAndPutBack, (address(nfpm), 2)));
        (bool staked, address heldBy) = abi.decode(ret, (bool, address));
        assertTrue(staked);
        assertEq(heldBy, address(router), "unstaked into the router");
        assertEq(nfpm.ownerOf(2), address(gauge), "restaked");
        assertEq(gauge.stakedBy(address(nfpm), 2), alice, "restaked for alice");

        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(CoreHarness.takeAndPutBack, (address(nfpm), 2)));
    }

    function test_take_stakedFarmCannotUnstake_reverts() public {
        MockERC721 nfpm = new MockERC721();
        MockGauge gauge = new MockGauge();
        nfpm.mint(alice, 3);
        vm.startPrank(alice);
        nfpm.approve(address(gauge), 3);
        gauge.deposit(address(nfpm), 3, alice);
        vm.stopPrank();
        address farm = address(new MockCustodyFarm(gauge, false));
        vm.prank(admin);
        router.setFarm(address(nfpm), farm);

        vm.prank(alice);
        vm.expectRevert(IRouterErrors.FarmUnsupported.selector);
        router.execute(abi.encodeCall(CoreHarness.takeAndPutBack, (address(nfpm), 3)));
    }

    // ------------------------------------------------------------------ account, registries, delegate

    function test_account_userAndAutomation() public {
        MockERC721 nfpm = new MockERC721();
        nfpm.mint(alice, 5);
        vm.prank(admin);
        router.setAdapter(address(nfpm), address(harness));

        AdjustRangeParams memory p;
        p.nfpm = address(nfpm);
        p.tokenId = 5;

        // user path: msg.sender, whatever the params name
        vm.prank(bob);
        bytes memory ret = router.execute(abi.encodeCall(CoreHarness.adjustRange, (p)));
        assertEq(abi.decode(ret, (address)), bob);

        // automation: the recorded account, only for the recorded target
        StructHash.Order memory o;
        o.chainId = int64(int256(block.chainid));
        o.nfpmAddress = address(nfpm);
        o.tokenId = 5;
        o.orderType = "ORDER_TYPE_REBALANCE";
        bytes memory order = abi.encode(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, router.hashOrder(order));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(operator);
        ret =
            router.executeAutomation(alice, address(nfpm), 5, uint8(AutoAction.AUTO_ADJUST), abi.encode(p), order, sig);
        assertEq(abi.decode(ret, (address)), alice);

        p.tokenId = 6;
        vm.prank(operator);
        vm.expectRevert(IRouterErrors.NotAutomation.selector);
        router.executeAutomation(alice, address(nfpm), 5, uint8(AutoAction.AUTO_ADJUST), abi.encode(p), order, sig);

        p.tokenId = 5;
        p.nfpm = address(tokenA);
        vm.prank(operator);
        vm.expectRevert(IRouterErrors.NotAutomation.selector);
        router.executeAutomation(alice, address(nfpm), 5, uint8(AutoAction.AUTO_ADJUST), abi.encode(p), order, sig);
    }

    function test_adapterFarmDelegate() public {
        address nfpm = makeAddr("coreRegNfpm");
        vm.expectRevert(IRouterErrors.UnsupportedNfpm.selector);
        router.execute(abi.encodeCall(CoreHarness.adapterOf, (nfpm)));
        bytes memory ret = router.execute(abi.encodeCall(CoreHarness.farmOf, (nfpm)));
        assertEq(abi.decode(ret, (address)), address(0), "farm may be zero");

        vm.startPrank(admin);
        router.setAdapter(nfpm, address(harness));
        router.setFarm(nfpm, address(swapper));
        vm.stopPrank();
        ret = router.execute(abi.encodeCall(CoreHarness.adapterOf, (nfpm)));
        assertEq(abi.decode(ret, (address)), address(harness));
        ret = router.execute(abi.encodeCall(CoreHarness.farmOf, (nfpm)));
        assertEq(abi.decode(ret, (address)), address(swapper));

        // reverts bubble unchanged
        vm.expectRevert(MockSwapRouter.Rejected.selector);
        router.execute(
            abi.encodeCall(CoreHarness.delegateTo, (address(swapper), abi.encodeCall(MockSwapRouter.fail, ())))
        );
    }

    function test_onlyDelegateCall() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        harness.trackedOf(_addrs(address(tokenA)));
    }
}
