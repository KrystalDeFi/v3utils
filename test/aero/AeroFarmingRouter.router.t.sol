// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroFarmingHelper.automation.t.sol";

/// @dev Swap router stand-in that tries to re-enter the router mid-flow (once with a user flow, once with the
/// automated entry while the automation account is recorded), records the revert data, then pays `amountOut`.
contract ReentrantSwapRouter {
    bytes public userRet;
    bytes public autoRet;
    bool public userOk;
    bool public autoOk;

    function swap(AeroFarmingRouter router, IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut, bytes memory autoCall)
        external
    {
        V3Utils.Instructions memory ins;
        (userOk, userRet) = address(router)
            .call(
                abi.encodeCall(
                    AeroFarmingRouter.execute, (abi.encodeCall(IAeroFarmingLogic.exit, (address(0), 0, ins)))
                )
            );
        (autoOk, autoRet) = address(router).call(abi.encodeCall(AeroFarmingRouter.execute, (autoCall)));
        tokenIn.transferFrom(msg.sender, address(this), tokenIn.allowance(msg.sender, address(this)));
        tokenOut.transfer(msg.sender, amountOut);
    }
}

contract AeroFarmingRouterTest is AutomationBase {
    int24 constant TS = 50;

    event ImplementationLockedForever(address implementation, address v3utils);

    function setUp() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        (user, userKey) = makeAddrAndKey("aeroRouterUser");
        deal(WETH, user, 10 ether);
        deal(USDC_BASE, user, 50_000e6);
        _approveGauge(user, GAUGE_A_BASE, true);
        vm.startPrank(user);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC_BASE).approve(address(router), type(uint256).max);
        vm.stopPrank();
        _mint(GAUGE_A_BASE, POOL_A_BASE, WETH, USDC_BASE, TS, 1 ether, 5000e6, 10);
    }

    function _liq() internal view returns (uint128 l) {
        (,,,,,,, l,,,,) = INonfungiblePositionManager(NFPM).positions(id);
    }

    function _exitIns() internal view returns (V3Utils.Instructions memory ins) {
        ins.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        ins.protocol = Nfpm.Protocol.AERODROME;
        ins.liquidity = _liq();
        ins.deadline = block.timestamp + 1 hours;
    }

    function _exitOrder() internal view returns (OrderParams memory) {
        return _params(IAeroFarmingLogic.AutoAction.AUTO_EXIT, GAUGE_A_BASE, abi.encode(_exitIns()), user);
    }

    function _assertUntouched(uint128 liq) internal {
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
        assertEq(IERC721(NFPM).ownerOf(id), GAUGE_A_BASE);
        assertEq(_liq(), liq);
    }

    function _missingRole(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        );
    }

    // ------------------------------------------------------------ Review Focus 1

    /// The automated entry needs the automation account recorded by executeAutomation; through `execute` it is
    /// zero, so neither the stake owner, an attacker, nor the operator can reach it.
    function test_execute_cannotReachAutomatedEntry() public {
        uint128 liq = _liq();
        bytes memory call_ = abi.encodeCall(
            IAeroFarmingLogic.executeAutomated,
            (IAeroFarmingLogic.AutoAction.AUTO_EXIT, user, GAUGE_A_BASE, id, abi.encode(_exitIns()))
        );
        address attacker = makeAddr("aeroRouterAttacker");
        address[3] memory callers = [user, attacker, operator];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IAeroFarmingLogic.NotAutomation.selector);
            router.execute(call_);
        }
        // account = 0 matches the cleared slot's value but is rejected too
        bytes memory zero = abi.encodeCall(
            IAeroFarmingLogic.executeAutomated,
            (IAeroFarmingLogic.AutoAction.AUTO_EXIT, address(0), GAUGE_A_BASE, id, abi.encode(_exitIns()))
        );
        vm.prank(attacker);
        vm.expectRevert(IAeroFarmingLogic.NotAutomation.selector);
        router.execute(zero);
        _assertUntouched(liq);
        // the slot is cleared after a real automated run
        OrderParams memory p = _exitOrder();
        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertEq(uint256(vm.load(address(router), bytes32(uint256(AeroStorage.SLOT) + 5))), 0);
    }

    // ------------------------------------------------------------ Review Focus 2

    function test_logic_directCallReverts() public {
        Common.SwapAndMintParams memory mp;
        Common.SwapAndIncreaseLiquidityParams memory ip;
        V3Utils.Instructions memory ins = _exitIns();
        IAeroFarmingLogic.CompoundParams memory cp;
        uint128 liq = _liq();
        vm.startPrank(user);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.zapInAndStake(GAUGE_A_BASE, mp, false);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.addLiquidity(GAUGE_A_BASE, ip, false);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.removeLiquidity(GAUGE_A_BASE, id, ins);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.exit(GAUGE_A_BASE, id, ins);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.rebalance(GAUGE_A_BASE, id, ins);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.compound(GAUGE_A_BASE, id, cp);
        vm.expectRevert(IAeroFarmingLogic.NotDelegateCall.selector);
        logic.executeAutomated(IAeroFarmingLogic.AutoAction.AUTO_EXIT, user, GAUGE_A_BASE, id, abi.encode(ins));
        vm.stopPrank();
        _assertUntouched(liq);
    }

    // ------------------------------------------------------------ Review Focus 3

    function test_order_wrongChainId_reverts() public {
        OrderParams memory p = _exitOrder();
        StructHash.Order memory o = abi.decode(p.order, (StructHash.Order));
        o.chainId = 10;
        p.order = abi.encode(o);
        p.signature = _sign(userKey, p.order); // a valid signature by the stake owner
        uint128 liq = _liq();
        vm.prank(operator);
        vm.expectRevert(AeroFarmingRouter.WrongChainId.selector);
        _executeOrder(p);
        _assertUntouched(liq);
    }

    function test_order_wrongNfpm_reverts() public {
        OrderParams memory p = _exitOrder();
        StructHash.Order memory o = abi.decode(p.order, (StructHash.Order));
        o.nfpmAddress = makeAddr("aeroOtherNfpm");
        p.order = abi.encode(o);
        p.signature = _sign(userKey, p.order);
        uint128 liq = _liq();
        vm.prank(operator);
        vm.expectRevert(AeroFarmingRouter.WrongPositionManager.selector);
        _executeOrder(p);
        _assertUntouched(liq);
    }

    // ------------------------------------------------------------ Review Focus 4

    function test_setImplementation_keepsStateAndOrders() public {
        OrderParams memory p = _exitOrder(); // signed before the swap
        bytes32 digest = router.hashOrder(p.order);
        AeroFarmingLogic newLogic = new AeroFarmingLogic();
        vm.prank(admin);
        router.setImplementation(address(newLogic));
        assertEq(router.implementation(), address(newLogic));
        assertEq(router.v3utils(), V3UTILS);
        assertEq(router.gaugeFactory(), GAUGE_FACTORY);
        assertEq(router.rewardToken(), AERO);
        assertTrue(router.compoundEnabled());
        assertEq(router.weth(), WETH);
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(router.hasRole(router.ADMIN_ROLE(), admin));
        assertTrue(router.hasRole(router.PAUSER_ROLE(), pauser));
        assertTrue(router.hasRole(router.OPERATOR_ROLE(), operator));
        assertTrue(router.hasRole(router.WITHDRAWER_ROLE(), withdrawer));
        assertEq(router.hashOrder(p.order), digest);

        vm.prank(operator);
        _executeOrder(p);
        assertEq(IERC721(NFPM).ownerOf(id), user);
        assertFalse(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
    }

    function test_lockImplementation() public {
        address rando = makeAddr("aeroRouterRando");
        bytes memory err = _missingRole(rando, router.ADMIN_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        router.lockImplementation();
        assertFalse(router.implementationLocked());

        vm.expectEmit(address(router));
        emit ImplementationLockedForever(address(logic), V3UTILS);
        vm.prank(admin);
        router.lockImplementation();
        assertTrue(router.implementationLocked());
        AeroFarmingLogic newLogic = new AeroFarmingLogic();
        vm.prank(admin);
        vm.expectRevert(AeroFarmingRouter.ImplementationLocked.selector);
        router.setImplementation(address(newLogic));
        assertEq(router.implementation(), address(logic));
        // the lock also freezes the V3Utils the logic hands NFTs to
        vm.prank(admin);
        vm.expectRevert(AeroFarmingRouter.ImplementationLocked.selector);
        router.setV3Utils(makeAddr("aeroRouterNewV3Utils"));
        assertEq(router.v3utils(), V3UTILS);

        // flows keep working on the locked logic
        uint128 part = _liq() / 3;
        V3Utils.Instructions memory ins = _exitIns();
        ins.liquidity = part;
        vm.prank(user);
        _removeLiquidity(GAUGE_A_BASE, id, ins);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
    }

    /// @dev `execute` is payable only for flows that take ETH; value sent to a non-payable flow reverts in the
    /// delegatecall (which checks callvalue) and leaves the router's balance untouched.
    function test_execute_valueToNonPayableFlow_reverts() public {
        vm.deal(user, 1 ether);
        uint256 before_ = address(router).balance;
        V3Utils.Instructions memory ins = _exitIns();
        bytes[2] memory calls = [
            abi.encodeCall(IAeroFarmingLogic.exit, (GAUGE_A_BASE, id, ins)),
            abi.encodeCall(IAeroFarmingLogic.removeLiquidity, (GAUGE_A_BASE, id, ins))
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(user);
            vm.expectRevert();
            router.execute{value: 1 wei}(calls[i]);
            assertEq(address(router).balance, before_, "router ETH balance changed");
        }
        assertEq(user.balance, 1 ether);
        assertTrue(ICLGauge(GAUGE_A_BASE).stakedContains(user, id));
    }

    // ------------------------------------------------------------ Review Focus 5

    function test_initialize_onlyDeployerOrigin() public {
        address deployer = makeAddr("aeroRouterDeployer");
        address rando = makeAddr("aeroRouterFrontRunner");
        vm.prank(deployer, deployer);
        AeroFarmingRouter r = new AeroFarmingRouter();

        // a front-runner (also when the deployer is only the tx.origin, not the caller) cannot initialize
        vm.prank(rando, rando);
        vm.expectRevert(AeroFarmingRouter.NotInitializer.selector);
        r.initialize(rando, rando, rando, rando, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH);
        vm.prank(rando, deployer);
        vm.expectRevert(AeroFarmingRouter.NotInitializer.selector);
        r.initialize(rando, rando, rando, rando, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH);

        vm.prank(deployer);
        r.initialize(admin, operator, withdrawer, pauser, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH);
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(r.hasRole(r.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(r.hasRole(r.DEFAULT_ADMIN_ROLE(), rando));

        // once only, even for the deployer
        vm.prank(deployer);
        vm.expectRevert(AeroFarmingRouter.AlreadyInitialized.selector);
        r.initialize(deployer, deployer, deployer, deployer, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH);
        assertFalse(r.hasRole(r.DEFAULT_ADMIN_ROLE(), deployer));
    }

    // ------------------------------------------------------------ implementation guards

    function test_execute_unsetImplementation_reverts() public {
        AeroFarmingRouter r = new AeroFarmingRouter(); // not initialized: no implementation
        assertEq(r.implementation(), address(0));
        V3Utils.Instructions memory ins = _exitIns();
        vm.prank(user);
        vm.expectRevert(AeroFarmingRouter.ImplementationNotSet.selector);
        r.execute(abi.encodeCall(IAeroFarmingLogic.exit, (GAUGE_A_BASE, id, ins)));
    }

    function test_setImplementation_requiresCode() public {
        address codeless = makeAddr("aeroCodelessLogic");
        vm.startPrank(admin);
        vm.expectRevert(AeroFarmingRouter.InvalidImplementation.selector);
        router.setImplementation(codeless);
        vm.expectRevert(AeroFarmingRouter.InvalidImplementation.selector);
        router.setImplementation(address(0));
        vm.stopPrank();
        assertEq(router.implementation(), address(logic));

        AeroFarmingRouter r = new AeroFarmingRouter();
        vm.prank(tx.origin);
        vm.expectRevert(AeroFarmingRouter.InvalidImplementation.selector);
        r.initialize(admin, operator, withdrawer, pauser, codeless, V3UTILS, GAUGE_FACTORY, AERO, true, WETH);
    }

    // ------------------------------------------------------------ execute surface

    /// `execute` only reaches logic functions: router admin and role functions are not in the logic, so passing
    /// their calldata through `execute` reverts and changes nothing.
    function test_execute_cannotReachAdminFunctions() public {
        address attacker = makeAddr("aeroRouterAttacker");
        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        bytes[4] memory calls = [
            abi.encodeCall(AeroFarmingRouter.setImplementation, (attacker)),
            abi.encodeCall(IAccessControl.grantRole, (adminRole, attacker)),
            abi.encodeCall(AeroFarmingRouter.withdrawNative, (attacker)),
            abi.encodeCall(AeroFarmingRouter.setV3Utils, (attacker))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(attacker);
            vm.expectRevert(bytes(""));
            router.execute(calls[i]);
        }
        assertEq(router.implementation(), address(logic));
        assertFalse(router.hasRole(adminRole, attacker));
        assertEq(router.v3utils(), V3UTILS);
    }

    /// A call back into the router from inside a flow (here the harvest swap router, during executeAutomation while
    /// the automation account is recorded) hits nonReentrant, both for a user flow and for the automated entry.
    function test_reentrancy_blockedDuringFlow() public {
        address swapRouter = makeAddr("aeroReentrantSwapRouter");
        vm.etch(swapRouter, address(new ReentrantSwapRouter()).code);
        vm.mockCall(V3UTILS, abi.encodeWithSignature("swapRouter()"), abi.encode(swapRouter));
        deal(USDC_BASE, swapRouter, 1_000e6);

        IAeroFarmingLogic.HarvestParams memory hp;
        hp.targetToken = USDC_BASE;
        bytes memory autoCall = abi.encodeCall(
            IAeroFarmingLogic.executeAutomated,
            (IAeroFarmingLogic.AutoAction.AUTO_EXIT, user, GAUGE_A_BASE, id, abi.encode(_exitIns()))
        );
        hp.swapData = abi.encodeCall(ReentrantSwapRouter.swap, (router, IERC20(AERO), IERC20(USDC_BASE), 1e6, autoCall));
        OrderParams memory p = _params(IAeroFarmingLogic.AutoAction.AUTO_HARVEST, GAUGE_A_BASE, abi.encode(hp), user);
        uint128 liq = _liq();
        uint256 u0 = IERC20(USDC_BASE).balanceOf(user);
        vm.prank(operator);
        _executeOrder(p);

        ReentrantSwapRouter r = ReentrantSwapRouter(swapRouter);
        bytes memory reentrant = abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call");
        assertFalse(r.userOk());
        assertEq(r.userRet(), reentrant);
        assertFalse(r.autoOk());
        assertEq(r.autoRet(), reentrant);
        assertEq(IERC20(USDC_BASE).balanceOf(user) - u0, 1e6);
        _assertUntouched(liq);
    }

    function test_storageSlot_matchesFormula() public {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("krystal.aero.farming.storage")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(AeroStorage.SLOT, expected);
        // config sits in the namespaced slot of the router
        assertEq(address(uint160(uint256(vm.load(address(router), AeroStorage.SLOT)))), V3UTILS);
    }
}
