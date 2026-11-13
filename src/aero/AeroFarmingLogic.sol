// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-core/libraries/FullMath.sol";
import "./IAero.sol";
import "./IAeroFarmingLogic.sol";
import "./AeroStorage.sol";

interface V3UtilsLike {
    function swapAndMint(Common.SwapAndMintParams calldata params)
        external
        payable
        returns (Common.SwapAndMintResult memory result);
    function swapAndIncreaseLiquidity(Common.SwapAndIncreaseLiquidityParams calldata params)
        external
        payable
        returns (Common.SwapAndIncreaseLiquidityResult memory result);
}

interface IWETHLike {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Stateless logic of the Aero farming router: every user flow and the operator flows. It runs only by
/// DELEGATECALL from AeroFarmingRouter, so address(this) is the router (the address users approve on gauges),
/// msg.sender is the router's caller, and config/flow state comes from the AeroStorage slot of the router.
/// @dev Holds no storage (immutables only) and has no admin, role, upgrade, receive or NFT-receive function: those
/// live in the router's own code, so nothing reachable through `execute` can change roles or the implementation.
/// Reentrancy and pause are enforced by the router's entry points.
contract AeroFarmingLogic is IAeroFarmingLogic {
    using SafeERC20 for IERC20;

    uint64 internal constant MAX_GAS_FEE_X64 = 5534023222112865280;
    uint64 internal constant MAX_PERFORMANCE_FEE_X64 = 5902958103587057000;

    address private immutable self;

    constructor() {
        self = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == self) revert NotDelegateCall();
        _;
    }

    // ---------------------------------------------------------------- user flows (account = msg.sender)

    function zapInAndStake(address gauge, Common.SwapAndMintParams memory p, bool unwrap)
        external
        payable
        onlyDelegateCall
        returns (uint256 tokenId)
    {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        if (address(p.nfpm) != address(nfpm) || p.protocol != Nfpm.Protocol.AERODROME || p.token0 == p.token1) {
            revert InvalidInstructions();
        }
        p.recipient = address(this);

        (address[3] memory tokens, uint256[3] memory amounts) =
            _slots(address(p.token0), address(p.token1), address(p.swapSourceToken), p.amount0, p.amount1, p.amount2);
        address[] memory list = _tokenSet(tokens[0], tokens[1], tokens[2], address(0));
        _checkUnwrap(unwrap);
        uint256[] memory before = _snapshot(list);

        _pullInputs(tokens, amounts);

        _approveInputs(tokens, amounts, false);
        tokenId = V3UtilsLike(AeroStorage.layout().v3utils).swapAndMint(p).tokenId;
        _approveInputs(tokens, amounts, true);

        _stake(gauge, nfpm, tokenId, msg.sender);
        _sweep(list, before, msg.sender, unwrap);
        emit FarmAction(msg.sender, gauge, tokenId, tokenId, Action.ZAP_IN, false);
    }

    function addLiquidity(address gauge, Common.SwapAndIncreaseLiquidityParams memory p, bool unwrap)
        external
        payable
        onlyDelegateCall
    {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        if (address(p.nfpm) != address(nfpm) || p.protocol != Nfpm.Protocol.AERODROME) {
            revert InvalidInstructions();
        }
        _checkUnwrap(unwrap);
        uint256 tokenId = p.tokenId;
        p.recipient = address(this);

        (address[3] memory tokens, uint256[3] memory amounts) = _increaseInputs(nfpm, p);
        address[] memory list = _tokenSet(tokens[0], tokens[1], tokens[2], AeroStorage.layout().rewardToken);
        uint256[] memory before = _snapshot(list);

        _unstake(gauge, tokenId, msg.sender);
        _pullInputs(tokens, amounts);

        _approveInputs(tokens, amounts, false);
        V3UtilsLike(AeroStorage.layout().v3utils).swapAndIncreaseLiquidity(p);
        _approveInputs(tokens, amounts, true);

        _stake(gauge, nfpm, tokenId, msg.sender);
        _sweep(list, before, msg.sender, unwrap);
        emit FarmAction(msg.sender, gauge, tokenId, tokenId, Action.ADD_LIQUIDITY, false);
    }

