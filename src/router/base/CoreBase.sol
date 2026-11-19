// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "v3-core/libraries/FullMath.sol";
import {FeeType, InputTokenParams, SwapParams} from "../RouterTypes.sol";
import {RouterStorage} from "../RouterStorage.sol";
import {IRouterErrors} from "../IRouterErrors.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {NativeCurrency} from "./NativeCurrency.sol";

/// @notice Shared building blocks of every core module: the per-call balance ledger, input pulling, fees, the swap
/// list, the account and custody (take, put back). Runs only by DELEGATECALL from the router, as the router.
/// @dev The router holds users' NFT and gauge approvals and may hold stray tokens or native that belong to no one in
/// the current call. Everything a call spends or returns is therefore measured against the ledger opened at its
/// start: `_held` is the call's balance delta, never the router's whole balance. Native is `address(0)`.
///
/// Flow order: `_open` BEFORE `_takeInputs` (the ERC20 snapshot must precede the pull; native's snapshot already
/// excludes `msg.value`), and every token the call may hold - inputs, both legs of every swap, the pool's tokens,
/// rewards - among the candidates, since only ledger tokens are swept by `_close` and only they can be swapped.
abstract contract CoreBase is IRouterErrors {
    using SafeERC20 for IERC20;

    uint256 internal constant Q64 = 2 ** 64;

    /// @dev This contract's own address, to tell a direct call from a delegatecall.
    address private immutable _self = address(this);

    /// @notice What the call held of each tracked token when it started. Native is `address(0)`.
    struct Ledger {
        address[] tokens;
        uint256[] start;
    }

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert NotDelegateCall();
        _;
    }

    // ---------------------------------------------------------------- ledger

    /// @dev Opens the call's ledger. Call it exactly once per flow, first: before `_takeInputs` (the ERC20 snapshot
    /// must precede the pull) and before anything else moves a balance.
    ///
    /// Tracks the distinct `candidates`, skipping addresses without code other than native. Native is always tracked
    /// when `msg.value != 0` (added if missing), so value the call brought is always swept back. A registered NFPM
    /// reverts `InvalidToken()`: it answers the ERC20 `approve` selector, so a swap must never be able to approve one.
    ///
    /// Each start is the balance net of what `msg.value` already added: native starts at `balance - msg.value`. On an
    /// ENSHRINED chain `weth` is a view of that same native balance, so it starts at the pre-existing native rounded
    /// UP to `weth` units: `ceil((balance - msg.value) / nativeScale)`. Then `held(weth) * nativeScale` never exceeds
    /// the call's own native, so not even sub-unit dust of the router's balance can be released through `weth`.
    function _open(address[] memory candidates) internal view returns (Ledger memory l) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        uint256 n = candidates.length;
        address[] memory unique = new address[](n + 1);
        uint256 count;
        // index n stands for native when the call brought value
        for (uint256 i; i <= n; i++) {
            address t;
            if (i < n) t = candidates[i];
            else if (msg.value == 0) break;
            if (t != address(0)) {
                if (t.code.length == 0) continue;
                if (s.adapter[t] != address(0)) revert InvalidToken();
            }
            bool seen;
            for (uint256 j; j < count; j++) {
                if (unique[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) unique[count++] = t;
        }

        address weth = s.weth;
        bool enshrined = s.nativeMode == RouterStorage.NATIVE_ENSHRINED;
        uint256 preexistingNative = address(this).balance - msg.value;
        l.tokens = new address[](count);
        l.start = new uint256[](count);
        for (uint256 i; i < count; i++) {
            address t = unique[i];
            l.tokens[i] = t;
            if (t == address(0)) {
                l.start[i] = preexistingNative;
            } else if (enshrined && t == weth) {
                uint256 scale = s.nativeScale;
                l.start[i] = (preexistingNative + scale - 1) / scale;
            } else {
                l.start[i] = _balanceOf(t);
            }
        }
    }

    /// @dev What the call holds of `token` now: its balance delta since `_open`, saturating at 0. Reverts
    /// `NotTracked()` for a token not in the ledger.
    function _held(Ledger memory l, address token) internal view returns (uint256) {
        return _heldAt(l, _indexOf(l, token));
    }

    /// @dev Sends `to` what the call holds of every ledger token, and nothing else. Each amount is read just before
    /// its transfer, so on an ENSHRINED chain, where native and `weth` are one balance, it is paid once, not twice.
    ///
    /// A native payer (`msg.value != 0`) on a WRAPPED chain gets the call's `weth` back as native: exactly
    /// `_held(weth)` is unwrapped first, which moves it into the call's held native (whose start excludes the
    /// router's own native), so it is paid once, as native, and no pre-existing `weth` or native is touched. Calls
    /// without value get `weth` as `weth`; they can end `swaps[]` with a `weth -> native` step instead.
    function _close(Ledger memory l, address to) internal {
        if (msg.value != 0) _unwrapHeldWeth(l);
        for (uint256 i; i < l.tokens.length; i++) {
            uint256 amount = _heldAt(l, i);
            if (amount != 0) _send(l.tokens[i], to, amount);
        }
    }

    /// @dev Sends `to` `amount` of `token` out of what the call holds, before `_close` (e.g. fees returned ahead of
    /// the swaps). More than the call holds reverts `AmountError()`, so it can never spend the router's own balance;
    /// 0 sends nothing.
    function _pay(Ledger memory l, address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (amount > _held(l, token)) revert AmountError();
        _send(token, to, amount);
    }

    /// @dev On a WRAPPED chain, unwraps what the call holds of `weth` (nothing if `weth` is untracked). Native is
    /// tracked whenever `msg.value != 0`, so the unwrapped amount is part of the call's held native.
    function _unwrapHeldWeth(Ledger memory l) private {
        RouterStorage.Layout storage s = RouterStorage.layout();
        if (s.nativeMode != RouterStorage.NATIVE_WRAPPED) return;
        address weth = s.weth;
        for (uint256 i; i < l.tokens.length; i++) {
            if (l.tokens[i] != weth) continue;
            uint256 amount = _heldAt(l, i);
            if (amount != 0) NativeCurrency.toNativeUnits(weth, false, amount);
            return;
        }
    }

    // ---------------------------------------------------------------- account

    /// @dev The account a flow acts for. Under `executeAutomation`, the recorded order account, and only for the
    /// recorded target `(nfpm, tokenId)` (else `NotAutomation()`); otherwise `msg.sender`.
    function _account(address nfpm, uint256 tokenId) internal view returns (address) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        address account = s.automationAccount;
        if (account == address(0)) return msg.sender;
        if (s.automationTarget != keccak256(abi.encode(nfpm, tokenId))) revert NotAutomation();
        return account;
    }

    // ---------------------------------------------------------------- inputs and fees

    /// @dev Pulls the ERC20 inputs from `msg.sender`, requiring the router be credited exactly `amount` (else
    /// `TransferError()`, e.g. a fee-on-transfer token). Native inputs must sum to exactly `msg.value` (0 when there
    /// are none), else `AmountError()`. A token listed twice reverts `SameToken()`.
    function _takeInputs(InputTokenParams[] memory inputs) internal {
        uint256 native;
        for (uint256 i; i < inputs.length; i++) {
            address token = inputs[i].token;
            uint256 amount = inputs[i].amount;
            for (uint256 j; j < i; j++) {
                if (inputs[j].token == token) revert SameToken();
            }
            if (token == address(0)) {
                native += amount;
            } else {
                uint256 before = IERC20(token).balanceOf(address(this));
                IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
                uint256 credited = IERC20(token).balanceOf(address(this));
                if (credited < before || credited - before != amount) revert TransferError();
            }
        }
        if (native != msg.value) revert AmountError();
    }

    /// @dev Takes `feeX64 / 2**64` of each `amounts[i]` of `tokens[i]` to the fee taker and emits v4utils'
    /// `TakeFees` (see `_chargeFees`; `feeX64 == 0` does nothing).
    function _takeFees(
        Ledger memory l,
        address nfpm,
        uint256 tokenId,
        address account,
        address[] memory tokens,
        uint256[] memory amounts,
        uint64 feeX64,
        FeeType t
    ) internal returns (uint256[] memory taken) {
        TakeFeesEventData memory data = _chargeFees(l, tokens, amounts, feeX64, t);
        taken = new uint256[](tokens.length);
        for (uint256 i; i < data.feeTokens.length; i++) {
            taken[i] = data.feeTokens[i].amount;
        }
        _emitFees(nfpm, tokenId, account, data);
    }

    /// @dev `_takeFees` without the event, for a flow that only learns the event's tokenId later (a mint): transfers
    /// the fees and returns the payload for `_emitFees`. `feeX64` above the cap for `t` reverts `TooMuchFee()`;
    /// `feeX64 == 0` transfers nothing and returns an empty payload. Each fee must be covered by what the call holds
    /// of its token (`AmountError()`; `NotTracked()` for a token not in the ledger), so a fee can never spend the
    /// router's own balance, whatever `amounts` says.
    function _chargeFees(Ledger memory l, address[] memory tokens, uint256[] memory amounts, uint64 feeX64, FeeType t)
        internal
        returns (TakeFeesEventData memory data)
    {
        if (amounts.length != tokens.length) revert AmountError();
        data.feeType = t;
        if (feeX64 == 0) return data;
        RouterStorage.Layout storage s = RouterStorage.layout();
        if (feeX64 > s.maxFeeX64[uint8(t)]) revert TooMuchFee();
        data.feeTokens = _payFees(l, tokens, amounts, feeX64, s.feeTaker);
        data.feeX64 = feeX64;
    }

    /// @dev Emits `TakeFees` for a `_chargeFees` payload; nothing for an empty one (`feeX64 == 0`).
    function _emitFees(address nfpm, uint256 tokenId, address account, TakeFeesEventData memory data) internal {
        if (data.feeX64 != 0) emit TakeFees(nfpm, tokenId, account, data);
    }

    function _payFees(
        Ledger memory l,
        address[] memory tokens,
        uint256[] memory amounts,
        uint64 feeX64,
        address feeTaker
    ) private returns (InputTokenParams[] memory feeTokens) {
        feeTokens = new InputTokenParams[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            uint256 fee = FullMath.mulDiv(amounts[i], feeX64, Q64);
            if (fee > _held(l, tokens[i])) revert AmountError();
            feeTokens[i] = InputTokenParams(tokens[i], fee);
            if (fee != 0) _send(tokens[i], feeTaker, fee);
        }
    }

    // ---------------------------------------------------------------- swaps

    /// @dev Runs the steps in order. `amountIn == 0` means everything the call holds of `tokenIn`; a larger
    /// `amountIn` than that reverts `AmountError()`, so a swap never spends the router's own balance. `tokenOut`
    /// must be tracked (else `NotTracked()`), so its output is swept. A native<->`weth` step is a conversion and
    /// ignores `swapData`; any other step runs `swapRouter.call(swapData)` with an exact, reset-after approval.
    function _swaps(Ledger memory l, SwapParams[] memory swaps) internal {
        for (uint256 i; i < swaps.length; i++) {
            SwapParams memory p = swaps[i];
            if (p.tokenIn == p.tokenOut) revert SameToken();
            _indexOf(l, p.tokenOut);
            uint256 held = _held(l, p.tokenIn);
            uint256 amountIn = p.amountIn == 0 ? held : p.amountIn;
            if (amountIn > held) revert AmountError();
            (uint256 inDelta, uint256 outDelta) = _swap(p.tokenIn, p.tokenOut, amountIn, p.swapData, i);
            if (outDelta < p.amountOutMin) revert SwapSlippage();
            emit Swap(p.tokenIn, p.tokenOut, inDelta, outDelta);
        }
    }

    /// @dev One step; returns the amounts it moved (unit-converted for a native<->`weth` conversion, balance deltas
    /// otherwise). An empty `swapData` is a no-op step (v4utils parity).
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, bytes memory swapData, uint256 index)
        private
        returns (uint256 inDelta, uint256 outDelta)
    {
        RouterStorage.Layout storage s = RouterStorage.layout();
        address weth = s.weth;
        bool enshrined = s.nativeMode == RouterStorage.NATIVE_ENSHRINED;
        if (tokenIn == address(0) && tokenOut == weth) {
            return (amountIn, NativeCurrency.toTokenUnits(weth, enshrined, amountIn));
        }
        if (tokenIn == weth && tokenOut == address(0)) {
            return (amountIn, NativeCurrency.toNativeUnits(weth, enshrined, amountIn));
        }
        if (swapData.length == 0) return (0, 0);
        // a low-level call to a codeless address succeeds, which would burn native and pass a 0 amountOutMin
        address swapRouter = s.swapRouter;
        if (swapRouter == address(0)) revert ZeroSwapRouter();
        inDelta = _balanceOf(tokenIn); // before
        outDelta = _balanceOf(tokenOut); // before
        _callSwapRouter(swapRouter, tokenIn, amountIn, swapData, index);
        inDelta = _sub0(inDelta, _balanceOf(tokenIn));
        outDelta = _sub0(_balanceOf(tokenOut), outDelta);
    }

    /// @dev Calls `swapRouter` with `swapData`, paying `amountIn` as value (native) or approving exactly `amountIn`
    /// and resetting the approval after (ERC20).
    function _callSwapRouter(
        address swapRouter,
        address tokenIn,
        uint256 amountIn,
        bytes memory swapData,
        uint256 index
    ) private {
        uint256 value;
        if (tokenIn == address(0)) value = amountIn;
        else _approveExact(tokenIn, swapRouter, amountIn);
        (bool ok,) = swapRouter.call{value: value}(swapData);
        if (!ok) revert SwapFailed(swapData, index);
        if (tokenIn != address(0)) _approve(tokenIn, swapRouter, 0);
    }

    /// @dev Approves exactly `amount` (none when 0). Resets to 0 first for tokens that refuse a non-zero to non-zero
    /// change, ignoring that result for tokens that refuse approve(0); the non-zero approve must succeed.
    function _approveExact(address token, address spender, uint256 amount) private {
        if (amount == 0) return;
        _approve(token, spender, 0);
        if (!_approve(token, spender, amount)) revert ApproveFailed();
    }

    function _approve(address token, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    // ---------------------------------------------------------------- registries and delegatecall

    /// @dev The adapter for `nfpm`, else `UnsupportedNfpm()`.
    function _adapter(address nfpm) internal view returns (address adapter) {
        adapter = RouterStorage.layout().adapter[nfpm];
        if (adapter == address(0)) revert UnsupportedNfpm();
    }

    /// @dev The farm for `nfpm`; zero when it has none.
    function _farm(address nfpm) internal view returns (address) {
        return RouterStorage.layout().farm[nfpm];
    }

    /// @dev DELEGATECALLs `target` (an adapter or farm) with `data`; reverts bubble unchanged.
    function _delegate(address target, bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // ---------------------------------------------------------------- custody

    /// @dev Brings `account`'s position `tokenId` into the router and returns whether it was staked. A position in
    /// `account`'s wallet moves by `transferFrom` (needs the owner's NFPM approval to the router). Otherwise the NFPM's
    /// farm must report it staked by `account` and allow unstaking (else `FarmUnsupported()`), and unstakes it into
    /// the router. Anything else reverts `NotPositionHolder()`, before anything moves.
    /// @dev The wallet check runs first (as in the router's holder check), so a farm that reverts never blocks a
    /// wallet holder; a staked position is held by its gauge, so the two cases never overlap.
    function _take(address nfpm, uint256 tokenId, address account) internal returns (bool staked) {
        if (IERC721(nfpm).ownerOf(tokenId) == account) {
            IERC721(nfpm).transferFrom(account, address(this), tokenId);
            return false;
        }
        address farm = _farm(nfpm);
        if (
            farm == address(0)
                || !abi.decode(_delegate(farm, abi.encodeCall(IFarm.isStakedBy, (nfpm, tokenId, account))), (bool))
        ) revert NotPositionHolder();
        if (!abi.decode(_delegate(farm, abi.encodeCall(IFarm.canUnstake, ())), (bool))) revert FarmUnsupported();
        _delegate(farm, abi.encodeCall(IFarm.unstake, (nfpm, tokenId, account)));
        return true;
    }

    /// @dev Returns the router-held position where `_take` found it: restaked for `account` through the farm when
    /// `staked` (`FarmUnsupported()` if the NFPM has no farm), else to `account`'s wallet.
    function _putBack(address nfpm, uint256 tokenId, address account, bool staked) internal {
        if (staked) {
            address farm = _farm(nfpm);
            if (farm == address(0)) revert FarmUnsupported();
            _delegate(farm, abi.encodeCall(IFarm.stake, (nfpm, tokenId, account)));
        } else {
            IERC721(nfpm).transferFrom(address(this), account, tokenId);
        }
    }

    // ---------------------------------------------------------------- private helpers

    function _indexOf(Ledger memory l, address token) private pure returns (uint256) {
        for (uint256 i; i < l.tokens.length; i++) {
            if (l.tokens[i] == token) return i;
        }
        revert NotTracked();
    }

    function _heldAt(Ledger memory l, uint256 i) private view returns (uint256) {
        return _sub0(_balanceOf(l.tokens[i]), l.start[i]);
    }

    /// @dev `a - b`, saturating at 0.
    function _sub0(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Sends native by call (`NativeTransferFailed()` on failure), ERC20s by `safeTransfer`.
    function _send(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
