// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "../../src/StructHash.sol";
import "v3-core/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Calls the internal StructHash overload so the test can compare it with the deployed library.
contract StructHashHarness {
    function hashOrder(bytes memory encoded) external pure returns (bytes32) {
        return StructHash._hash(abi.decode(encoded, (StructHash.Order)));
    }
}

interface ICLPoolAuto {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256, int256);
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
        AeroFarmingHelper.Action action,
        bool automated
    );
    event CancelOrder(address user, bytes32 hash, bytes signature);

    function _mint(
        address gauge,
        address pool,
        address t0,
        address t1,
        int24 ts,
        uint256 a0,
        uint256 a1,
        int24 half
    ) internal returns (int24 base) {
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
        id = helper.zapInAndStake(gauge, p, false);
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
        bytes32 digest = helper.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _params(AeroFarmingHelper.AutoAction a, address gauge, bytes memory data, address account)
        internal
        view
        returns (AeroFarmingHelper.OrderParams memory p)
    {
        p.action = a;
        p.account = account;
        p.gauge = gauge;
        p.tokenId = id;
        p.actionData = data;
        p.order = _order();
        p.signature = _sign(userKey, p.order);
    }

    function _farmActions(Vm.Log[] memory logs, uint256 tokenId, AeroFarmingHelper.Action act, bool automated)
        internal
        view
        returns (uint256 found, uint256 newId)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(helper) || logs[i].topics[0] != FarmAction.selector) continue;
            if (logs[i].topics[3] != bytes32(tokenId)) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            (uint256 n, AeroFarmingHelper.Action a, bool au) =
                abi.decode(logs[i].data, (uint256, AeroFarmingHelper.Action, bool));
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
        _deployHelper(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroOrderUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        _approveGauge(user, GAUGE_A_BASE, false);
        vm.startPrank(user);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        IERC20(USDC_BASE).approve(address(helper), type(uint256).max);
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

    function _adjustParams() internal view returns (AeroFarmingHelper.OrderParams memory) {
        return _params(AeroFarmingHelper.AutoAction.AUTO_ADJUST, GAUGE_A_BASE, abi.encode(_rebalanceIns()), user);
    }

    function _assertClean() internal {
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0);
        assertEq(IERC20(USDC_BASE).balanceOf(address(helper)), 0);
        assertEq(IERC20(AERO).balanceOf(address(helper)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(helper)), 0);
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

    function test_domainSeparator_usesProxyAddress() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AeroFarmingHelper"),
                keccak256("1"),
                block.chainid,
                address(helper)
            )
        );
        assertEq(helper.domainSeparator(), expected);
        bytes memory o = _order();
        assertEq(
            helper.hashOrder(o), keccak256(abi.encodePacked("\x19\x01", expected, IStructHash(STRUCT_HASH)._hash(o)))
        );
    }

    function test_autoAdjust_validOrder() public {
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        vm.recordLogs();
        vm.prank(operator);
        uint256 newId = helper.executeOrder(p);
        assertTrue(newId != id);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
        assertEq(IERC721(NFPM).ownerOf(newId), GAUGE_A_BASE);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertEq(_liq(), 0);
        _assertClean();
        (uint256 found, uint256 n) =
            _farmActions(vm.getRecordedLogs(), id, AeroFarmingHelper.Action.REBALANCE, true);
        assertEq(found, 1);
        assertEq(n, newId);
    }

    function test_autoExit_validOrder() public {
        AeroFarmingHelper.OrderParams memory p =
            _params(AeroFarmingHelper.AutoAction.AUTO_EXIT, GAUGE_A_BASE, abi.encode(_ins(_liq())), user);
        vm.recordLogs();
        vm.prank(operator);
        helper.executeOrder(p);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(_liq(), 0);
        _assertClean();
        (uint256 found,) = _farmActions(vm.getRecordedLogs(), id, AeroFarmingHelper.Action.EXIT, true);
        assertEq(found, 1);
    }

    function test_execute_nonOperatorReverts() public {
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        bytes32 role = helper.OPERATOR_ROLE();
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
        helper.executeOrder(p);
    }

    function test_execute_wrongSignerReverts() public {
        (, uint256 otherKey) = makeAddrAndKey("aeroOrderOther");
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        p.signature = _sign(otherKey, p.order);
        vm.prank(operator);
        vm.expectRevert(AeroFarmingHelper.InvalidSignature.selector);
        helper.executeOrder(p);
    }

    function test_execute_signerNotStakeOwnerReverts() public {
        (address other, uint256 otherKey) = makeAddrAndKey("aeroOrderOther");
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        p.account = other;
        p.signature = _sign(otherKey, p.order); // perfectly valid signature, but other does not own the stake
        vm.prank(operator);
        vm.expectRevert(AeroFarmingHelper.NotStakeOwner.selector);
        helper.executeOrder(p);
    }

    function test_execute_cancelledReverts() public {
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        bytes32 digest = helper.hashOrder(p.order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertFalse(helper.isOrderCancelled(user, digest));
        vm.expectEmit(address(helper));
        emit CancelOrder(user, digest, sig);
        vm.prank(user);
        helper.cancelOrder(digest, sig);
        assertTrue(helper.isOrderCancelled(user, digest));
        assertFalse(helper.isOrderCancelled(operator, digest));
        vm.prank(operator);
        vm.expectRevert(AeroFarmingHelper.OrderCancelled.selector);
        helper.executeOrder(p);
    }

    function test_cancelOrder_badSignatureReverts() public {
        bytes memory o = _order();
        bytes32 digest = helper.hashOrder(o);
        (, uint256 otherKey) = makeAddrAndKey("aeroOrderOther");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(user);
        vm.expectRevert(AeroFarmingHelper.InvalidSignature.selector);
        helper.cancelOrder(digest, sig);
    }

    function test_orderValidAcrossUpgrade() public {
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        AeroFarmingHelper newImpl = new AeroFarmingHelper();
        vm.prank(admin);
        helper.upgradeTo(address(newImpl));
        vm.prank(operator);
        uint256 newId = helper.executeOrder(p);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, newId));
    }

    function test_execute_whenPausedReverts() public {
        AeroFarmingHelper.OrderParams memory p = _adjustParams();
        vm.prank(admin);
        helper.pause();
        vm.prank(operator);
        vm.expectRevert(bytes("Pausable: paused"));
        helper.executeOrder(p);
    }

    function test_autoHarvest_notSupportedYet() public {
        AeroFarmingHelper.OrderParams memory p =
            _params(AeroFarmingHelper.AutoAction.AUTO_HARVEST, GAUGE_A_BASE, "", user);
        vm.prank(operator);
        vm.expectRevert(AeroFarmingHelper.NotSupportedAction.selector);
        helper.executeOrder(p);
    }
}