    function removeLiquidity(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        external
        onlyDelegateCall
    {
        _modify(msg.sender, gauge, tokenId, ins, Action.REMOVE_LIQUIDITY, false);
    }

    function exit(address gauge, uint256 tokenId, V3Utils.Instructions memory ins) external onlyDelegateCall {
        _modify(msg.sender, gauge, tokenId, ins, Action.EXIT, false);
    }

    function rebalance(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        external
        onlyDelegateCall
        returns (uint256 newTokenId)
    {
        newTokenId = _modify(msg.sender, gauge, tokenId, ins, Action.REBALANCE, false);
    }

    function compound(address gauge, uint256 tokenId, CompoundParams memory p) external onlyDelegateCall {
        _compound(msg.sender, gauge, tokenId, p, false);
    }

    // ---------------------------------------------------------------- operator flows

    /// @dev The router records `account` in AeroStorage only around its own call to this function (after checking
    /// the gauge, that `account` owns the stake, and `account`'s signed, uncancelled order); through `execute` the
    /// recorded account is zero, so this reverts.
    function executeAutomated(
        AutoAction action,
        address account,
        address gauge,
        uint256 tokenId,
        bytes calldata actionData
    ) external onlyDelegateCall returns (uint256 tokenIdAfter) {
        address recorded = AeroStorage.layout().automationAccount;
        if (recorded == address(0) || recorded != account) revert NotAutomation();
        tokenIdAfter = tokenId;
        if (action == AutoAction.AUTO_COMPOUND) {
            _compound(account, gauge, tokenId, abi.decode(actionData, (CompoundParams)), true);
        } else if (action == AutoAction.AUTO_HARVEST) {
            _harvest(account, gauge, tokenId, abi.decode(actionData, (HarvestParams)));
        } else {
            tokenIdAfter = _modify(
                account,
                gauge,
                tokenId,
                abi.decode(actionData, (V3Utils.Instructions)),
                action == AutoAction.AUTO_ADJUST ? Action.REBALANCE : Action.EXIT,
                true
            );
        }
    }

    // ---------------------------------------------------------------- internals

    function _checkUnwrap(bool unwrap) internal view {
        if (unwrap && AeroStorage.layout().weth == address(0)) revert NativeDisabled();
    }

    /// @dev The claim includes the account's deferredEmissions from all its positions in this gauge; they are
    /// compounded into `tokenId` and charged the performance fee. A zero fee emits no DeductFees.
    function _compound(address account, address gauge, uint256 tokenId, CompoundParams memory p, bool automated)
        internal
    {
        if (!AeroStorage.layout().compoundEnabled) revert CompoundDisabled();
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        _checkUnwrap(p.unwrap);
        (address token0, address token1,) = _positionInfo(nfpm, tokenId);
        address[] memory list = _tokenSet(token0, token1, AeroStorage.layout().rewardToken, address(0));
        uint256[] memory before = _snapshot(list);

        _claimAndIncrease(account, gauge, nfpm, tokenId, p, token0, token1);
        _stake(gauge, nfpm, tokenId, account);
        _sweep(list, before, account, p.unwrap);
        emit FarmAction(account, gauge, tokenId, tokenId, Action.COMPOUND, automated);
    }

    /// @dev Claim emissions, unstake, take the performance fee and add the remaining reward to the position.
    function _claimAndIncrease(
        address account,
        address gauge,
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        CompoundParams memory p,
        address token0,
        address token1
    ) internal {
        address reward = AeroStorage.layout().rewardToken;
        uint256 claimed = _claim(gauge, account, tokenId, reward);
        _unstake(gauge, tokenId, account);
        uint256 fee = _takeFee(
            address(nfpm),
            tokenId,
            account,
            token0,
            token1,
            claimed,
            p.performanceFeeX64,
            Common.FeeType.PERFORMANCE_FEE
        );
        _increaseWithReward(nfpm, tokenId, token0, token1, reward, claimed - fee, p);
    }

    /// @dev Claims `account`'s emissions for `tokenId` to this contract and returns the reward-token delta.
    function _claim(address gauge, address account, uint256 tokenId, address reward)
        internal
        returns (uint256 claimed)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 b = IERC20(reward).balanceOf(address(this));
        ICLGauge(gauge).claimEmissions(account, address(this), ids);
        claimed = IERC20(reward).balanceOf(address(this)) - b;
    }

    /// @dev Runs V3Utils.swapAndIncreaseLiquidity with `amount` of the reward token as the only input.
    function _increaseWithReward(
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        address token0,
        address token1,
        address reward,
        uint256 amount,
        CompoundParams memory c
    ) internal {
        Common.SwapAndIncreaseLiquidityParams memory p;
        p.protocol = Nfpm.Protocol.AERODROME;
        p.nfpm = nfpm;
        p.tokenId = tokenId;
        if (reward == token0) p.amount0 = amount;
        else if (reward == token1) p.amount1 = amount;
        else p.amount2 = amount;
        p.recipient = address(this);
        p.deadline = c.deadline;
        p.swapSourceToken = IERC20(reward);
        p.amountIn0 = c.amountIn0;
        p.amountOut0Min = c.amountOut0Min;
        p.swapData0 = c.swapData0;
        p.amountIn1 = c.amountIn1;
        p.amountOut1Min = c.amountOut1Min;
        p.swapData1 = c.swapData1;
        p.amountAddMin0 = c.amountAddMin0;
        p.amountAddMin1 = c.amountAddMin1;
        p.gasFeeX64 = c.gasFeeX64;

        address v = AeroStorage.layout().v3utils;
        IERC20(reward).forceApprove(v, amount);
        V3UtilsLike(v).swapAndIncreaseLiquidity(p);
        IERC20(reward).forceApprove(v, 0);
    }

    /// @dev Claims the emissions (the position stays staked), takes the gas fee, optionally swaps the rest into
    /// `p.targetToken` (Base only) and pays the account.
    function _harvest(address account, address gauge, uint256 tokenId, HarvestParams memory p) internal {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        address reward = AeroStorage.layout().rewardToken;
        address target = p.targetToken;
        bool doSwap = target != address(0) && target != reward;
        if (doSwap && !AeroStorage.layout().compoundEnabled) revert CompoundDisabled();
        address[] memory list = _tokenSet(reward, target, address(0), address(0));
        uint256[] memory before = _snapshot(list);

        uint256 claimed = _claim(gauge, account, tokenId, reward);
        uint256 fee = _harvestFee(nfpm, tokenId, account, claimed, p.gasFeeX64);
        if (doSwap) _swap(IERC20(reward), IERC20(target), claimed - fee, p.amountOutMin, p.swapData);
        _sweep(list, before, account, false);
        emit FarmAction(account, gauge, tokenId, tokenId, Action.HARVEST, true);
    }

    function _harvestFee(
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        address account,
        uint256 claimed,
        uint64 feeX64
    ) private returns (uint256) {
        (address token0, address token1,) = _positionInfo(nfpm, tokenId);
        return _takeFee(address(nfpm), tokenId, account, token0, token1, claimed, feeX64, Common.FeeType.GAS_FEE);
    }

    /// @dev Same logic as CommonLib.swap, inline so the logic needs no library link.
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (amountIn != 0 && swapData.length != 0 && address(tokenOut) != address(0)) {
            address router = V3Utils(payable(AeroStorage.layout().v3utils)).swapRouter();
            uint256 inBefore = tokenIn.balanceOf(address(this));
            uint256 outBefore = tokenOut.balanceOf(address(this));

            tokenIn.forceApprove(router, amountIn);
            (bool ok,) = router.call(swapData);
            if (!ok) revert SwapFailed(swapData, 0);
            tokenIn.forceApprove(router, 0);

            amountInDelta = inBefore - tokenIn.balanceOf(address(this));
            amountOutDelta = tokenOut.balanceOf(address(this)) - outBefore;
            if (amountOutDelta < amountOutMin) revert SlippageError();
        }
    }

