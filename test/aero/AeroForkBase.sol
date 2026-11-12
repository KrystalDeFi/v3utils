// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/aero/AeroFarmingHelper.sol";
import "../../src/aero/AeroAutomationModule.sol";

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
    AeroFarmingHelper internal helper;
    AeroAutomationModule internal moduleImpl; // the module implementation (never called directly in production)
    AeroAutomationModule internal automation; // the helper proxy, typed for the operator path served by its fallback

    function _forkBase() internal {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), BASE_BLOCK);
    }

    function _forkOp() internal {
        vm.createSelectFork(vm.envString("OP_RPC_URL"), OP_BLOCK);
    }

    function _deployHelper(address rewardToken, bool compoundEnabled, address weth)
        internal
        returns (AeroFarmingHelper)
    {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        withdrawer = makeAddr("withdrawer");
        AeroFarmingHelper impl = new AeroFarmingHelper();
        moduleImpl = new AeroAutomationModule();
        bytes memory init = abi.encodeCall(
            AeroFarmingHelper.initialize,
            (
                admin,
                operator,
                withdrawer,
                V3UTILS,
                GAUGE_FACTORY,
                rewardToken,
                compoundEnabled,
                weth,
                STRUCT_HASH,
                address(moduleImpl)
            )
        );
        helper = AeroFarmingHelper(payable(address(new ERC1967Proxy(address(impl), init))));
        automation = AeroAutomationModule(address(helper));
        return helper;
    }

    /// @dev Approves the most recently deployed helper on the gauge.
    function _approveGauge(address user, address gauge, bool claim) internal {
        vm.startPrank(user);
        ICLGaugeApprovals(gauge).setApprovalForAll(address(helper), true);
        if (claim) ICLGaugeApprovals(gauge).approveForClaim(address(helper), true);
        vm.stopPrank();
    }
}

interface ICLGaugeApprovals {
    function setApprovalForAll(address operator, bool approved) external;
    function approveForClaim(address operator, bool approved) external;
}