contract AeroFarmingHelperAutoCompoundTest is AutomationBase {
    int24 constant TS = 200;

    function setUp() public {
        _forkBase();
        _deployHelper(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroOrderCompoundUser");
        deal(AERO, user, 100_000 ether);
        deal(WETH, user, 100 ether);
        _approveGauge(user, GAUGE_B_BASE, true);
        vm.startPrank(user);
        IERC20(AERO).approve(address(helper), type(uint256).max);
        IERC20(WETH).approve(address(helper), type(uint256).max);
        vm.stopPrank();
        int24 base = _mint(GAUGE_B_BASE, POOL_B_BASE, AERO, WETH, TS, 10_000 ether, 10 ether, 10);
        // sell AERO until the tick is below the range so the claim can be added with no swap
        deal(AERO, address(this), 50_000_000 ether);
        ICLPoolAuto(POOL_B_BASE).swap(
            address(this), true, int256(50_000_000 ether), TickMath.getSqrtRatioAtTick(base - 10 * TS - 100), ""
        );
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
        AeroFarmingHelper.CompoundParams memory c;
        c.deadline = block.timestamp + 1 hours;
        c.performanceFeeX64 = 1 << 62;
        AeroFarmingHelper.OrderParams memory p =
            _params(AeroFarmingHelper.AutoAction.AUTO_COMPOUND, GAUGE_B_BASE, abi.encode(c), user);
        vm.recordLogs();
        vm.prank(operator);
        helper.executeOrder(p);
        (,,,,,,, uint128 l1,,,,) = INonfungiblePositionManager(NFPM).positions(id);
        assertGt(l1, l0);
        assertTrue(ICLGauge(GAUGE_B_BASE).stakedContains(user, id));
        assertEq(IERC20(AERO).balanceOf(address(helper)), 0);
        assertEq(IERC20(WETH).balanceOf(address(helper)), 0);
        assertEq(IERC721(NFPM).balanceOf(address(helper)), 0);
        (uint256 found,) = _farmActions(vm.getRecordedLogs(), id, AeroFarmingHelper.Action.COMPOUND, true);
        assertEq(found, 1);
    }
}
