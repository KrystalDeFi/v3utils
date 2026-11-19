// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {
    FeeType,
    MintParams,
    Position,
    SwapParams,
    DecreaseAndSwapParams,
    AdjustRangeParams,
    CompoundParams,
    HarvestParams
} from "../RouterTypes.sol";
import {ICoreModify} from "../interfaces/ICoreModify.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {CoreBase} from "../base/CoreBase.sol";

/// @notice Flows on an existing position: `decreaseAndSwap` withdraws part or all of it (or only its fees) and swaps
/// the proceeds, `adjustRange` moves it to a new range, `compound` adds its trading fees back into it and `harvest`
/// pays them out (optionally swapped to a `destToken`). Runs only by DELEGATECALL from the router, for the account
/// `_account` resolves (the caller, or the order's account under `executeAutomation`). None of the flows takes native,
/// so none is payable: value sent with them reverts.
/// A staked position (§6.4, §6.7) is unstaked for the flow and restaked after it, except: a withdraw that empties it
/// ends in the wallet; `adjustRange` restakes the new NFT and sends the old, empty one to the wallet; `harvest` claims
/// the farm's rewards and leaves the position staked; `compound` claims the rewards, unstakes, adds and restakes. The
/// farm's reward token is always in the ledger: emissions an unstake pays the router are rewards, charged the flow's
/// PERFORMANCE_FEE (`performanceFeeX64`), and the rest reaches the account.
/// @dev Every flow reads top to bottom in the pipeline order of spec §6.6:
///   1. read the position and locate it (`NotPositionHolder()` before anything moves), open the ledger, take the
///      position (wallet or farm, §6.4); a staked compound/harvest claims the farm's rewards first and takes
///      PERFORMANCE_FEE on them;
///   2. collect the earned fees and take PERFORMANCE_FEE on them (skipped for a staked position whose farm takes its
///      trading fees, `earnsTradingFees == false`); then remove liquidity, collect the principal and
///      take PROTOCOL_FEE then GAS_FEE on it. Earned fees and principal are told apart by collecting twice (fees
///      first), as v4utils does, and each amount is the call's balance delta, never an NFPM-reported figure;
///   3. run the swaps;
///   4. mint (adjustRange);
///   5. put the position(s) back;
///   6. sweep what the call holds to the account;
///   7. emit the flow's event. `TakeFees` is emitted as each fee is taken, tagged with the position's tokenId.
contract CoreModify is ICoreModify, CoreBase {
    /// @dev The position a flow acts on, and for whom.
    struct Target {
        address nfpm;
        uint256 tokenId;
        address account;
        address adapter;
        address token0;
        address token1;
    }

    /// @dev What a mint did: the new position, its liquidity and what the NFPM took.
    struct Minted {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    /// @inheritdoc ICoreModify
    /// @dev `decrease.liquidity` above the position's is clamped to it (as v4utils), so `type(uint128).max` means
    /// "everything". GAS_FEE goes on the earned fees only for a fees-only call (`liquidity == 0`), else on the principal
    /// (v4utils). A withdraw that leaves the position with no liquidity sends the NFT to the wallet, even when it came
    /// from a farm (§6.4); otherwise it goes back where it came from.
    function decreaseAndSwap(DecreaseAndSwapParams calldata params)
        external
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        (Target memory t, Position memory pos) = _target(params.nfpm, params.tokenId);
        (address farm, Ledger memory l) = _openAndTake(params.swaps, t, params.destToken, params.performanceFeeX64);

        uint128 liquidity = params.decrease.liquidity;
        _collectFees(l, t, params.performanceFeeX64, liquidity == 0 ? params.gasFeeX64 : 0);
        if (liquidity > pos.liquidity) liquidity = pos.liquidity;
        if (liquidity != 0) {
            _withdraw(
                l,
                t,
                liquidity,
                params.decrease.amount0Min,
                params.decrease.amount1Min,
                params.decrease.deadline,
                params.protocolFeeX64,
                params.gasFeeX64
            );
        }
        _swaps(l, params.swaps);
        // GHSA-m36p (v4utils): what the account receives of destToken is the call's delta, read before the sweep
        amountOut = _held(l, params.destToken);

        _putBack(t.nfpm, t.tokenId, t.account, farm != address(0) && liquidity < pos.liquidity);
        _close(l, t.account);

        emit DecreaseAndSwap(t.nfpm, t.tokenId, liquidity, params.destToken, amountOut);
    }

    /// @inheritdoc ICoreModify
    /// @dev Without `compoundFees` the net earned fees go to the account before the swaps, so the swaps, `amountIn == 0`
    /// ones included, only ever see the principal (v4utils GHSA-v6cm). The principal is removed with no amount
    /// minimums (as v4utils); `mint.minLiquidity` is the flow's slippage bound, and `mint.deadline` serves both.
    function adjustRange(AdjustRangeParams calldata params)
        external
        onlyDelegateCall
        returns (uint256 newTokenId, uint128 liquidity)
    {
        (Target memory t, Position memory pos) = _target(params.nfpm, params.tokenId);
        (address farm, Ledger memory l) = _openAndTake(params.swaps, t, t.token0, params.performanceFeeX64);

        uint256[] memory fees = _collectFees(l, t, params.performanceFeeX64, 0);
        if (!params.compoundFees) {
            _pay(l, t.token0, t.account, fees[0]);
            _pay(l, t.token1, t.account, fees[1]);
        }
        if (pos.liquidity != 0) {
            _withdraw(l, t, pos.liquidity, 0, 0, params.mint.deadline, params.protocolFeeX64, params.gasFeeX64);
        }
        _swaps(l, params.swaps);
        Minted memory m = _mint(l, t, pos, params.mint);
        if (m.liquidity < params.mint.minLiquidity) revert LiquiditySlippage();

        _putBack(t.nfpm, m.tokenId, t.account, farm != address(0));
        _putBack(t.nfpm, t.tokenId, t.account, false);
        _close(l, t.account);

        emit AdjustRange(t.nfpm, t.tokenId, m.tokenId, m.liquidity, m.amount0, m.amount1);
        return (m.tokenId, m.liquidity);
    }

    /// @inheritdoc ICoreModify
    /// @dev A wallet position compounds its trading fees. A staked one compounds its farm rewards: the farm must allow
    /// it (`CompoundDisabled()`, before anything moves), claim them (PERFORMANCE_FEE on everything the farm paid), and
    /// the position is unstaked, increased and restaked; its trading fees are added too only if the farm lets a staked
    /// position earn them. The increase takes what the call holds of the pool's tokens after the swaps, so the
    /// router's own balances are never added.
    function compound(CompoundParams calldata params) external onlyDelegateCall returns (uint128 liquidity) {
        (Target memory t,) = _target(params.nfpm, params.tokenId);
        address farm = _locate(t.nfpm, t.tokenId, t.account);
        if (farm != address(0) && !_farmFlag(farm, abi.encodeCall(IFarm.canCompound, ()))) revert CompoundDisabled();
        address reward = _rewardOf(farm, t.token0);
        Ledger memory l = _open(_candidates(params.swaps, t, t.token0, reward));

        _earnings(l, t, farm, reward, params.performanceFeeX64, true);
        _swaps(l, params.swaps);
        uint256 used0;
        uint256 used1;
        (liquidity, used0, used1) = _addHeld(l, t, params.increase.deadline);
        if (liquidity < params.increase.minLiquidity) revert LiquiditySlippage();

        _putBack(t.nfpm, t.tokenId, t.account, farm != address(0));
        _close(l, t.account);

        emit CompoundFees(t.nfpm, t.tokenId, liquidity, used0, used1);
    }

    /// @inheritdoc ICoreModify
    /// @dev A staked position claims its farm rewards (PERFORMANCE_FEE on them) and stays staked; its NFT moves only
    /// when the farm lets it earn trading fees too (unstake, collect, restake). Where the farm cannot compound
    /// (`canCompound == false`, e.g. xAERO off Base) the reward is paid as is: a `destToken` other than zero or the
    /// reward, or any `swaps`, reverts `CompoundDisabled()` before anything moves.
    function harvest(HarvestParams calldata params) external onlyDelegateCall returns (uint256 amountOut) {
        (Target memory t,) = _target(params.nfpm, params.tokenId);
        address farm = _locate(t.nfpm, t.tokenId, t.account);
        address reward = _rewardOf(farm, t.token0);
        address dest = params.destToken;
        // where the farm cannot compound, its reward is paid as is: no conversion (PR #64)
        if (
            farm != address(0) && ((dest != address(0) && dest != reward) || params.swaps.length != 0)
                && !_farmFlag(farm, abi.encodeCall(IFarm.canCompound, ()))
        ) revert CompoundDisabled();
        Ledger memory l = _open(_candidates(params.swaps, t, dest, reward));

        (uint256 rewardNet, uint256[] memory feesNet, bool earnsFees) =
            _earnings(l, t, farm, reward, params.performanceFeeX64, false);
        // non-zero when something earned is not already `destToken` (only tested against 0, never summed)
        uint256 toConvert;
        if (dest != reward) toConvert = rewardNet;
        if (dest != t.token0 && dest != t.token1) toConvert |= feesNet[0] | feesNet[1];
        if (dest != address(0) && toConvert != 0 && params.swaps.length == 0) revert MissingSwapData();
        _swaps(l, params.swaps);
        amountOut = _held(l, dest);

        if (earnsFees) _putBack(t.nfpm, t.tokenId, t.account, farm != address(0));
        _close(l, t.account);

        emit Harvest(t.nfpm, t.tokenId, dest, amountOut);
    }

    // ---------------------------------------------------------------- steps

    /// @dev The account, adapter and position for `(nfpm, tokenId)`: `NotAutomation()` for another target under
    /// `executeAutomation`, `UnsupportedNfpm()` without an adapter.
    function _target(address nfpm, uint256 tokenId) private returns (Target memory t, Position memory pos) {
        t.nfpm = nfpm;
        t.tokenId = tokenId;
        t.account = _account(nfpm, tokenId);
        t.adapter = _adapter(nfpm);
        pos = abi.decode(_delegate(t.adapter, abi.encodeCall(IAdapter.position, (nfpm, tokenId))), (Position));
        t.token0 = pos.key.token0;
        t.token1 = pos.key.token1;
    }

    /// @dev Steps 1 of decrease and adjust: locates the position (`NotPositionHolder()` / `FarmUnsupported()` before
    /// anything moves), opens the ledger over the flow's tokens and the farm's reward token, and takes the position; a
    /// staked one's unstake emissions are charged `performanceFeeX64` (see `_bringCharged`).
    function _openAndTake(SwapParams[] calldata swaps, Target memory t, address extra, uint64 performanceFeeX64)
        private
        returns (address farm, Ledger memory l)
    {
        farm = _locate(t.nfpm, t.tokenId, t.account);
        address reward = _rewardOf(farm, t.token0);
        l = _open(_candidates(swaps, t, extra, reward));
        _bringCharged(l, t.nfpm, t.tokenId, t.account, farm, reward, performanceFeeX64);
    }

    /// @dev Every token the flow can touch: both legs of every swap, the pool's tokens, `extra` (the destToken) and
    /// `reward` (the farm's reward token, or a pool token for a wallet position).
    function _candidates(SwapParams[] calldata swaps, Target memory t, address extra, address reward)
        private
        pure
        returns (address[] memory c)
    {
        uint256 n = 2 * swaps.length;
        c = new address[](n + 4);
        for (uint256 i; i < swaps.length; i++) {
            c[2 * i] = swaps[i].tokenIn;
            c[2 * i + 1] = swaps[i].tokenOut;
        }
        c[n] = t.token0;
        c[n + 1] = t.token1;
        c[n + 2] = extra;
        c[n + 3] = reward;
    }

    /// @dev What compound and harvest gather, net of PERFORMANCE_FEE: a staked position's farm rewards (`rewardNet`;
    /// the position is unstaked into the router with `take`, or when the farm lets it earn trading fees), then its
    /// trading fees (`feesNet`; zeros, and the NFT not taken, when `earnsFees` is false). A wallet position is taken
    /// and only collects its trading fees.
    function _earnings(Ledger memory l, Target memory t, address farm, address reward, uint64 feeX64, bool take)
        private
        returns (uint256 rewardNet, uint256[] memory feesNet, bool earnsFees)
    {
        earnsFees = farm == address(0) || _farmFlag(farm, abi.encodeCall(IFarm.earnsTradingFees, ()));
        if (farm != address(0)) rewardNet = _claimRewards(l, t, farm, reward, feeX64, take || earnsFees);
        else _bring(t.nfpm, t.tokenId, t.account, address(0));
        feesNet = earnsFees ? _collectFees(l, t, feeX64, 0) : new uint256[](2);
    }

    /// @dev Adds everything the call holds of the pool's tokens to the router-held position; a quiet position (nothing
    /// held) is left as it is, since the pool would revert on zero liquidity.
    function _addHeld(Ledger memory l, Target memory t, uint256 deadline)
        private
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        uint256 held0 = _held(l, t.token0);
        uint256 held1 = _held(l, t.token1);
        if (held0 == 0 && held1 == 0) return (0, 0, 0);
        (liquidity, used0, used1) = abi.decode(
            _delegate(t.adapter, abi.encodeCall(IAdapter.increase, (t.nfpm, t.tokenId, held0, held1, deadline))),
            (uint128, uint256, uint256)
        );
    }

    /// @dev Claims the staked position's farm rewards to the router (the farm requires the account's claim approval)
    /// and, with `unstake`, unstakes it into the router right after; then takes PERFORMANCE_FEE on everything the call
    /// holds of `reward`, i.e. what the farm paid, claim and unstake together. The flow has taken no inputs, so nothing
    /// else of `reward` can be held yet. Returns the net reward.
    function _claimRewards(Ledger memory l, Target memory t, address farm, address reward, uint64 feeX64, bool unstake)
        private
        returns (uint256 net)
    {
        _delegate(farm, abi.encodeCall(IFarm.claim, (t.nfpm, t.tokenId, t.account)));
        if (unstake) _bring(t.nfpm, t.tokenId, t.account, farm);
        uint256 paid = _held(l, reward);
        net = paid - _chargeReward(l, t.nfpm, t.tokenId, t.account, reward, paid, feeX64);
    }

    /// @dev Collects what the position owes (its earned fees, before any decrease) and takes PERFORMANCE_FEE, then
    /// GAS_FEE, on it. Returns the collected amounts net of both fees.
    function _collectFees(Ledger memory l, Target memory t, uint64 performanceFeeX64, uint64 gasFeeX64)
        private
        returns (uint256[] memory net)
    {
        net = _collect(l, t);
        uint256[] memory perf = _fees(l, t, net, performanceFeeX64, FeeType.PERFORMANCE_FEE);
        uint256[] memory gas = _fees(l, t, net, gasFeeX64, FeeType.GAS_FEE);
        net[0] -= perf[0] + gas[0];
        net[1] -= perf[1] + gas[1];
    }

    /// @dev Removes `liquidity`, collects the principal, and takes PROTOCOL_FEE, then GAS_FEE, on it. The NFPM checks
    /// the deadline and the minimums against the gross amounts; the minimums are checked again against what the
    /// collect actually delivered (`SlippageError()`), so a pool token that skims on transfer out fails visibly
    /// instead of short-filling (V3Utils #62).
    function _withdraw(
        Ledger memory l,
        Target memory t,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        uint64 protocolFeeX64,
        uint64 gasFeeX64
    ) private {
        _delegate(
            t.adapter,
            abi.encodeCall(IAdapter.decrease, (t.nfpm, t.tokenId, liquidity, amount0Min, amount1Min, deadline))
        );
        uint256[] memory principal = _collect(l, t);
        if (principal[0] < amount0Min || principal[1] < amount1Min) revert SlippageError();
        _fees(l, t, principal, protocolFeeX64, FeeType.PROTOCOL_FEE);
        _fees(l, t, principal, gasFeeX64, FeeType.GAS_FEE);
    }

    /// @dev Collects everything the position owes and returns what the call received of (token0, token1).
    function _collect(Ledger memory l, Target memory t) private returns (uint256[] memory amounts) {
        uint256 before0 = _held(l, t.token0);
        uint256 before1 = _held(l, t.token1);
        _delegate(t.adapter, abi.encodeCall(IAdapter.collect, (t.nfpm, t.tokenId)));
        amounts = new uint256[](2);
        amounts[0] = _held(l, t.token0) - before0;
        amounts[1] = _held(l, t.token1) - before1;
    }

    /// @dev Takes `feeX64` of `amounts` of (token0, token1), labelled `feeType`, tagged with the position.
    function _fees(Ledger memory l, Target memory t, uint256[] memory amounts, uint64 feeX64, FeeType feeType)
        private
        returns (uint256[] memory taken)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = t.token0;
        tokens[1] = t.token1;
        taken = _takeFees(l, t.nfpm, t.tokenId, t.account, tokens, amounts, feeX64, feeType);
    }

    /// @dev Mints `m`'s range of the position's pool to the router from everything the call holds of its tokens.
    function _mint(Ledger memory l, Target memory t, Position memory pos, MintParams calldata m)
        private
        returns (Minted memory a)
    {
        bytes memory ret = _delegate(
            t.adapter,
            abi.encodeCall(
                IAdapter.mint,
                (
                    t.nfpm,
                    pos.key,
                    m.tickLower,
                    m.tickUpper,
                    _held(l, t.token0),
                    _held(l, t.token1),
                    address(this),
                    m.deadline
                )
            )
        );
        (a.tokenId, a.liquidity, a.amount0, a.amount1) = abi.decode(ret, (uint256, uint128, uint256, uint256));
    }
}
