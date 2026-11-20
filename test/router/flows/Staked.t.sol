// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {ICoreMint} from "../../../src/router/interfaces/ICoreMint.sol";
import {ICoreModify} from "../../../src/router/interfaces/ICoreModify.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {CoreModify} from "../../../src/router/modules/CoreModify.sol";
import {
    FeeType,
    PoolKey,
    IncreaseParams,
    InputTokenParams,
    SwapParams,
    SwapAndMintParams,
    SwapAndIncreaseParams,
    AdjustRangeParams,
    CompoundParams,
    HarvestParams,
    DecreaseAndSwapParams,
    DecreaseParams
} from "../../../src/router/RouterTypes.sol";
import {AeroFarmBase, ITestGauge, ITestPool} from "../farms/AeroFarmBase.sol";
import {UniV3FlowBase} from "./UniV3FlowBase.sol";

/// @notice Every flow on a position staked in a new Aero gauge (Base fork, gauge A WETH/USDC). The router never
/// becomes the recorded staker: the user stays the depositor, and the router acts with the gauge approvals the user
/// grants (`setApprovalForAll` to unstake, `approveForClaim` to claim).
contract StakedTest is AeroFarmBase {
    event CompoundFees(
        address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event Harvest(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount);

    function setUp() public {
        _setUpAero(false);
        _approveGauge(staker, GAUGE_A, true);
        vm.prank(staker);
        IERC721(NFPM).setApprovalForAll(address(router), true);
    }

    function _flowTokens() internal pure returns (address[] memory) {
        return _tokens3(WETH, USDC_BASE, AERO);
    }

    // ------------------------------------------------------------------ swapAndMint

    function test_mintAndStake_stakedForUser_routerHoldsNothing() public {
        uint256 tokenId = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, true));
        _assertStaked(GAUGE_A, staker, tokenId);
        assertFalse(ITestGauge(GAUGE_A).stakedContains(address(router), tokenId), "router is not the staker");
        assertGt(_liq(tokenId), 0, "liquidity");
        _assertRouterClean(_flowTokens());
    }

    function test_mintAndStake_poolWithoutGauge_reverts() public {
        SwapAndMintParams memory p =
            _mintParams(_key(AERO, USDC_BASE, TS_NO_GAUGE), POOL_NO_GAUGE, 1_000 ether, 1_000e6, true);
        vm.expectRevert(IRouterErrors.InvalidGauge.selector);
        this.mintAs(staker, p);
    }

    function test_mintAndStake_deadGauge_reverts() public {
        SwapAndMintParams memory p = _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, true);
        _killGauge(GAUGE_A);
        vm.expectRevert(IRouterErrors.GaugeNotLive.selector);
        this.mintAs(staker, p);
    }

    /// @dev Without `stake`, a pool with no gauge works, and so do the wallet flows on its positions (the farm's holder
    /// check answers false there instead of reverting); a non-holder still gets NotPositionHolder.
    function test_mint_noStake_poolWithoutGauge_ok() public {
        uint256 tokenId =
            _mint(staker, _mintParams(_key(AERO, USDC_BASE, TS_NO_GAUGE), POOL_NO_GAUGE, 1_000 ether, 1_000e6, false));
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker, "NFT to the wallet");
        _assertRouterClean(_tokens3(AERO, USDC_BASE, WETH));

        uint128 l0 = _liq(tokenId);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        this.decreaseAs(attacker, tokenId, l0 / 2);

        _decrease(staker, tokenId, l0 / 2, USDC_BASE);
        assertEq(_liq(tokenId), l0 - l0 / 2, "partial withdraw");
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker, "back to the wallet");
    }

    /// @dev External wrappers so `vm.expectRevert` binds to the router call, not to the setup calls before it.
    function mintAs(address who, SwapAndMintParams memory p) external {
        _mint(who, p);
    }

    function decreaseAs(address who, uint256 tokenId, uint128 liquidity) external {
        _decrease(who, tokenId, liquidity, WETH);
    }

    // ------------------------------------------------------------------ swapAndIncrease

    function _increaseParams(uint256 tokenId, uint256 inWeth, uint256 inUsdc)
        internal
        returns (SwapAndIncreaseParams memory p)
    {
        _dealAndApprove(WETH, staker, inWeth);
        _dealAndApprove(USDC_BASE, staker, inUsdc);
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.increase = IncreaseParams({minLiquidity: 0, deadline: block.timestamp});
        p.inputTokens = new InputTokenParams[](2);
        p.inputTokens[0] = InputTokenParams(WETH, inWeth);
        p.inputTokens[1] = InputTokenParams(USDC_BASE, inUsdc);
    }

    /// @dev Aero cannot add in place: unstake, increase, restake. The emissions the unstake pays the router (the user
    /// granted approveForClaim) are swept to the user, never stranded.
    function test_increase_staked_restaked() public {
        uint256 tokenId = _stakedA();
        uint128 l0 = _liq(tokenId);
        uint256 aero0 = _bal(AERO, staker);
        assertGt(_earned(GAUGE_A, staker, tokenId), 0, "emissions accrued");
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, 0.5 ether, 1_000e6);

        vm.prank(staker);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));

        assertGt(_liq(tokenId), l0, "liquidity added");
        _assertStaked(GAUGE_A, staker, tokenId);
        assertGt(_bal(AERO, staker), aero0, "unstake emissions reach the user");
        _assertRouterClean(_flowTokens());
    }

    function test_increase_staked_withoutGaugeApproval_reverts() public {
        uint256 tokenId = _stakedA();
        vm.prank(staker);
        ITestGauge(GAUGE_A).setApprovalForAll(address(router), false);
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, 0.5 ether, 1_000e6);
        vm.prank(staker);
        vm.expectRevert(bytes("NW"));
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
    }

    // ------------------------------------------------------------------ decreaseAndSwap

    function test_decrease_partial_staked_staysStaked() public {
        uint256 tokenId = _stakedA();
        uint128 l0 = _liq(tokenId);
        uint256 w0 = _bal(WETH, staker);
        uint256 u0 = _bal(USDC_BASE, staker);
        uint256 a0 = _bal(AERO, staker);

        _decrease(staker, tokenId, l0 / 3, WETH);

        assertEq(_liq(tokenId), l0 - l0 / 3, "liquidity removed");
        _assertStaked(GAUGE_A, staker, tokenId);
        assertGt(_bal(WETH, staker), w0, "WETH paid");
        assertGt(_bal(USDC_BASE, staker), u0, "USDC paid");
        assertGt(_bal(AERO, staker), a0, "emissions paid");
        _assertRouterClean(_flowTokens());
    }

    function test_decrease_full_staked_endsInWallet() public {
        uint256 tokenId = _stakedA();
        _decrease(staker, tokenId, type(uint128).max, WETH);
        assertEq(_liq(tokenId), 0, "emptied");
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker, "NFT in the wallet");
        assertFalse(ITestGauge(GAUGE_A).stakedContains(staker, tokenId), "unstaked");
        _assertRouterClean(_flowTokens());
    }

    /// @dev Controller decision 4: a full withdraw is the user's way out even from a killed gauge.
    function test_decrease_full_staked_deadGauge_endsInWallet() public {
        uint256 tokenId = _stakedA();
        _killGauge(GAUGE_A);
        _decrease(staker, tokenId, type(uint128).max, WETH);
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker, "NFT in the wallet");
        _assertRouterClean(_flowTokens());
    }

    /// @dev Controller decision 4: a partial withdraw would restake into a killed gauge, so it reverts clearly.
    function test_decrease_partial_staked_deadGauge_reverts() public {
        uint256 tokenId = _stakedA();
        uint128 l0 = _liq(tokenId);
        _killGauge(GAUGE_A);
        vm.expectRevert(IRouterErrors.GaugeNotLive.selector);
        this.decreaseAs(staker, tokenId, l0 / 3);
        _assertStaked(GAUGE_A, staker, tokenId);
    }

    // ------------------------------------------------------------------ adjustRange

    function test_adjustRange_staked_newNftStaked_oldToWallet() public {
        uint256 tokenId = _stakedA();
        AdjustRangeParams memory p = _adjustParams(tokenId, POOL_A, TS_A);
        vm.prank(staker);
        bytes memory ret = router.execute(abi.encodeCall(ICoreModify.adjustRange, (p)));
        (uint256 newId, uint128 liquidity) = abi.decode(ret, (uint256, uint128));

        assertTrue(newId != tokenId, "new position");
        assertGt(liquidity, 0, "new liquidity");
        _assertStaked(GAUGE_A, staker, newId);
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker, "old NFT to the wallet");
        assertEq(_liq(tokenId), 0, "old NFT emptied");
        assertFalse(ITestGauge(GAUGE_A).stakedContains(staker, tokenId), "old NFT unstaked");
        _assertRouterClean(_flowTokens());
    }

    function test_adjustRange_staked_deadGauge_reverts() public {
        uint256 tokenId = _stakedA();
        AdjustRangeParams memory p = _adjustParams(tokenId, POOL_A, TS_A);
        _killGauge(GAUGE_A);
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.GaugeNotLive.selector);
        router.execute(abi.encodeCall(ICoreModify.adjustRange, (p)));
    }

    // ------------------------------------------------------------------ compound

    /// @dev Claim (25% PERFORMANCE_FEE on the AERO claimed), swap two thirds of the net reward into the pool's tokens,
    /// unstake, increase, restake; the AERO not swapped and the increase leftovers go to the user.
    function test_compound_staked_rewards_performanceFee() public {
        uint256 tokenId = _stakedA();
        uint256 claimed = _earned(GAUGE_A, staker, tokenId);
        assertGt(claimed, 0, "no emissions accrued");
        uint256 fee = _fee(claimed, PERF_FEE_X64);
        uint256 net = claimed - fee;
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _mockStep(AERO, net / 3, WETH, 0.0003 ether);
        swaps[1] = _mockStep(AERO, net / 3, USDC_BASE, 1e6);
        uint128 l0 = _liq(tokenId);
        uint256 a0 = _bal(AERO, staker);

        vm.recordLogs();
        uint128 added = _compound(staker, _compoundParams(tokenId, swaps));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(added, 0, "added");
        assertEq(_liq(tokenId), l0 + added, "liquidity");
        _assertStaked(GAUGE_A, staker, tokenId);
        assertEq(_bal(AERO, routerFeeTaker), fee, "performance fee on the reward");
        assertEq(_bal(AERO, staker) - a0, net - 2 * (net / 3), "unswapped AERO to the user");
        assertEq(_bal(AERO, address(swapper)), 2 * (net / 3), "swap inputs");
        _assertRouterClean(_flowTokens());

        // exactly one TakeFees: PERFORMANCE_FEE on [AERO] = claimed, tagged with the position and the user
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != TakeFees.selector) continue;
            n++;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(NFPM))));
            assertEq(logs[i].topics[2], bytes32(tokenId));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(staker))));
            IRouterErrors.TakeFeesEventData memory d = abi.decode(logs[i].data, (IRouterErrors.TakeFeesEventData));
            assertEq(uint8(d.feeType), uint8(FeeType.PERFORMANCE_FEE));
            assertEq(d.feeX64, PERF_FEE_X64);
            assertEq(d.feeTokens.length, 1);
            assertEq(d.feeTokens[0].token, AERO);
            assertEq(d.feeTokens[0].amount, fee);
        }
        assertEq(n, 1, "one TakeFees");
    }

    function test_compound_staked_requiresApproveForClaim() public {
        uint256 tokenId = _stakedA();
        vm.prank(staker);
        ITestGauge(GAUGE_A).approveForClaim(address(router), false);
        CompoundParams memory p = _compoundParams(tokenId, _noSwaps());
        vm.prank(staker);
        vm.expectRevert(bytes("NA"));
        router.execute(abi.encodeCall(ICoreModify.compound, (p)));
    }

    /// @dev Router-held tokens (seeded before the call) are neither added nor swept on a staked compound.
    function test_compound_staked_routerBalancesUntouched() public {
        uint256 tokenId = _stakedA();
        deal(AERO, address(router), 7 ether);
        deal(WETH, address(router), 3 ether);
        deal(USDC_BASE, address(router), 5_000e6);
        uint256 net = _earned(GAUGE_A, staker, tokenId);
        net -= _fee(net, PERF_FEE_X64);
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _mockStep(AERO, net / 2, WETH, 0.0003 ether);
        swaps[1] = _mockStep(AERO, 0, USDC_BASE, 1e6); // amountIn 0: the rest the call holds of AERO
        _compound(staker, _compoundParams(tokenId, swaps));
        assertEq(_bal(AERO, address(swapper)), net, "only the call's AERO swapped");
        assertEq(_bal(AERO, address(router)), 7 ether, "router AERO");
        assertEq(_bal(WETH, address(router)), 3 ether, "router WETH");
        assertEq(_bal(USDC_BASE, address(router)), 5_000e6, "router USDC");
        _assertStaked(GAUGE_A, staker, tokenId);
    }

    // ------------------------------------------------------------------ harvest

    function test_harvest_staked_rewards_staysStaked() public {
        uint256 tokenId = _stakedA();
        uint256 claimed = _earned(GAUGE_A, staker, tokenId);
        assertGt(claimed, 0, "no emissions accrued");
        uint256 fee = _fee(claimed, PERF_FEE_X64);
        uint128 l0 = _liq(tokenId);
        uint256 a0 = _bal(AERO, staker);

        vm.expectCall(GAUGE_A, abi.encodeWithSelector(ITestGauge.withdrawFrom.selector), 0);
        uint256 amountOut = _harvest(staker, _harvestParams(tokenId, AERO, _noSwaps()));

        assertEq(amountOut, claimed - fee, "amountOut");
        assertEq(_bal(AERO, staker) - a0, claimed - fee, "net reward to the user");
        assertEq(_bal(AERO, routerFeeTaker), fee, "performance fee");
        assertEq(_liq(tokenId), l0, "liquidity untouched");
        _assertStaked(GAUGE_A, staker, tokenId);
        _assertRouterClean(_flowTokens());
    }

    function test_harvest_staked_swapToDestToken() public {
        uint256 tokenId = _stakedA();
        uint256 net = _earned(GAUGE_A, staker, tokenId);
        net -= _fee(net, PERF_FEE_X64);
        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = _mockStep(AERO, 0, USDC_BASE, 7e6);
        uint256 u0 = _bal(USDC_BASE, staker);
        uint256 amountOut = _harvest(staker, _harvestParams(tokenId, USDC_BASE, swaps));
        assertEq(amountOut, 7e6, "amountOut");
        assertEq(_bal(USDC_BASE, staker) - u0, 7e6, "USDC to the user");
        assertEq(_bal(AERO, address(swapper)), net, "the whole net reward swapped");
        _assertStaked(GAUGE_A, staker, tokenId);
        _assertRouterClean(_flowTokens());
    }

    function test_harvest_staked_destTokenNoSwaps_reverts() public {
        uint256 tokenId = _stakedA();
        assertGt(_earned(GAUGE_A, staker, tokenId), 0, "no emissions accrued");
        HarvestParams memory p = _harvestParams(tokenId, USDC_BASE, _noSwaps());
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.MissingSwapData.selector);
        router.execute(abi.encodeCall(ICoreModify.harvest, (p)));
    }

    function test_harvest_staked_requiresApproveForClaim() public {
        uint256 tokenId = _stakedA();
        vm.prank(staker);
        ITestGauge(GAUGE_A).approveForClaim(address(router), false);
        HarvestParams memory p = _harvestParams(tokenId, AERO, _noSwaps());
        vm.prank(staker);
        vm.expectRevert(bytes("NA"));
        router.execute(abi.encodeCall(ICoreModify.harvest, (p)));
    }

    // ------------------------------------------------------------------ unstake emissions are fee-collectible

    /// @dev Runs `flow` (0 decrease, 1 adjustRange, 2 swapAndIncrease) on a staked position with `feeX64` as its
    /// performanceFeeX64. With approveForClaim, the unstake pays the router the emissions; PERFORMANCE_FEE is taken on
    /// exactly that reward-token delta (one TakeFees on [AERO] tagged with the position) and the rest reaches the user.
    function _unstakeEmissionsCase(uint8 flow, uint64 feeX64) internal {
        uint256 tokenId = _stakedA();
        uint256 emissions = _earned(GAUGE_A, staker, tokenId);
        assertGt(emissions, 0, "no emissions accrued");
        uint256 a0 = _bal(AERO, staker);
        bytes memory call;
        if (flow == 0) {
            DecreaseAndSwapParams memory p;
            p.nfpm = NFPM;
            p.tokenId = tokenId;
            p.decrease =
                DecreaseParams({liquidity: _liq(tokenId) / 3, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
            p.destToken = WETH;
            p.performanceFeeX64 = feeX64;
            call = abi.encodeCall(ICoreModify.decreaseAndSwap, (p));
        } else if (flow == 1) {
            AdjustRangeParams memory p = _adjustParams(tokenId, POOL_A, TS_A);
            p.performanceFeeX64 = feeX64;
            call = abi.encodeCall(ICoreModify.adjustRange, (p));
        } else {
            SwapAndIncreaseParams memory p = _increaseParams(tokenId, 0.5 ether, 1_000e6);
            p.performanceFeeX64 = feeX64;
            call = abi.encodeCall(ICoreMint.swapAndIncrease, (p));
        }

        vm.recordLogs();
        vm.prank(staker);
        router.execute(call);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 fee = _fee(emissions, feeX64);
        assertEq(_bal(AERO, routerFeeTaker), fee, "fee taker gets exactly the fee on the emissions");
        assertEq(_bal(AERO, staker) - a0, emissions - fee, "user gets the rest");
        _assertRouterClean(_flowTokens());

        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != TakeFees.selector) continue;
            IRouterErrors.TakeFeesEventData memory d = abi.decode(logs[i].data, (IRouterErrors.TakeFeesEventData));
            if (d.feeTokens.length != 1 || d.feeTokens[0].token != AERO) continue;
            n++;
            assertEq(logs[i].topics[2], bytes32(tokenId), "tagged with the position");
            assertEq(uint8(d.feeType), uint8(FeeType.PERFORMANCE_FEE));
            assertEq(d.feeX64, feeX64);
            assertEq(d.feeTokens[0].amount, fee);
        }
        assertEq(n, feeX64 == 0 ? 0 : 1, "TakeFees on the emissions");
    }

    function test_decrease_staked_unstakeEmissions_performanceFee() public {
        _unstakeEmissionsCase(0, PERF_FEE_X64);
    }

    function test_decrease_staked_unstakeEmissions_zeroFee() public {
        _unstakeEmissionsCase(0, 0);
    }

    function test_adjustRange_staked_unstakeEmissions_performanceFee() public {
        _unstakeEmissionsCase(1, PERF_FEE_X64);
    }

    function test_adjustRange_staked_unstakeEmissions_zeroFee() public {
        _unstakeEmissionsCase(1, 0);
    }

    function test_increase_staked_unstakeEmissions_performanceFee() public {
        _unstakeEmissionsCase(2, PERF_FEE_X64);
    }

    function test_increase_staked_unstakeEmissions_zeroFee() public {
        _unstakeEmissionsCase(2, 0);
    }

    /// @dev Without approveForClaim the gauge pays the emissions to the user itself on withdrawFrom: no fee is possible.
    function test_decrease_staked_noClaimApproval_emissionsToUserUnfeed() public {
        uint256 tokenId = _stakedA();
        vm.prank(staker);
        ITestGauge(GAUGE_A).approveForClaim(address(router), false);
        uint256 emissions = _earned(GAUGE_A, staker, tokenId);
        assertGt(emissions, 0, "no emissions accrued");
        uint256 a0 = _bal(AERO, staker);
        DecreaseAndSwapParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.decrease =
            DecreaseParams({liquidity: _liq(tokenId) / 3, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        p.destToken = WETH;
        p.performanceFeeX64 = PERF_FEE_X64;
        vm.prank(staker);
        router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (p)));
        assertEq(_bal(AERO, routerFeeTaker), 0, "no fee without the router receiving them");
        assertEq(_bal(AERO, staker) - a0, emissions, "the gauge pays the user all its emissions directly");
        _assertStaked(GAUGE_A, staker, tokenId);
        _assertRouterClean(_flowTokens());
    }

    uint64 internal constant OVER_PERF_CAP = 5902958103587057001; // the PERFORMANCE_FEE cap + 1

    /// @dev An over-cap performanceFeeX64 reverts TooMuchFee even when the unstake pays no emissions (same block as
    /// the stake, inside the penalty window), so the result does not depend on accrual. swapAndIncrease is the flow
    /// whose performanceFeeX64 applies to nothing but unstake emissions.
    function test_increase_staked_perfFeeOverCap_noEmissions_reverts() public {
        uint256 tokenId = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, true));
        assertEq(_earned(GAUGE_A, staker, tokenId), 0, "no emissions yet");
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, 0.5 ether, 1_000e6);
        p.performanceFeeX64 = OVER_PERF_CAP;
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.TooMuchFee.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
    }

    /// @dev ... and for a wallet position too (no unstake at all).
    function test_increase_wallet_perfFeeOverCap_reverts() public {
        uint256 tokenId = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, false));
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, 0.5 ether, 1_000e6);
        p.performanceFeeX64 = OVER_PERF_CAP;
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.TooMuchFee.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
    }

    /// @dev At the cap exactly, a staked increase with no emissions succeeds and emits no TakeFees on the reward.
    function test_increase_staked_perfFeeAtCap_noEmissions_ok() public {
        uint256 tokenId = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, true));
        SwapAndIncreaseParams memory p = _increaseParams(tokenId, 0.5 ether, 1_000e6);
        p.performanceFeeX64 = OVER_PERF_CAP - 1;
        vm.recordLogs();
        vm.prank(staker);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != TakeFees.selector) continue;
            IRouterErrors.TakeFeesEventData memory d = abi.decode(logs[i].data, (IRouterErrors.TakeFeesEventData));
            assertTrue(d.feeType != FeeType.PERFORMANCE_FEE, "no reward fee event for zero emissions");
        }
        _assertStaked(GAUGE_A, staker, tokenId);
        _assertRouterClean(_flowTokens());
    }

    // ------------------------------------------------------------------ holder checks and the receive guard

    /// @dev Review Focus 2: someone else's staked position reverts NotPositionHolder in every flow, before anything
    /// moves (the gauge is never asked to withdraw or claim), even with the attacker's own gauge approvals in place.
    function test_notHolder_staked_reverts() public {
        uint256 tokenId = _stakedA();
        _approveGauge(attacker, GAUGE_A, true);
        _dealAndApprove(WETH, attacker, 1 ether);
        _dealAndApprove(USDC_BASE, attacker, 1_000e6);

        SwapAndIncreaseParams memory inc = _increaseParams(tokenId, 0.1 ether, 100e6);
        DecreaseAndSwapParams memory dec;
        dec.nfpm = NFPM;
        dec.tokenId = tokenId;
        dec.decrease =
            DecreaseParams({liquidity: type(uint128).max, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(ICoreMint.swapAndIncrease, (inc));
        calls[1] = abi.encodeCall(ICoreModify.decreaseAndSwap, (dec));
        calls[2] = abi.encodeCall(ICoreModify.adjustRange, (_adjustParams(tokenId, POOL_A, TS_A)));
        calls[3] = abi.encodeCall(ICoreModify.compound, (_compoundParams(tokenId, _noSwaps())));
        calls[4] = abi.encodeCall(ICoreModify.harvest, (_harvestParams(tokenId, AERO, _noSwaps())));

        // from here to the end of the test, the gauge is never asked to withdraw or claim
        vm.expectCall(GAUGE_A, abi.encodeWithSelector(ITestGauge.withdrawFrom.selector), 0);
        vm.expectCall(GAUGE_A, abi.encodeWithSelector(ITestGauge.claimEmissions.selector), 0);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(attacker);
            vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
            router.execute(calls[i]);
        }
        _assertStaked(GAUGE_A, staker, tokenId);
        assertFalse(ITestGauge(GAUGE_A).stakedContains(attacker, tokenId));
    }

    /// @dev The router takes an NFT only under a farm's expected-NFT record: not one a holder sends it, nor one the
    /// gauge sends it outside a flow.
    function test_unsolicitedNft_rejected() public {
        uint256 tokenId = _stakedA();
        vm.prank(staker);
        ITestGauge(GAUGE_A).withdraw(tokenId);
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker);
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        IERC721(NFPM).safeTransferFrom(staker, address(router), tokenId);

        vm.prank(NFPM);
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        router.onERC721Received(GAUGE_A, GAUGE_A, tokenId, "");
    }
}

