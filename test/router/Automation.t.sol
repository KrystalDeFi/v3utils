// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {StructHash} from "../../src/StructHash.sol";
import {RouterStorage} from "../../src/router/RouterStorage.sol";
import {CoreModify} from "../../src/router/modules/CoreModify.sol";
import {ICoreModify} from "../../src/router/interfaces/ICoreModify.sol";
import {IRouterErrors} from "../../src/router/IRouterErrors.sol";
import {
    AutoAction,
    SwapParams,
    MintParams,
    IncreaseParams,
    DecreaseParams,
    AdjustRangeParams,
    DecreaseAndSwapParams,
    CompoundParams,
    HarvestParams
} from "../../src/router/RouterTypes.sol";
import {RouterTestBase} from "./RouterTestBase.sol";
import {UniV3FlowBase} from "./flows/UniV3FlowBase.sol";
import {AeroFarmBase, ITestGauge} from "./farms/AeroFarmBase.sol";

/// @dev Order building, signing and the operator call, shared by the Arbitrum and Base suites.
abstract contract AutomationOrders is RouterTestBase {
    function _order(address nfpm, uint256 tokenId) internal view returns (StructHash.Order memory o) {
        o.chainId = int64(int256(block.chainid));
        o.nfpmAddress = nfpm;
        o.tokenId = tokenId;
        o.orderType = "ORDER_TYPE_REBALANCE";
        o.signatureTime = int64(int256(block.timestamp));
    }

    function _sign(uint256 key, bytes memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, router.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The operator runs `action` for `account`, under an order for (`nfpm`, `tokenId`) signed by `key`.
    function _auto(
        uint256 key,
        address account,
        address nfpm,
        uint256 tokenId,
        AutoAction action,
        bytes memory actionData
    ) internal returns (bytes memory) {
        bytes memory order = abi.encode(_order(nfpm, tokenId));
        return _autoWith(account, nfpm, tokenId, action, actionData, order, _sign(key, order));
    }

    function _autoWith(
        address account,
        address nfpm,
        uint256 tokenId,
        AutoAction action,
        bytes memory actionData,
        bytes memory order,
        bytes memory signature
    ) internal returns (bytes memory) {
        vm.prank(routerOperator);
        return router.executeAutomation(account, nfpm, tokenId, uint8(action), actionData, order, signature);
    }

    /// @dev `automationAccount` (slot 8, offset 1, packed after `locked`) and `automationTarget` (slot 9) of the
    /// ERC-7201 layout, as `forge inspect` lays them out.
    function _assertRecordCleared() internal view {
        uint256 base = uint256(RouterStorage.SLOT);
        assertEq(uint256(vm.load(address(router), bytes32(base + 8))) >> 8, 0, "automationAccount cleared");
        assertEq(vm.load(address(router), bytes32(base + 9)), bytes32(0), "automationTarget cleared");
    }
}

/// @notice executeAutomation on an unstaked Uniswap v3 position (Arbitrum fork).
contract AutomationUnstakedTest is UniV3FlowBase, AutomationOrders {
    uint64 internal constant PERF_FEE_X64 = 1844674407370955161; // 10%

    uint256 internal aliceKey;
    CoreModify internal coreModify;
    address internal trader = makeAddr("auTrader");

    function setUp() public override {
        super.setUp();
        (, aliceKey) = makeAddrAndKey("cmAlice");
        coreModify = new CoreModify();
        _registerModule(ICoreModify.decreaseAndSwap.selector, address(coreModify));
        _registerModule(ICoreModify.adjustRange.selector, address(coreModify));
        _registerModule(ICoreModify.compound.selector, address(coreModify));
        _registerModule(ICoreModify.harvest.selector, address(coreModify));
    }

    function _churn() internal {
        uint256 usdcOut = _poolSwap(trader, WETH, USDC, 100 ether);
        _poolSwap(trader, USDC, WETH, usdcOut);
    }

    function _adjustParams(uint256 tokenId) internal view returns (AdjustRangeParams memory p) {
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.swaps = new SwapParams[](0);
        p.mint = MintParams({tickLower: -199000, tickUpper: -197000, minLiquidity: 0, deadline: block.timestamp});
        p.compoundFees = true;
        p.performanceFeeX64 = PERF_FEE_X64;
    }

    function _harvestParams(uint256 tokenId) internal view returns (HarvestParams memory) {
        return HarvestParams({
            nfpm: NFPM,
            tokenId: tokenId,
            swaps: _swaps1(_step(WETH, USDC, 0, 1)),
            destToken: USDC,
            performanceFeeX64: PERF_FEE_X64
        });
    }

    function _runAdjust(uint256 tokenId) internal returns (bytes memory) {
        return _auto(aliceKey, alice, NFPM, tokenId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(tokenId)));
    }

    function _ticksOf(uint256 tokenId) internal view returns (int24 lower, int24 upper) {
        (,,,,, lower, upper,,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
    }

    function test_auto_adjust_unstaked() public {
        (uint256 tokenId,) = _aliceMints();
        _churn();
        (uint256 newId, uint128 liquidity) = abi.decode(_runAdjust(tokenId), (uint256, uint128));
        assertTrue(newId != tokenId, "new position");
        assertGt(liquidity, 0, "new liquidity");
        assertEq(_liquidityOf(newId), liquidity, "new NFT liquidity");
        assertEq(_liquidityOf(tokenId), 0, "old emptied");
        // the new NFT keeps the old one's state: in the wallet of the same account, in the new range
        assertEq(IERC721(NFPM).ownerOf(newId), alice, "new NFT in alice's wallet");
        (int24 lower, int24 upper) = _ticksOf(newId);
        assertEq(lower, -199000);
        assertEq(upper, -197000);
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));
        _assertRecordCleared();
    }

    function test_auto_harvest_unstaked_tradingFees() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        uint256 usdc0 = _bal(USDC, alice);
        uint256 out = abi.decode(
            _auto(aliceKey, alice, NFPM, tokenId, AutoAction.AUTO_HARVEST, abi.encode(_harvestParams(tokenId))),
            (uint256)
        );
        assertGt(out, 0, "harvested");
        assertEq(_bal(USDC, alice) - usdc0, out, "paid to alice, not the operator");
        assertEq(_bal(USDC, routerOperator), 0, "operator got nothing");
        assertEq(_liquidityOf(tokenId), liquidity, "no liquidity removed");
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice, "NFT back in the wallet");
        assertGt(_bal(WETH, routerFeeTaker), 0, "performance fee taken");
        _assertRouterClean(_tokens3(WETH, USDC, address(0)));
        _assertRecordCleared();
    }

    function test_auto_exit_unstaked_toWallet() public {
        (uint256 tokenId,) = _aliceMints();
        DecreaseAndSwapParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.decrease =
            DecreaseParams({liquidity: type(uint128).max, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        p.destToken = WETH;
        p.swaps = _swaps1(_step(USDC, WETH, 0, 1));
        uint256 weth0 = _bal(WETH, alice);
        uint256 out = abi.decode(_auto(aliceKey, alice, NFPM, tokenId, AutoAction.AUTO_EXIT, abi.encode(p)), (uint256));
        assertGt(out, 0);
        assertEq(_bal(WETH, alice) - weth0, out, "to alice");
        assertEq(_liquidityOf(tokenId), 0, "emptied");
        _assertRecordCleared();
    }

    function test_auto_compound_unstaked_tradingFees() public {
        (uint256 tokenId, uint128 liquidity) = _aliceMints();
        _churn();
        CompoundParams memory p = CompoundParams({
            nfpm: NFPM,
            tokenId: tokenId,
            swaps: new SwapParams[](0),
            increase: IncreaseParams({minLiquidity: 0, deadline: block.timestamp}),
            performanceFeeX64: PERF_FEE_X64
        });
        uint128 added =
            abi.decode(_auto(aliceKey, alice, NFPM, tokenId, AutoAction.AUTO_COMPOUND, abi.encode(p)), (uint128));
        assertGt(added, 0);
        assertEq(_liquidityOf(tokenId), liquidity + added, "liquidity grew");
        _assertRecordCleared();
    }

    /// @dev `actionData` names another position than the one the order and holder check covered: the flow refuses.
    function test_auto_paramsTargetMismatch_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        _dealAndApprove(WETH, alice, IN_WETH);
        _dealAndApprove(USDC, alice, IN_USDC);
        (uint256 other,) = _mint(
            alice, _mintParams(IN_LOWER, IN_UPPER, _inputs2(WETH, IN_WETH, USDC, IN_USDC), new SwapParams[](0), 0, 0), 0
        );
        assertTrue(other != tokenId);
        // the order, holder check and recorded target are for `tokenId`; the params are for alice's other NFT
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(aliceKey, order);
        vm.expectRevert(IRouterErrors.NotAutomation.selector);
        _autoWith(alice, NFPM, tokenId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(other)), order, sig);
        assertGt(_liquidityOf(other), 0, "other position untouched");
    }

    function test_auto_notHolder_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        (address mallory, uint256 malloryKey) = makeAddrAndKey("auMallory");
        // mallory signs a perfectly valid order, but does not hold alice's NFT
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(malloryKey, order);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        _autoWith(mallory, NFPM, tokenId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(tokenId)), order, sig);
        assertEq(IERC721(NFPM).ownerOf(tokenId), alice);
    }

    function test_auto_wrongChainOrNfpm_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        bytes memory data = abi.encode(_adjustParams(tokenId));

        StructHash.Order memory o = _order(NFPM, tokenId);
        o.chainId = int64(int256(block.chainid)) + 1;
        bytes memory order = abi.encode(o);
        bytes memory sig = _sign(aliceKey, order);
        vm.expectRevert(IRouterErrors.WrongChainId.selector);
        _autoWith(alice, NFPM, tokenId, AutoAction.AUTO_ADJUST, data, order, sig);

        o = _order(address(0xdead), tokenId);
        order = abi.encode(o);
        sig = _sign(aliceKey, order);
        vm.expectRevert(IRouterErrors.WrongPositionManager.selector);
        _autoWith(alice, NFPM, tokenId, AutoAction.AUTO_ADJUST, data, order, sig);
    }

    function test_auto_badSignature_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        (, uint256 otherKey) = makeAddrAndKey("auOther");
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(otherKey, order);
        vm.expectRevert(IRouterErrors.InvalidSignature.selector);
        _autoWith(alice, NFPM, tokenId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(tokenId)), order, sig);
    }

    function test_auto_cancelledOrder_reverts() public {
        (uint256 tokenId,) = _aliceMints();
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(aliceKey, order);
        bytes32 digest = router.hashOrder(order);
        vm.prank(alice);
        router.cancelOrder(digest, sig);
        assertTrue(router.isOrderCancelled(alice, digest));
        vm.expectRevert(IRouterErrors.OrderCancelled.selector);
        _autoWith(alice, NFPM, tokenId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(tokenId)), order, sig);
    }

    function test_auto_onlyOperator() public {
        (uint256 tokenId,) = _aliceMints();
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(aliceKey, order);
        // neither the account itself nor a stranger may run the bot path
        vm.prank(alice);
        vm.expectRevert();
        router.executeAutomation(
            alice, NFPM, tokenId, uint8(AutoAction.AUTO_ADJUST), abi.encode(_adjustParams(tokenId)), order, sig
        );
        vm.prank(bob);
        vm.expectRevert();
        router.executeAutomation(
            alice, NFPM, tokenId, uint8(AutoAction.AUTO_ADJUST), abi.encode(_adjustParams(tokenId)), order, sig
        );
    }

    /// @dev A user cannot reach another account's position through `execute`: no automation record, so the account is
    /// the caller, who does not hold the token.
    function test_execute_cannotSpoofAutomation() public {
        (uint256 tokenId,) = _aliceMints();
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(ICoreModify.adjustRange, (_adjustParams(tokenId))));
    }

    function test_automationRecordCleared() public {
        (uint256 tokenId,) = _aliceMints();
        _runAdjust(tokenId);
        _assertRecordCleared();
        // and a later plain `execute` by a stranger is not mistaken for automation
        vm.prank(bob);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(abi.encodeCall(ICoreModify.adjustRange, (_adjustParams(tokenId))));
    }
}

