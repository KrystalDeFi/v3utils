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
        emit ConfigUpdated(v3utils_, structHash_);
    }

    function setV3Utils(address v3utils_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        v3utils = v3utils_;
        emit ConfigUpdated(v3utils_, structHash);
    }

    function setStructHash(address structHash_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        structHash = structHash_;
        emit ConfigUpdated(v3utils, structHash_);
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
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "native transfer failed");
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
    function zapInAndStake(address gauge, Common.SwapAndMintParams calldata params, bool unwrap)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        Common.SwapAndMintParams memory p = params;
        if (address(p.nfpm) != address(nfpm) || p.protocol != Nfpm.Protocol.AERODROME || p.token0 == p.token1) {
            revert InvalidInstructions();
        }
        p.recipient = address(this);

        address[3] memory tokens = [address(p.token0), address(p.token1), address(0)];
        uint256[3] memory amounts = [p.amount0, p.amount1, uint256(0)];
        if (p.swapSourceToken != p.token0 && p.swapSourceToken != p.token1 && address(p.swapSourceToken) != address(0))
        {
            tokens[2] = address(p.swapSourceToken);
            amounts[2] = p.amount2;
        }
        address[] memory list = _nonZero(tokens);
        if (unwrap && weth == address(0)) revert NativeDisabled();
        uint256[] memory before = _snapshot(list);

        _pullInputs(tokens, amounts);

        address v = v3utils;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, amounts[i]);
        }
        tokenId = V3UtilsLike(v).swapAndMint(p).tokenId;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, 0);
        }

        _stake(gauge, nfpm, tokenId, msg.sender);
        _sweep(list, before, msg.sender, unwrap);
        emit FarmAction(msg.sender, gauge, tokenId, tokenId, Action.ZAP_IN, false);
    }

    /// @notice Add liquidity to a staked position: unstake, increase through V3Utils, restake. Leftovers go back to the caller.
    function addLiquidity(address gauge, Common.SwapAndIncreaseLiquidityParams calldata params, bool unwrap)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        INonfungiblePositionManager nfpm = _validateGauge(gauge);
        if (address(params.nfpm) != address(nfpm) || params.protocol != Nfpm.Protocol.AERODROME) {
            revert InvalidInstructions();
        }
        if (unwrap && weth == address(0)) revert NativeDisabled();
        uint256 tokenId = params.tokenId;
        Common.SwapAndIncreaseLiquidityParams memory p = params;
        p.recipient = address(this);

        (address[3] memory tokens, uint256[3] memory amounts) = _increaseInputs(nfpm, p);
        address[] memory list = _tokenSet(tokens[0], tokens[1], tokens[2], rewardToken);
        uint256[] memory before = _snapshot(list);

        _unstake(gauge, tokenId, msg.sender);
        _pullInputs(tokens, amounts);

        address v = v3utils;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, amounts[i]);
        }
        V3UtilsLike(v).swapAndIncreaseLiquidity(p);
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, 0);
        }

        _stake(gauge, nfpm, tokenId, msg.sender);
        _sweep(list, before, msg.sender, unwrap);
        emit FarmAction(msg.sender, gauge, tokenId, tokenId, Action.ADD_LIQUIDITY, false);
    }

    /// @notice Withdraw part of a staked position's liquidity (and collect fees); the NFT is restaked under the same id.
    function removeLiquidity(address gauge, uint256 tokenId, V3Utils.Instructions calldata ins)
        external
        nonReentrant
        whenNotPaused
    {
        _modify(msg.sender, gauge, tokenId, ins, Action.REMOVE_LIQUIDITY, false);
    }

    /// @notice Withdraw all liquidity of a staked position and return the (empty) NFT, unstaked, to the caller.
    function exit(address gauge, uint256 tokenId, V3Utils.Instructions calldata ins)
        external
        nonReentrant
        whenNotPaused
    {
        _modify(msg.sender, gauge, tokenId, ins, Action.EXIT, false);
    }

    /// @notice Move a staked position to a new range: V3Utils mints the new position, which is staked for the caller.
    /// The old (emptied) NFT is returned, unstaked, to the caller.
    function rebalance(address gauge, uint256 tokenId, V3Utils.Instructions calldata ins)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 newTokenId)
    {
        newTokenId = _modify(msg.sender, gauge, tokenId, ins, Action.REBALANCE, false);
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
            // any liquidity: V3Utils bounds it by the position
        } else if (action == Action.REMOVE_LIQUIDITY) {
            if (ins.liquidity == 0 || ins.liquidity >= liquidity) revert InvalidInstructions();
        } else if (action == Action.EXIT) {
            if (ins.liquidity != liquidity) revert InvalidInstructions();
        } else {
            revert NotSupportedAction();
        }
        if (ins.unwrap && weth == address(0)) revert NativeDisabled();
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
        tokens = [t0, t1, address(0)];
        amounts = [p.amount0, p.amount1, uint256(0)];
        if (
            address(p.swapSourceToken) != address(0) && address(p.swapSourceToken) != t0
                && address(p.swapSourceToken) != t1
        ) {
            tokens[2] = address(p.swapSourceToken);
            amounts[2] = p.amount2;
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
                if (w == address(0)) revert NativeDisabled();
                IWETHLike(w).withdraw(delta);
                (bool ok,) = to.call{value: delta}("");
                require(ok, "native transfer failed");
            } else {
                IERC20(tokens[i]).safeTransfer(to, delta);
            }
        }
    }

    /// @dev Pulls `amounts` from msg.sender. msg.value is wrapped and counts toward the WETH slot.
    function _pullInputs(address[3] memory tokens, uint256[3] memory amounts_) internal {
        uint256[3] memory amounts = [amounts_[0], amounts_[1], amounts_[2]]; // real copy: caller keeps full amounts
        uint256 native = msg.value;
        if (native > 0) {
            address w = weth;
            if (w == address(0)) revert NativeDisabled();
            bool matched;
            for (uint256 i; i < 3; ++i) {
                if (tokens[i] == w) {
                    if (native > amounts[i]) revert NativeDisabled();
                    amounts[i] -= native;
                    matched = true;
                    break;
                }
            }
            if (!matched) revert NativeDisabled();
            IWETHLike(w).deposit{value: native}();
        }
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
        }
    }

    function _nonZero(address[3] memory tokens) internal pure returns (address[] memory list) {
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) ++n;
        }
        list = new address[](n);
        n = 0;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) list[n++] = tokens[i];
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
        require(msg.sender == weth, "only weth");
    }
}
