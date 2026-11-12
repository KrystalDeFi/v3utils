// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./AeroFarmingCore.sol";
import {SignatureValidator} from "@krystal/util-contracts/contracts/SignatureValidator.sol";

/// @notice Operator path of AeroFarmingHelper. Callers call the helper proxy; the helper's fallback DELEGATECALLs
/// this contract, so it runs on the proxy's storage, roles and token approvals, and address(this) is the proxy.
/// @dev Called directly, it has no roles, no approvals and its initializers are disabled, so it can do nothing.
/// It must not define initialize, upgrade functions, receive or onERC721Received, nor declare storage.
contract AeroAutomationModule is AeroFarmingCore {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice EIP-712 domain separator, computed per call so it binds to the proxy address.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPE_HASH, keccak256("AeroFarmingHelper"), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @notice EIP-712 digest of an abi-encoded `StructHash.Order`.
    function hashOrder(bytes calldata order) public view returns (bytes32 digest) {
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), IStructHash(structHash)._hash(order)));
    }

    /// @notice Cancel an order (identified by its EIP-712 digest) signed by the caller.
    function cancelOrder(bytes32 hash, bytes calldata signature) external {
        if (!SignatureValidator.isValidSignatureNow(msg.sender, hash, signature)) revert InvalidSignature();
        _cancelledOrder[_cancelKey(msg.sender, hash)] = true;
        emit CancelOrder(msg.sender, hash, signature);
    }

    function isOrderCancelled(address actor, bytes32 hash) external view returns (bool) {
        return _cancelledOrder[_cancelKey(actor, hash)];
    }

    /// @dev Keyed on the digest (not the signature bytes, which can be re-encoded) and scoped per actor.
    function _cancelKey(address actor, bytes32 digest) private pure returns (bytes32) {
        return keccak256(abi.encode(actor, digest));
    }

    /// @notice Operator entry point: runs an action on `p.account`'s staked position under an order the account signed.
    /// The order's tokenId, nfpm and type are not checked on-chain (the signed order only authorises the operator).
    function executeOrder(OrderParams calldata p)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 tokenIdAfter)
    {
        _validateOrder(p);
        address account = p.account;
        tokenIdAfter = p.tokenId;
        if (p.action == AutoAction.AUTO_COMPOUND) {
            _compound(account, p.gauge, tokenIdAfter, abi.decode(p.actionData, (CompoundParams)), true);
        } else if (p.action == AutoAction.AUTO_HARVEST) {
            _harvest(account, p.gauge, tokenIdAfter, abi.decode(p.actionData, (HarvestParams)));
        } else {
            tokenIdAfter = _modify(
                account,
                p.gauge,
                tokenIdAfter,
                abi.decode(p.actionData, (V3Utils.Instructions)),
                p.action == AutoAction.AUTO_ADJUST ? Action.REBALANCE : Action.EXIT,
                true
            );
        }
    }

    /// @dev Claims the emissions (the position stays staked), takes the gas fee, optionally swaps the rest into
    /// `p.targetToken` (Base only) and pays the account.
    function _harvest(address account, address gauge, uint256 tokenId, HarvestParams memory p) internal {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        address reward = rewardToken;
        address target = p.targetToken;
        bool doSwap = target != address(0) && target != reward;
        if (doSwap && !compoundEnabled) revert CompoundDisabled();
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

    /// @dev Same logic as CommonLib.swap, inline so the helper needs no library link.
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData)
        internal
        returns (uint256 amountInDelta, uint256 amountOutDelta)
    {
        if (amountIn != 0 && swapData.length != 0 && address(tokenOut) != address(0)) {
            address router = V3Utils(payable(v3utils)).swapRouter();
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

    /// @dev Gauge check, then: `p.account` owns the stake, signed `p.order`, and has not cancelled it.
    function _validateOrder(OrderParams calldata p) internal view {
        address account = p.account;
        _validateGauge(p.gauge);
        if (!ICLGauge(p.gauge).stakedContains(account, p.tokenId)) revert NotStakeOwner();
        bytes32 digest = hashOrder(p.order);
        if (!SignatureValidator.isValidSignatureNow(account, digest, p.signature)) revert InvalidSignature();
        if (_cancelledOrder[_cancelKey(account, digest)]) revert OrderCancelled();
    }
}
