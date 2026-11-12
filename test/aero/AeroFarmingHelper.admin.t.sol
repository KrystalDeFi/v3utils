// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract AeroHarness is AeroFarmingHelper {
    function validateGauge(address g) external view returns (address) {
        return address(_validateGauge(g));
    }

    function requireLive(address g) external view {
        _requireLive(g);
    }
}

/// @dev Stand-in module whose answer proves which module the proxy fallback delegates to.
contract FakeAutomationModule {
    function domainSeparator() external pure returns (bytes32) {
        return bytes32(uint256(42));
    }
}

contract AeroFarmingHelperAdminTest is AeroForkBase {
    AeroFarmingHelper h;

    event AutomationModuleUpdated(address module);

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
        assertEq(h.automationModule(), address(moduleImpl));
        assertTrue(h.hasRole(h.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), operator));
        assertTrue(h.hasRole(h.WITHDRAWER_ROLE(), withdrawer));
    }

    function test_initialize_twiceReverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        h.initialize(
            admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH, address(moduleImpl)
        );
    }

    function test_implementation_initializeReverts() public {
        AeroFarmingHelper impl = new AeroFarmingHelper();
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize(
            admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH, address(moduleImpl)
        );
    }

    function test_upgrade_nonAdminReverts() public {
        AeroFarmingHelper newImpl = new AeroFarmingHelper();
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.DEFAULT_ADMIN_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
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
        assertEq(h.automationModule(), address(moduleImpl));
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), operator));
    }

    function test_setV3Utils_onlyAdmin() public {
        address other = makeAddr("newV3");
        address rando = makeAddr("rando");
        bytes memory err = _missingRole(rando, h.DEFAULT_ADMIN_ROLE());
        vm.expectRevert(err);
        vm.prank(rando);
        h.setV3Utils(other);

        vm.prank(admin);
        h.setV3Utils(other);
        assertEq(h.v3utils(), other);

        address sh = makeAddr("newSh");
        vm.expectRevert(err);
        vm.prank(rando);
        h.setStructHash(sh);
        vm.prank(admin);
        h.setStructHash(sh);
        assertEq(h.structHash(), sh);
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

    /// @dev Mints an NFT straight to the helper (a stray transfer the helper's receive guard would not accept).
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
        // transferFrom (not safeTransferFrom) so the helper's onERC721Received guard is bypassed
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
        bytes memory err = _missingRole(rando, h.DEFAULT_ADMIN_ROLE());
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

    function test_validateGauge_rejectsNonGauge() public {
        AeroHarness hh = new AeroHarness();
        AeroHarness p = AeroHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(hh),
                        abi.encodeCall(
                            AeroFarmingHelper.initialize,
                            (
                                admin,
                                operator,
                                withdrawer,
                                V3UTILS,
                                GAUGE_FACTORY,
                                AERO,
                                true,
                                WETH,
                                STRUCT_HASH,
                                address(moduleImpl)
                            )
                        )
                    )
                ))
        );
        vm.expectRevert(AeroFarmingCore.InvalidGauge.selector);
        p.validateGauge(address(0xdead));
        assertEq(p.validateGauge(GAUGE_A_BASE), NFPM);
    }

    function test_validateGauge_acceptsGaugeA() public {
        AeroHarness hh = new AeroHarness();
        // AeroHarness constructor disables initializers; use a proxy
        AeroHarness p = AeroHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(hh),
                        abi.encodeCall(
                            AeroFarmingHelper.initialize,
                            (
                                admin,
                                operator,
                                withdrawer,
                                V3UTILS,
                                GAUGE_FACTORY,
                                AERO,
                                true,
                                WETH,
                                STRUCT_HASH,
                                address(moduleImpl)
                            )
                        )
                    )
                ))
        );
        assertEq(p.validateGauge(GAUGE_A_BASE), NFPM);
        // The repo compiles with evm_version=london, and the live LeafVoter uses PUSH0, so the revm
        // hardfork here cannot execute it. Mock both branches instead of calling it live.
        bytes memory q = abi.encodeWithSelector(ILeafVoter.isActivated.selector, GAUGE_A_BASE);
        vm.mockCall(LEAF_VOTER, q, abi.encode(true));
        p.requireLive(GAUGE_A_BASE);
        vm.mockCall(LEAF_VOTER, q, abi.encode(false));
        vm.expectRevert(AeroFarmingCore.GaugeNotLive.selector);
        p.requireLive(GAUGE_A_BASE);
    }

    function test_receive_onlyWeth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(h).call{value: 1}("");
        assertFalse(ok);
    }

    function _domain(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AeroFarmingHelper"),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
    }

    function test_setAutomationModule_onlyAdmin() public {
        address fake = address(new FakeAutomationModule());
        address rando = makeAddr("aeroRando");
        bytes32 role = h.DEFAULT_ADMIN_ROLE();
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
        h.setAutomationModule(fake);
        assertEq(h.automationModule(), address(moduleImpl));
        assertEq(automation.domainSeparator(), _domain(address(h)));

        vm.expectEmit(address(h));
        emit AutomationModuleUpdated(fake);
        vm.prank(admin);
        h.setAutomationModule(fake);
        assertEq(h.automationModule(), fake);
        assertEq(automation.domainSeparator(), bytes32(uint256(42))); // the fallback now reaches the new module

        AeroAutomationModule m2 = new AeroAutomationModule();
        vm.prank(admin);
        h.setAutomationModule(address(m2));
        assertEq(h.automationModule(), address(m2));
        assertEq(automation.domainSeparator(), _domain(address(h)));
    }

    function test_setAutomationModule_codelessReverts() public {
        vm.prank(admin);
        vm.expectRevert(AeroFarmingCore.ModuleNotSet.selector);
        h.setAutomationModule(makeAddr("aeroCodelessModule"));
        assertEq(h.automationModule(), address(moduleImpl));

        AeroFarmingHelper impl = new AeroFarmingHelper();
        bytes memory init = abi.encodeCall(
            AeroFarmingHelper.initialize,
            (
                admin,
                operator,
                withdrawer,
                V3UTILS,
                GAUGE_FACTORY,
                AERO,
                true,
                WETH,
                STRUCT_HASH,
                makeAddr("aeroCodelessModule")
            )
        );
        vm.expectRevert(AeroFarmingCore.ModuleNotSet.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_fallback_moduleNotSetReverts() public {
        vm.prank(admin);
        h.setAutomationModule(address(0));
        vm.expectRevert(AeroFarmingCore.ModuleNotSet.selector);
        automation.domainSeparator();

        // a proxy initialised without a module
        AeroFarmingHelper impl = new AeroFarmingHelper();
        bytes memory init = abi.encodeCall(
            AeroFarmingHelper.initialize,
            (admin, operator, withdrawer, V3UTILS, GAUGE_FACTORY, AERO, true, WETH, STRUCT_HASH, address(0))
        );
        AeroAutomationModule bare = AeroAutomationModule(address(new ERC1967Proxy(address(impl), init)));
        AeroFarmingCore.OrderParams memory p;
        vm.expectRevert(AeroFarmingCore.ModuleNotSet.selector);
        vm.prank(operator);
        bare.executeOrder(p);
    }

    function test_fallback_unknownSelectorReverts() public {
        (bool ok, bytes memory ret) = address(h).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }
}

interface ICLPoolSlot0Admin {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
}
