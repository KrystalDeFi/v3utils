// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AeroHarness is AeroFarmingHelper {
    function validateGauge(address g) external view returns (address) {
        return address(_validateGauge(g));
    }

    function requireLive(address g) external view {
        _requireLive(g);
    }
}

contract AeroFarmingHelperAdminTest is AeroForkBase {
    AeroFarmingHelper h;

    function setUp() public {
        _forkBase();
        h = _deployHelper(AERO, true, WETH);
    }

    function test_initialize_setsConfig() public {
        assertEq(h.v3utils(), V3UTILS);
        assertEq(address(h.gaugeFactory()), GAUGE_FACTORY);
        assertEq(h.rewardToken(), AERO);
        assertTrue(h.compoundEnabled());
        assertEq(h.weth(), WETH);
        assertEq(h.structHash(), STRUCT_HASH);
        assertTrue(h.hasRole(h.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), operator));
        assertTrue(h.hasRole(h.WITHDRAWER_ROLE(), withdrawer));
    }

    function test_initialize_twiceReverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        h.initialize(admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH);
    }

    function test_implementation_initializeReverts() public {
        AeroFarmingHelper impl = new AeroFarmingHelper();
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize(admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH);
    }

    function test_upgrade_nonAdminReverts() public {
        AeroFarmingHelper newImpl = new AeroFarmingHelper();
        vm.expectRevert();
        vm.prank(makeAddr("rando"));
        h.upgradeTo(address(newImpl));
    }

    function test_upgrade_adminPreservesState() public {
        AeroFarmingHelper newImpl = new AeroFarmingHelper();
        vm.prank(admin);
        h.upgradeTo(address(newImpl));
        assertEq(h.v3utils(), V3UTILS);
        assertEq(address(h.gaugeFactory()), GAUGE_FACTORY);
        assertEq(h.rewardToken(), AERO);
        assertTrue(h.compoundEnabled());
        assertEq(h.weth(), WETH);
        assertEq(h.structHash(), STRUCT_HASH);
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), operator));
    }

    function test_setV3Utils_onlyAdmin() public {
        address other = makeAddr("newV3");
        vm.expectRevert();
        vm.prank(makeAddr("rando"));
        h.setV3Utils(other);

        vm.prank(admin);
        h.setV3Utils(other);
        assertEq(h.v3utils(), other);

        address sh = makeAddr("newSh");
        vm.expectRevert();
        vm.prank(makeAddr("rando"));
        h.setStructHash(sh);
        vm.prank(admin);
        h.setStructHash(sh);
        assertEq(h.structHash(), sh);
    }

    function test_withdrawERC20_onlyWithdrawer() public {
        deal(USDC_BASE, address(h), 1000);
        vm.expectRevert();
        vm.prank(makeAddr("rando"));
        h.withdrawERC20(IERC20(USDC_BASE), makeAddr("to"));

        address to = makeAddr("to");
        IERC20 usdc = IERC20(USDC_BASE);
        vm.prank(withdrawer);
        h.withdrawERC20(usdc, to);
        assertEq(usdc.balanceOf(to), 1000);
    }

    function test_pause_blocksFlows() public {
        vm.expectRevert();
        vm.prank(makeAddr("rando"));
        h.pause();

        vm.prank(admin);
        h.pause();
        assertTrue(h.paused());
        vm.prank(admin);
        h.unpause();
        assertFalse(h.paused());
    }

    function test_validateGauge_rejectsNonGauge() public {
        AeroHarness hh = new AeroHarness();
        AeroHarness p = AeroHarness(
            payable(
                address(
                    new ERC1967Proxy(
                        address(hh),
                        abi.encodeCall(
                            AeroFarmingHelper.initialize,
                            (admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH)
                        )
                    )
                )
            )
        );
        vm.expectRevert(AeroFarmingHelper.InvalidGauge.selector);
        p.validateGauge(address(0xdead));
        assertEq(p.validateGauge(GAUGE_A_BASE), NFPM);
    }

    function test_validateGauge_acceptsGaugeA() public {
        AeroHarness hh = new AeroHarness();
        // AeroHarness constructor disables initializers; use a proxy
        AeroHarness p = AeroHarness(
            payable(
                address(
                    new ERC1967Proxy(
                        address(hh),
                        abi.encodeCall(
                            AeroFarmingHelper.initialize,
                            (admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH)
                        )
                    )
                )
            )
        );
        assertEq(p.validateGauge(GAUGE_A_BASE), NFPM);
        // The repo compiles with evm_version=london, and the live LeafVoter uses PUSH0, so the revm
        // hardfork here cannot execute it. Mock both branches instead of calling it live.
        bytes memory q = abi.encodeWithSelector(ILeafVoter.isActivated.selector, GAUGE_A_BASE);
        vm.mockCall(LEAF_VOTER, q, abi.encode(true));
        p.requireLive(GAUGE_A_BASE);
        vm.mockCall(LEAF_VOTER, q, abi.encode(false));
        vm.expectRevert(AeroFarmingHelper.GaugeNotLive.selector);
        p.requireLive(GAUGE_A_BASE);
    }

    function test_receive_onlyWeth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(h).call{value: 1}("");
        assertFalse(ok);
    }
}
