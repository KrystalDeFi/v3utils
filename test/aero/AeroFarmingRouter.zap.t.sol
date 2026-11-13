// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";

contract AeroFarmingRouterZapTest is AeroForkBase {
    address user;
    int24 constant TS = 50;

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
        user = makeAddr("aeroZapUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        vm.deal(user, 10 ether);
        _approveGauge(user, GAUGE_A_BASE, false);
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _params(uint256 a0, uint256 a1) internal view returns (Common.SwapAndMintParams memory p) {
        // pool tokens: token0 = WETH (0x42..06 < 0x83..), token1 = USDC
        (, int24 tick,,,,) = ICLPoolSlot0(POOL_A_BASE).slot0();
        int24 base = (tick / TS) * TS;
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.token0 = IERC20(WETH);
        p.token1 = IERC20(USDC_BASE);
        p.fee = 0;
        p.tickSpacing = TS;
        p.tickLower = base - 10 * TS;
        p.tickUpper = base + 10 * TS;
        p.amount0 = a0;
        p.amount1 = a1;
        p.deadline = block.timestamp + 1 hours;
        p.swapSourceToken = IERC20(address(0));
        p.recipient = user; // must be overridden by the router
    }

    function _bal(address t, address a) internal view returns (uint256) {
        return IERC20(t).balanceOf(a);
    }

    function _check(uint256 id, uint256 w0, uint256 u0, uint256 h0w, uint256 h0u, uint256 suppliedW) internal {
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        assertEq(_bal(WETH, address(router)), h0w);
        assertEq(_bal(USDC_BASE, address(router)), h0u);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
        assertLe(w0 > _bal(WETH, user) ? w0 - _bal(WETH, user) : 0, suppliedW);
        assertLe(u0 - _bal(USDC_BASE, user), 5000e6);
    }

    function test_zapIn_stakesForUser() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        vm.recordLogs();
        vm.prank(user);
        uint256 id = _zapIn(GAUGE_A_BASE, p, false);
        _check(id, w0, u0, 0, 0, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = FarmAction.selector;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != sig) continue;
            ++found;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_A_BASE))));
            assertEq(logs[i].topics[3], bytes32(id));
            (uint256 newId, IAeroFarmingLogic.Action a, bool automated) =
                abi.decode(logs[i].data, (uint256, IAeroFarmingLogic.Action, bool));
            assertEq(newId, id);
            assertEq(uint8(a), uint8(IAeroFarmingLogic.Action.ZAP_IN));
            assertFalse(automated);
        }
        assertEq(found, 1);
    }

    function test_zapIn_withNativeEth() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_BASE, user);
        uint256 e0 = user.balance;
        vm.prank(user);
        uint256 id = _zapIn(1 ether, GAUGE_A_BASE, p, false);
        _check(id, w0, u0, 0, 0, 0);
        assertGe(_bal(WETH, user), w0); // WETH untouched; leftovers of the wrapped ETH come back as WETH
        assertLe(e0 - user.balance, 1 ether);
        assertEq(address(router).balance, 0);
    }

    function test_zapIn_unwrapLeftoverWeth_paysNative() public {
        // far more WETH than the range needs, so there is a WETH leftover to unwrap
        Common.SwapAndMintParams memory p = _params(5 ether, 1000e6);
        uint256 e0 = user.balance;
        uint256 w0 = _bal(WETH, user);
        vm.prank(user);
        uint256 id = _zapIn(GAUGE_A_BASE, p, true);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertGt(user.balance, e0, "leftover WETH not paid as native");
        assertEq(_bal(WETH, user), w0 - 5 ether, "leftover must not come back as WETH");
        assertEq(address(router).balance, 0);
        assertEq(_bal(WETH, address(router)), 0);
        assertEq(_bal(USDC_BASE, address(router)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
    }

    function test_zapIn_nativeDisabledReverts() public {
        _deployRouter(AERO, true, address(0));
        _approveGauge(user, GAUGE_A_BASE, false);
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        vm.startPrank(user);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.expectRevert(IAeroFarmingLogic.NativeDisabled.selector);
        _zapInExpectRevert(1 ether, GAUGE_A_BASE, p, false);
        vm.stopPrank();
    }

    function test_zapIn_wrongProtocolReverts() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        p.protocol = Nfpm.Protocol.UNI_V3;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _zapInExpectRevert(GAUGE_A_BASE, p, false);
    }

    function test_zapIn_deadGaugeReverts() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        vm.mockCall(
            LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.isActivated.selector, GAUGE_A_BASE), abi.encode(false)
        );
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.GaugeNotLive.selector);
        _zapInExpectRevert(GAUGE_A_BASE, p, false);
    }

    function test_zapIn_preexistingBalanceNotForwarded() public {
        deal(USDC_BASE, address(router), 5e6);
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        vm.prank(user);
        _zapIn(GAUGE_A_BASE, p, false);
        assertEq(_bal(USDC_BASE, address(router)), 5e6);
    }

    function test_onERC721Received_rejectsUnsolicited() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        vm.prank(user);
        uint256 id = _zapIn(GAUGE_A_BASE, p, false);
        // unstake directly through gauge to get an NFT in user's hands
        vm.prank(user);
        ICLGaugeWithdraw(GAUGE_A_BASE).withdraw(id);
        address h = address(router);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.UnexpectedNft.selector);
        IERC721(NFPM).safeTransferFrom(user, h, id);
    }

    function test_onERC721Received_wrongSenderReverts() public {
        address h = address(router);
        vm.expectRevert(IAeroFarmingLogic.UnexpectedNft.selector);
        AeroFarmingRouter(payable(h)).onERC721Received(GAUGE_A_BASE, GAUGE_A_BASE, 1, "");
    }

    function test_onERC721Received_noActiveGaugeSpoofedReverts() public {
        vm.prank(NFPM);
        vm.expectRevert(IAeroFarmingLogic.UnexpectedNft.selector);
        router.onERC721Received(GAUGE_A_BASE, GAUGE_A_BASE, 1, "");
    }

    function test_zapIn_unwrapNativeDisabledReverts() public {
        _deployRouter(AERO, true, address(0));
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.NativeDisabled.selector);
        _zapInExpectRevert(GAUGE_A_BASE, p, true);
    }

    function test_zapIn_nfpmMismatchReverts() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        p.nfpm = INonfungiblePositionManager(makeAddr("otherNfpm"));
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _zapInExpectRevert(GAUGE_A_BASE, p, false);
    }

    function test_zapIn_sameTokenReverts() public {
        Common.SwapAndMintParams memory p = _params(1 ether, 5000e6);
        p.token1 = p.token0;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.InvalidInstructions.selector);
        _zapInExpectRevert(GAUGE_A_BASE, p, false);
    }
}

interface ICLPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
}

interface ICLGaugeWithdraw {
    function withdraw(uint256 tokenId) external;
}
