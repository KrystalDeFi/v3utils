// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "../../src/StructHash.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Calls the internal StructHash overload so the test can compare it with the deployed library.
contract StructHashHarness {
    function hashOrder(bytes memory encoded) external pure returns (bytes32) {
        return StructHash._hash(abi.decode(encoded, (StructHash.Order)));
    }
}

interface ICLPoolAuto {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

/// @dev Not a gauge of the factory, but claims every account stakes every token.
contract FakeGaugeAlwaysStaked {
    function stakedContains(address, uint256) external pure returns (bool) {
        return true;
    }

    function nft() external pure returns (address) {
        return address(0);
    }
}

abstract contract AutomationBase is AeroForkBase {
    uint256 internal userKey;
    address internal user;
    uint256 internal id;

    event FarmAction(
        address indexed user,
        address indexed gauge,
        uint256 indexed tokenId,
        uint256 newTokenId,
        IAeroFarmingLogic.Action action,
        bool automated
    );
    event CancelOrder(address user, bytes32 hash, bytes signature);

    function _mint(address gauge, address pool, address t0, address t1, int24 ts, uint256 a0, uint256 a1, int24 half)
        internal
        returns (int24 base)
    {
        (, int24 tick,,,,) = ICLPoolAuto(pool).slot0();
        base = (tick / ts) * ts;
        Common.SwapAndMintParams memory p;
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.token0 = IERC20(t0);
        p.token1 = IERC20(t1);
        p.tickSpacing = ts;
        p.tickLower = base - half * ts;
        p.tickUpper = base + half * ts;
        p.amount0 = a0;
        p.amount1 = a1;
        p.deadline = block.timestamp + 1 hours;
        p.recipient = user;
        vm.prank(user);
        id = _zapIn(gauge, p, false);
        (uint256 minStakeBlocks,) = ICLGaugeFactory(GAUGE_FACTORY).effectivePenaltyConfig(gauge);
        vm.roll(block.number + minStakeBlocks + 1000);
        vm.warp(block.timestamp + 2 * (minStakeBlocks + 1000));
    }

    function _order() internal view returns (bytes memory) {
        StructHash.Order memory o;
        o.chainId = int64(int256(block.chainid));
        o.nfpmAddress = NFPM;
        o.tokenId = id;
        o.orderType = "ORDER_TYPE_REBALANCE";
        o.signatureTime = int64(int256(block.timestamp));
        return abi.encode(o);
    }

    function _sign(uint256 key, bytes memory order) internal view returns (bytes memory) {
        bytes32 digest = router.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _params(IAeroFarmingLogic.AutoAction a, address gauge, bytes memory data, address account)
        internal
        view
        returns (OrderParams memory p)
    {
        p.action = a;
        p.account = account;
        p.gauge = gauge;
        p.tokenId = id;
        p.actionData = data;
        p.order = _order();
        p.signature = _sign(userKey, p.order);
    }

    function _farmActions(Vm.Log[] memory logs, uint256 tokenId, IAeroFarmingLogic.Action act, bool automated)
        internal
        view
        returns (uint256 found, uint256 newId)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != FarmAction.selector) continue;
            if (logs[i].topics[3] != bytes32(tokenId)) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            (uint256 n, IAeroFarmingLogic.Action a, bool au) =
                abi.decode(logs[i].data, (uint256, IAeroFarmingLogic.Action, bool));
            assertEq(uint8(a), uint8(act));
            assertEq(au, automated);
            newId = n;
            ++found;
        }
    }
}

