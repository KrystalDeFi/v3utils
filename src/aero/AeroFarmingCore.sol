// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../Common.sol";
import "../V3Utils.sol";
import "v3-core/libraries/FullMath.sol";
import "./IAero.sol";

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

/// @notice Storage, types and shared internals of AeroFarmingHelper (the proxy implementation) and
/// AeroAutomationModule (reached from the helper's fallback by DELEGATECALL). Both contracts inherit this one
/// contract, so they have the same storage layout.
/// @dev Storage is append-only. Neither AeroFarmingHelper nor AeroAutomationModule may declare storage of its own.
abstract contract AeroFarmingCore is Initializable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    uint64 internal constant MAX_GAS_FEE_X64 = 5534023222112865280;
    uint64 internal constant MAX_PERFORMANCE_FEE_X64 = 5902958103587057000;
    bytes32 internal constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // storage (append-only, in this order)
    address public v3utils;
    ICLGaugeFactory public gaugeFactory;
    address public rewardToken; // AERO on Base, xAERO elsewhere
    bool public compoundEnabled; // true only on Base
    address public weth; // 0 => native disabled (Arc)
    address public structHash; // deployed StructHash library on this chain
    address internal _activeGauge; // non-zero only inside a flow (NFT receive guard)
    mapping(bytes32 => bool) internal _cancelledOrder;
    address public automationModule; // AeroAutomationModule, reached by delegatecall from the helper's fallback

    enum Action {
        ZAP_IN,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY,
        REBALANCE,
        EXIT,
        COMPOUND,
        HARVEST
    }

    enum AutoAction {
        AUTO_ADJUST,
        AUTO_EXIT,
        AUTO_COMPOUND,
        AUTO_HARVEST
    }

    struct CompoundParams {
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        uint256 deadline;
        uint64 performanceFeeX64;
        uint64 gasFeeX64;
        bool unwrap;
    }

    struct HarvestParams {
        address targetToken; // 0 or the reward token => pay the reward token as is
        uint256 amountOutMin;
        bytes swapData;
        uint64 gasFeeX64;
    }

    struct OrderParams {
        AutoAction action;
        address account;
        address gauge;
        uint256 tokenId;
        bytes actionData;
        bytes order;
        bytes signature;
    }

    event FarmAction(
        address indexed user,
        address indexed gauge,
        uint256 indexed tokenId,
        uint256 newTokenId,
        Action action,
        bool automated
    );
    event DeductFees(
        address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, Common.DeductFeesEventData data
    );
    event CancelOrder(address user, bytes32 hash, bytes signature);
    event ConfigUpdated(address v3utils, address structHash);
    event AutomationModuleUpdated(address module);

    error InvalidGauge();
    error GaugeNotLive();
    error NativeDisabled();
    error CompoundDisabled();
    error UnexpectedNft();
    error NotStakeOwner();
    error InvalidSignature();
    error OrderCancelled();
    error InvalidInstructions();
    error FeeTooHigh();
    error NotSupportedAction();
    error NativeTransferFailed();
    error UnexpectedNative();
    error ModuleNotSet();
    error SlippageError();
    error SwapFailed(bytes swapData, uint256 index);

    function _checkUnwrap(bool unwrap) internal view {
        if (unwrap && weth == address(0)) revert NativeDisabled();
    }

    function _compound(address account, address gauge, uint256 tokenId, CompoundParams memory p, bool automated)
        internal
    {
        if (!compoundEnabled) revert CompoundDisabled();
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        _checkUnwrap(p.unwrap);
        (address token0, address token1,) = _positionInfo(nfpm, tokenId);
        address[] memory list = _tokenSet(token0, token1, rewardToken, address(0));
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
        address reward = rewardToken;
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

        address v = v3utils;
        IERC20(reward).forceApprove(v, amount);
        V3UtilsLike(v).swapAndIncreaseLiquidity(p);
        IERC20(reward).forceApprove(v, 0);
    }

    /// @dev Sends `amount * feeX64 / 2^64` of the reward token to V3Utils' FEE_TAKER and emits DeductFees.
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
        address reward = rewardToken;
        IERC20(reward).safeTransfer(V3Utils(payable(v3utils)).FEE_TAKER(), fee);

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

    /// @dev Unstake, run `ins` through V3Utils, then restake (REMOVE_LIQUIDITY), restake the new NFT (REBALANCE) or hand the NFT to `account` (EXIT).
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
        nfpm.safeTransferFrom(address(this), v3utils, tokenId, abi.encode(ins));
        if (action == Action.REMOVE_LIQUIDITY) {
            _stake(gauge, nfpm, tokenId, account);
            tokenIdAfter = tokenId;
        } else if (action == Action.REBALANCE) {
            // V3Utils sends the new NFT first and returns the old one last, so the enumeration ends [..., new, old]
            tokenIdAfter = nfpm.tokenOfOwnerByIndex(address(this), nfpm.balanceOf(address(this)) - 2);
            if (tokenIdAfter == tokenId || nfpm.ownerOf(tokenIdAfter) != address(this)) revert UnexpectedNft();
            _stake(gauge, nfpm, tokenIdAfter, account);
            nfpm.transferFrom(address(this), account, tokenId);
        } else {
            nfpm.transferFrom(address(this), account, tokenId);
            tokenIdAfter = tokenId;
        }
        _sweep(list, before, account, unwrap);
        emit FarmAction(account, gauge, tokenId, tokenIdAfter, action, automated);
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
        list = _tokenSet(token0, token1, ins.targetToken, rewardToken);
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
        _activeGauge = gauge;
        ICLGauge(gauge).withdrawFrom(tokenId, account);
        _activeGauge = address(0);
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
        address w = weth;
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
        ICLGaugeFactory f = gaugeFactory;
        if (!f.isGauge(gauge)) revert InvalidGauge();
        address n = ICLGauge(gauge).nft();
        if (n != f.nft()) revert InvalidGauge();
        nfpm = INonfungiblePositionManager(n);
    }

    function _requireLive(address gauge) internal view {
        if (!ILeafVoter(gaugeFactory.leafVoter()).isActivated(gauge)) revert GaugeNotLive();
    }
}
