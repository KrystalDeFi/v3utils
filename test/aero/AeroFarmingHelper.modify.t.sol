// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";

contract AeroFarmingHelperModifyTest is AeroForkBase {
    address user;
    int24 constant TS = 50;
    uint256 id;

    event FarmAction(
        address indexed user,
        address indexed gauge,
        uint256 indexed tokenId,
        uint256 newTokenId,
        AeroFarmingHelper.Action action,
        bool automated
    );

    function setUp() public {
        _forkBase();
        _deployHelper(AERO, true, WETH);
        user = makeAddr("aeroModifyUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        _approveGauge(user, GAUGE_A_BASE, false);
        vm.startPrank(user);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC_BASE).approve(address(helper), type(uint256).max);
        vm.stopPrank();

        (, int24 tick,,,,) = ICLPoolSlot0(POOL_A_BASE).slot0();
        int24 base = (tick / TS) * TS;
        Common.SwapAndMintParams memory p;
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.token0 = IERC20(WETH);
        p.token1 = IERC20(USDC_BASE);
        p.tickSpacing = TS;
        p.tickLower = base - 10 * TS;
        p.tickUpper = base + 10 * TS;
        p.amount0 = 1 ether;
        p.amount1 = 5000e6;
        p.deadline = block.timestamp + 1 hours;
        p.recipient = user;
        vm.prank(user);
        id = helper.zapInAndStake(GAUGE_A_BASE, p, false);

        (uint256 minStakeBlocks,) = ICLGaugeFactory(GAUGE_FACTORY).effectivePenaltyConfig(GAUGE_A_BASE);
        vm.roll(block.number + minStakeBlocks + 10);
        vm.warp(block.timestamp + 2 * (minStakeBlocks + 10));
    }

    function _liq() internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = INonfungiblePositionManager(NFPM).positions(id);
    }

    function _bal(address t, address a) internal view returns (uint256) {
        return IERC20(t).balanceOf(a);
    }

    function _ins(uint128 liquidity) internal view returns (V3Utils.Instructions memory ins) {
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        ins.protocol = Nfpm.Protocol.AERODROME;
        ins.liquidity = liquidity;
        ins.deadline = block.timestamp + 1 hours;
        ins.recipient = user; // must be overridden by helper
    }

    function _addParams(uint256 a0, uint256 a1) internal view returns (Common.SwapAndIncreaseLiquidityParams memory p) {
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.tokenId = id;
        p.amount0 = a0;
        p.amount1 = a1;
        p.deadline = block.timestamp + 1 hours;
        p.recipient = user; // must be overridden by helper
    }

    function _assertHelperClean(uint256 w, uint256 u, uint256 a) internal {
        assertEq(_bal(WETH, address(helper)), w);
        assertEq(_bal(USDC_BASE, address(helper)), u);
        assertEq(_bal(AERO, address(helper)), a);
        assertEq(IERC721(NFPM).balanceOf(address(helper)), 0);
    }

    function _farmActionCount(Vm.Log[] memory logs, uint256 tokenId, AeroFarmingHelper.Action act)
        internal
        view
        returns (uint256 found)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(helper) || logs[i].topics[0] != FarmAction.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_A_BASE))));
            assertEq(logs[i].topics[3], bytes32(tokenId));
            (uint256 newId, AeroFarmingHelper.Action a, bool automated) =
                abi.decode(logs[i].data, (uint256, AeroFarmingHelper.Action, bool));
            assertEq(newId, tokenId);
            assertEq(uint8(a), uint8(act));
            assertFalse(automated);
            ++found;
        }
    }

    function test_add_increasesLiquidityAndRestakes() public {
        uint128 l0 = _liq();
        Common.SwapAndIncreaseLiquidityParams memory p = _addParams(0.5 ether, 2000e6);
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        vm.recordLogs();
        vm.prank(user);
        helper.addLiquidity(GAUGE_A_BASE, p, false);
        assertGt(_liq(), l0);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        _assertHelperClean(0, 0, 0);
        assertLe(w0 - _bal(WETH, user), 0.5 ether);
        assertLe(u0 - _bal(USDC_BASE, user), 2000e6);
        assertEq(_farmActionCount(vm.getRecordedLogs(), id, AeroFarmingHelper.Action.ADD_LIQUIDITY), 1);
    }

    function test_add_withoutGaugeApprovalReverts() public {
        vm.prank(user);
        ICLGaugeApprovals(GAUGE_A_BASE).setApprovalForAll(address(helper), false);
        Common.SwapAndIncreaseLiquidityParams memory p = _addParams(0.5 ether, 2000e6);
        vm.prank(user);
        vm.expectRevert(bytes("NW"));
        helper.addLiquidity(GAUGE_A_BASE, p, false);
    }

    function test_remove_partialRestakesSameId() public {
        uint128 l0 = _liq();
        uint128 part = l0 / 3;
        V3Utils.Instructions memory ins = _ins(part);
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        vm.recordLogs();
        vm.prank(user);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
        assertEq(_liq(), l0 - part);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        assertGt(_bal(WETH, user), w0);
        assertGt(_bal(USDC_BASE, user), u0);
        _assertHelperClean(0, 0, 0);
        assertEq(_farmActionCount(vm.getRecordedLogs(), id, AeroFarmingHelper.Action.REMOVE_LIQUIDITY), 1);
    }

    function test_remove_fullLiquidityReverts() public {
        V3Utils.Instructions memory ins = _ins(_liq());
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
    }

    function test_remove_zeroLiquidityReverts() public {
        V3Utils.Instructions memory ins = _ins(0);
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
    }

    function test_remove_withClaimApproval_forwardsRewardAndPoolTokens() public {
        vm.prank(user);
        ICLGaugeApprovals(GAUGE_A_BASE).approveForClaim(address(helper), true);
        uint256 a0 = _bal(AERO, user);
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        vm.prank(user);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
        assertGt(_bal(AERO, user), a0);
        _assertHelperClean(0, 0, 0);
    }

    function test_remove_withoutClaimApproval_userReceivesTokens() public {
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        vm.prank(user);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
        assertGt(_bal(WETH, user), w0);
        assertGt(_bal(USDC_BASE, user), u0);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        _assertHelperClean(0, 0, 0);
    }

    function test_attackerCannotActOnOthersStake() public {
        address attacker = makeAddr("aeroModifyAttacker");
        deal(WETH, attacker, 10 ether);
        deal(USDC_BASE, attacker, 50_000e6);
        _approveGauge(attacker, GAUGE_A_BASE, true);
        vm.startPrank(attacker);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC_BASE).approve(address(helper), type(uint256).max);
        vm.stopPrank();

        V3Utils.Instructions memory rem = _ins(_liq() / 2);
        V3Utils.Instructions memory ex = _ins(_liq());
        Common.SwapAndIncreaseLiquidityParams memory p = _addParams(0.5 ether, 2000e6);
        AeroFarmingHelper h = helper;

        vm.startPrank(attacker);
        vm.expectRevert(bytes("NA"));
        h.removeLiquidity(GAUGE_A_BASE, id, rem);
        vm.expectRevert(bytes("NA"));
        h.exit(GAUGE_A_BASE, id, ex);
        vm.expectRevert(bytes("NA"));
        h.addLiquidity(GAUGE_A_BASE, p, false);
        vm.stopPrank();

        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(attacker, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
    }

    function test_exit_returnsNftUnstaked() public {
        V3Utils.Instructions memory ins = _ins(_liq());
        vm.recordLogs();
        vm.prank(user);
        helper.exit(GAUGE_A_BASE, id, ins);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), 0);
        _assertHelperClean(0, 0, 0);
        assertEq(_farmActionCount(vm.getRecordedLogs(), id, AeroFarmingHelper.Action.EXIT), 1);
    }

    function test_exit_partialLiquidityReverts() public {
        V3Utils.Instructions memory ins = _ins(_liq() - 1);
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.exit(GAUGE_A_BASE, id, ins);
    }

    function test_exit_onDeadGaugeStillWorks() public {
        V3Utils.Instructions memory ins = _ins(_liq());
        vm.mockCall(
            LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.isActivated.selector, GAUGE_A_BASE), abi.encode(false)
        );
        vm.prank(user);
        helper.exit(GAUGE_A_BASE, id, ins);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
    }

    function _rebalanceIns() internal view returns (V3Utils.Instructions memory ins) {
        (, int24 tick,,,,) = ICLPoolSlot0(POOL_A_BASE).slot0();
        int24 base = (tick / TS) * TS;
        ins = _ins(_liq());
        ins.whatToDo = V3Utils.WhatToDo.CHANGE_RANGE;
        ins.tickLower = base - 5 * TS;
        ins.tickUpper = base + 5 * TS;
    }

    function test_rebalance_restakesNewId() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        uint256 a0 = _bal(AERO, user);
        vm.prank(user);
        uint256 newId = helper.rebalance(GAUGE_A_BASE, id, ins);
        assertTrue(newId != id);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(newId), GAUGE_A_BASE);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), 0);
        (,,,,,,, uint128 nl,,,,) = INonfungiblePositionManager(NFPM).positions(newId);
        assertGt(nl, 0);
        _assertHelperClean(0, 0, 0);
        assertGe(_bal(AERO, user), a0);
    }

    function test_rebalance_emitsFarmAction() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        vm.recordLogs();
        vm.prank(user);
        uint256 newId = helper.rebalance(GAUGE_A_BASE, id, ins);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(helper) || logs[i].topics[0] != FarmAction.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_A_BASE))));
            assertEq(logs[i].topics[3], bytes32(id));
            (uint256 n, AeroFarmingHelper.Action a, bool automated) =
                abi.decode(logs[i].data, (uint256, AeroFarmingHelper.Action, bool));
            assertEq(n, newId);
            assertEq(uint8(a), uint8(AeroFarmingHelper.Action.REBALANCE));
            assertFalse(automated);
            ++found;
        }
        assertEq(found, 1);
    }

    function test_rebalance_withStrayNftHeld() public {
        address eoa = makeAddr("aeroStrayOwner");
        (, int24 tick,,,,) = ICLPoolSlot0(POOL_A_BASE).slot0();
        int24 base = (tick / TS) * TS;
        deal(WETH, eoa, 1 ether);
        deal(USDC_BASE, eoa, 5000e6);
        vm.startPrank(eoa);
        IERC20(WETH).approve(NFPM, type(uint256).max);
        IERC20(USDC_BASE).approve(NFPM, type(uint256).max);
        INonfungiblePositionManager.AerodromeMintParams memory mp = INonfungiblePositionManager.AerodromeMintParams(
            WETH, USDC_BASE, TS, base - 10 * TS, base + 10 * TS, 0.1 ether, 500e6, 0, 0, eoa, block.timestamp + 1 hours, 0
        );
        (uint256 stray,,,) = INonfungiblePositionManager(NFPM).mint(mp);
        IERC721(NFPM).transferFrom(eoa, address(helper), stray);
        vm.stopPrank();
        assertEq(IERC721(NFPM).ownerOf(stray), address(helper));

        V3Utils.Instructions memory ins = _rebalanceIns();
        vm.prank(user);
        uint256 newId = helper.rebalance(GAUGE_A_BASE, id, ins);
        assertTrue(newId != stray);
        assertEq(IERC721(NFPM).ownerOf(stray), address(helper));
        assertEq(IERC721(NFPM).balanceOf(address(helper)), 1);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(id), user);
    }

    function test_rebalance_insidePenaltyWindow_succeedsAndForfeits() public {
        // fresh stake, then rebalance in the next block (inside the penalty window)
        V3Utils.Instructions memory ins = _rebalanceIns();
        vm.prank(user);
        uint256 newId = helper.rebalance(GAUGE_A_BASE, id, ins);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        V3Utils.Instructions memory ins2 = _rebalanceIns();
        (,,,,,,, uint128 l,,,,) = INonfungiblePositionManager(NFPM).positions(newId);
        ins2.liquidity = l;
        uint256 a0 = _bal(AERO, user);
        uint256 h0 = _bal(AERO, address(helper));
        vm.prank(user);
        uint256 newId2 = helper.rebalance(GAUGE_A_BASE, newId, ins2);
        assertTrue(newId2 != newId);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId2));
        assertEq(_bal(AERO, user), a0);
        assertEq(_bal(AERO, address(helper)), h0);
    }

    function test_rebalance_wrongWhatToDoReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.rebalance(GAUGE_A_BASE, id, ins);
    }

    function test_removeWithChangeRangeReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        ins.liquidity = _liq() / 2;
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
    }

    function test_compoundFeesInstructionReverts() public {
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        ins.whatToDo = V3Utils.WhatToDo.COMPOUND_FEES;
        vm.startPrank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.removeLiquidity(GAUGE_A_BASE, id, ins);
        ins.liquidity = _liq();
        vm.expectRevert(AeroFarmingHelper.InvalidInstructions.selector);
        helper.exit(GAUGE_A_BASE, id, ins);
        vm.stopPrank();
    }

    function test_unwrapNativeDisabledReverts() public {
        _deployHelper(AERO, true, address(0));
        AeroFarmingHelper h = helper;
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        ins.unwrap = true;
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.NativeDisabled.selector);
        h.removeLiquidity(GAUGE_A_BASE, id, ins);
    }
}

interface ICLPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
}
