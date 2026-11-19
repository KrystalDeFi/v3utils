// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {UniV3Adapter} from "../../../src/router/adapters/UniV3Adapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {PoolKey} from "../../../src/router/RouterTypes.sol";
import {AdapterConformance} from "./AdapterConformance.sol";

/// @dev Uniswap v3 on Arbitrum.
contract UniV3AdapterTest is AdapterConformance {
    function _setUpFixture() internal override returns (Fixture memory x) {
        _forkArbitrum();
        x.nfpm = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        x.adapter = address(new UniV3Adapter());
        x.key = PoolKey({
            token0: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH
            token1: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC
            fee: 500,
            tickSpacing: 10,
            deployer: address(0)
        });
        // pool tick is -197975 at the pinned block
        x.tickLower = -198500;
        x.tickUpper = -197500;
        x.amount0 = 1 ether;
        x.amount1 = 5_000e6;
        x.expectedPool = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    }

    function test_directCall_reverts() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        UniV3Adapter(f.adapter).collect(f.nfpm, 1);
    }
}

/// @dev Pancake v3 on Base, through the same adapter (BSC has no archive RPC).
contract PancakeV3AdapterTest is AdapterConformance {
    function _setUpFixture() internal override returns (Fixture memory x) {
        _forkBase();
        x.nfpm = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
        x.adapter = address(new UniV3Adapter());
        x.key = PoolKey({
            token0: 0x4200000000000000000000000000000000000006, // WETH
            token1: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
            fee: 500,
            tickSpacing: 10,
            deployer: address(0)
        });
        // pool tick is -200091 at the pinned block
        x.tickLower = -200600;
        x.tickUpper = -199600;
        x.amount0 = 1 ether;
        x.amount1 = 2_500e6;
        x.expectedPool = 0xB775272E537cc670C65DC852908aD47015244EaF;
    }
}
