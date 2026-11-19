// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IFarm} from "../../../src/router/interfaces/IFarm.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {AeroGaugeFarm} from "../../../src/router/farms/AeroGaugeFarm.sol";
import {PoolKey} from "../../../src/router/RouterTypes.sol";
import {CoreHarness} from "../mocks/CoreHarness.sol";
import {AeroFarmBase, ITestPool} from "./AeroFarmBase.sol";

/// @notice AeroGaugeFarm on its own, delegatecalled as the router through CoreHarness.delegateTo, on a Base fork.
contract AeroGaugeFarmTest is AeroFarmBase {
    CoreHarness internal harness;

    function setUp() public {
        _setUpAero(false);
        harness = new CoreHarness();
        _registerModule(CoreHarness.delegateTo.selector, address(harness));
    }

    /// @dev Runs `data` on the farm as the router (msg.sender of the flow is this test).
    function _farmCall(bytes memory data) internal returns (bytes memory) {
        bytes memory ret = router.execute(abi.encodeCall(CoreHarness.delegateTo, (address(farm), data)));
        return abi.decode(ret, (bytes));
    }

    /// @dev `_farmCall` without decoding, for a `vm.expectRevert`ed call (which returns no data).
    function _farmCallReverting(bytes memory data) internal {
        router.execute(abi.encodeCall(CoreHarness.delegateTo, (address(farm), data)));
    }

    function _bool(bytes memory data) internal returns (bool) {
        return abi.decode(_farmCall(data), (bool));
    }

    function test_constructor_config() public {
        assertEq(farm.gaugeFactory(), GAUGE_FACTORY);
        assertTrue(farm.compoundEnabled());
        assertTrue(_bool(abi.encodeCall(IFarm.canUnstake, ())), "canUnstake");
        assertFalse(_bool(abi.encodeCall(IFarm.canIncreaseStaked, ())), "canIncreaseStaked");
        assertFalse(_bool(abi.encodeCall(IFarm.earnsTradingFees, ())), "earnsTradingFees");
        assertTrue(_bool(abi.encodeCall(IFarm.canCompound, ())), "canCompound");
        assertEq(abi.decode(_farmCall(abi.encodeCall(IFarm.rewardToken, ())), (address)), AERO, "rewardToken");

        AeroGaugeFarm op = new AeroGaugeFarm(GAUGE_FACTORY, XAERO, false);
        assertFalse(op.compoundEnabled());
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(IRouterErrors.ZeroAddress.selector);
        new AeroGaugeFarm(address(0), AERO, true);
        vm.expectRevert(IRouterErrors.ZeroAddress.selector);
        new AeroGaugeFarm(GAUGE_FACTORY, address(0), true);
    }

    function test_isStakedBy_stakedPosition() public {
        _approveGauge(staker, GAUGE_A, true);
        uint256 tokenId = _stakedA();
        assertTrue(_bool(abi.encodeCall(IFarm.isStakedBy, (NFPM, tokenId, staker))), "staker");
        assertFalse(_bool(abi.encodeCall(IFarm.isStakedBy, (NFPM, tokenId, attacker))), "someone else");
    }

    /// @dev Controller decision 5: a pool with no gauge answers false (never reverts), so wallet positions there work.
    function test_isStakedBy_poolWithoutGauge_false() public {
        assertEq(ITestPool(POOL_NO_GAUGE).gauge(), address(0), "fixture pool has no gauge");
        uint256 tokenId =
            _mint(staker, _mintParams(_key(AERO, USDC_BASE, TS_NO_GAUGE), POOL_NO_GAUGE, 1_000 ether, 1_000e6, false));
        assertFalse(_bool(abi.encodeCall(IFarm.isStakedBy, (NFPM, tokenId, staker))));
    }

    /// @dev A pool reporting a gauge the factory did not create is not a farm: false, not a revert.
    function test_isStakedBy_foreignGauge_false() public {
        _approveGauge(staker, GAUGE_A, true);
        uint256 tokenId = _stakedA();
        vm.mockCall(POOL_A, abi.encodeCall(ITestPool.gauge, ()), abi.encode(makeAddr("aeroFakeGauge")));
        assertFalse(_bool(abi.encodeCall(IFarm.isStakedBy, (NFPM, tokenId, staker))));
    }

    function test_checkStakeable_liveGauge_ok() public {
        _farmCall(abi.encodeCall(IFarm.checkStakeable, (NFPM, _key(WETH, USDC_BASE, TS_A))));
    }

    function test_checkStakeable_noGauge_reverts() public {
        vm.expectRevert(IRouterErrors.InvalidGauge.selector);
        _farmCallReverting(abi.encodeCall(IFarm.checkStakeable, (NFPM, _key(AERO, USDC_BASE, TS_NO_GAUGE))));
    }

    function test_checkStakeable_noPool_reverts() public {
        vm.expectRevert(IRouterErrors.InvalidGauge.selector);
        _farmCallReverting(abi.encodeCall(IFarm.checkStakeable, (NFPM, _key(WETH, USDC_BASE, 7))));
    }

    function test_checkStakeable_foreignGauge_reverts() public {
        vm.mockCall(POOL_A, abi.encodeCall(ITestPool.gauge, ()), abi.encode(makeAddr("aeroFakeGauge")));
        vm.expectRevert(IRouterErrors.InvalidGauge.selector);
        _farmCallReverting(abi.encodeCall(IFarm.checkStakeable, (NFPM, _key(WETH, USDC_BASE, TS_A))));
    }

    function test_checkStakeable_deadGauge_reverts() public {
        _killGauge(GAUGE_A);
        vm.expectRevert(IRouterErrors.GaugeNotLive.selector);
        _farmCallReverting(abi.encodeCall(IFarm.checkStakeable, (NFPM, _key(WETH, USDC_BASE, TS_A))));
    }

    /// @dev A farm registered for another NFPM finds no gauge: the gauge's `nft()` must be the NFPM it was asked about.
    function test_checkStakeable_otherNfpm_reverts() public {
        address other = makeAddr("aeroOtherNfpm");
        vm.mockCall(other, abi.encodeWithSignature("factory()"), abi.encode(0x9CB220581b91b0C83223012FE69688b92aD07a76));
        vm.expectRevert(IRouterErrors.InvalidGauge.selector);
        _farmCallReverting(abi.encodeCall(IFarm.checkStakeable, (other, _key(WETH, USDC_BASE, TS_A))));
    }

    function test_increaseStaked_unsupported() public {
        vm.expectRevert(IRouterErrors.FarmUnsupported.selector);
        _farmCallReverting(abi.encodeCall(IFarm.increaseStaked, (NFPM, 1, 1, 1, block.timestamp)));
    }

    function test_directCall_reverts() public {
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.stake(NFPM, 1, staker);
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.unstake(NFPM, 1, staker);
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.claim(NFPM, 1, staker);
        // the reads too, as on the adapters (the immutable getters stay public)
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.isStakedBy(NFPM, 1, staker);
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.canUnstake();
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.canIncreaseStaked();
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.earnsTradingFees();
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.canCompound();
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.rewardToken();
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.checkStakeable(NFPM, _key(WETH, USDC_BASE, TS_A));
        vm.expectRevert(IRouterErrors.NotDelegateCall.selector);
        farm.increaseStaked(NFPM, 1, 1, 1, block.timestamp);
        assertEq(farm.gaugeFactory(), GAUGE_FACTORY);
        assertTrue(farm.compoundEnabled());
    }

    /// @dev `claim` pays the router the account's emissions and returns exactly the reward delta.
    function test_claim_returnsRewardDelta() public {
        _approveGauge(staker, GAUGE_A, true);
        uint256 tokenId = _stakedA();
        uint256 earned = _earned(GAUGE_A, staker, tokenId);
        assertGt(earned, 0, "no emissions accrued");
        uint256 claimed = abi.decode(_farmCall(abi.encodeCall(IFarm.claim, (NFPM, tokenId, staker))), (uint256));
        assertEq(claimed, earned, "claimed");
        assertEq(_bal(AERO, address(router)), earned, "paid to the router");
        _assertStaked(GAUGE_A, staker, tokenId);
    }

    /// @dev `unstake` brings the NFT in under the expected-NFT record (the receive guard accepts it) and `stake` puts it
    /// back for the same account.
    function test_unstake_thenStake_roundTrip() public {
        _approveGauge(staker, GAUGE_A, true);
        uint256 tokenId = _stakedA();
        _farmCall(abi.encodeCall(IFarm.unstake, (NFPM, tokenId, staker)));
        assertEq(IERC721(NFPM).ownerOf(tokenId), address(router), "unstaked into the router");
        assertFalse(_bool(abi.encodeCall(IFarm.isStakedBy, (NFPM, tokenId, staker))), "no longer staked");
        _farmCall(abi.encodeCall(IFarm.stake, (NFPM, tokenId, staker)));
        _assertStaked(GAUGE_A, staker, tokenId);
    }
}
