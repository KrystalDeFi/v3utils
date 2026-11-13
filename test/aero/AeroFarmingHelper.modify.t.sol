// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";

/// @dev V3Utils stand-in for CHANGE_RANGE that misbehaves: on receiving the old NFT it sends back every NFT in
/// `extras` (in order, instead of one freshly minted position), then the old NFT, all with plain transferFrom.
contract MisbehavingV3Utils is IERC721Receiver {
    uint256[] internal extras;

    function setExtras(uint256[] memory e) external {
        extras = e;
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        for (uint256 i; i < extras.length; ++i) {
            IERC721(msg.sender).transferFrom(address(this), from, extras[i]);
        }
        IERC721(msg.sender).transferFrom(address(this), from, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AeroFarmingHelperModifyTest is AeroForkBase {
    address user;
    int24 constant TS = 50;
    uint256 id;

    event FarmAction(
        address indexed user,
        address indexed gauge,
        uint256 indexed tokenId,
        uint256 newTokenId,
        IAeroFarmingLogic.Action action,
        bool automated
    );

    function setUp() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        user = makeAddr("aeroModifyUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        _approveGauge(user, GAUGE_A_BASE, false);
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
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
        id = _zapIn(GAUGE_A_BASE, p, false);

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
        ins.recipient = user; // must be overridden by the router
    }

    function _addParams(uint256 a0, uint256 a1) internal view returns (Common.SwapAndIncreaseLiquidityParams memory p) {
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.tokenId = id;
        p.amount0 = a0;
        p.amount1 = a1;
        p.deadline = block.timestamp + 1 hours;
        p.recipient = user; // must be overridden by the router
    }

    function _assertRouterClean(uint256 w, uint256 u, uint256 a) internal {
        assertEq(_bal(WETH, address(router)), w);
        assertEq(_bal(USDC_BASE, address(router)), u);
        assertEq(_bal(AERO, address(router)), a);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
    }

    function _farmActionCount(Vm.Log[] memory logs, uint256 tokenId, IAeroFarmingLogic.Action act)
        internal
        view
        returns (uint256 found)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != FarmAction.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_A_BASE))));
            assertEq(logs[i].topics[3], bytes32(tokenId));
            (uint256 newId, IAeroFarmingLogic.Action a, bool automated) =
                abi.decode(logs[i].data, (uint256, IAeroFarmingLogic.Action, bool));
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
        _addLiquidity(GAUGE_A_BASE, p, false);
        assertGt(_liq(), l0);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        _assertRouterClean(0, 0, 0);
        assertLe(w0 - _bal(WETH, user), 0.5 ether);
        assertLe(u0 - _bal(USDC_BASE, user), 2000e6);
        assertEq(_farmActionCount(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.ADD_LIQUIDITY), 1);
    }

    function test_add_withoutGaugeApprovalReverts() public {
        vm.prank(user);
        ICLGaugeApprovals(GAUGE_A_BASE).setApprovalForAll(address(router), false);
        Common.SwapAndIncreaseLiquidityParams memory p = _addParams(0.5 ether, 2000e6);
        vm.prank(user);
        vm.expectRevert(bytes("NW"));
        _addLiquidity(GAUGE_A_BASE, p, false);
    }

    function test_remove_partialRestakesSameId() public {
        uint128 l0 = _liq();
        uint128 part = l0 / 3;
        V3Utils.Instructions memory ins = _ins(part);
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        vm.recordLogs();
        vm.prank(user);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
        assertEq(_liq(), l0 - part);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        assertGt(_bal(WETH, user), w0);
        assertGt(_bal(USDC_BASE, user), u0);
        _assertRouterClean(0, 0, 0);
        assertEq(_farmActionCount(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.REMOVE_LIQUIDITY), 1);
    }

    function test_remove_unwrap_paysNative() public {
        uint128 part = _liq() / 3;
        V3Utils.Instructions memory ins = _ins(part);
        ins.unwrap = true;
        uint256 e0 = user.balance;
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        vm.prank(user);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
        assertGt(user.balance, e0, "WETH not paid as native");
        assertEq(_bal(WETH, user), w0, "WETH must not be paid as token");
        assertGt(_bal(USDC_BASE, user), u0);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(address(router).balance, 0);
        _assertRouterClean(0, 0, 0);
    }

    function test_remove_fullLiquidityReverts() public {
        V3Utils.Instructions memory ins = _ins(_liq());
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
    }

    function test_remove_zeroLiquidityReverts() public {
        V3Utils.Instructions memory ins = _ins(0);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
    }

    function test_remove_withClaimApproval_forwardsRewardAndPoolTokens() public {
        vm.prank(user);
        ICLGaugeApprovals(GAUGE_A_BASE).approveForClaim(address(router), true);
        uint256 a0 = _bal(AERO, user);
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        vm.prank(user);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
        assertGt(_bal(AERO, user), a0);
        _assertRouterClean(0, 0, 0);
    }

    function test_remove_withoutClaimApproval_userReceivesTokens() public {
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        vm.prank(user);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
        assertGt(_bal(WETH, user), w0);
        assertGt(_bal(USDC_BASE, user), u0);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        _assertRouterClean(0, 0, 0);
    }

    function test_attackerCannotActOnOthersStake() public {
        address attacker = makeAddr("aeroModifyAttacker");
        deal(WETH, attacker, 10 ether);
        deal(USDC_BASE, attacker, 50_000e6);
        _approveGauge(attacker, GAUGE_A_BASE, true);
        vm.startPrank(attacker);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        vm.stopPrank();

        V3Utils.Instructions memory rem = _ins(_liq() / 2);
        V3Utils.Instructions memory ex = _ins(_liq());
        Common.SwapAndIncreaseLiquidityParams memory p = _addParams(0.5 ether, 2000e6);

        vm.startPrank(attacker);
        vm.expectRevert(bytes("NA"));
        _removeLiquidity(GAUGE_A_BASE, id, rem);
        vm.expectRevert(bytes("NA"));
        _exit(GAUGE_A_BASE, id, ex);
        vm.expectRevert(bytes("NA"));
        _addLiquidity(GAUGE_A_BASE, p, false);
        vm.stopPrank();

        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(attacker, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
    }

    function test_exit_returnsNftUnstaked() public {
        V3Utils.Instructions memory ins = _ins(_liq());
        vm.recordLogs();
        vm.prank(user);
        _exit(GAUGE_A_BASE, id, ins);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), 0);
        _assertRouterClean(0, 0, 0);
        assertEq(_farmActionCount(vm.getRecordedLogs(), id, IAeroFarmingLogic.Action.EXIT), 1);
    }

    function test_exit_partialLiquidityReverts() public {
        V3Utils.Instructions memory ins = _ins(_liq() - 1);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _exit(GAUGE_A_BASE, id, ins);
    }

    function test_exit_onDeadGaugeStillWorks() public {
        V3Utils.Instructions memory ins = _ins(_liq());
        vm.mockCall(
            LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.isActivated.selector, GAUGE_A_BASE), abi.encode(false)
        );
        vm.prank(user);
        _exit(GAUGE_A_BASE, id, ins);
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
        uint256 newId = _rebalance(GAUGE_A_BASE, id, ins);
        assertTrue(newId != id);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(newId), GAUGE_A_BASE);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), 0);
        assertEq(IERC721(NFPM).getApproved(newId), address(0));
        assertEq(IERC721(NFPM).getApproved(id), address(0));
        (,,,,,,, uint128 nl,,,,) = INonfungiblePositionManager(NFPM).positions(newId);
        assertGt(nl, 0);
        _assertRouterClean(0, 0, 0);
        assertGe(_bal(AERO, user), a0);
    }

    function test_rebalance_emitsFarmAction() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        vm.recordLogs();
        vm.prank(user);
        uint256 newId = _rebalance(GAUGE_A_BASE, id, ins);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != FarmAction.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_A_BASE))));
            assertEq(logs[i].topics[3], bytes32(id));
            (uint256 n, IAeroFarmingLogic.Action a, bool automated) =
                abi.decode(logs[i].data, (uint256, IAeroFarmingLogic.Action, bool));
            assertEq(n, newId);
            assertEq(uint8(a), uint8(IAeroFarmingLogic.Action.REBALANCE));
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
            WETH,
            USDC_BASE,
            TS,
            base - 10 * TS,
            base + 10 * TS,
            0.1 ether,
            500e6,
            0,
            0,
            eoa,
            block.timestamp + 1 hours,
            0
        );
        (uint256 stray,,,) = INonfungiblePositionManager(NFPM).mint(mp);
        (uint256 stray2,,,) = INonfungiblePositionManager(NFPM).mint(mp);
        IERC721(NFPM).transferFrom(eoa, address(router), stray);
        IERC721(NFPM).transferFrom(eoa, address(router), stray2);
        vm.stopPrank();
        assertEq(IERC721(NFPM).balanceOf(address(router)), 2);

        V3Utils.Instructions memory ins = _rebalanceIns();
        vm.prank(user);
        uint256 newId = _rebalance(GAUGE_A_BASE, id, ins);
        assertTrue(newId != stray && newId != stray2);
        assertEq(IERC721(NFPM).ownerOf(stray), address(router));
        assertEq(IERC721(NFPM).ownerOf(stray2), address(router));
        assertEq(IERC721(NFPM).balanceOf(address(router)), 2);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(id), user);
    }

    function test_rebalance_insidePenaltyWindow_succeedsAndForfeits() public {
        // fresh stake, then rebalance in the next block (inside the penalty window)
        V3Utils.Instructions memory ins = _rebalanceIns();
        vm.prank(user);
        uint256 newId = _rebalance(GAUGE_A_BASE, id, ins);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        V3Utils.Instructions memory ins2 = _rebalanceIns();
        (,,,,,,, uint128 l,,,,) = INonfungiblePositionManager(NFPM).positions(newId);
        ins2.liquidity = l;
        uint256 a0 = _bal(AERO, user);
        uint256 h0 = _bal(AERO, address(router));
        vm.prank(user);
        uint256 newId2 = _rebalance(GAUGE_A_BASE, newId, ins2);
        assertTrue(newId2 != newId);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId2));
        assertEq(_bal(AERO, user), a0);
        assertEq(_bal(AERO, address(router)), h0);
    }

    function test_rebalance_wrongWhatToDoReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _rebalance(GAUGE_A_BASE, id, ins);
    }

    function test_rebalance_partialLiquidityReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        ins.liquidity = _liq() / 2;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _rebalance(GAUGE_A_BASE, id, ins);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
    }

    function test_removeWithChangeRangeReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        ins.liquidity = _liq() / 2;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
    }

    function test_compoundFeesInstructionReverts() public {
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        ins.whatToDo = V3Utils.WhatToDo.COMPOUND_FEES;
        vm.startPrank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
        ins.liquidity = _liq();
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _exit(GAUGE_A_BASE, id, ins);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- rebalance result checks

    /// @dev Points the router at a MisbehavingV3Utils holding `n` positions minted with ticks [lower, upper].
    function _misbehavingV3Utils(uint256 n, int24 lower, int24 upper) internal returns (MisbehavingV3Utils m) {
        m = new MisbehavingV3Utils();
        address eoa = makeAddr("aeroMisbehavingMinter");
        deal(WETH, eoa, 1 ether);
        deal(USDC_BASE, eoa, 5000e6);
        uint256[] memory ids = new uint256[](n);
        vm.startPrank(eoa);
        IERC20(WETH).approve(NFPM, type(uint256).max);
        IERC20(USDC_BASE).approve(NFPM, type(uint256).max);
        for (uint256 i; i < n; ++i) {
            (ids[i],,,) = INonfungiblePositionManager(NFPM).mint(
                INonfungiblePositionManager.AerodromeMintParams(
                    WETH, USDC_BASE, TS, lower, upper, 0.1 ether, 500e6, 0, 0, address(m), block.timestamp + 1 hours, 0
                )
            );
        }
        vm.stopPrank();
        m.setExtras(ids);
        vm.prank(admin);
        router.setV3Utils(address(m));
    }

    function _assertRebalanceUntouched(uint128 liq) internal view {
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        assertEq(_liq(), liq);
    }

    /// V3Utils returns only the old NFT (no new position): the NFT balance moved by 0, not +1.
    function test_rebalance_noNewNftReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        uint128 liq = _liq();
        _misbehavingV3Utils(0, ins.tickLower, ins.tickUpper);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.RebalanceMismatch.selector);
        _rebalance(GAUGE_A_BASE, id, ins);
        _assertRebalanceUntouched(liq);
    }

    /// V3Utils returns two new NFTs (with the requested range) plus the old one: +2, not +1.
    function test_rebalance_extraNftReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        uint128 liq = _liq();
        _misbehavingV3Utils(2, ins.tickLower, ins.tickUpper);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.RebalanceMismatch.selector);
        _rebalance(GAUGE_A_BASE, id, ins);
        _assertRebalanceUntouched(liq);
    }

    /// V3Utils returns one new NFT whose range is not the one in `ins`.
    function test_rebalance_wrongRangeReverts() public {
        V3Utils.Instructions memory ins = _rebalanceIns();
        uint128 liq = _liq();
        _misbehavingV3Utils(1, ins.tickLower - TS, ins.tickUpper);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.RebalanceMismatch.selector);
        _rebalance(GAUGE_A_BASE, id, ins);

        _misbehavingV3Utils(1, ins.tickLower, ins.tickUpper + TS);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.RebalanceMismatch.selector);
        _rebalance(GAUGE_A_BASE, id, ins);
        _assertRebalanceUntouched(liq);

        // control: one new NFT with the requested range passes the checks and is staked for the user
        MisbehavingV3Utils m = _misbehavingV3Utils(1, ins.tickLower, ins.tickUpper);
        uint256 expected = INonfungiblePositionManager(NFPM).tokenOfOwnerByIndex(address(m), 0);
        vm.prank(user);
        uint256 newId = _rebalance(GAUGE_A_BASE, id, ins);
        assertEq(newId, expected);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
    }

    function test_unwrapNativeDisabledReverts() public {
        _deployRouter(AERO, true, address(0));
        V3Utils.Instructions memory ins = _ins(_liq() / 2);
        ins.unwrap = true;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.NativeDisabled.selector);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
    }
}

interface ICLPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
}
