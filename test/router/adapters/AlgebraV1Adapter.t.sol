// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AlgebraV1Adapter} from "../../../src/router/adapters/AlgebraV1Adapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {PoolKey} from "../../../src/router/RouterTypes.sol";
import {AdapterConformance} from "./AdapterConformance.sol";

/// @dev Camelot V3 (Algebra V1) on Arbitrum.
contract AlgebraV1AdapterTest is AdapterConformance {
    function _setUpFixture() internal override returns (Fixture memory x) {
        _forkArbitrum();
        x.nfpm = 0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15;
        x.adapter = address(new AlgebraV1Adapter());
        x.key = PoolKey({
            token0: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH
            token1: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC
            fee: 0, // dynamic
            tickSpacing: 10,
            deployer: address(0)
        });
        // pool tick is -197973 at the pinned block
        x.tickLower = -198500;
        x.tickUpper = -197500;
        x.amount0 = 1 ether;
        x.amount1 = 5_000e6;
        x.expectedPool = 0xB1026b8e7276e7AC75410F1fcbbe21796e8f7526;
    }

    function test_directCall_reverts() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        AlgebraV1Adapter(f.adapter).collect(f.nfpm, 1);
    }
}