/// @notice Optimism: the farm pays xAERO and cannot compound it; harvest pays the reward as is.
contract StakedOpTest is AeroFarmBase {
    uint256 internal tokenId;

    function setUp() public {
        _setUpAero(true);
        _approveGauge(staker, GAUGE_OP, true);
        // pool tokens: token0 = USDC (0x0b2C.. < 0x4200..), token1 = WETH
        tokenId = _mint(staker, _mintParams(_key(USDC_OP, WETH, TS_OP), POOL_OP, 10_000e6, 5 ether, true));
        _pastPenalty(GAUGE_OP);
    }

    /// @dev Ruling: off Base the reward is paid as is. A staked harvest asking to convert it (destToken set and not the
    /// reward, or any swaps) reverts CompoundDisabled before anything moves.
    function test_op_harvest_conversion_compoundDisabled() public {
        HarvestParams memory toWeth = _harvestParams(tokenId, WETH, _noSwaps());
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.CompoundDisabled.selector);
        router.execute(abi.encodeCall(ICoreModify.harvest, (toWeth)));

        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = SwapParams({tokenIn: XAERO, amountIn: 0, tokenOut: WETH, amountOutMin: 0, swapData: hex"01"});
        HarvestParams memory withSwaps = _harvestParams(tokenId, XAERO, swaps);
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.CompoundDisabled.selector);
        router.execute(abi.encodeCall(ICoreModify.harvest, (withSwaps)));
        _assertStaked(GAUGE_OP, staker, tokenId);
    }

    /// @dev destToken 0 and no swaps: the xAERO is paid as is (amountOut is the native delta, 0).
    function test_op_harvest_zeroDest_paysXAero() public {
        uint256 claimed = _earned(GAUGE_OP, staker, tokenId);
        assertGt(claimed, 0, "no xAERO emissions accrued");
        uint256 fee = _fee(claimed, PERF_FEE_X64);
        uint256 x0 = _bal(XAERO, staker);
        _harvest(staker, _harvestParams(tokenId, address(0), _noSwaps()));
        assertEq(_bal(XAERO, staker) - x0, claimed - fee, "net xAERO to the user");
        assertEq(_bal(XAERO, routerFeeTaker), fee, "performance fee in xAERO");
        _assertStaked(GAUGE_OP, staker, tokenId);
        _assertRouterClean(_tokens3(USDC_OP, WETH, XAERO));
    }

    function test_op_compoundDisabled_harvestPaysXAero() public {
        _assertStaked(GAUGE_OP, staker, tokenId);
        CompoundParams memory c = _compoundParams(tokenId, _noSwaps());
        vm.prank(staker);
        vm.expectRevert(IRouterErrors.CompoundDisabled.selector);
        router.execute(abi.encodeCall(ICoreModify.compound, (c)));

        uint256 claimed = _earned(GAUGE_OP, staker, tokenId);
        assertGt(claimed, 0, "no xAERO emissions accrued");
        uint256 fee = _fee(claimed, PERF_FEE_X64);
        uint256 x0 = _bal(XAERO, staker);
        uint256 amountOut = _harvest(staker, _harvestParams(tokenId, XAERO, _noSwaps()));
        assertEq(amountOut, claimed - fee, "amountOut");
        assertEq(_bal(XAERO, staker) - x0, claimed - fee, "net xAERO to the user");
        assertEq(_bal(XAERO, routerFeeTaker), fee, "performance fee in xAERO");
        _assertStaked(GAUGE_OP, staker, tokenId);
        _assertRouterClean(_tokens3(USDC_OP, WETH, XAERO));
    }
}

