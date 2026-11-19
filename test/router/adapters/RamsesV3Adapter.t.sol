// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {RamsesV3Adapter} from "../../../src/router/adapters/RamsesV3Adapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {PoolKey} from "../../../src/router/RouterTypes.sol";
import {AdapterConformance} from "./AdapterConformance.sol";

/// @dev Ramses V3 NFPM on HyperEVM (chain 999), found by enumerating the deployed V3Utils whitelist:
/// 0xb3f77c5134d643483253d22e0ca24627ae42ed51 ("Ramses V3 Non Fungible Position", `positions()` returns 10 words).
/// Run with `FOUNDRY_EVM_VERSION=cancun` (the HyperEVM contracts use post-shanghai opcodes; otherwise NotActivated).
/// The NFPM has no `factory()`; its `deployer()` exposes `RamsesV3Factory()`. WHYPE/USDC, tickSpacing 5.
contract RamsesV3AdapterTest is AdapterConformance {
    function _setUpFixture() internal override returns (Fixture memory x) {
        _forkHyperEvm();
        x.nfpm = 0xB3F77C5134D643483253D22E0Ca24627aE42ED51;
        x.adapter = address(new RamsesV3Adapter());
        x.key = PoolKey({
            token0: 0x5555555555555555555555555555555555555555, // WHYPE
            token1: 0xb88339CB7199b77E23DB6E890353E22632Ba630f, // USDC
            fee: 0,
            tickSpacing: 5,
            deployer: address(0)
        });
        // pool tick is -208736 at the pinned block
        x.tickLower = -209250;
        x.tickUpper = -208250;
        x.amount0 = 1 ether;
        x.amount1 = 900e6;
        x.expectedPool = 0x5a177cF0EfFB7e0e7115D792E587c1A5a9CbC9D4;
    }

    function test_directCall_reverts() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        RamsesV3Adapter(f.adapter).collect(f.nfpm, 1);
    }
}
