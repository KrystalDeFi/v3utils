// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";

interface ICLPoolSlot0B {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

contract AeroFarmingHelperCompoundTest is AeroForkBase {
    address user;
    int24 constant TS = 200;
    uint256 id;
    address feeTaker;

    event FarmAction(
        address indexed user,
        address indexed gauge,
        uint256 indexed tokenId,
        uint256 newTokenId,
        AeroFarmingHelper.Action action,
        bool automated
    );

    event DeductFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, Common.DeductFeesEventData data
    );

    function setUp() public {
        _forkBase();
        _deployHelper(AERO, true, WETH);
        user = makeAddr("aeroCompoundUser");
        feeTaker = V3Utils(payable(V3UTILS)).FEE_TAKER();
        deal(AERO, user, 100_000 ether);
        deal(WETH, user, 100 ether);
        _approveGauge(user, GAUGE_B_BASE, true);
        vm.startPrank(user);
        IERC20(AERO).approve(address(helper), type(uint256).max);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        vm.stopPrank();

        (, int24 tick,,,,) = ICLPoolSlot0B(POOL_B_BASE).slot0();
        int24 base = (tick / TS) * TS;
        Common.SwapAndMintParams memory p;
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.token0 = IERC20(AERO);
        p.token1 = IERC20(WETH);
        p.tickSpacing = TS;
        p.tickLower = base - 10 * TS;
        p.tickUpper = base + 10 * TS;
        p.amount0 = 10_000 ether;
        p.amount1 = 10 ether;
        p.deadline = block.timestamp + 1 hours;
        p.recipient = user;
        vm.prank(user);
        id = helper.zapInAndStake(GAUGE_B_BASE, p, false);

        (uint256 minStakeBlocks,) = ICLGaugeFactory(GAUGE_FACTORY).effectivePenaltyConfig(GAUGE_B_BASE);
        vm.roll(block.number + minStakeBlocks + 1000);
        vm.warp(block.timestamp + 2 * (minStakeBlocks + 1000));
        _pushPriceBelowRange(base - 10 * TS);
    }

    /// @dev AERO is token0 and the pool is in range, so a compound would need a swap (recorded router calldata is
    /// not available on the fork). Selling AERO into the pool until the tick is below the range makes the position
    /// token0-only, so the AERO claim can be added with no swap. The pool accrues the emissions up to this swap.
    function _pushPriceBelowRange(int24 tickLower) internal {
        deal(AERO, address(this), 50_000_000 ether);
        uint160 limit = TickMath.getSqrtRatioAtTick(tickLower - 100);
        ICLPoolSlot0B(POOL_B_BASE).swap(address(this), true, int256(50_000_000 ether), limit, "");
        (, int24 tick,,,,) = ICLPoolSlot0B(POOL_B_BASE).slot0();
        assertLt(tick, tickLower, "price not pushed below range");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes calldata) external {
        require(msg.sender == POOL_B_BASE);
        if (amount0Delta > 0) IERC20(AERO).transfer(msg.sender, uint256(amount0Delta));
    }