/// @dev MasterChef-v3-like holder: keeps staked NFTs under a recorded staker and adds liquidity from its caller's tokens
/// with no owner check (as `MasterChefV3.increaseLiquidity`), refunding what the NFPM did not take.
contract MockChef {
    using SafeERC20 for IERC20;

    mapping(uint256 => address) public stakerOf;
    uint256 public increaseCalls;

    function stakeFrom(address nfpm, uint256 tokenId) external {
        IERC721(nfpm).transferFrom(msg.sender, address(this), tokenId);
        stakerOf[tokenId] = msg.sender;
    }

    function increase(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        increaseCalls++;
        (,, address token0, address token1,,,,,,,,) = INonfungiblePositionManager(nfpm).positions(tokenId);
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        IERC20(token0).forceApprove(nfpm, amount0);
        IERC20(token1).forceApprove(nfpm, amount1);
        (liquidity, used0, used1) = INonfungiblePositionManager(nfpm)
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(tokenId, amount0, amount1, 0, 0, deadline)
            );
        IERC20(token0).forceApprove(nfpm, 0);
        IERC20(token1).forceApprove(nfpm, 0);
        IERC20(token0).safeTransfer(msg.sender, amount0 - used0);
        IERC20(token1).safeTransfer(msg.sender, amount1 - used1);
    }
}

