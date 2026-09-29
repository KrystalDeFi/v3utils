// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../IntegrationTestBase.sol";
import "./SurchargeToken.t.sol";

/// @notice V3Automation reaches the same accounting through its own entry point. AUTO_ADJUST is the
///         useful case because it crosses the pool in BOTH directions in one call: it decreases and
///         collects (the token skims on the way out) and then re-mints into the new range (the token
///         surcharges on the way in). Either half alone used to be enough to revert the operator's
///         transaction with an opaque ERC20 balance error.
contract SurchargeTokenAutomationTest is IntegrationTestBase {
    StructHash.Order emptyUserConfig;

    IUniV3Factory constant FACTORY = IUniV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    uint24 constant FEE = 3000;
    int24 constant TICK_LOWER = -60;
    int24 constant TICK_UPPER = 60;
    int24 constant NEW_TICK_LOWER = -120;
    int24 constant NEW_TICK_UPPER = 120;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint256 constant SUR_IN = 10 ether;
    uint256 constant WETH_IN = 1 ether;

    MockSurchargeToken sur;
    address pool;

    address positionOwner;
    uint256 positionOwnerKey;

    function setUp() external {
        _setupBase();

        sur = new MockSurchargeToken(100, 100); // 1% buy, 1% sell - same as ARGUS
        pool = FACTORY.createPool(address(sur), address(WETH_ERC20), FEE);
        IUniV3PoolMin(pool).initialize(SQRT_PRICE_1_1);
        sur.setMainPool(pool);

        (positionOwner, positionOwnerKey) = makeAddrAndKey("positionOwner");

        sur.mint(positionOwner, SUR_IN);
        _writeTokenBalance(positionOwner, address(WETH_ERC20), WETH_IN);

        vm.startPrank(positionOwner);
        sur.approve(address(v3utils), type(uint256).max);
        WETH_ERC20.approve(address(v3utils), type(uint256).max);
        vm.stopPrank();
    }

    function _mintPosition() internal returns (Common.SwapAndMintResult memory result) {
        bool surIsToken0 = IUniV3PoolMin(pool).token0() == address(sur);

        Common.SwapAndMintParams memory params = Common.SwapAndMintParams(
            Nfpm.Protocol.UNI_V3,
            NPM,
            surIsToken0 ? IERC20(address(sur)) : WETH_ERC20,
            surIsToken0 ? WETH_ERC20 : IERC20(address(sur)),
            FEE,
            0, // tickSpacing - unused for uni v3
            TICK_LOWER,
            TICK_UPPER,
            0, // protocolFeeX64
            0, // gasFeeX64
            surIsToken0 ? SUR_IN : WETH_IN,
            surIsToken0 ? WETH_IN : SUR_IN,
            0, // amount2
            positionOwner,
            block.timestamp,
            IERC20(address(0)), // no swap
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            address(0)
        );

        vm.prank(positionOwner);
        result = v3utils.swapAndMint(params);
    }

    function testAutoAdjustAcrossSurchargePool() external {
        Common.SwapAndMintResult memory minted = _mintPosition();
        uint256 nftsBefore = NPM.balanceOf(positionOwner);

        bytes memory signature = _signOrder(emptyUserConfig, positionOwnerKey);

        V3Automation.ExecuteParams memory params = V3Automation.ExecuteParams(
            V3Automation.Action.AUTO_ADJUST,
            Nfpm.Protocol.UNI_V3,
            NPM,
            minted.tokenId,
            minted.liquidity,
            IUniV3PoolMin(pool).token0(), // targetToken - no swap is performed, amounts are zero
            0,
            0,
            "",
            0,
            0,
            "",
            0, // amountRemoveMin0
            0, // amountRemoveMin1
            block.timestamp,
            0, // gasFeeX64
            0, // liquidityFeeX64
            0, // performanceFeeX64
            NEW_TICK_LOWER,
            NEW_TICK_UPPER,
            true, // compoundFees
            0, // amountAddMin0
            0, // amountAddMin1
            abi.encode(emptyUserConfig),
            signature
        );

        vm.prank(positionOwner);
        NPM.setApprovalForAll(address(v3automation), true);

        vm.prank(TEST_OWNER_ACCOUNT);
        v3automation.execute(params);

        // The old position is emptied and a new one minted into the new range.
        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(minted.tokenId);
        assertEq(liquidityAfter, 0, "old position should be emptied");
        assertGt(NPM.balanceOf(positionOwner), nftsBefore, "new position should have been minted");

        // v3automation is a pass-through: whatever the token skimmed or surcharged came out of the
        // position, never out of a balance the contract kept behind.
        assertEq(sur.balanceOf(address(v3automation)), 0, "v3automation retained SUR");
        assertEq(WETH_ERC20.balanceOf(address(v3automation)), 0, "v3automation retained WETH");
    }

    function _signOrder(StructHash.Order memory order, uint256 privateKey)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = v3automation.hashTypedDataV4(StructHash._hash(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
