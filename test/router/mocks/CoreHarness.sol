// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {CoreBase} from "../../../src/router/base/CoreBase.sol";
import {FeeType, InputTokenParams, SwapParams, AdjustRangeParams} from "../../../src/router/RouterTypes.sol";

/// @dev Exposes CoreBase's internals as module functions; registered behind a real router with `setModule` and
/// reached through `execute`, so it runs as the router, on the router's balances.
contract CoreHarness is CoreBase {
    using SafeERC20 for IERC20;

    /// @dev A flow skeleton: open over `candidates`, take `inputs` from the caller, run `swaps`, report what the call
    /// holds of each tracked token, then close to the caller.
    function flow(address[] calldata candidates, InputTokenParams[] calldata inputs, SwapParams[] calldata swaps)
        external
        payable
        onlyDelegateCall
        returns (address[] memory tokens, uint256[] memory held)
    {
        Ledger memory l = _open(candidates);
        _takeInputs(inputs);
        _swaps(l, swaps);
        tokens = l.tokens;
        held = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            held[i] = _held(l, tokens[i]);
        }
        _close(l, msg.sender);
    }

    /// @dev Opens, then receives `amount` of `token` from `from` mid-call (as a collect would), and closes to `to`.
    function receiveAndClose(address[] calldata candidates, address token, address from, uint256 amount, address to)
        external
        onlyDelegateCall
        returns (uint256 held)
    {
        Ledger memory l = _open(candidates);
        IERC20(token).safeTransferFrom(from, address(this), amount);
        held = _held(l, token);
        _close(l, to);
    }

    function heldOf(address[] calldata candidates, address token) external view onlyDelegateCall returns (uint256) {
        Ledger memory l = _open(candidates);
        return _held(l, token);
    }

    function trackedOf(address[] calldata candidates) external view onlyDelegateCall returns (address[] memory) {
        return _open(candidates).tokens;
    }

    function takeFees(
        address nfpm,
        uint256 tokenId,
        address account,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint64 feeX64,
        FeeType t
    ) external onlyDelegateCall returns (uint256[] memory) {
        return _takeFees(nfpm, tokenId, account, tokens, amounts, feeX64, t);
    }

    /// @dev Takes the caller's position, reports where it sits, then puts it back.
    function takeAndPutBack(address nfpm, uint256 tokenId)
        external
        onlyDelegateCall
        returns (bool staked, address heldBy)
    {
        address account = _account(nfpm, tokenId);
        staked = _take(nfpm, tokenId, account);
        heldBy = IERC721(nfpm).ownerOf(tokenId);
        _putBack(nfpm, tokenId, account, staked);
    }

    /// @dev Registered under the AUTO_ADJUST flow selector: returns the account `_account` resolves for the params.
    function adjustRange(AdjustRangeParams calldata p) external view onlyDelegateCall returns (address) {
        return _account(p.nfpm, p.tokenId);
    }

    function adapterOf(address nfpm) external view onlyDelegateCall returns (address) {
        return _adapter(nfpm);
    }

    function farmOf(address nfpm) external view onlyDelegateCall returns (address) {
        return _farm(nfpm);
    }

    function delegateTo(address target, bytes calldata data) external onlyDelegateCall returns (bytes memory) {
        return _delegate(target, data);
    }
}

/// @dev Gauge stand-in: holds staked NFTs and records each one's staker.
contract MockGauge {
    mapping(address => mapping(uint256 => address)) public stakedBy;

    function deposit(address nfpm, uint256 tokenId, address account) external {
        IERC721(nfpm).transferFrom(msg.sender, address(this), tokenId);
        stakedBy[nfpm][tokenId] = account;
    }

    /// @dev Only the recorded staker's position, and only to the caller.
    function withdraw(address nfpm, uint256 tokenId, address account) external {
        require(stakedBy[nfpm][tokenId] == account, "not staker");
        delete stakedBy[nfpm][tokenId];
        IERC721(nfpm).transferFrom(address(this), msg.sender, tokenId);
    }
}

/// @dev Farm stand-in over a MockGauge (delegatecalled, so it runs as the router; config in immutables only).
contract MockCustodyFarm {
    MockGauge public immutable gauge;
    bool public immutable unstakeable;

    constructor(MockGauge gauge_, bool unstakeable_) {
        gauge = gauge_;
        unstakeable = unstakeable_;
    }

    function isStakedBy(address nfpm, uint256 tokenId, address account) external view returns (bool) {
        return gauge.stakedBy(nfpm, tokenId) == account;
    }

    function canUnstake() external view returns (bool) {
        return unstakeable;
    }

    function unstake(address nfpm, uint256 tokenId, address account) external {
        gauge.withdraw(nfpm, tokenId, account);
    }

    function stake(address nfpm, uint256 tokenId, address account) external {
        IERC721(nfpm).approve(address(gauge), tokenId);
        gauge.deposit(nfpm, tokenId, account);
    }
}
