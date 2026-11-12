// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../Common.sol";
import "../V3Utils.sol";
import "v3-core/libraries/FullMath.sol";
import "./IAero.sol";
import {SignatureValidator} from "@krystal/util-contracts/contracts/SignatureValidator.sol";

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

contract AeroFarmingHelper is
    Initializable,
    UUPSUpgradeable,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    uint64 internal constant MAX_GAS_FEE_X64 = 5534023222112865280;
    uint64 internal constant MAX_PERFORMANCE_FEE_X64 = 5902958103587057000;

    // storage (append-only, in this order)
    address public v3utils;
    ICLGaugeFactory public gaugeFactory;
    address public rewardToken; // AERO on Base, xAERO elsewhere
    bool public compoundEnabled; // true only on Base
    address public weth; // 0 => native disabled (Arc)
    address public structHash; // deployed StructHash library on this chain
    address internal _activeGauge; // non-zero only inside a flow (NFT receive guard)
    mapping(bytes32 => bool) internal _cancelledOrder;

    enum Action {
        ZAP_IN,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY,
        REBALANCE,
        EXIT,
        COMPOUND,
        HARVEST
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
    enum AutoAction {
        AUTO_ADJUST,
        AUTO_EXIT,
        AUTO_COMPOUND,
        AUTO_HARVEST
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

    event CancelOrder(address user, bytes32 hash, bytes signature);
    event ConfigUpdated(address v3utils, address structHash);

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address operator,
        address withdrawer,
        address v3utils_,
        address gaugeFactory_,
        address rewardToken_,
        bool compoundEnabled_,
        address weth_,
        address structHash_
    ) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(WITHDRAWER_ROLE, withdrawer);
        v3utils = v3utils_;
        gaugeFactory = ICLGaugeFactory(gaugeFactory_);
        rewardToken = rewardToken_;
        compoundEnabled = compoundEnabled_;
        weth = weth_;
        structHash = structHash_;
        _emitConfig();
    }

    function setV3Utils(address v3utils_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        v3utils = v3utils_;
        _emitConfig();
    }

    function setStructHash(address structHash_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        structHash = structHash_;
        _emitConfig();
    }

    function _checkUnwrap(bool unwrap) internal view {
        if (unwrap && weth == address(0)) revert NativeDisabled();
    }

    function _emitConfig() internal {
        emit ConfigUpdated(v3utils, structHash);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function withdrawERC20(IERC20 token, address to) external onlyRole(WITHDRAWER_ROLE) {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    function withdrawERC721(IERC721 nft, uint256 tokenId, address to) external onlyRole(WITHDRAWER_ROLE) {
        nft.safeTransferFrom(address(this), to, tokenId);
    }

    function withdrawNative(address to) external onlyRole(WITHDRAWER_ROLE) {
        _sendNative(to, address(this).balance);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Accepts the NFT only while a flow is withdrawing it from the active gauge.
    function onERC721Received(address operator, address from, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        address active = _activeGauge;
        if (msg.sender != gaugeFactory.nft() || active == address(0) || operator != active || from != active) {
            revert UnexpectedNft();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Zap tokens (and/or native coin) into a new Aero CL position and stake it in `gauge` for the caller.
    function zapInAndStake(address gauge, Common.SwapAndMintParams memory p, bool unwrap)
        external
        payable
        nonReentrant
        whenNotPaused
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
        tokenId = V3UtilsLike(v3utils).swapAndMint(p).tokenId;
        _approveInputs(tokens, amounts, true);

        _stake(gauge, nfpm, tokenId, msg.sender);
        _sweep(list, before, msg.sender, unwrap);
        emit FarmAction(msg.sender, gauge, tokenId, tokenId, Action.ZAP_IN, false);
    }

    /// @notice Add liquidity to a staked position: unstake, increase through V3Utils, restake. Leftovers go back to the caller.
    function addLiquidity(address gauge, Common.SwapAndIncreaseLiquidityParams memory p, bool unwrap)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        if (address(p.nfpm) != address(nfpm) || p.protocol != Nfpm.Protocol.AERODROME) {
            revert InvalidInstructions();
        }
        _checkUnwrap(unwrap);
        uint256 tokenId = p.tokenId;
        p.recipient = address(this);

        (address[3] memory tokens, uint256[3] memory amounts) = _increaseInputs(nfpm, p);
        address[] memory list = _tokenSet(tokens[0], tokens[1], tokens[2], rewardToken);
        uint256[] memory before = _snapshot(list);

        _unstake(gauge, tokenId, msg.sender);
        _pullInputs(tokens, amounts);

        _approveInputs(tokens, amounts, false);
        V3UtilsLike(v3utils).swapAndIncreaseLiquidity(p);
        _approveInputs(tokens, amounts, true);

        _stake(gauge, nfpm, tokenId, msg.sender);
        _sweep(list, before, msg.sender, unwrap);
        emit FarmAction(msg.sender, gauge, tokenId, tokenId, Action.ADD_LIQUIDITY, false);
    }

    /// @notice Withdraw part of a staked position's liquidity (and collect fees); the NFT is restaked under the same id.
    function removeLiquidity(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        external
        nonReentrant
        whenNotPaused
    {
        _modify(msg.sender, gauge, tokenId, ins, Action.REMOVE_LIQUIDITY, false);
    }

    /// @notice Withdraw all liquidity of a staked position and return the (empty) NFT, unstaked, to the caller.
    function exit(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        external
        nonReentrant
        whenNotPaused
    {
        _modify(msg.sender, gauge, tokenId, ins, Action.EXIT, false);
    }

    /// @notice Move a staked position to a new range: V3Utils mints the new position, which is staked for the caller.
    /// The old (emptied) NFT is returned, unstaked, to the caller.
    function rebalance(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 newTokenId)
    {
        newTokenId = _modify(msg.sender, gauge, tokenId, ins, Action.REBALANCE, false);
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

    /// @notice Claim the position's AERO emissions, take the performance fee and add the rest back to the position (Base only).
    /// Requires the caller to have approved this helper with `approveForClaim` on the gauge.
    function compound(address gauge, uint256 tokenId, CompoundParams memory p) external nonReentrant whenNotPaused {
        _compound(msg.sender, gauge, tokenId, p, false);
    }

    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 domain separator, computed per call so it binds to the proxy address.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPE_HASH, keccak256("AeroFarmingHelper"), keccak256("1"), block.chainid, address(this)
            )
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
        address account = p.account;
        if (!ICLGauge(p.gauge).stakedContains(account, p.tokenId)) revert NotStakeOwner();
        bytes32 digest = hashOrder(p.order);
        if (!SignatureValidator.isValidSignatureNow(account, digest, p.signature)) revert InvalidSignature();
        if (_cancelledOrder[_cancelKey(account, digest)]) revert OrderCancelled();

        tokenIdAfter = p.tokenId;
        if (p.action == AutoAction.AUTO_COMPOUND) {
            _compound(account, p.gauge, tokenIdAfter, abi.decode(p.actionData, (CompoundParams)), true);
        } else if (p.action == AutoAction.AUTO_HARVEST) {
            revert NotSupportedAction();
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

    /// @dev Approves V3Utils for `amounts` of each non-zero token, or resets the approvals to zero.
    function _approveInputs(address[3] memory tokens, uint256[3] memory amounts, bool reset) internal {
        address v = v3utils;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, reset ? 0 : amounts[i]);
        }
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @dev Pulls `amounts` from msg.sender. msg.value is wrapped and counts toward the WETH slot.
    function _pullInputs(address[3] memory tokens, uint256[3] memory amounts_) internal {
        uint256[3] memory amounts = [amounts_[0], amounts_[1], amounts_[2]]; // real copy: caller keeps full amounts
        uint256 native = msg.value;
        if (native > 0) {
            address w = weth;
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

    /// @dev Only accepts native coin from WETH (unwrap).
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedNative();
    }
}
