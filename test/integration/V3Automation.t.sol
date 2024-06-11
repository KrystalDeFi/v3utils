// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../IntegrationTestBase.sol";

contract V3AutomationIntegrationTest is IntegrationTestBase {
    Signature.Order emptyUserConfig; // todo: remove this when we fill user configuration

    function setUp() external {
        _setupBase();
    }

    function testAutoAdjustRange() external {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();
        (address userAddress, uint256 privateKey) = makeAddrAndKey("positionOwnerAddress");

        vm.startPrank(TEST_NFT_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, userAddress, TEST_NFT);
        vm.stopPrank();

        bytes32 digest = v3automation.hashTypedDataV4(v3automation.hash(emptyUserConfig));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 countBefore = NPM.balanceOf(userAddress);

        (, , , , , , , uint128 liquidityBefore, , , , ) = NPM.positions(
            TEST_NFT
        );

        V3Automation.ExecuteParams memory params = V3Automation.ExecuteParams(
            V3Automation.Action.AUTO_ADJUST,
            Common.Protocol.UNI_V3,
            NPM,
            userAddress,
            TEST_NFT,
            liquidityBefore,
            address(USDC),
            500000000000000000,
            400000,
            _get05DAIToUSDCSwapData(),
            0,
            0,
            "",
            0,
            0,
            block.timestamp,
            184467440737095520, // 0.01 * 2^64
            0,
            MIN_TICK_500,
            -MIN_TICK_500,
            true,
            0,
            0,
            emptyUserConfig,
            signature
        );

        // using approve / execute pattern
        vm.prank(userAddress);
        NPM.setApprovalForAll(address(v3automation), true);

        vm.prank(TEST_OWNER_ACCOUNT);

        v3automation.execute(params);

        // now we have 2 NFTs (1 empty)
        uint256 countAfter = NPM.balanceOf(userAddress);
        assertGt(countAfter, countBefore);

        (, , , , , , , uint128 liquidityAfter, , , , ) = NPM.positions(
            TEST_NFT
        );
        assertEq(liquidityAfter, 0);
    }

    function testAutoAdjustRangeNotOperator() external {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();

        (, , , , , , , uint128 liquidityBefore, , , , ) = NPM.positions(
            TEST_NFT
        );

        V3Automation.ExecuteParams memory params = V3Automation.ExecuteParams(
            V3Automation.Action.AUTO_ADJUST,
            Common.Protocol.UNI_V3,
            NPM,
            TEST_NFT_ACCOUNT,
            TEST_NFT,
            liquidityBefore,
            address(0),
            500000000000000000,
            400000,
            _get05DAIToUSDCSwapData(),
            0,
            0,
            "",
            0,
            0,
            block.timestamp,
            184467440737095520, // 0.01 * 2^64
            0,
            MIN_TICK_100,
            -MIN_TICK_100,
            true,
            0,
            0,
            emptyUserConfig,
            ""
        );

        // using approve / execute pattern
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(v3automation), true);

        vm.prank(TEST_NFT_ACCOUNT); // this is not a operator

        vm.expectRevert();
        v3automation.execute(params);
    }
}
