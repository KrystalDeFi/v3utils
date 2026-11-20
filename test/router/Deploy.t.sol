// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {V3UtilsRouterScript} from "../../script/V3UtilsRouter.s.sol";
import {V3UtilsRouter} from "../../src/router/V3UtilsRouter.sol";
import {ICoreMint} from "../../src/router/interfaces/ICoreMint.sol";
import {ICoreModify} from "../../src/router/interfaces/ICoreModify.sol";
import {FeeType, AutoAction} from "../../src/router/RouterTypes.sol";
import {RouterTestBase} from "./RouterTestBase.sol";

/// @notice Runs the deploy script on a Base fork (cancun: the Aero farm reads the gauge factory).
contract DeployTest is RouterTestBase {
    address internal constant AERO_NFPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address internal constant UNI_NFPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address internal constant GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address internal constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant DEPLOYER_KEY = 0xA11CE5;

    function _setEnv() internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("ADMIN", vm.toString(makeAddr("dpAdmin")));
        vm.setEnv("OPERATOR", vm.toString(makeAddr("dpOperator")));
        vm.setEnv("WITHDRAWER", vm.toString(makeAddr("dpWithdrawer")));
        address swapRouter = makeAddr("dpSwapRouter");
        vm.etch(swapRouter, hex"00"); // the router refuses a codeless swap router
        vm.setEnv("SWAP_ROUTER", vm.toString(swapRouter));
        vm.setEnv("FEE_TAKER", vm.toString(makeAddr("dpFeeTaker")));
        vm.setEnv("NATIVE_WETH", vm.toString(WETH));
        vm.setEnv("NATIVE_MODE", "0");
        vm.setEnv("ADAPTERS", string.concat(vm.toString(UNI_NFPM), ":uni,", vm.toString(AERO_NFPM), ":aerodrome"));
        vm.setEnv("AERO_GAUGE_FACTORY", vm.toString(GAUGE_FACTORY));
        vm.setEnv("AERO_REWARD_TOKEN", vm.toString(AERO));
        vm.setEnv("AERO_COMPOUND_ENABLED", "true");
    }

    function test_deploy_base_registersEverything() public {
        _forkBase();
        _setEnv();
        V3UtilsRouterScript script = new V3UtilsRouterScript();
        script.run();
        (V3UtilsRouter r,,,) = script.deployed();

        bytes4[6] memory sels = [
            ICoreMint.swapAndMint.selector,
            ICoreMint.swapAndIncrease.selector,
            ICoreModify.decreaseAndSwap.selector,
            ICoreModify.adjustRange.selector,
            ICoreModify.compound.selector,
            ICoreModify.harvest.selector
        ];
        for (uint256 i = 0; i < sels.length; i++) {
            address m = r.module(sels[i]);
            assertGt(m.code.length, 0, "module has code");
        }
        // swapAndMint/swapAndIncrease share CoreMint; the four modify flows share CoreModify
        assertEq(r.module(sels[0]), r.module(sels[1]));
        assertEq(r.module(sels[2]), r.module(sels[5]));
        assertTrue(r.module(sels[0]) != r.module(sels[2]));

        // executeAutomation's action -> flow mapping
        assertEq(r.autoSelector(uint8(AutoAction.AUTO_ADJUST)), ICoreModify.adjustRange.selector, "AUTO_ADJUST");
        assertEq(r.autoSelector(uint8(AutoAction.AUTO_EXIT)), ICoreModify.decreaseAndSwap.selector, "AUTO_EXIT");
        assertEq(r.autoSelector(uint8(AutoAction.AUTO_COMPOUND)), ICoreModify.compound.selector, "AUTO_COMPOUND");
        assertEq(r.autoSelector(uint8(AutoAction.AUTO_HARVEST)), ICoreModify.harvest.selector, "AUTO_HARVEST");
        assertEq(r.autoSelector(4), bytes4(0), "nothing else mapped");

        assertGt(r.adapter(UNI_NFPM).code.length, 0, "uni adapter");
        assertGt(r.adapter(AERO_NFPM).code.length, 0, "aero adapter");
        assertTrue(r.adapter(UNI_NFPM) != r.adapter(AERO_NFPM));
        assertGt(r.farm(AERO_NFPM).code.length, 0, "aero farm");
        assertEq(r.farm(UNI_NFPM), address(0), "no farm on uni");

        assertEq(r.maxFeeX64(FeeType.GAS_FEE), 5534023222112865280);
        assertEq(r.maxFeeX64(FeeType.PROTOCOL_FEE), 5534023222112865280);
        assertEq(r.maxFeeX64(FeeType.PERFORMANCE_FEE), 5902958103587057000);
        assertEq(r.weth(), WETH);
        assertEq(r.nativeMode(), 0);
        assertFalse(r.locked(), "never locked");

        address deployer = vm.addr(DEPLOYER_KEY);
        assertFalse(r.hasRole(r.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(r.hasRole(r.ADMIN_ROLE(), deployer));
        assertFalse(r.hasRole(r.OPERATOR_ROLE(), deployer));
        assertFalse(r.hasRole(r.WITHDRAWER_ROLE(), deployer));
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), makeAddr("dpAdmin")));
        assertTrue(r.hasRole(r.ADMIN_ROLE(), makeAddr("dpAdmin")));
        assertTrue(r.hasRole(r.OPERATOR_ROLE(), makeAddr("dpOperator")));
        assertTrue(r.hasRole(r.WITHDRAWER_ROLE(), makeAddr("dpWithdrawer")));

        _assertBadConfigsRevert();
    }

    /// @dev Env vars are process-wide and forge runs tests in parallel, so the rejection cases run in the same test
    /// as the happy path instead of in tests of their own.
    function _assertBadConfigsRevert() internal {
        vm.setEnv("NATIVE_MODE", "1");
        vm.setEnv("NATIVE_WETH", vm.toString(makeAddr("noCodeView")));
        V3UtilsRouterScript s1 = new V3UtilsRouterScript();
        vm.expectRevert(bytes("NATIVE_WETH has no code (ENSHRINED needs the token view)"));
        s1.run();
        vm.setEnv("NATIVE_MODE", "0");
        vm.setEnv("NATIVE_WETH", vm.toString(WETH));

        vm.setEnv("ADAPTERS", string.concat(vm.toString(UNI_NFPM), ":nope"));
        V3UtilsRouterScript s2 = new V3UtilsRouterScript();
        vm.expectRevert(bytes("unknown adapter kind: nope"));
        s2.run();
    }
}
