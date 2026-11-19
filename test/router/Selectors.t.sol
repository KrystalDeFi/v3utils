// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {V3UtilsRouter} from "../../src/router/V3UtilsRouter.sol";
import {CoreMint} from "../../src/router/modules/CoreMint.sol";
import {CoreModify} from "../../src/router/modules/CoreModify.sol";
import {UniV3Adapter} from "../../src/router/adapters/UniV3Adapter.sol";
import {AlgebraV1Adapter} from "../../src/router/adapters/AlgebraV1Adapter.sol";
import {AerodromeAdapter} from "../../src/router/adapters/AerodromeAdapter.sol";
import {RamsesV3Adapter} from "../../src/router/adapters/RamsesV3Adapter.sol";
import {AlgebraIntegralAdapter} from "../../src/router/adapters/AlgebraIntegralAdapter.sol";
import {AeroGaugeFarm} from "../../src/router/farms/AeroGaugeFarm.sol";
import {ICoreMint} from "../../src/router/interfaces/ICoreMint.sol";
import {ICoreModify} from "../../src/router/interfaces/ICoreModify.sol";
import {IAdapter} from "../../src/router/interfaces/IAdapter.sol";
import {IFarm} from "../../src/router/interfaces/IFarm.sol";

/// @notice Guards that need no fork: module selectors never shadow the router's own, and every deployed piece fits
/// the contract size limit.
contract SelectorsTest is Test {
    uint256 internal constant MAX_SIZE = 24_576;

    /// @dev The router's external selectors, listed by hand from its ABI (44 entries, as `forge inspect V3UtilsRouter methodIdentifiers` lists them).
    function _routerSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](44);
        uint256 i;
        s[i++] = V3UtilsRouter.execute.selector;
        s[i++] = V3UtilsRouter.executeAutomation.selector;
        s[i++] = V3UtilsRouter.initialize.selector;
        s[i++] = V3UtilsRouter.hashOrder.selector;
        s[i++] = V3UtilsRouter.cancelOrder.selector;
        s[i++] = V3UtilsRouter.isOrderCancelled.selector;
        s[i++] = V3UtilsRouter.setModule.selector;
        s[i++] = V3UtilsRouter.setAdapter.selector;
        s[i++] = V3UtilsRouter.setFarm.selector;
        s[i++] = V3UtilsRouter.setAutoSelector.selector;
        s[i++] = V3UtilsRouter.setSwapRouter.selector;
        s[i++] = V3UtilsRouter.setNativeConfig.selector;
        s[i++] = V3UtilsRouter.setFeeTaker.selector;
        s[i++] = V3UtilsRouter.setMaxFeeX64.selector;
        s[i++] = V3UtilsRouter.lock.selector;
        s[i++] = V3UtilsRouter.pause.selector;
        s[i++] = V3UtilsRouter.unpause.selector;
        s[i++] = V3UtilsRouter.withdrawERC20.selector;
        s[i++] = V3UtilsRouter.withdrawERC721.selector;
        s[i++] = V3UtilsRouter.withdrawNative.selector;
        s[i++] = V3UtilsRouter.module.selector;
        s[i++] = V3UtilsRouter.adapter.selector;
        s[i++] = V3UtilsRouter.farm.selector;
        s[i++] = V3UtilsRouter.autoSelector.selector;
        s[i++] = V3UtilsRouter.swapRouter.selector;
        s[i++] = V3UtilsRouter.feeTaker.selector;
        s[i++] = V3UtilsRouter.maxFeeX64.selector;
        s[i++] = V3UtilsRouter.weth.selector;
        s[i++] = V3UtilsRouter.locked.selector;
        s[i++] = V3UtilsRouter.nativeMode.selector;
        s[i++] = V3UtilsRouter.nativeScale.selector;
        s[i++] = V3UtilsRouter.onERC721Received.selector;
        s[i++] = bytes4(keccak256("DOMAIN_SEPARATOR()"));
        s[i++] = bytes4(keccak256("ADMIN_ROLE()"));
        s[i++] = bytes4(keccak256("OPERATOR_ROLE()"));
        s[i++] = bytes4(keccak256("WITHDRAWER_ROLE()"));
        s[i++] = bytes4(keccak256("DEFAULT_ADMIN_ROLE()"));
        s[i++] = bytes4(keccak256("hasRole(bytes32,address)"));
        s[i++] = bytes4(keccak256("getRoleAdmin(bytes32)"));
        s[i++] = bytes4(keccak256("grantRole(bytes32,address)"));
        s[i++] = bytes4(keccak256("revokeRole(bytes32,address)"));
        s[i++] = bytes4(keccak256("renounceRole(bytes32,address)"));
        s[i++] = bytes4(keccak256("paused()"));
        s[i++] = bytes4(keccak256("supportsInterface(bytes4)"));
        require(i == s.length, "selector list length");
    }

    function _moduleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6 + 6 + 11);
        uint256 i;
        // ICoreMint / ICoreModify: the registered flows
        s[i++] = ICoreMint.swapAndMint.selector;
        s[i++] = ICoreMint.swapAndIncrease.selector;
        s[i++] = ICoreModify.decreaseAndSwap.selector;
        s[i++] = ICoreModify.adjustRange.selector;
        s[i++] = ICoreModify.compound.selector;
        s[i++] = ICoreModify.harvest.selector;
        // IAdapter
        s[i++] = IAdapter.position.selector;
        s[i++] = IAdapter.pool.selector;
        s[i++] = IAdapter.mint.selector;
        s[i++] = IAdapter.increase.selector;
        s[i++] = IAdapter.decrease.selector;
        s[i++] = IAdapter.collect.selector;
        // IFarm
        s[i++] = IFarm.isStakedBy.selector;
        s[i++] = IFarm.canUnstake.selector;
        s[i++] = IFarm.canIncreaseStaked.selector;
        s[i++] = IFarm.earnsTradingFees.selector;
        s[i++] = IFarm.canCompound.selector;
        s[i++] = IFarm.rewardToken.selector;
        s[i++] = IFarm.checkStakeable.selector;
        s[i++] = IFarm.stake.selector;
        s[i++] = IFarm.unstake.selector;
        s[i++] = IFarm.claim.selector;
        s[i++] = IFarm.increaseStaked.selector;
        require(i == s.length, "selector list length");
    }

    function test_moduleSelectors_neverCollideWithRouter() public pure {
        bytes4[] memory r = _routerSelectors();
        bytes4[] memory m = _moduleSelectors();
        for (uint256 i = 0; i < m.length; i++) {
            for (uint256 j = 0; j < r.length; j++) {
                require(m[i] != r[j], "module selector collides with router");
            }
        }
    }

    /// @dev Measured on deployed code (immutables included), which is what the 24,576-byte limit applies to; the
    /// default profile has no `fs_permissions`, so `out/*.json` is not read here. `linkReferences` is checked with
    /// `jq '.bytecode.linkReferences' out/<C>.sol/<C>.json` (all `{}`).
    function test_sizes() public {
        _assertSize("V3UtilsRouter", address(new V3UtilsRouter()).code.length);
        _assertSize("CoreMint", address(new CoreMint()).code.length);
        _assertSize("CoreModify", address(new CoreModify()).code.length);
        _assertSize("UniV3Adapter", address(new UniV3Adapter()).code.length);
        _assertSize("AlgebraV1Adapter", address(new AlgebraV1Adapter()).code.length);
        _assertSize("AerodromeAdapter", address(new AerodromeAdapter()).code.length);
        _assertSize("RamsesV3Adapter", address(new RamsesV3Adapter()).code.length);
        _assertSize("AlgebraIntegralAdapter", address(new AlgebraIntegralAdapter()).code.length);
        _assertSize("AeroGaugeFarm", address(new AeroGaugeFarm(address(0x1), address(0x2), true)).code.length);
    }

    function _assertSize(string memory name, uint256 size) internal {
        emit log_named_uint(name, size);
        assertGt(size, 0, name);
        assertLe(size, MAX_SIZE, name);
    }
}