contract AeroFarmingHelperAutomationTest is AutomationBase {
    int24 constant TS = 50;

    function setUp() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroOrderUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        _approveGauge(user, GAUGE_A_BASE, false);
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        vm.stopPrank();
        _mint(GAUGE_A_BASE, POOL_A_BASE, WETH, USDC_BASE, TS, 1 ether, 5000e6, 10);
    }

    function _liq() internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = INonfungiblePositionManager(NFPM).positions(id);
    }

    function _ins(uint128 liquidity) internal view returns (V3Utils.Instructions memory ins) {
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        ins.protocol = Nfpm.Protocol.AERODROME;
        ins.liquidity = liquidity;
        ins.deadline = block.timestamp + 1 hours;
    }

    function _rebalanceIns() internal view returns (V3Utils.Instructions memory ins) {
        (, int24 tick,,,,) = ICLPoolAuto(POOL_A_BASE).slot0();
        int24 base = (tick / TS) * TS;
        ins = _ins(_liq());
        ins.whatToDo = V3Utils.WhatToDo.CHANGE_RANGE;
        ins.tickLower = base - 5 * TS;
        ins.tickUpper = base + 5 * TS;
    }

    function _adjustParams() internal view returns (OrderParams memory) {
        return _params(IAeroFarmingLogic.AutoAction.AUTO_ADJUST, GAUGE_A_BASE, abi.encode(_rebalanceIns()), user);
    }

    function _assertClean() internal {
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20(USDC_BASE).balanceOf(address(router)), 0);
        assertEq(IERC20(AERO).balanceOf(address(router)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
    }

    function test_structHashParity_deployedLibMatchesSource() public {
        StructHashHarness h = new StructHashHarness();
        StructHash.Order memory o;
        o.chainId = 8453;
        o.nfpmAddress = NFPM;
        o.tokenId = 12345;
        o.orderType = "ORDER_TYPE_REBALANCE";
        o.signatureTime = 1700000000;
        o.config.rebalanceConfig.recurring = true;
        o.config.rebalanceConfig.autoCompound.action.maxGasProportionX64 = 7;
        bytes memory enc = abi.encode(o);
        bytes32 viaSource = h.hashOrder(enc);
        assertEq(IStructHash(STRUCT_HASH)._hash(enc), viaSource);
        assertTrue(viaSource != bytes32(0));
        // zero-filled order too
        StructHash.Order memory z;
        bytes memory encZ = abi.encode(z);
        assertEq(IStructHash(STRUCT_HASH)._hash(encZ), h.hashOrder(encZ));
    }

    function test_domainSeparator_usesRouterAddress() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AeroFarmingRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        assertEq(router.DOMAIN_SEPARATOR(), expected);
        bytes memory o = _order();
        assertEq(
            router.hashOrder(o), keccak256(abi.encodePacked("\x19\x01", expected, IStructHash(STRUCT_HASH)._hash(o)))
        );
    }

    function test_autoAdjust_validOrder() public {
        OrderParams memory p = _adjustParams();
        vm.recordLogs();
        vm.prank(operator);
        uint256 newId = _executeOrder(p);
        assertTrue(newId != id);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(newId), GAUGE_A_BASE);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertEq(_liq(), 0);
        _assertClean();
        (uint256 found, uint256 n) = _farmActions(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.REBALANCE, true);
        assertEq(found, 1);
        assertEq(n, newId);
    }

    function test_autoExit_validOrder() public {
        OrderParams memory p =
            _params(IAeroFarmingLogic.AutoAction.AUTO_EXIT, GAUGE_A_BASE, abi.encode(_ins(_liq())), user);
        vm.recordLogs();
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), 0);
        _assertClean();
        (uint256 found,) = _farmActions(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.EXIT, true);
        assertEq(found, 1);
    }

    function test_execute_nonOperatorReverts() public {
        OrderParams memory p = _adjustParams();
        bytes32 role = router.OPERATOR_ROLE();
        address caller = makeAddr("aeroNotOperator");
        vm.expectRevert(
            bytes(
                string.concat(
                    "AccessControl: account ",
                    Strings.toHexString(caller),
                    " is missing role ",
                    Strings.toHexString(uint256(role), 32)
                )
            )
        );
        vm.prank(caller);
        _executeOrder(p);
    }

    function test_execute_wrongSignerReverts() public {
        (, uint256 otherKey) = makeAddrAndKey("aeroOrderOther");
        OrderParams memory p = _adjustParams();
        p.signature = _sign(otherKey, p.order);
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.InvalidSignature.selector);
        _executeOrder(p);
    }

    function test_execute_signerNotStakeOwnerReverts() public {
        // account A has its own stake in the same gauge and signs a valid order for it
        uint256 victimId = id;
        address victim = user;
        (address other, uint256 otherKey) = makeAddrAndKey("aeroOrderOther");
        deal(WETH, other, 10 ether);
        deal(USDC_BASE, other, 50_000e6);
        _approveGauge(other, GAUGE_A_BASE, false);
        vm.startPrank(other);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        vm.stopPrank();
        user = other;
        _mint(GAUGE_A_BASE, POOL_A_BASE, WETH, USDC_BASE, TS, 1 ether, 5000e6, 10);
        uint256 otherId = id;
        user = victim;
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(other, otherId));
        bytes memory otherOrder = _order(); // references A's own tokenId
        bytes memory otherSig = _sign(otherKey, otherOrder);

        // the operator points A's order at the victim B's tokenId
        id = victimId;
        uint128 victimLiq = _liq();
        OrderParams memory p = _adjustParams();
        p.account = other;
        p.order = otherOrder;
        p.signature = otherSig;
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.NotStakeOwner.selector);
        _executeOrder(p);

        // B's position is untouched
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(victim, victimId));
        assertEq(IERC721(NFPM).ownerOf(victimId), GAUGE_A_BASE);
        assertEq(_liq(), victimLiq);

        // positive control: the same signed order does act on A's own stake
        id = otherId;
        p = _params(IAeroFarmingLogic.AutoAction.AUTO_EXIT, GAUGE_A_BASE, abi.encode(_ins(_liq())), other);
        p.order = otherOrder;
        p.signature = otherSig;
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC721(NFPM).ownerOf(otherId), other);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(victim, victimId));
    }

    function test_execute_cancelledReverts() public {
        OrderParams memory p = _adjustParams();
        bytes32 digest = router.hashOrder(p.order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertFalse(router.isOrderCancelled(user, digest));
        vm.expectEmit(address(router));
        emit CancelOrder(user, digest, sig);
        vm.prank(user);
        router.cancelOrder(digest, sig);
        assertTrue(router.isOrderCancelled(user, digest));
        assertFalse(router.isOrderCancelled(operator, digest));
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.OrderCancelled.selector);
        _executeOrder(p);
    }

    function test_cancelOrder_badSignatureReverts() public {
        bytes memory o = _order();
        bytes32 digest = router.hashOrder(o);
        (, uint256 otherKey) = makeAddrAndKey("aeroOrderOther");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidSignature.selector);
        router.cancelOrder(digest, sig);
    }

    function test_orderValidAcrossUpgrade() public {
        OrderParams memory p = _adjustParams();
        AeroFarmingLogic newLogic = new AeroFarmingLogic();
        vm.prank(admin);
        router.setImplementation(address(newLogic));
        vm.prank(operator);
        uint256 newId = _executeOrder(p);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
    }

    function test_execute_whenPausedReverts() public {
        OrderParams memory p = _adjustParams();
        vm.prank(pauser);
        router.pause();
        vm.prank(operator);
        vm.expectRevert(bytes("Pausable: paused"));
        _executeOrder(p);
    }

    function test_logic_directCallCannotAct() public {
        OrderParams memory p = _adjustParams(); // a valid order signed by the stake owner
        uint128 liq = _liq();
        // the logic has no roles, no order check and no recorded automation account of its own: a direct call
        // to its automated entry is rejected before anything else
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        vm.prank(operator);
        logic.executeAutomated(p.action, p.account, p.gauge, p.tokenId, p.actionData);

        // the logic has no initialize (no fallback either)
        bytes memory init = abi.encodeCall(
            AeroFarmingRouter.initialize,
            (operator, operator, operator, operator, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH)
        );
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(logic).call(init);
        assertFalse(ok);
        assertEq(ret.length, 0);

        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), liq);
    }

    function test_execute_invalidGaugeReverts() public {
        address fake = address(new FakeGaugeAlwaysStaked());
        OrderParams memory p = _adjustParams();
        p.gauge = fake;
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.InvalidGauge.selector);
        _executeOrder(p);
    }
}