/// @dev A farm that cannot unstake but adds liquidity in place through `MockChef` (delegatecalled; config in
/// immutables only). The shape of a future MasterChefV3 farm.
contract MockInPlaceFarm {
    using SafeERC20 for IERC20;

    error NotSupported();

    MockChef public immutable chef;
    address public immutable reward;

    constructor(MockChef chef_, address reward_) {
        chef = chef_;
        reward = reward_;
    }

    function isStakedBy(address, uint256 tokenId, address account) external payable returns (bool) {
        return chef.stakerOf(tokenId) == account;
    }

    function canUnstake() external payable returns (bool) {
        return false;
    }

    function canIncreaseStaked() external payable returns (bool) {
        return true;
    }

    function earnsTradingFees() external payable returns (bool) {
        return true;
    }

    function canCompound() external payable returns (bool) {
        return false;
    }

    function rewardToken() external payable returns (address) {
        return reward;
    }

    function checkStakeable(address, PoolKey calldata) external payable {}

    function stake(address, uint256, address) external payable {
        revert NotSupported();
    }

    function unstake(address, uint256, address) external payable {
        revert NotSupported();
    }

    function claim(address, uint256, address) external payable returns (uint256) {
        revert NotSupported();
    }

    function increaseStaked(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        payable
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        (,, address token0, address token1,,,,,,,,) = INonfungiblePositionManager(nfpm).positions(tokenId);
        IERC20(token0).forceApprove(address(chef), amount0);
        IERC20(token1).forceApprove(address(chef), amount1);
        (liquidity, used0, used1) = chef.increase(nfpm, tokenId, amount0, amount1, deadline);
        IERC20(token0).forceApprove(address(chef), 0);
        IERC20(token1).forceApprove(address(chef), 0);
    }
}

