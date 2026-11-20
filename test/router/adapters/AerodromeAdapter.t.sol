// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AerodromeAdapter} from "../../../src/router/adapters/AerodromeAdapter.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {PoolKey} from "../../../src/router/RouterTypes.sol";
import {AdapterConformance} from "./AdapterConformance.sol";

/// @dev The new Aero (MetaDEX03 Slipstream) on Base. Run with `FOUNDRY_EVM_VERSION=cancun` (its LeafVoter uses PUSH0).
contract AerodromeAdapterTest is AdapterConformance {
    function _setUpFixture() internal override returns (Fixture memory x) {
        _forkBase();
        x.nfpm = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
        x.adapter = address(new AerodromeAdapter());
        x.key = PoolKey({
            token0: 0x4200000000000000000000000000000000000006, // WETH
            token1: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
            fee: 0,
            tickSpacing: 50,
            deployer: address(0)
        });
        // pool tick is -200093 at the pinned block
        x.tickLower = -200600;
        x.tickUpper = -199600;
        x.amount0 = 1 ether;
        x.amount1 = 2_500e6;
        x.expectedPool = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c;
    }

    function test_directCall_reverts() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        AerodromeAdapter(f.adapter).collect(f.nfpm, 1);
    }
}