    /// @dev Sends `amount * feeX64 / 2^64` of the reward token to V3Utils' FEE_TAKER and emits DeductFees.
    /// A zero fee transfers nothing and emits no DeductFees (unlike Common's NoFees revert).
    function _takeFee(
        address nfpm,
        uint256 tokenId,
        address account,
        address token0,
        address token1,
        uint256 amount,
        uint64 feeX64,
        Common.FeeType t
    ) internal returns (uint256 fee) {
        uint64 cap = t == Common.FeeType.GAS_FEE ? MAX_GAS_FEE_X64 : MAX_PERFORMANCE_FEE_X64;
        if (feeX64 > cap) revert FeeTooHigh();
        fee = FullMath.mulDiv(amount, feeX64, 2 ** 64);
        if (fee == 0) return 0;
        address reward = AeroStorage.layout().rewardToken;
        IERC20(reward).safeTransfer(V3Utils(payable(AeroStorage.layout().v3utils)).FEE_TAKER(), fee);

        Common.DeductFeesEventData memory d;
        d.feeX64 = feeX64;
        d.feeType = t;
        d.token0 = token0;
        d.token1 = token1;
        if (reward == token0) {
            d.amount0 = amount;
            d.feeAmount0 = fee;
        } else if (reward == token1) {
            d.amount1 = amount;
            d.feeAmount1 = fee;
        } else {
            d.token2 = reward;
            d.amount2 = amount;
            d.feeAmount2 = fee;
        }
        emit DeductFees(nfpm, tokenId, account, d);
    }

