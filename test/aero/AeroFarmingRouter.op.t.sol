// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroFarmingRouter.automation.t.sol";

/// @dev Non-Base behaviour on Optimism: reward token is xAERO, compounding is disabled, native coin is WETH.
contract AeroFarmingRouterOpTest is AutomationBase {
    int24 constant TS = 100;
    address internal constant USDC_OP = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // token0 of the OP pool
    address feeTaker;

    function setUp() public {
        _forkOp();
        _deployRouter(XAERO, false, WETH);
        (user, userKey) = makeAddrAndKey("aeroOpUser");
        feeTaker = V3Utils(payable(V3UTILS)).FEE_TAKER();
        deal(WETH, user, 50 ether);
        deal(USDC_OP, user, 100_000e6);
        _approveGauge(user, GAUGE_A_OP, true);
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_OP).approve(address(router), type(uint256).max);
        vm.stopPrank();
        _mint(GAUGE_A_OP, POOL_A_OP, USDC_OP, WETH, TS, 10_000e6, 5 ether, 10);
    }

    function _bal(address t, address a) internal view returns (uint256) {
        return IERC20(t).balanceOf(a);
    }

    function _earned() internal view returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return ICLGauge(GAUGE_A_OP).earned(user, ids);
    }

    function _liq() internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = INonfungiblePositionManager(NFPM).positions(id);
    }

    function _harvest(IAeroFarmingLogic.HarvestParams memory h) internal view returns (OrderParams memory) {
        return _params(IAeroFarmingLogic.AutoAction.AUTO_HARVEST, GAUGE_A_OP, abi.encode(h), user);
    }

    function test_op_zapInAndStake() public view {
        assertTrue(ICLGauge(GAUGE_A_OP).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_OP);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
        assertEq(_bal(WETH, address(router)), 0);
        assertEq(_bal(USDC_OP, address(router)), 0);
        assertEq(_bal(XAERO, address(router)), 0);
        assertEq(router.rewardToken(), XAERO);
        assertFalse(router.compoundEnabled());
        assertEq(router.weth(), WETH);
    }

    function test_op_compoundReverts() public {
        IAeroFarmingLogic.CompoundParams memory p;
        p.deadline = block.timestamp + 1 hours;
        vm.prank(user);
        vm.expectRevert(IAeroFarmingLogic.CompoundDisabled.selector);
        _compound(GAUGE_A_OP, id, p);
    }

    function test_op_autoHarvest_paysXAero() public {
        uint256 claimed = _earned();
        assertGt(claimed, 0, "no xAERO emissions accrued");
        IAeroFarmingLogic.HarvestParams memory h; // no target: pay the reward as is
        h.gasFeeX64 = 1 << 62;
        uint256 fee = FullMath.mulDiv(claimed, h.gasFeeX64, 2 ** 64);
        OrderParams memory p = _harvest(h);
        uint256 u0 = _bal(XAERO, user);
        uint256 ft0 = _bal(XAERO, feeTaker);
        uint256 hx = _bal(XAERO, address(router));
        vm.prank(operator);
        _executeOrder(p);
        assertGt(_bal(XAERO, user), u0);
        assertEq(_bal(XAERO, user) - u0, claimed - fee);
        assertEq(_bal(XAERO, feeTaker) - ft0, fee);
        assertEq(_bal(XAERO, address(router)), hx);
        assertTrue(ICLGauge(GAUGE_A_OP).stakedContains(user, id));
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
    }

    function test_op_autoHarvest_targetIsReward_succeeds() public {
        uint256 claimed = _earned();
        assertGt(claimed, 0, "no xAERO emissions accrued");
        IAeroFarmingLogic.HarvestParams memory h;
        h.targetToken = XAERO; // == reward: no swap, so compoundEnabled=false does not matter
        h.gasFeeX64 = 1 << 62;
        uint256 fee = FullMath.mulDiv(claimed, h.gasFeeX64, 2 ** 64);
        OrderParams memory p = _harvest(h);
        uint256 u0 = _bal(XAERO, user);
        uint256 hx = _bal(XAERO, address(router));
        vm.prank(operator);
        _executeOrder(p);
        assertEq(_bal(XAERO, user) - u0, claimed - fee);
        assertEq(_bal(XAERO, address(router)), hx);
    }

    function test_op_autoHarvest_swapReverts() public {
        IAeroFarmingLogic.HarvestParams memory h;
        h.targetToken = WETH;
        h.gasFeeX64 = 1 << 62;
        OrderParams memory p = _harvest(h);
        vm.prank(operator);
        vm.expectRevert(IAeroFarmingLogic.CompoundDisabled.selector);
        _executeOrder(p);
    }

    function test_op_removeWithClaimApproval_forwardsXAero() public {
        uint256 claimed = _earned();
        assertGt(claimed, 0, "no xAERO emissions accrued");
        V3Utils.Instructions memory ins;
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        ins.protocol = Nfpm.Protocol.AERODROME;
        ins.liquidity = _liq() / 2;
        ins.deadline = block.timestamp + 1 hours;
        uint256 x0 = _bal(XAERO, user);
        uint256 w0 = _bal(WETH, user);
        uint256 u0 = _bal(USDC_OP, user);
        vm.prank(user);
        _removeLiquidity(GAUGE_A_OP, id, ins);
        assertGe(_bal(XAERO, user) - x0, claimed);
        assertGt(_bal(WETH, user) + _bal(USDC_OP, user), w0 + u0);
        assertTrue(ICLGauge(GAUGE_A_OP).stakedContains(user, id));
        assertEq(_bal(XAERO, address(router)), 0);
        assertEq(_bal(WETH, address(router)), 0);
        assertEq(_bal(USDC_OP, address(router)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(router)), 0);
    }
}