contract AeroFarmingHelperAutoCompoundTest is AutomationBase {
    int24 constant TS = 200;

    function setUp() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroOrderCompoundUser");
        deal(AERO, user, 100_000 ether);
        deal(WETH, user, 100 ether);
        _approveGauge(user, GAUGE_B_BASE, true);
        vm.startPrank(user);
        IERC20(AERO).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();
        int24 base = _mint(GAUGE_B_BASE, POOL_B_BASE, AERO, WETH, TS, 10_000 ether, 10 ether, 10);
        // sell AERO until the tick is below the range so the claim can be added with no swap
        deal(AERO, address(this), 50_000_000 ether);
        ICLPoolAuto(POOL_B_BASE)
            .swap(address(this), true, int256(50_000_000 ether), TickMath.getSqrtRatioAtTick(base - 10 * TS - 100), "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes calldata) external {
        require(msg.sender == POOL_B_BASE);
        if (amount0Delta > 0) IERC20(AERO).transfer(msg.sender, uint256(amount0Delta));
    }

    function test_autoCompound_validOrder() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 claimed = ICLGauge(GAUGE_B_BASE).earned(user, ids);
        assertGt(claimed, 0);
        (,,,,,,, uint128 l0,,,,) = INonfungiblePositionManager(NFPM).positions(id);
        IAeroFarmingLogic.CompoundParams memory c;
        c.deadline = block.timestamp + 1 hours;
        c.performanceFeeX64 = 1 << 62;
        uint256 expectedFee = FullMath.mulDiv(claimed, c.performanceFeeX64, 2 ** 64);
        assertGt(expectedFee, 0);
        address feeTaker = V3Utils(payable(V3UTILS)).FEE_TAKER();
        uint256 ft0 = IERC20(AERO).balanceOf(feeTaker);
        OrderParams memory p = _params(IAeroFarmingLogic.AutoAction.AUTO_COMPOUND, GAUGE_B_BASE, abi.encode(c), user);
        vm.recordLogs();
        vm.prank(operator);
        _executeOrder(p);
        (,,,,,,, uint128 l1,,,,) = INonfungiblePositionManager(NFPM).positions(id);
        assertGt(l1, l0);
        assertEq(IERC20(AERO).balanceOf(feeTaker) - ft0, expectedFee);
        assertTrue(ICLGauge(GAUGE_B_BASE).stakedContains(user, id));
        assertEq(IERC20(AERO).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
        (uint256 found,) = _farmActions(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.COMPOUND, true);
        assertEq(found, 1);
    }
}

