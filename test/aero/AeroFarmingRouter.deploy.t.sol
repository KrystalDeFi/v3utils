// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroForkBase.sol";
import "../../script/AeroFarmingRouter.s.sol";

contract AeroFarmingRouterDeployTest is AeroForkBase {
    function test_deployScript_base() public {
        _forkBase();
        address adm = makeAddr("deployAdmin");
        address op = makeAddr("deployOperator");
        address wd = makeAddr("deployWithdrawer");
        address ps = makeAddr("deployPauser");
        uint256 pk = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        address deployer = vm.addr(pk);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));
        vm.setEnv("ADMIN", vm.toString(adm));
        vm.setEnv("OPERATOR", vm.toString(op));
        vm.setEnv("WITHDRAWER", vm.toString(wd));
        vm.setEnv("PAUSER", vm.toString(ps));
        vm.setEnv("V3UTILS", vm.toString(V3UTILS));
        vm.setEnv("GAUGE_FACTORY", vm.toString(GAUGE_FACTORY));
        vm.setEnv("REWARD_TOKEN", vm.toString(AERO));
        vm.setEnv("COMPOUND_ENABLED", "true");
        vm.setEnv("NATIVE_WETH", vm.toString(WETH));

        // env is process-global and forge runs tests in parallel, so the zero-address check shares this test
        AeroFarmingRouterScript script = new AeroFarmingRouterScript();
        vm.setEnv("ADMIN", vm.toString(address(0)));
        vm.expectRevert(bytes("ADMIN must be non-zero"));
        script.run();
        vm.setEnv("ADMIN", vm.toString(adm));
        vm.setEnv("PAUSER", vm.toString(address(0)));
        vm.expectRevert(bytes("PAUSER must be non-zero"));
        script.run();
        vm.setEnv("PAUSER", vm.toString(ps));

        vm.recordLogs();
        script.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the router is the emitter of ImplementationSet (emitted by initialize)
        address router_ = _routerFrom(logs);
        assertTrue(router_ != address(0), "router found");
        AeroFarmingRouter h = AeroFarmingRouter(payable(router_));

        assertEq(h.v3utils(), V3UTILS);
        assertEq(h.gaugeFactory(), GAUGE_FACTORY);
        assertEq(h.rewardToken(), AERO);
        assertTrue(h.compoundEnabled());
        assertEq(h.weth(), WETH);
        // exact role layout: admin holds DEFAULT_ADMIN_ROLE + ADMIN_ROLE, each other role one holder, deployer none
        bytes32[5] memory roles =
            [h.DEFAULT_ADMIN_ROLE(), h.ADMIN_ROLE(), h.PAUSER_ROLE(), h.OPERATOR_ROLE(), h.WITHDRAWER_ROLE()];
        address[5] memory holders = [adm, adm, ps, op, wd];
        address[5] memory who = [adm, ps, op, wd, deployer];
        for (uint256 r; r < roles.length; ++r) {
            for (uint256 a; a < who.length; ++a) {
                assertEq(h.hasRole(roles[r], who[a]), who[a] == holders[r], "role layout");
            }
        }
        address impl = h.implementation();
        assertGt(impl.code.length, 0);
        assertTrue(impl != router_);
        assertFalse(h.implementationLocked());
        // the operator path's domain is bound to the deployed router
        assertEq(h.DOMAIN_SEPARATOR(), _domain(router_));

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
        router_ = _routerFrom(logs);
        assertEq(AeroFarmingRouter(payable(router_)).rewardToken(), XAERO);
        assertFalse(AeroFarmingRouter(payable(router_)).compoundEnabled());
        vm.setEnv("REWARD_TOKEN", vm.toString(AERO));
        vm.setEnv("COMPOUND_ENABLED", "true");
    }

    function _routerFrom(Vm.Log[] memory logs) internal pure returns (address router_) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ImplementationSet(address)")) router_ = logs[i].emitter;
        }
    }

    function _domain(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AeroFarmingRouter"),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
    }

    function test_orderInterface_onRouter() public {
        _forkBase();
        _deployRouter(AERO, true, WETH);
        assertEq(router.DOMAIN_SEPARATOR(), _domain(address(router)));
        assertFalse(router.isOrderCancelled(address(this), bytes32(uint256(1))));
    }

    /// The logic must expose none of the router's admin, role or order functions: everything reachable through
    /// `execute` is a flow. Called on the logic directly, a function it has would revert NotDelegateCall (or
    /// return, for a view); an empty revert means it has no such function (and no fallback).
    function test_logic_hasNoRouterOnlySelectors() public {
        _forkBase();
        AeroFarmingLogic l = new AeroFarmingLogic();
        bytes4[17] memory sels = [
            AeroFarmingRouter.initialize.selector,
            AeroFarmingRouter.setImplementation.selector,
            AeroFarmingRouter.lockImplementation.selector,
            AeroFarmingRouter.setV3Utils.selector,
            AeroFarmingRouter.pause.selector,
            AeroFarmingRouter.unpause.selector,
            AeroFarmingRouter.withdrawERC20.selector,
            AeroFarmingRouter.withdrawERC721.selector,
            AeroFarmingRouter.withdrawNative.selector,
            AeroFarmingRouter.cancelOrder.selector,
            AeroFarmingRouter.executeAutomation.selector,
            AeroFarmingRouter.execute.selector,
            IAccessControl.grantRole.selector,
            IAccessControl.revokeRole.selector,
            IAccessControl.renounceRole.selector,
            IERC721Receiver.onERC721Received.selector,
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 i; i < sels.length; i++) {
            (bool ok, bytes memory ret) = address(l).call(abi.encodePacked(sels[i], new bytes(256)));
            assertFalse(ok, "must revert");
            assertEq(ret.length, 0, "logic has a router-only selector");
        }
    }
}