    /// @dev Unstake, run `ins` through V3Utils, then restake (REMOVE_LIQUIDITY), restake the new NFT (REBALANCE) or
    /// hand the NFT to `account` (EXIT).
    function _modify(
        address account,
        address gauge,
        uint256 tokenId,
        V3Utils.Instructions memory ins,
        Action action,
        bool automated
    ) internal returns (uint256 tokenIdAfter) {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        address[] memory list = _prepareModify(nfpm, tokenId, ins, action);
        bool unwrap = ins.unwrap;
        ins.recipient = address(this);
        ins.unwrap = false;
        uint256[] memory before = _snapshot(list);

        _unstake(gauge, tokenId, account);
        // NFTs held with the old one in hand, before V3Utils gets it (REBALANCE checks the result against it)
        uint256 held = action == Action.REBALANCE ? nfpm.balanceOf(address(this)) : 0;
        nfpm.safeTransferFrom(address(this), AeroStorage.layout().v3utils, tokenId, abi.encode(ins));
        if (action == Action.REMOVE_LIQUIDITY) {
            _stake(gauge, nfpm, tokenId, account);
            tokenIdAfter = tokenId;
        } else if (action == Action.REBALANCE) {
            tokenIdAfter = _rebalancedId(nfpm, tokenId, ins, held);
            _stake(gauge, nfpm, tokenIdAfter, account);
            nfpm.transferFrom(address(this), account, tokenId);
        } else {
            nfpm.transferFrom(address(this), account, tokenId);
            tokenIdAfter = tokenId;
        }
        _sweep(list, before, account, unwrap);
        emit FarmAction(account, gauge, tokenId, tokenIdAfter, action, automated);
    }

    /// @dev The position V3Utils minted for a CHANGE_RANGE. It sends the new NFT first and returns the old one last,
    /// so exactly one NFT more than `held` is held and the enumeration ends [..., new, old]; the new position must
    /// have the range `ins` asked for.
    function _rebalancedId(
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        V3Utils.Instructions memory ins,
        uint256 held
    ) internal view returns (uint256 newId) {
        uint256 bal = nfpm.balanceOf(address(this));
        if (bal != held + 1) revert RebalanceMismatch();
        newId = nfpm.tokenOfOwnerByIndex(address(this), bal - 2);
        if (newId == tokenId || nfpm.ownerOf(newId) != address(this)) revert UnexpectedNft();
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nfpm.positions(newId);
        if (tickLower != ins.tickLower || tickUpper != ins.tickUpper) revert RebalanceMismatch();
    }

    /// @dev Validates `ins` for `action` against the position and returns the tokens to track.
    function _prepareModify(
        INonfungiblePositionManager nfpm,
        uint256 tokenId,
        V3Utils.Instructions memory ins,
        Action action
    ) internal view returns (address[] memory list) {
        (address token0, address token1, uint128 liquidity) = _positionInfo(nfpm, tokenId);
        V3Utils.WhatToDo expected =
            action == Action.REBALANCE ? V3Utils.WhatToDo.CHANGE_RANGE : V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        if (ins.protocol != Nfpm.Protocol.AERODROME || ins.whatToDo != expected) revert InvalidInstructions();
        if (action == Action.REBALANCE) {
            if (ins.liquidity != liquidity) revert InvalidInstructions();
        } else if (action == Action.REMOVE_LIQUIDITY) {
            if (ins.liquidity == 0 || ins.liquidity >= liquidity) revert InvalidInstructions();
        } else if (action == Action.EXIT) {
            if (ins.liquidity != liquidity) revert InvalidInstructions();
        } else {
            revert NotSupportedAction();
        }
        _checkUnwrap(ins.unwrap);
        list = _tokenSet(token0, token1, ins.targetToken, AeroStorage.layout().rewardToken);
    }

    function _positionInfo(INonfungiblePositionManager nfpm, uint256 tokenId)
        internal
        view
        returns (address token0, address token1, uint128 liquidity)
    {
        (,, token0, token1,,,, liquidity,,,,) = nfpm.positions(tokenId);
    }