/// @dev AUTO_COMPOUND where the reward (AERO) is not a pool token: amount2 path, swaps through the etched swap router.
contract AeroFarmingHelperAutoCompoundGaugeATest is AutomationBase {
    int24 constant TS = 50;
    address internal swapRouter;

    function setUp() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroOrderCompoundAUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        _approveGauge(user, GAUGE_A_BASE, true);
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        vm.stopPrank();
        _mint(GAUGE_A_BASE, POOL_A_BASE, WETH, USDC_BASE, TS, 1 ether, 5000e6, 10);
        // V3Utils reads its own swapRouter from storage, so the mock code goes at the real swapRouter address
        swapRouter = V3Utils(payable(V3UTILS)).swapRouter();
        vm.etch(swapRouter, address(new MockSwapRouter()).code);
        deal(WETH, swapRouter, 100 ether);
        deal(USDC_BASE, swapRouter, 1_000_000e6);
    }

    function test_autoCompound_gaugeA_rewardNotPoolToken() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 claimed = ICLGauge(GAUGE_A_BASE).earned(user, ids);
        assertGt(claimed, 0);
        IAeroFarmingLogic.CompoundParams memory c;
        c.deadline = block.timestamp + 1 hours;
        c.performanceFeeX64 = 1 << 62;
        uint256 fee = FullMath.mulDiv(claimed, c.performanceFeeX64, 2 ** 64);
        uint256 net = claimed - fee;
        c.amountIn0 = net / 3;
        c.amountIn1 = net / 3;
        c.amountOut0Min = 0.0003 ether;
        c.amountOut1Min = 1e6;
        c.swapData0 = abi.encodeCall(MockSwapRouter.swap, (IERC20(AERO), IERC20(WETH), 0.0003 ether));
        c.swapData1 = abi.encodeCall(MockSwapRouter.swap, (IERC20(AERO), IERC20(USDC_BASE), 1e6));
        (,,,,,,, uint128 l0,,,,) = INonfungiblePositionManager(NFPM).positions(id);
        address feeTaker = V3Utils(payable(V3UTILS)).FEE_TAKER();
        uint256 ft0 = IERC20(AERO).balanceOf(feeTaker);
        uint256 uA = IERC20(AERO).balanceOf(user);
        OrderParams memory p = _params(IAeroFarmingLogic.AutoAction.AUTO_COMPOUND, GAUGE_A_BASE, abi.encode(c), user);

        vm.recordLogs();
        vm.prank(operator);
        _executeOrder(p);

        (,,,,,,, uint128 l1,,,,) = INonfungiblePositionManager(NFPM).positions(id);
        assertGt(l1, l0, "liquidity not increased");
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC20(AERO).balanceOf(feeTaker) - ft0, fee, "performance fee");
        assertEq(IERC20(AERO).balanceOf(user) - uA, net - c.amountIn0 - c.amountIn1, "unswapped AERO swept to user");
        address h = address(router);
        assertEq(IERC20(AERO).balanceOf(h), 0);
        assertEq(IERC20(WETH).balanceOf(h), 0);
        assertEq(IERC20(USDC_BASE).balanceOf(h), 0);
        assertEq(IERC721(NFPM).balanceOf(h), 0);
        assertEq(IERC20(AERO).allowance(h, V3UTILS), 0);
        assertEq(IERC20(WETH).allowance(h, V3UTILS), 0);
        assertEq(IERC20(USDC_BASE).allowance(h, V3UTILS), 0);
        (uint256 found,) = _farmActions(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.COMPOUND, true);
        assertEq(found, 1);
    }
}

