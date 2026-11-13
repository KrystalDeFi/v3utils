// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/aero/AeroFarmingRouter.sol";
import "../../src/aero/AeroFarmingLogic.sol";

/// @dev Pulls the caller's whole allowance of `tokenIn`, pays `amountOut` of `tokenOut`.
contract MockSwapRouter {
    function swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut) external {
        tokenIn.transferFrom(msg.sender, address(this), tokenIn.allowance(msg.sender, address(this)));
        tokenOut.transfer(msg.sender, amountOut);
    }
}

abstract contract AeroForkBase is Test {
    uint256 internal constant BASE_BLOCK = 56384489;
    uint256 internal constant OP_BLOCK = 159434366;

    address internal constant NFPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address internal constant GAUGE_FACTORY = 0xf437f62053ACB121665b8fDBfeA8F214FB8E589d;
    address internal constant LEAF_VOTER = 0x382409fad8503FbCdbB27A4211551fa03e884078;
    address internal constant V3UTILS = 0xb4acbC082b5e7dEd571c98EE4257778a9D784B36;
    address internal constant STRUCT_HASH = 0xB486F83280F19cf652843b8F79e52572D589Bbf9;
    address internal constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address internal constant XAERO = 0xbdEaeA5205d16f34Cb40038052d91235D87B4C54;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant GAUGE_A_BASE = 0x46a9dCa72D78366571bE583aa69C1DC16E6889fB;
    address internal constant POOL_A_BASE = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c;
    address internal constant GAUGE_B_BASE = 0xb1b27a2fa4E67a6d0Ee1aA9De97c8b1DDF54FDD4;
    address internal constant POOL_B_BASE = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3;
    address internal constant GAUGE_A_OP = 0x8F6a9ea8304Fe2c16a6a11f31ABa71F2c526cFd9;
    address internal constant POOL_A_OP = 0xcA231D91eC00385a54e541f504617d2197f9B7c3;

    address internal admin;
    address internal operator;
    address internal withdrawer;
    address internal pauser;
    AeroFarmingRouter internal router;
    AeroFarmingLogic internal logic; // the logic implementation (never called directly in production)

    /// @dev Test-side bundle of executeAutomation's arguments.
    struct OrderParams {
        IAeroFarmingLogic.AutoAction action;
        address account;
        address gauge;
        uint256 tokenId;
        bytes actionData;
        bytes order;
        bytes signature;
    }

    function _forkBase() internal {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), BASE_BLOCK);
    }

    function _forkOp() internal {
        vm.createSelectFork(vm.envString("OP_RPC_URL"), OP_BLOCK);
    }

    /// @dev Deploys a logic and a router (tx.origin is the router's initializer) and initializes the router.
    function _deployRouter(address rewardToken, bool compoundEnabled, address weth)
        internal
        returns (AeroFarmingRouter)
    {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        withdrawer = makeAddr("withdrawer");
        pauser = makeAddr("pauser");
        logic = new AeroFarmingLogic();
        router = new AeroFarmingRouter();
        vm.prank(tx.origin);
        router.initialize(
            admin,
            operator,
            withdrawer,
            pauser,
            address(logic),
            V3UTILS,
            GAUGE_FACTORY,
            rewardToken,
            compoundEnabled,
            weth
        );
        return router;
    }

    /// @dev Approves the most recently deployed router on the gauge.
    function _approveGauge(address user, address gauge, bool claim) internal {
        vm.startPrank(user);
        ICLGaugeApprovals(gauge).setApprovalForAll(address(router), true);
        if (claim) ICLGaugeApprovals(gauge).approveForClaim(address(router), true);
        vm.stopPrank();
    }

    // Call-path wrappers: each makes exactly one external call (router.execute / executeAutomation), so a
    // vm.prank / vm.expectRevert placed before the wrapper binds to that call.

    function _zapIn(address gauge, Common.SwapAndMintParams memory p, bool unwrap) internal returns (uint256) {
        return _zapIn(0, gauge, p, unwrap);
    }

    function _zapIn(uint256 value, address gauge, Common.SwapAndMintParams memory p, bool unwrap)
        internal
        returns (uint256 tokenId)
    {
        bytes memory ret =
            router.execute{value: value}(abi.encodeCall(IAeroFarmingLogic.zapInAndStake, (gauge, p, unwrap)));
        assertEq(ret.length, 32, "zapInAndStake return data");
        tokenId = abi.decode(ret, (uint256));
    }

    /// @dev For a vm.expectRevert'ed zap: an expected revert makes the call return no data, which `_zapIn` (it
    /// requires exactly one word back) would reject.
    function _zapInExpectRevert(address gauge, Common.SwapAndMintParams memory p, bool unwrap) internal {
        _zapInExpectRevert(0, gauge, p, unwrap);
    }

    function _zapInExpectRevert(uint256 value, address gauge, Common.SwapAndMintParams memory p, bool unwrap)
        internal
    {
        router.execute{value: value}(abi.encodeCall(IAeroFarmingLogic.zapInAndStake, (gauge, p, unwrap)));
    }

    function _addLiquidity(address gauge, Common.SwapAndIncreaseLiquidityParams memory p, bool unwrap) internal {
        router.execute(abi.encodeCall(IAeroFarmingLogic.addLiquidity, (gauge, p, unwrap)));
    }

    function _removeLiquidity(address gauge, uint256 tokenId, V3Utils.Instructions memory ins) internal {
        router.execute(abi.encodeCall(IAeroFarmingLogic.removeLiquidity, (gauge, tokenId, ins)));
    }

    function _exit(address gauge, uint256 tokenId, V3Utils.Instructions memory ins) internal {
        router.execute(abi.encodeCall(IAeroFarmingLogic.exit, (gauge, tokenId, ins)));
    }

    function _rebalance(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        internal
        returns (uint256 newTokenId)
    {
        bytes memory ret = router.execute(abi.encodeCall(IAeroFarmingLogic.rebalance, (gauge, tokenId, ins)));
        assertEq(ret.length, 32, "rebalance return data");
        newTokenId = abi.decode(ret, (uint256));
    }

    /// @dev For a vm.expectRevert'ed rebalance (see `_zapInExpectRevert`).
    function _rebalanceExpectRevert(address gauge, uint256 tokenId, V3Utils.Instructions memory ins) internal {
        router.execute(abi.encodeCall(IAeroFarmingLogic.rebalance, (gauge, tokenId, ins)));
    }

    function _compound(address gauge, uint256 tokenId, IAeroFarmingLogic.CompoundParams memory p) internal {
        router.execute(abi.encodeCall(IAeroFarmingLogic.compound, (gauge, tokenId, p)));
    }

    function _executeOrder(OrderParams memory p) internal returns (uint256) {
        return router.executeAutomation(p.account, p.gauge, p.tokenId, p.action, p.actionData, p.order, p.signature);
    }
}

interface ICLGaugeApprovals {
    function setApprovalForAll(address operator, bool approved) external;
    function approveForClaim(address operator, bool approved) external;
}