/// @notice executeAutomation on positions staked in a new Aero gauge, and an unstaked Aero one (Base fork).
/// Run with `FOUNDRY_EVM_VERSION=cancun`.
contract AutomationStakedTest is AeroFarmBase, AutomationOrders {
    uint256 internal stakerKey;

    function setUp() public {
        _setUpAero(false);
        (, stakerKey) = makeAddrAndKey("aeroStaker");
        _approveGauge(staker, GAUGE_A, true);
        vm.prank(staker);
        IERC721(NFPM).setApprovalForAll(address(router), true);
    }

    function _flowTokens() internal pure returns (address[] memory) {
        return _tokens3(WETH, USDC_BASE, AERO);
    }

    function _run(uint256 tokenId, AutoAction action, bytes memory data) internal returns (bytes memory) {
        return _auto(stakerKey, staker, NFPM, tokenId, action, data);
    }

    function test_auto_adjust_unstaked_and_staked() public {
        // staked: the new NFT is staked for the same account, the old one is emptied into the wallet
        uint256 stakedId = _stakedA();
        (uint256 newId, uint128 liquidity) = abi.decode(
            _run(stakedId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(stakedId, POOL_A, TS_A))),
            (uint256, uint128)
        );
        assertTrue(newId != stakedId, "new position");
        assertGt(liquidity, 0);
        _assertStaked(GAUGE_A, staker, newId);
        assertEq(IERC721(NFPM).ownerOf(stakedId), staker, "old NFT to the wallet");
        assertEq(_liq(stakedId), 0, "old NFT emptied");
        _assertRouterClean(_flowTokens());
        _assertRecordCleared();

        // unstaked: the new NFT stays in the wallet
        uint256 walletId = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, false));
        (newId, liquidity) = abi.decode(
            _run(walletId, AutoAction.AUTO_ADJUST, abi.encode(_adjustParams(walletId, POOL_A, TS_A))),
            (uint256, uint128)
        );
        assertEq(IERC721(NFPM).ownerOf(newId), staker, "new NFT in the wallet");
        assertFalse(ITestGauge(GAUGE_A).stakedContains(staker, newId), "not staked");
        assertEq(_liq(newId), liquidity);
        _assertRouterClean(_flowTokens());
        _assertRecordCleared();
    }

    function test_auto_exit_staked_toWallet() public {
        uint256 tokenId = _stakedA();
        DecreaseAndSwapParams memory p;
        p.nfpm = NFPM;
        p.tokenId = tokenId;
        p.decrease =
            DecreaseParams({liquidity: type(uint128).max, amount0Min: 0, amount1Min: 0, deadline: block.timestamp});
        p.destToken = WETH;
        p.performanceFeeX64 = PERF_FEE_X64;
        uint256 weth0 = _bal(WETH, staker);
        uint256 out = abi.decode(_run(tokenId, AutoAction.AUTO_EXIT, abi.encode(p)), (uint256));
        assertGt(out, 0);
        assertEq(_bal(WETH, staker) - weth0, out, "to the account");
        assertEq(_bal(WETH, routerOperator), 0, "operator got nothing");
        assertEq(_liq(tokenId), 0, "emptied");
        assertEq(IERC721(NFPM).ownerOf(tokenId), staker, "NFT in the wallet");
        assertFalse(ITestGauge(GAUGE_A).stakedContains(staker, tokenId), "unstaked");
        _assertRouterClean(_flowTokens());
        _assertRecordCleared();
    }

    function test_auto_compound_staked_rewards() public {
        uint256 tokenId = _stakedA();
        uint256 claimed = _earned(GAUGE_A, staker, tokenId);
        assertGt(claimed, 0, "no emissions accrued");
        uint256 fee = _fee(claimed, PERF_FEE_X64);
        uint256 net = claimed - fee;
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _mockStep(AERO, net / 3, WETH, 0.0003 ether);
        swaps[1] = _mockStep(AERO, net / 3, USDC_BASE, 1e6);
        uint128 l0 = _liq(tokenId);
        uint128 added =
            abi.decode(_run(tokenId, AutoAction.AUTO_COMPOUND, abi.encode(_compoundParams(tokenId, swaps))), (uint128));
        assertGt(added, 0, "added");
        assertEq(_liq(tokenId), l0 + added, "liquidity");
        _assertStaked(GAUGE_A, staker, tokenId);
        assertEq(_bal(AERO, routerFeeTaker), fee, "performance fee on the reward");
        assertEq(_bal(AERO, routerOperator), 0, "operator got nothing");
        _assertRouterClean(_flowTokens());
        _assertRecordCleared();
    }

    function test_auto_harvest_staked_rewards() public {
        uint256 tokenId = _stakedA();
        uint256 claimed = _earned(GAUGE_A, staker, tokenId);
        uint256 a0 = _bal(AERO, staker);
        uint256 out = abi.decode(
            _run(tokenId, AutoAction.AUTO_HARVEST, abi.encode(_harvestParams(tokenId, AERO, _noSwaps()))), (uint256)
        );
        assertEq(out, claimed - _fee(claimed, PERF_FEE_X64));
        assertEq(_bal(AERO, staker) - a0, out);
        _assertStaked(GAUGE_A, staker, tokenId);
        _assertRecordCleared();
    }

    /// @dev A position someone else staked: the operator cannot run it for the wrong account.
    function test_auto_notHolder_staked_reverts() public {
        uint256 tokenId = _stakedA();
        (address mallory, uint256 malloryKey) = makeAddrAndKey("aeroMallory");
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(malloryKey, order);
        bytes memory data = abi.encode(_adjustParams(tokenId, POOL_A, TS_A));
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        _autoWith(mallory, NFPM, tokenId, AutoAction.AUTO_ADJUST, data, order, sig);
        _assertStaked(GAUGE_A, staker, tokenId);
    }

    function test_auto_paramsTargetMismatch_staked_reverts() public {
        uint256 tokenId = _stakedA();
        uint256 other = _mint(staker, _mintParams(_key(WETH, USDC_BASE, TS_A), POOL_A, 1 ether, 2_500e6, true));
        bytes memory data = abi.encode(_adjustParams(other, POOL_A, TS_A));
        bytes memory order = abi.encode(_order(NFPM, tokenId));
        bytes memory sig = _sign(stakerKey, order);
        vm.expectRevert(IRouterErrors.NotAutomation.selector);
        _autoWith(staker, NFPM, tokenId, AutoAction.AUTO_ADJUST, data, order, sig);
        _assertStaked(GAUGE_A, staker, other);
    }

    /// @dev A plain `execute` by a stranger on a staked position is not mistaken for automation after a bot run.
    function test_execute_cannotSpoofAutomation_staked() public {
        uint256 tokenId = _stakedA();
        bytes memory call = abi.encodeCall(ICoreModify.adjustRange, (_adjustParams(tokenId, POOL_A, TS_A)));
        vm.prank(attacker);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        router.execute(call);
    }
}