contract AeroFarmingHelperAutoHarvestTest is AutomationBase {
    int24 constant TS = 200;
    address internal feeTaker;

    event DeductFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, Common.DeductFeesEventData data
    );

    function setUp() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroOrderHarvestUser");
        deal(AERO, user, 100_000 ether);
        deal(WETH, user, 100 ether);
        _approveGauge(user, GAUGE_B_BASE, true);
        vm.startPrank(user);
        IERC20(AERO).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.stopPrank();
        _mint(GAUGE_B_BASE, POOL_B_BASE, AERO, WETH, TS, 10_000 ether, 10 ether, 10);
        feeTaker = V3Utils(payable(V3UTILS)).FEE_TAKER();
    }

    function _earned() internal view returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return ICLGauge(GAUGE_B_BASE).earned(user, ids);
    }

    function _harvestOrder(IAeroFarmingLogic.HarvestParams memory h) internal view returns (OrderParams memory) {
        return _params(IAeroFarmingLogic.AutoAction.AUTO_HARVEST, GAUGE_B_BASE, abi.encode(h), user);
    }

    function _assertHarvestLogs(Vm.Log[] memory logs, uint256 claimed, uint256 fee, uint64 feeX64) internal view {
        uint256 fees;
        uint256 actions;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            if (logs[i].topics[0] == DeductFees.selector) {
                ++fees;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(NFPM))));
                assertEq(logs[i].topics[2], bytes32(id));
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(user))));
                Common.DeductFeesEventData memory d = abi.decode(logs[i].data, (Common.DeductFeesEventData));
                assertEq(d.token0, AERO);
                assertEq(d.token1, WETH);
                assertEq(d.token2, address(0));
                assertEq(d.amount0, claimed);
                assertEq(d.amount1, 0);
                assertEq(d.amount2, 0);
                assertEq(d.feeAmount0, fee);
                assertEq(d.feeAmount1, 0);
                assertEq(d.feeAmount2, 0);
                assertEq(d.feeX64, feeX64);
                assertEq(uint8(d.feeType), uint8(Common.FeeType.GAS_FEE));
            } else if (logs[i].topics[0] == FarmAction.selector) {
                ++actions;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_B_BASE))));
                assertEq(logs[i].topics[3], bytes32(id));
                (uint256 newId, IAeroFarmingLogic.Action a, bool automated) =
                    abi.decode(logs[i].data, (uint256, IAeroFarmingLogic.Action, bool));
                assertEq(newId, id);
                assertEq(uint8(a), uint8(IAeroFarmingLogic.Action.HARVEST));
                assertTrue(automated);
            }
        }
        assertEq(fees, 1);
        assertEq(actions, 1);
    }

    function test_autoHarvest_noSwap_paysAeroMinusGasFee() public {
        uint256 claimed = _earned();
        assertGt(claimed, 0);
        IAeroFarmingLogic.HarvestParams memory h;
        h.gasFeeX64 = 1 << 62;
        uint256 fee = FullMath.mulDiv(claimed, h.gasFeeX64, 2 ** 64);
        assertGt(fee, 0);
        OrderParams memory p = _harvestOrder(h);
        uint256 u0 = IERC20(AERO).balanceOf(user);
        uint256 ft0 = IERC20(AERO).balanceOf(feeTaker);
        vm.recordLogs();
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC20(AERO).balanceOf(user) - u0, claimed - fee);
        assertEq(IERC20(AERO).balanceOf(feeTaker) - ft0, fee);
        assertEq(IERC20(AERO).balanceOf(address(router)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
        assertTrue(ICLGauge(GAUGE_B_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_B_BASE);
        _assertHarvestLogs(vm.getRecordedLogs(), claimed, fee, h.gasFeeX64);
    }

    function test_autoHarvest_gasFeeAboveCapReverts() public {
        IAeroFarmingLogic.HarvestParams memory h;
        h.gasFeeX64 = 5534023222112865280 + 1;
        OrderParams memory p = _harvestOrder(h);
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.FeeTooHigh.selector);
        _executeOrder(p);
    }

    function test_autoHarvest_swapPath_routerCalled() public {
        uint256 claimed = _earned();
        IAeroFarmingLogic.HarvestParams memory h;
        h.gasFeeX64 = 1 << 62;
        h.targetToken = WETH;
        h.amountOutMin = 1 ether;
        uint256 fee = FullMath.mulDiv(claimed, h.gasFeeX64, 2 ** 64);
        address swapRouter = makeAddr("aeroMockRouter");
        vm.etch(swapRouter, address(new MockSwapRouter()).code);
        vm.mockCall(V3UTILS, abi.encodeWithSignature("swapRouter()"), abi.encode(swapRouter));
        deal(WETH, swapRouter, 5 ether);
        h.swapData = abi.encodeCall(MockSwapRouter.swap, (IERC20(AERO), IERC20(WETH), 2 ether));
        OrderParams memory p = _harvestOrder(h);
        uint256 uA = IERC20(AERO).balanceOf(user);
        uint256 uW = IERC20(WETH).balanceOf(user);
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC20(WETH).balanceOf(user) - uW, 2 ether);
        assertEq(IERC20(AERO).balanceOf(user), uA); // all post-fee AERO went into the swap
        assertEq(IERC20(AERO).balanceOf(swapRouter), claimed - fee);
        assertEq(IERC20(AERO).allowance(address(router), swapRouter), 0);
        assertEq(IERC20(AERO).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertTrue(ICLGauge(GAUGE_B_BASE).stakedContains(user, id));
    }

    function test_autoHarvest_swapBelowMinReverts() public {
        IAeroFarmingLogic.HarvestParams memory h;
        h.targetToken = WETH;
        h.amountOutMin = 3 ether;
        address swapRouter = makeAddr("aeroMockRouter2");
        vm.etch(swapRouter, address(new MockSwapRouter()).code);
        vm.mockCall(V3UTILS, abi.encodeWithSignature("swapRouter()"), abi.encode(swapRouter));
        deal(WETH, swapRouter, 5 ether);
        h.swapData = abi.encodeCall(MockSwapRouter.swap, (IERC20(AERO), IERC20(WETH), 2 ether));
        OrderParams memory p = _harvestOrder(h);
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.SlippageError.selector);
        _executeOrder(p);
    }

    function _etchRouter(string memory label, address routerCode) internal returns (address swapRouter) {
        swapRouter = makeAddr(label);
        vm.etch(swapRouter, routerCode.code);
        vm.mockCall(V3UTILS, abi.encodeWithSignature("swapRouter()"), abi.encode(swapRouter));
    }

    function test_autoHarvest_routerReverts_swapFailed() public {
        IAeroFarmingLogic.HarvestParams memory h;
        h.targetToken = WETH;
        // the swapRouter holds no WETH, so its payout reverts
        _etchRouter("aeroRevertRouter", address(new MockSwapRouter()));
        h.swapData = abi.encodeCall(MockSwapRouter.swap, (IERC20(AERO), IERC20(WETH), 2 ether));
        OrderParams memory p = _harvestOrder(h);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAeroFarmingLogic.SwapFailed.selector, h.swapData, 0));
        _executeOrder(p);
    }

    function test_autoHarvest_partialFill_leftoverToUser() public {
        uint256 claimed = _earned();
        IAeroFarmingLogic.HarvestParams memory h;
        h.gasFeeX64 = 1 << 62;
        h.targetToken = WETH;
        uint256 fee = FullMath.mulDiv(claimed, h.gasFeeX64, 2 ** 64);
        uint256 net = claimed - fee;
        uint256 pulled = net / 4;
        address swapRouter = _etchRouter("aeroPartialRouter", address(new PartialFillRouter()));
        deal(WETH, swapRouter, 5 ether);
        h.swapData = abi.encodeCall(PartialFillRouter.swap, (IERC20(AERO), IERC20(WETH), pulled, 2 ether));
        OrderParams memory p = _harvestOrder(h);
        uint256 uA = IERC20(AERO).balanceOf(user);
        uint256 uW = IERC20(WETH).balanceOf(user);
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC20(WETH).balanceOf(user) - uW, 2 ether);
        assertEq(IERC20(AERO).balanceOf(user) - uA, net - pulled, "unpulled reward goes to the user");
        assertEq(IERC20(AERO).balanceOf(swapRouter), pulled);
        assertEq(IERC20(AERO).allowance(address(router), swapRouter), 0);
        assertEq(IERC20(AERO).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
    }

    function test_autoHarvest_targetIsReward_noSwap() public {
        uint256 claimed = _earned();
        IAeroFarmingLogic.HarvestParams memory h;
        h.gasFeeX64 = 1 << 62;
        h.targetToken = AERO;
        h.swapData = hex"deadbeef"; // would fail if a swap were attempted
        uint256 fee = FullMath.mulDiv(claimed, h.gasFeeX64, 2 ** 64);
        OrderParams memory p = _harvestOrder(h);
        uint256 uA = IERC20(AERO).balanceOf(user);
        vm.expectCall(V3UTILS, abi.encodeWithSignature("swapRouter()"), 0);
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC20(AERO).balanceOf(user) - uA, claimed - fee);
        assertEq(IERC20(AERO).balanceOf(address(router)), 0);
    }
}

/// @dev Pulls only `pull` of `tokenIn` from the caller (less than the allowance) and pays `amountOut` of `tokenOut`.
contract PartialFillRouter {
    function swap(IERC20 tokenIn, IERC20 tokenOut, uint256 pull, uint256 amountOut) external {
        tokenIn.transferFrom(msg.sender, address(this), pull);
        tokenOut.transfer(msg.sender, amountOut);
    }
}
