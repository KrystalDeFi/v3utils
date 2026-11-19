// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V3UtilsRouter} from "../../src/router/V3UtilsRouter.sol";

/// @notice Shared base of the router's fork tests: pinned forks per chain, a freshly deployed router with test roles,
/// registry helpers and token funding. Later flow/farm/automation suites inherit it.
/// @dev RPC URLs come from `<CHAIN>_RPC_URL` env vars and default to public archive endpoints, so tests run with no
/// env set. There is no archive BSC RPC, so there is no `_forkBsc`; Pancake v3 is exercised on Base.
abstract contract RouterTestBase is Test {
    // ---- pinned fork blocks
    uint256 internal constant ARBITRUM_BLOCK = 171544977;
    uint256 internal constant BASE_BLOCK = 56384489;
    uint256 internal constant OP_BLOCK = 145000000;

    string internal constant ARBITRUM_RPC_DEFAULT =
        "https://arbitrum.blockpi.network/v1/rpc/d806195b2a58dc2aa626f6c77b0626fc4d03d70d";
    string internal constant BASE_RPC_DEFAULT = "https://mainnet.base.org";
    string internal constant OP_RPC_DEFAULT = "https://mainnet.optimism.io";

    // ---- test roles
    address internal routerDeployer = makeAddr("rtDeployer");
    address internal routerAdmin = makeAddr("rtAdmin");
    address internal routerOperator = makeAddr("rtOperator");
    address internal routerWithdrawer = makeAddr("rtWithdrawer");
    address internal routerSwapRouter = makeAddr("rtSwapRouter");
    address internal routerFeeTaker = makeAddr("rtFeeTaker");

    V3UtilsRouter internal router;

    function _forkArbitrum() internal returns (uint256 id) {
        id = vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", ARBITRUM_RPC_DEFAULT), ARBITRUM_BLOCK);
    }

    function _forkBase() internal returns (uint256 id) {
        id = vm.createSelectFork(vm.envOr("BASE_RPC_URL", BASE_RPC_DEFAULT), BASE_BLOCK);
    }

    function _forkOp() internal returns (uint256 id) {
        id = vm.createSelectFork(vm.envOr("OP_RPC_URL", OP_RPC_DEFAULT), OP_BLOCK);
    }

    /// @dev Deploys and initializes a router on the current fork (WRAPPED native mode, `weth_` as given).
    function _deployRouter(address weth_) internal returns (V3UtilsRouter r) {
        vm.prank(routerDeployer, routerDeployer);
        r = new V3UtilsRouter();
        vm.prank(routerDeployer, routerDeployer);
        r.initialize(routerAdmin, routerOperator, routerWithdrawer, routerSwapRouter, routerFeeTaker, weth_, 0);
        router = r;
    }

    function _register(address nfpm, address adapter, address farm) internal {
        vm.startPrank(routerAdmin);
        router.setAdapter(nfpm, adapter);
        if (farm != address(0)) router.setFarm(nfpm, farm);
        vm.stopPrank();
    }

    function _registerModule(bytes4 selector, address module) internal {
        vm.prank(routerAdmin);
        router.setModule(selector, module);
    }

    /// @dev Gives `who` `amount` of `token` and approves the router for it.
    function _dealAndApprove(address token, address who, uint256 amount) internal {
        deal(token, who, amount);
        vm.prank(who);
        IERC20(token).approve(address(router), type(uint256).max);
    }
}