    /// @dev De-duplicated list of the non-zero addresses among a, b, c, d.
    function _tokenSet(address a, address b, address c, address d) internal pure returns (address[] memory list) {
        address[4] memory all = [a, b, c, d];
        list = new address[](4);
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            address t = all[i];
            if (t == address(0)) continue;
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (list[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) list[n++] = t;
        }
        assembly {
            mstore(list, n)
        }
    }

    function _unstake(address gauge, uint256 tokenId, address account) internal {
        AeroStorage.Layout storage s = AeroStorage.layout();
        s.activeGauge = gauge;
        ICLGauge(gauge).withdrawFrom(tokenId, account);
        s.activeGauge = address(0);
    }

    function _stake(address gauge, INonfungiblePositionManager nfpm, uint256 tokenId, address account) internal {
        _requireLive(gauge);
        IERC721(address(nfpm)).approve(gauge, tokenId);
        ICLGauge(gauge).depositFor(tokenId, account);
    }

    function _snapshot(address[] memory tokens) internal view returns (uint256[] memory snap) {
        snap = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            snap[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    /// @dev Forwards `balance - snapshot` of each token to `to`. WETH delta is sent as native coin iff `unwrap`.
    function _sweep(address[] memory tokens, uint256[] memory before, address to, bool unwrap) internal {
        address w = AeroStorage.layout().weth;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal <= before[i]) continue;
            uint256 delta = bal - before[i];
            if (unwrap && tokens[i] == w) {
                IWETHLike(w).withdraw(delta);
                _sendNative(to, delta);
            } else {
                IERC20(tokens[i]).safeTransfer(to, delta);
            }
        }
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _validateGauge(address gauge) internal view returns (INonfungiblePositionManager nfpm) {
        ICLGaugeFactory f = ICLGaugeFactory(AeroStorage.layout().gaugeFactory);
        if (!f.isGauge(gauge)) revert InvalidGauge();
        address n = ICLGauge(gauge).nft();
        if (n != f.nft()) revert InvalidGauge();
        nfpm = INonfungiblePositionManager(n);
    }

    function _requireLive(address gauge) internal view {
        if (!ILeafVoter(ICLGaugeFactory(AeroStorage.layout().gaugeFactory).leafVoter()).isActivated(gauge)) {
            revert GaugeNotLive();
        }
    }

    /// @dev Token slots (token0, token1, optional swap source) and the amounts to pull for an increase.
    function _increaseInputs(INonfungiblePositionManager nfpm, Common.SwapAndIncreaseLiquidityParams memory p)
        internal
        view
        returns (address[3] memory tokens, uint256[3] memory amounts)
    {
        (address t0, address t1,) = _positionInfo(nfpm, p.tokenId);
        return _slots(t0, t1, address(p.swapSourceToken), p.amount0, p.amount1, p.amount2);
    }

    /// @dev The third slot is the swap source token, used only when it is neither token0 nor token1.
    function _slots(address t0, address t1, address src, uint256 a0, uint256 a1, uint256 a2)
        internal
        pure
        returns (address[3] memory tokens, uint256[3] memory amounts)
    {
        tokens = [t0, t1, address(0)];
        amounts = [a0, a1, uint256(0)];
        if (src != address(0) && src != t0 && src != t1) {
            tokens[2] = src;
            amounts[2] = a2;
        }
    }

    /// @dev Approves V3Utils for `amounts` of each non-zero token, or resets the approvals to zero.
    function _approveInputs(address[3] memory tokens, uint256[3] memory amounts, bool reset) internal {
        address v = AeroStorage.layout().v3utils;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, reset ? 0 : amounts[i]);
        }
    }

    /// @dev Pulls `amounts` from msg.sender. msg.value is wrapped and counts toward the WETH slot.
    function _pullInputs(address[3] memory tokens, uint256[3] memory amounts_) internal {
        uint256[3] memory amounts = [amounts_[0], amounts_[1], amounts_[2]]; // real copy: caller keeps full amounts
        uint256 native = msg.value;
        if (native > 0) {
            address w = AeroStorage.layout().weth;
            if (w == address(0)) revert NativeDisabled();
            uint256 i;
            while (i < 3 && tokens[i] != w) ++i;
            if (i == 3 || native > amounts[i]) revert NativeDisabled();
            amounts[i] -= native;
            IWETHLike(w).deposit{value: native}();
        }
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
        }
    }
}