    function _earned() internal view returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return ICLGauge(GAUGE_B_BASE).earned(user, ids);
    }

    function _liq() internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = INonfungiblePositionManager(NFPM).positions(id);
    }

    function _bal(address t, address a) internal view returns (uint256) {
        return IERC20(t).balanceOf(a);
    }

    function _params(uint64 feeX64) internal view returns (AeroFarmingHelper.CompoundParams memory p) {
        p.deadline = block.timestamp + 1 hours;
        p.performanceFeeX64 = feeX64;
    }

    function test_compound_gaugeB_aeroIsToken0() public {
        uint256 claimed = _earned();
        assertGt(claimed, 0, "no emissions accrued");
        uint64 feeX64 = 1 << 62; // 25%
        uint256 expectedFee = FullMath.mulDiv(claimed, feeX64, 2 ** 64);
        uint128 l0 = _liq();
        uint256 ft0 = _bal(AERO, feeTaker);
        uint256 hA = _bal(AERO, address(helper));
        uint256 hW = _bal(WETH, address(helper));
        AeroFarmingHelper.CompoundParams memory p = _params(feeX64);

        vm.recordLogs();
        vm.prank(user);
        helper.compound(GAUGE_B_BASE, id, p);

        assertGt(_liq(), l0);
        assertEq(_bal(AERO, feeTaker) - ft0, expectedFee);
        assertEq(_bal(AERO, address(helper)), hA);
        assertEq(_bal(WETH, address(helper)), hW);
        assertEq(IERC721(NFPM).balanceOf(address(helper)), 0);
        assertTrue(ICLGauge(GAUGE_B_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_B_BASE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fees;
        uint256 actions;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(helper)) continue;
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
                assertEq(d.feeAmount0, expectedFee);
                assertEq(d.feeAmount1, 0);
                assertEq(d.feeAmount2, 0);
                assertEq(d.feeX64, feeX64);
                assertEq(uint8(d.feeType), uint8(Common.FeeType.PERFORMANCE_FEE));
            } else if (logs[i].topics[0] == FarmAction.selector) {
                ++actions;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(GAUGE_B_BASE))));
                assertEq(logs[i].topics[3], bytes32(id));
                (uint256 newId, AeroFarmingHelper.Action a, bool automated) =
                    abi.decode(logs[i].data, (uint256, AeroFarmingHelper.Action, bool));
                assertEq(newId, id);
                assertEq(uint8(a), uint8(AeroFarmingHelper.Action.COMPOUND));
                assertFalse(automated);
            }
        }
        assertEq(fees, 1);
        assertEq(actions, 1);
    }

    function test_compound_requiresClaimApproval() public {
        vm.prank(user);
        ICLGaugeApprovals(GAUGE_B_BASE).approveForClaim(address(helper), false);
        AeroFarmingHelper.CompoundParams memory p = _params(0);
        vm.prank(user);
        vm.expectRevert(bytes("NA"));
        helper.compound(GAUGE_B_BASE, id, p);
    }

    function test_compound_feeAboveCapReverts() public {
        AeroFarmingHelper.CompoundParams memory p = _params(5902958103587057001);
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.FeeTooHigh.selector);
        helper.compound(GAUGE_B_BASE, id, p);
    }

    function test_compound_disabledReverts() public {
        _deployHelper(AERO, false, WETH);
        AeroFarmingHelper h = helper;
        _approveGauge(user, GAUGE_B_BASE, true);
        AeroFarmingHelper.CompoundParams memory p = _params(0);
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.CompoundDisabled.selector);
        h.compound(GAUGE_B_BASE, id, p);
    }

    /// R2: the deployed V3Utils does not revert when amountIn0 exceeds the available claim and swapData0 is empty
    /// (the swap is a no-op), so the invariant under test is "no stuck funds": the flow succeeds, the position stays
    /// staked, the helper keeps nothing and any AERO not added reaches the user.
    function test_compound_quoteAboveClaim_noStuckFunds() public {
        uint256 claimed = _earned();
        uint64 feeX64 = 1 << 62;
        uint256 fee = FullMath.mulDiv(claimed, feeX64, 2 ** 64);
        AeroFarmingHelper.CompoundParams memory p = _params(feeX64);
        p.amountIn0 = claimed - fee + 1;
        uint128 l0 = _liq();
        uint256 u0 = _bal(AERO, user);
        uint256 hA = _bal(AERO, address(helper));
        uint256 hW = _bal(WETH, address(helper));
        uint256 ft0 = _bal(AERO, feeTaker);

        vm.prank(user);
        helper.compound(GAUGE_B_BASE, id, p);

        assertGt(_liq(), l0);
        assertTrue(ICLGauge(GAUGE_B_BASE).stakedContains(user, id));
        assertEq(_bal(AERO, address(helper)), hA);
        assertEq(_bal(WETH, address(helper)), hW);
        assertEq(IERC721(NFPM).balanceOf(address(helper)), 0);
        assertEq(_bal(AERO, feeTaker) - ft0, fee);
        // user's own AERO is untouched; whatever of the claim was not added comes back (never less)
        assertGe(_bal(AERO, user), u0);
        assertLe(_bal(AERO, user) - u0, claimed - fee);
    }
}
