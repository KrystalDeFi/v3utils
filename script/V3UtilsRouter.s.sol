// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {V3UtilsRouter} from "../src/router/V3UtilsRouter.sol";
import {CoreMint} from "../src/router/modules/CoreMint.sol";
import {CoreModify} from "../src/router/modules/CoreModify.sol";
import {ICoreMint} from "../src/router/interfaces/ICoreMint.sol";
import {ICoreModify} from "../src/router/interfaces/ICoreModify.sol";
import {UniV3Adapter} from "../src/router/adapters/UniV3Adapter.sol";
import {AlgebraV1Adapter} from "../src/router/adapters/AlgebraV1Adapter.sol";
import {AerodromeAdapter} from "../src/router/adapters/AerodromeAdapter.sol";
import {RamsesV3Adapter} from "../src/router/adapters/RamsesV3Adapter.sol";
import {AlgebraIntegralAdapter} from "../src/router/adapters/AlgebraIntegralAdapter.sol";
import {AeroGaugeFarm} from "../src/router/farms/AeroGaugeFarm.sol";
import {AutoAction} from "../src/router/RouterTypes.sol";

/// @notice Deploys V3UtilsRouter, its two modules, the adapters the chain needs and (with AERO_GAUGE_FACTORY) the Aero
/// gauge farm; initializes the router and registers every module selector, automation action, adapter and farm in one
/// broadcast. Plain CREATE (the init args differ per chain); the deployer EOA is tx.origin, so it may call `initialize`.
/// The deployer is the temporary admin (registration needs ADMIN_ROLE): it initializes with itself as admin, registers,
/// then grants DEFAULT_ADMIN_ROLE + ADMIN_ROLE to ADMIN and renounces both, all in the same broadcast, so it holds no
/// role once the script ends (when ADMIN is the deployer itself, it keeps them). It never calls `lock()`: lock by hand
/// once the deployment is checked.
/// Env (see sample.env): PRIVATE_KEY, ADMIN, OPERATOR, WITHDRAWER, SWAP_ROUTER, FEE_TAKER, NATIVE_WETH, NATIVE_MODE
/// (0 WRAPPED, 1 ENSHRINED), ADAPTERS (`nfpm:kind,nfpm:kind`; kind is uni, algebrav1, aerodrome, ramses or integral)
/// and optionally AERO_GAUGE_FACTORY, AERO_REWARD_TOKEN, AERO_COMPOUND_ENABLED (set the first two together; the farm
/// is registered on every `aerodrome` NFPM).
contract V3UtilsRouterScript is Script {
    struct Deployment {
        V3UtilsRouter router;
        CoreMint coreMint;
        CoreModify coreModify;
        AeroGaugeFarm farm;
    }

    struct Aero {
        address gaugeFactory;
        address rewardToken;
        bool compoundEnabled;
    }

    uint256 internal constant KIND_AERODROME = 2;

    /// @dev Set by `run`, read back by tests.
    Deployment public deployed;

    function run() external returns (Deployment memory d) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = _required("ADMIN");
        address operator = _required("OPERATOR");
        address withdrawer = _required("WITHDRAWER");
        address swapRouter = _required("SWAP_ROUTER");
        address feeTaker = _required("FEE_TAKER");
        address weth = _required("NATIVE_WETH");
        uint8 nativeMode = uint8(vm.envUint("NATIVE_MODE"));
        require(nativeMode <= 1, "NATIVE_MODE must be 0 (WRAPPED) or 1 (ENSHRINED)");
        // an ENSHRINED view with no code is skipped by the flows (they treat a codeless non-native token as absent)
        if (nativeMode == 1) require(weth.code.length > 0, "NATIVE_WETH has no code (ENSHRINED needs the token view)");

        Aero memory aero = Aero({
            gaugeFactory: vm.envOr("AERO_GAUGE_FACTORY", address(0)),
            rewardToken: vm.envOr("AERO_REWARD_TOKEN", address(0)),
            compoundEnabled: vm.envOr("AERO_COMPOUND_ENABLED", false)
        });
        require(
            (aero.gaugeFactory == address(0)) == (aero.rewardToken == address(0)),
            "AERO_GAUGE_FACTORY and AERO_REWARD_TOKEN go together"
        );
        (address[] memory nfpms, string[] memory kinds) = _parseAdapters(vm.envString("ADAPTERS"));

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        d.router = new V3UtilsRouter();
        d.coreMint = new CoreMint();
        d.coreModify = new CoreModify();
        // Registration needs ADMIN_ROLE and only the deployer (tx.origin) can initialize, so the deployer is the first
        // admin; the roles move to ADMIN and the deployer renounces them at the end of the same broadcast.
        d.router.initialize(deployer, operator, withdrawer, swapRouter, feeTaker, weth, nativeMode);

        _registerModules(d);
        _registerAdapters(d, nfpms, kinds, aero);

        if (admin != deployer) {
            d.router.grantRole(d.router.DEFAULT_ADMIN_ROLE(), admin);
            d.router.grantRole(d.router.ADMIN_ROLE(), admin);
            d.router.renounceRole(d.router.ADMIN_ROLE(), deployer);
            d.router.renounceRole(d.router.DEFAULT_ADMIN_ROLE(), deployer);
        }
        deployed = d;

        vm.stopBroadcast();

        console.log("V3UtilsRouter:", address(d.router));
        console.log("CoreMint:", address(d.coreMint));
        console.log("CoreModify:", address(d.coreModify));
        if (address(d.farm) != address(0)) console.log("AeroGaugeFarm:", address(d.farm));
        console.log("Not locked: call lock() once the deployment is checked.");
    }

    /// @dev One adapter per kind, shared by every NFPM of that kind; the farm goes on every `aerodrome` NFPM.
    function _registerAdapters(Deployment memory d, address[] memory nfpms, string[] memory kinds, Aero memory aero)
        internal
    {
        address[5] memory adapters;
        for (uint256 i = 0; i < nfpms.length; i++) {
            uint256 k = _kindIndex(kinds[i]);
            if (adapters[k] == address(0)) adapters[k] = _deployAdapter(k);
            d.router.setAdapter(nfpms[i], adapters[k]);
            if (k == KIND_AERODROME && aero.gaugeFactory != address(0)) {
                if (address(d.farm) == address(0)) {
                    d.farm = new AeroGaugeFarm(aero.gaugeFactory, aero.rewardToken, aero.compoundEnabled);
                }
                d.router.setFarm(nfpms[i], address(d.farm));
            }
        }
        require(
            aero.gaugeFactory == address(0) || address(d.farm) != address(0),
            "AERO_GAUGE_FACTORY set but no aerodrome NFPM in ADAPTERS"
        );
    }

    function _registerModules(Deployment memory d) internal {
        d.router.setModule(ICoreMint.swapAndMint.selector, address(d.coreMint));
        d.router.setModule(ICoreMint.swapAndIncrease.selector, address(d.coreMint));
        d.router.setModule(ICoreModify.decreaseAndSwap.selector, address(d.coreModify));
        d.router.setModule(ICoreModify.adjustRange.selector, address(d.coreModify));
        d.router.setModule(ICoreModify.compound.selector, address(d.coreModify));
        d.router.setModule(ICoreModify.harvest.selector, address(d.coreModify));
        // executeAutomation's action -> flow mapping (AutoAction ordinals)
        d.router.setAutoSelector(uint8(AutoAction.AUTO_ADJUST), ICoreModify.adjustRange.selector);
        d.router.setAutoSelector(uint8(AutoAction.AUTO_EXIT), ICoreModify.decreaseAndSwap.selector);
        d.router.setAutoSelector(uint8(AutoAction.AUTO_COMPOUND), ICoreModify.compound.selector);
        d.router.setAutoSelector(uint8(AutoAction.AUTO_HARVEST), ICoreModify.harvest.selector);
    }

    function _deployAdapter(uint256 k) internal returns (address) {
        if (k == 0) return address(new UniV3Adapter());
        if (k == 1) return address(new AlgebraV1Adapter());
        if (k == KIND_AERODROME) return address(new AerodromeAdapter());
        if (k == 3) return address(new RamsesV3Adapter());
        return address(new AlgebraIntegralAdapter());
    }

    function _kindIndex(string memory kind) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(kind));
        if (h == keccak256("uni")) return 0;
        if (h == keccak256("algebrav1")) return 1;
        if (h == keccak256("aerodrome")) return KIND_AERODROME;
        if (h == keccak256("ramses")) return 3;
        if (h == keccak256("integral")) return 4;
        revert(string.concat("unknown adapter kind: ", kind));
    }

    function _required(string memory key) internal view returns (address a) {
        a = vm.envAddress(key);
        require(a != address(0), string.concat(key, " must be non-zero"));
    }

    /// @dev `nfpm:kind,nfpm:kind` into parallel arrays.
    function _parseAdapters(string memory raw) internal view returns (address[] memory nfpms, string[] memory kinds) {
        string[] memory pairs = vm.split(raw, ",");
        nfpms = new address[](pairs.length);
        kinds = new string[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            string[] memory kv = vm.split(pairs[i], ":");
            require(kv.length == 2, string.concat("ADAPTERS entry must be nfpm:kind: ", pairs[i]));
            nfpms[i] = vm.parseAddress(kv[0]);
            require(nfpms[i] != address(0), "ADAPTERS nfpm must be non-zero");
            kinds[i] = kv[1];
        }
    }

    // To ignore from test coverage
    function test() external {}
}
