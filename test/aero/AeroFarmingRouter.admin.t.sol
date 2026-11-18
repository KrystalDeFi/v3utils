// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Exposes logic internals. Called directly (not through a router), so it reads its own AeroStorage slot,
/// which `setFactory` fills.
contract AeroHarness is AeroFarmingLogic {
    function setFactory(address f) external {
        AeroStorage.layout().gaugeFactory = f;
    }

    function gaugeOfPool(address t0, address t1, int24 ts) external view returns (address gauge) {
        (gauge,) = AeroGauge.ofPool(t0, t1, ts);
    }

    function requireLive(address g) external view {
        _requireLive(g);
    }
}

/// @dev Stand-in logic whose answer proves which implementation the router delegates to.
contract FakeLogic {
    function rebalance(uint256, V3Utils.Instructions memory) external pure returns (uint256) {
        return 42;
    }
}

contract AeroFarmingRouterAdminTest is AeroForkBase {
    AeroFarmingRouter h;

    event ImplementationSet(address implementation);

    function setUp() public {
        _forkBase();
        h = _deployRouter(AERO, true, WETH);
    }

    function test_initialize_setsConfig() public {
        assertEq(h.v3utils(), V3UTILS);
        assertEq(h.gaugeFactory(), GAUGE_FACTORY);
        assertEq(h.rewardToken(), AERO);
        assertTrue(h.compoundEnabled());
        assertEq(h.weth(), WETH);
        assertEq(h.implementation(), address(logic));
        assertFalse(h.implementationLocked());
        assertTrue(h.hasRole(h.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), operator));
        assertTrue(h.hasRole(h.WITHDRAWER_ROLE(), withdrawer));
    }

    /// Exact layout: admin holds DEFAULT_ADMIN_ROLE + ADMIN_ROLE, every other role sits with exactly one holder,
    /// the initializer holds nothing, and DEFAULT_ADMIN_ROLE administers every role.
    function test_initialize_roleLayout() public view {
        bytes32[4] memory roles = [h.DEFAULT_ADMIN_ROLE(), h.ADMIN_ROLE(), h.OPERATOR_ROLE(), h.WITHDRAWER_ROLE()];
        assertEq(roles[1], keccak256("ADMIN_ROLE"));
        address[4] memory holders = [admin, admin, operator, withdrawer];
        address[4] memory who = [admin, operator, withdrawer, tx.origin];
        for (uint256 r; r < roles.length; ++r) {
            assertEq(h.getRoleAdmin(roles[r]), h.DEFAULT_ADMIN_ROLE());
            for (uint256 a; a < who.length; ++a) {
                assertEq(h.hasRole(roles[r], who[a]), who[a] == holders[r]);
            }
        }
    }

    /// setImplementation, lockImplementation and setV3Utils need ADMIN_ROLE: every other role holder (and an
    /// account holding only DEFAULT_ADMIN_ROLE) is rejected with the exact AccessControl message.
    function test_adminSetters_rejectOtherRoles() public {
        address roleAdminOnly = makeAddr("aeroRoleAdminOnly");
        bytes32 defaultAdmin = h.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        h.grantRole(defaultAdmin, roleAdminOnly);
        address newLogic = address(new AeroFarmingLogic());
        address[4] memory callers = [operator, withdrawer, roleAdminOnly, makeAddr("rando")];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory err = _missingRole(callers[i], h.ADMIN_ROLE());
            vm.expectRevert(err);
            vm.prank(callers[i]);
            h.setImplementation(newLogic);
            vm.expectRevert(err);
            vm.prank(callers[i]);
            h.lockImplementation();
            vm.expectRevert(err);
            vm.prank(callers[i]);
            h.setV3Utils(newLogic);
        }
        assertEq(h.implementation(), address(logic));
        assertEq(h.v3utils(), V3UTILS);
        assertFalse(h.implementationLocked());
    }

    /// pause/unpause need ADMIN_ROLE (as in v4utils): the operator, the withdrawer and a DEFAULT_ADMIN_ROLE-only
    /// holder are rejected; the admin can pause and unpause.
    function test_pause_onlyAdmin() public {
        address roleAdminOnly = makeAddr("aeroRoleAdminOnlyPause");
        bytes32 defaultAdmin = h.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        h.grantRole(defaultAdmin, roleAdminOnly);
        address[3] memory callers = [operator, withdrawer, roleAdminOnly];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory err = _missingRole(callers[i], h.ADMIN_ROLE());
            vm.expectRevert(err);
            vm.prank(callers[i]);
            h.pause();
            vm.expectRevert(err);
            vm.prank(callers[i]);
            h.unpause();
        }
        assertFalse(h.paused());

        vm.prank(admin);
        h.pause();
        assertTrue(h.paused());
        bytes memory opErr = _missingRole(operator, h.ADMIN_ROLE());
        vm.expectRevert(opErr);
        vm.prank(operator);
        h.unpause();
        vm.prank(admin);
        h.unpause();
        assertFalse(h.paused());
    }

    function test_initialize_twiceReverts() public {
        vm.expectRevert(AeroFarmingRouter.AlreadyInitialized.selector);
        vm.prank(tx.origin);
        h.initialize(admin, operator, withdrawer, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH);
    }

    function test_logic_hasNoInitialize() public {
        bytes memory init = abi.encodeCall(
            AeroFarmingRouter.initialize,
            (admin, operator, withdrawer, address(logic), V3UTILS, GAUGE_FACTORY, AERO, true, WETH)
        );
        vm.prank(tx.origin);
        (bool ok, bytes memory ret) = address(logic).call(init);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_setImplementation_nonAdminReverts() public {
        AeroFarmingLogic newLogic = new AeroFarmingLogic();
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.ADMIN_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.setImplementation(address(newLogic));
        assertEq(h.implementation(), address(logic));
    }

    function test_setImplementation_adminPreservesState() public {
        AeroFarmingLogic newLogic = new AeroFarmingLogic();
        vm.prank(admin);
        h.setImplementation(address(newLogic));
        assertEq(h.implementation(), address(newLogic));
        assertEq(h.v3utils(), V3UTILS);
        assertEq(h.gaugeFactory(), GAUGE_FACTORY);
        assertEq(h.rewardToken(), AERO);
        assertTrue(h.compoundEnabled());
        assertEq(h.weth(), WETH);
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), operator));
    }

    function test_setV3Utils_onlyAdmin() public {
        address other = makeAddr("newV3");
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.ADMIN_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.setV3Utils(other);

        // zero or codeless: rejected (a later lockImplementation would freeze it forever)
        vm.startPrank(admin);
        vm.expectRevert(AeroFarmingRouter.InvalidV3Utils.selector);
        h.setV3Utils(address(0));
        vm.expectRevert(AeroFarmingRouter.InvalidV3Utils.selector);
        h.setV3Utils(other);
        assertEq(h.v3utils(), V3UTILS);

        vm.etch(other, hex"00");
        h.setV3Utils(other);
        vm.stopPrank();
        assertEq(h.v3utils(), other);
    }

    function test_withdrawERC20_onlyWithdrawer() public {
        deal(USDC_BASE, address(h), 1000);
        address rando = makeAddr("rando");
        address to = makeAddr("to");
        bytes memory err = _missingRole(rando, h.WITHDRAWER_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.withdrawERC20(IERC20(USDC_BASE), to);

        IERC20 usdc = IERC20(USDC_BASE);
        vm.prank(withdrawer);
        h.withdrawERC20(usdc, to);
        assertEq(usdc.balanceOf(to), 1000);
    }

    function test_withdrawERC721_onlyWithdrawer() public {
        uint256 tokenId = _strayNft();
        address to = makeAddr("nftTo");
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.WITHDRAWER_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.withdrawERC721(IERC721(NFPM), tokenId, to);
        assertEq(IERC721(NFPM).ownerOf(tokenId), address(h));

        vm.prank(withdrawer);
        h.withdrawERC721(IERC721(NFPM), tokenId, to);
        assertEq(IERC721(NFPM).ownerOf(tokenId), to);
    }

    function test_withdrawNative_onlyWithdrawer() public {
        vm.deal(address(h), 3 ether);
        address to = makeAddr("nativeTo");
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.WITHDRAWER_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.withdrawNative(to);
        assertEq(address(h).balance, 3 ether);

        vm.prank(withdrawer);
        h.withdrawNative(to);
        assertEq(to.balance, 3 ether);
        assertEq(address(h).balance, 0);
    }

    /// @dev Mints an NFT straight to the router (a stray transfer the router's receive guard would not accept).
    function _strayNft() internal returns (uint256 tokenId) {
        address minter = makeAddr("strayMinter");
        deal(WETH, minter, 1 ether);
        deal(USDC_BASE, minter, 5000e6);
        (, int24 tick,,,,) = ICLPoolSlot0Admin(POOL_A_BASE).slot0();
        int24 base = (tick / 50) * 50;
        Common.SwapAndMintParams memory p;
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = INonfungiblePositionManager(NFPM);
        p.token0 = IERC20(WETH);
        p.token1 = IERC20(USDC_BASE);
        p.tickSpacing = 50;
        p.tickLower = base - 500;
        p.tickUpper = base + 500;
        p.amount0 = 1 ether;
        p.amount1 = 5000e6;
        p.deadline = block.timestamp + 1 hours;
        p.recipient = minter;
        vm.startPrank(minter);
        IERC20(WETH).approve(V3UTILS, type(uint256).max);
        IERC20(USDC_BASE).approve(V3UTILS, type(uint256).max);
        tokenId = V3UtilsLike(V3UTILS).swapAndMint(p).tokenId;
        vm.stopPrank();
        // transferFrom (not safeTransferFrom) so the router's onERC721Received guard is bypassed
        vm.prank(minter);
        IERC721(NFPM).transferFrom(minter, address(h), tokenId);
    }

    function _missingRole(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        );
    }

    function test_pause_blocksFlows() public {
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.ADMIN_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.pause();

        vm.prank(admin);
        h.pause();
        assertTrue(h.paused());
        vm.prank(admin);
        h.unpause();
        assertFalse(h.paused());
    }

    function test_gaugeOfPool_rejectsNoPoolOrForeignGauge() public {
        AeroHarness p = new AeroHarness();
        p.setFactory(GAUGE_FACTORY);
        vm.expectRevert(IAeroFarmingLogic.InvalidGauge.selector);
        p.gaugeOfPool(WETH, USDC_BASE, 7); // no pool at this tickSpacing
        vm.mockCall(POOL_A_BASE, abi.encodeWithSelector(ICLPool.gauge.selector), abi.encode(address(0xdead)));
        vm.expectRevert(IAeroFarmingLogic.InvalidGauge.selector);
        p.gaugeOfPool(WETH, USDC_BASE, 50); // the pool reports a gauge the factory did not create
        vm.clearMockedCalls();
        assertEq(p.gaugeOfPool(USDC_BASE, WETH, 50), GAUGE_A_BASE); // token order does not matter
    }

    function test_validateGauge_acceptsGaugeA() public {
        AeroHarness p = new AeroHarness();
        p.setFactory(GAUGE_FACTORY);
        assertEq(p.gaugeOfPool(WETH, USDC_BASE, 50), GAUGE_A_BASE);
        // The repo compiles with evm_version=london, and the live LeafVoter uses PUSH0, so the revm
        // hardfork here cannot execute it. Mock both branches instead of calling it live.
        bytes memory q = abi.encodeWithSelector(ILeafVoter.isActivated.selector, GAUGE_A_BASE);
        vm.mockCall(LEAF_VOTER, q, abi.encode(true));
        p.requireLive(GAUGE_A_BASE);
        vm.mockCall(LEAF_VOTER, q, abi.encode(false));
        vm.expectRevert(IAeroFarmingLogic.GaugeNotLive.selector);
        p.requireLive(GAUGE_A_BASE);
    }

    function test_receive_onlyWeth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(h).call{value: 1}("");
        assertFalse(ok);
    }

    function _rebalanceViaRouter() internal returns (uint256) {
        V3Utils.Instructions memory ins;
        return abi.decode(h.execute(abi.encodeCall(IAeroFarmingLogic.rebalance, (1, ins))), (uint256));
    }

    function test_setImplementation_onlyAdmin() public {
        address fake = address(new FakeLogic());
        address rando = makeAddr("aeroRando");
        bytes32 role = h.ADMIN_ROLE();
        vm.expectRevert(
            bytes(
                string.concat(
                    "AccessControl: account ",
                    Strings.toHexString(rando),
                    " is missing role ",
                    Strings.toHexString(uint256(role), 32)
                )
            )
        );
        vm.prank(rando);
        h.setImplementation(fake);
        assertEq(h.implementation(), address(logic));

        vm.expectEmit(address(h));
        emit ImplementationSet(fake);
        vm.prank(admin);
        h.setImplementation(fake);
        assertEq(h.implementation(), fake);
        assertEq(_rebalanceViaRouter(), 42); // execute now reaches the new logic

        AeroFarmingLogic l2 = new AeroFarmingLogic();
        vm.prank(admin);
        h.setImplementation(address(l2));
        assertEq(h.implementation(), address(l2));
        V3Utils.Instructions memory ins;
        vm.expectRevert(); // the real logic again: a nonexistent position has no pool to derive a gauge from
        h.execute(abi.encodeCall(IAeroFarmingLogic.rebalance, (type(uint256).max, ins)));
    }

    function test_router_unknownSelectorReverts() public {
        (bool ok, bytes memory ret) = address(h).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok);
        assertEq(ret.length, 0);
        // an unknown selector passed through execute reaches the logic, which has no fallback either
        vm.expectRevert(bytes(""));
        h.execute(abi.encodeWithSelector(bytes4(0xdeadbeef)));
    }
}

interface ICLPoolSlot0Admin {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
}
