// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "../../script/AeroFarmingHelper.s.sol";
import "../../src/aero/IAeroAutomation.sol";

contract AeroFarmingHelperDeployTest is AeroForkBase {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_deployScript_base() public {
        _forkBase();
        address adm = makeAddr("deployAdmin");
        address op = makeAddr("deployOperator");
        address wd = makeAddr("deployWithdrawer");
        uint256 pk = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        address deployer = vm.addr(pk);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));
        vm.setEnv("ADMIN", vm.toString(adm));
        vm.setEnv("OPERATOR", vm.toString(op));
        vm.setEnv("WITHDRAWER", vm.toString(wd));
        vm.setEnv("V3UTILS", vm.toString(V3UTILS));
        vm.setEnv("GAUGE_FACTORY", vm.toString(GAUGE_FACTORY));
        vm.setEnv("REWARD_TOKEN", vm.toString(AERO));
        vm.setEnv("COMPOUND_ENABLED", "true");
        vm.setEnv("NATIVE_WETH", vm.toString(WETH));
        vm.setEnv("STRUCT_HASH", vm.toString(STRUCT_HASH));

        // env is process-global and forge runs tests in parallel, so the zero-address check shares this test
        AeroFarmingHelperScript script = new AeroFarmingHelperScript();
        vm.setEnv("ADMIN", vm.toString(address(0)));
        vm.expectRevert(bytes("ADMIN must be non-zero"));
        script.run();
        vm.setEnv("ADMIN", vm.toString(adm));

        vm.recordLogs();
        script.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the proxy is the ERC1967Proxy whose Upgraded event is emitted by it
        address proxy;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Upgraded(address)")) proxy = logs[i].emitter;
        }
        assertTrue(proxy != address(0), "proxy found");
        AeroFarmingHelper h = AeroFarmingHelper(payable(proxy));

        assertEq(h.v3utils(), V3UTILS);
        assertEq(address(h.gaugeFactory()), GAUGE_FACTORY);
        assertEq(h.rewardToken(), AERO);
        assertTrue(h.compoundEnabled());
        assertEq(h.weth(), WETH);
        assertEq(h.structHash(), STRUCT_HASH);
        assertTrue(h.hasRole(h.DEFAULT_ADMIN_ROLE(), adm));
        assertTrue(h.hasRole(h.OPERATOR_ROLE(), op));
        assertTrue(h.hasRole(h.WITHDRAWER_ROLE(), wd));
        bytes32 aRole = h.DEFAULT_ADMIN_ROLE();
        bytes32 oRole = h.OPERATOR_ROLE();
        bytes32 wRole = h.WITHDRAWER_ROLE();
        assertFalse(h.hasRole(aRole, deployer));
        assertFalse(h.hasRole(oRole, deployer));
        assertFalse(h.hasRole(wRole, deployer));
        assertFalse(h.hasRole(oRole, adm));
        assertFalse(h.hasRole(wRole, adm));
        assertFalse(h.hasRole(aRole, op));
        assertFalse(h.hasRole(wRole, op));
        assertFalse(h.hasRole(aRole, wd));
        assertFalse(h.hasRole(oRole, wd));
        assertTrue(h.automationModule() != address(0));
        assertGt(h.automationModule().code.length, 0);
        address impl = address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
        assertGt(impl.code.length, 0);
        assertTrue(impl != h.automationModule());
        // the operator path works through the deployed proxy
        assertEq(IAeroAutomation(proxy).domainSeparator(), AeroAutomationModule(proxy).domainSeparator());

        // Base: COMPOUND_ENABLED must be true (env is process-global, so restored right after)
        vm.setEnv("COMPOUND_ENABLED", "false");
        vm.expectRevert(bytes("COMPOUND_ENABLED must be true on Base"));
        script.run();
        vm.setEnv("COMPOUND_ENABLED", "true");

        // non-Base chain: REWARD_TOKEN must equal the leaf voter's RECEIPT_TOKEN
        vm.chainId(10);
        vm.mockCall(LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.RECEIPT_TOKEN.selector), abi.encode(XAERO));
        vm.expectRevert(bytes("REWARD_TOKEN must be the leaf voter RECEIPT_TOKEN"));
        script.run(); // REWARD_TOKEN is still AERO
        vm.setEnv("REWARD_TOKEN", vm.toString(XAERO));
        vm.setEnv("COMPOUND_ENABLED", "false");
        vm.recordLogs();
        script.run();
        logs = vm.getRecordedLogs();
        proxy = address(0);
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Upgraded(address)")) proxy = logs[i].emitter;
        }
        assertEq(AeroFarmingHelper(payable(proxy)).rewardToken(), XAERO);
        assertFalse(AeroFarmingHelper(payable(proxy)).compoundEnabled());
        vm.setEnv("REWARD_TOKEN", vm.toString(AERO));
        vm.setEnv("COMPOUND_ENABLED", "true");
    }

    function test_automationInterface_throughProxy() public {
        _forkBase();
        _deployHelper(AERO, true, WETH);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AeroFarmingHelper"),
                keccak256("1"),
                block.chainid,
                address(helper)
            )
        );
        assertEq(IAeroAutomation(address(helper)).domainSeparator(), expected);
        assertFalse(IAeroAutomation(address(helper)).isOrderCancelled(address(this), bytes32(uint256(1))));
    }

    /// An IAeroAutomation selector defined on the helper itself would shadow the module. A helper with the
    /// module unset answers unknown selectors with ModuleNotSet, so reaching that revert proves the helper
    /// has no function of its own for the selector.
    function test_automationSelectors_notShadowedByHelper() public {
        _forkBase();
        AeroFarmingHelper impl = new AeroFarmingHelper(); // implementation: automationModule is unset
        bytes4[5] memory sels = [
            IAeroAutomation.executeOrder.selector,
            IAeroAutomation.cancelOrder.selector,
            IAeroAutomation.isOrderCancelled.selector,
            IAeroAutomation.domainSeparator.selector,
            IAeroAutomation.hashOrder.selector
        ];
        for (uint256 i; i < sels.length; i++) {
            (bool ok, bytes memory ret) = address(impl).call(abi.encodePacked(sels[i], new bytes(256)));
            assertFalse(ok, "must revert");
            assertEq(bytes4(ret), AeroFarmingCore.ModuleNotSet.selector, "selector served by helper itself");
        }
    }
}
