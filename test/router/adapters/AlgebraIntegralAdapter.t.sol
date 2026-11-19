// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AlgebraIntegralAdapter} from "../../../src/router/adapters/AlgebraIntegralAdapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {PoolKey} from "../../../src/router/RouterTypes.sol";
import {AdapterConformance} from "./AdapterConformance.sol";

/// @dev Algebra Integral NFPM on Avalanche (chain 43114), found by enumerating the deployed V3Utils whitelist:
/// 0x3fed017ec0f5517cdf2e8a9a4156c64d74252146 ("Algebra Positions NFT-V2", `positions()` has a `deployer` field).
/// The only live pool found there is a custom-deployer pool (no default-deployer WAVAX/USDC pool exists), so the
/// fixture runs the `customPoolByPair` path: sAVAX/WAVAX under deployer 0xdcfc..5d29, tickSpacing 1.
/// Archive state at the pin is served by api.avax.network (other public Avalanche RPCs are pruned).
contract AlgebraIntegralAdapterTest is AdapterConformance {
    address internal constant CUSTOM_DEPLOYER = 0xDcFccf2e8c4EfBba9127B80eAc76c5A122125d29;

    function _setUpFixture() internal override returns (Fixture memory x) {
        _forkAvalanche();
        x.nfpm = 0x3fED017EC0f5517Cdf2E8a9a4156c64d74252146;
        x.adapter = address(new AlgebraIntegralAdapter());
        x.key = PoolKey({
            token0: 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE, // sAVAX
            token1: 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, // WAVAX
            fee: 0,
            tickSpacing: 1,
            deployer: CUSTOM_DEPLOYER
        });
        // pool tick is 2565 at the pinned block
        x.tickLower = 2300;
        x.tickUpper = 2800;
        x.amount0 = 1 ether;
        x.amount1 = 1.3 ether;
        x.expectedPool = 0xeE2Ceda742bfb2ef566aB57642D47aBA1909B653;
    }

    function test_directCall_reverts() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        AlgebraIntegralAdapter(f.adapter).collect(f.nfpm, 1);
    }
}