/// @notice A staked position whose farm adds in place (`canIncreaseStaked`) but cannot unstake, on the Arbitrum
/// Uniswap v3 fixture: swapAndIncrease goes through `increaseStaked` with no take or put back; every flow that needs
/// the NFT reverts FarmUnsupported.
contract StakedInPlaceTest is UniV3FlowBase {
    MockChef internal chef;
    MockInPlaceFarm internal inPlace;
    CoreModify internal coreModify;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        coreModify = new CoreModify();
        _registerModule(ICoreModify.decreaseAndSwap.selector, address(coreModify));
        _registerModule(ICoreModify.harvest.selector, address(coreModify));
        chef = new MockChef();
        inPlace = new MockInPlaceFarm(chef, ARB);
        _register(NFPM, adapter, address(inPlace));
        (tokenId,) = _aliceMints();
        vm.startPrank(alice);
        IERC721(NFPM).approve(address(chef), tokenId);
        chef.stakeFrom(NFPM, tokenId);
        vm.stopPrank();
    }

    function test_increase_staked_inPlaceFarm_mock() public {
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        SwapAndIncreaseParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.increase = IncreaseParams({minLiquidity: 0, deadline: block.timestamp});
        p.inputTokens = _inputs2(WETH, IN_WETH, USDC, IN_USDC);
        uint128 l0 = _liquidityOf(tokenId);

        vm.recordLogs();
        vm.prank(alice);
        bytes memory ret = router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint128 added = abi.decode(ret, (uint128));
        assertGt(added, 0, "added");
        assertEq(_liquidityOf(tokenId), l0 + added, "liquidity");
        assertEq(chef.increaseCalls(), 1, "exactly one increaseStaked");
        assertEq(IERC721(NFPM).ownerOf(tokenId), address(chef), "NFT stays with the farm");
        assertEq(chef.stakerOf(tokenId), alice, "still alice's stake");
        // the NFT never moved: no ERC721 Transfer of tokenId during the call
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == NFPM && logs[i].topics[0] == transferSig && logs[i].topics.length == 4) {
                assertTrue(uint256(logs[i].topics[3]) != tokenId, "NFT transferred");
            }
        }
        // leftovers back to alice, nothing on the router or the chef
        assertGt(_bal(WETH, alice) + _bal(USDC, alice), 0, "leftovers returned");
        _assertRouterClean(_tokens3(WETH, USDC, ARB));
        assertEq(_bal(WETH, address(chef)), 0, "chef WETH");
        assertEq(_bal(USDC, address(chef)), 0, "chef USDC");
    }

    function test_increase_inPlaceFarm_notHolder_reverts() public {
        _dealAndApprove(WETH, bob, IN_WETH);
        SwapAndIncreaseParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.increase = IncreaseParams({minLiquidity: 0, deadline: block.timestamp});
        p.inputTokens = _inputs1(WETH, IN_WETH);
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(ICoreMint.swapAndIncrease, (p)));
    }

    function test_decrease_inPlaceFarm_cannotUnstake_reverts() public {
        DecreaseAndSwapParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.decrease = DecreaseParams({liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.FarmUnsupported.selector);
        router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (p)));
    }

    function test_harvest_inPlaceFarm_cannotClaim_reverts() public {
        HarvestParams memory p = HarvestParams({
            nfpm: NFPM, tokenId: tokenId, swaps: new SwapParams[](0), destToken: WETH, performanceFeeX64: 0
        });
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.FarmUnsupported.selector);
        router.execute(abi.encodeCall(ICoreModify.harvest, (p)));
    }
}
