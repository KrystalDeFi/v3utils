// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./AeroFarmingCore.sol";

/// @notice Upgradeable (UUPS) helper that manages Aero CL positions staked in CLGauges on users' behalf.
/// The operator path (executeOrder, cancelOrder, isOrderCancelled, domainSeparator, hashOrder) lives in
/// `automationModule` and is reached through this contract's fallback by DELEGATECALL.
contract AeroFarmingHelper is AeroFarmingCore, UUPSUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

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
        address structHash_,
        address automationModule_
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
        _setAutomationModule(automationModule_);
    }

    function setV3Utils(address v3utils_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        v3utils = v3utils_;
        _emitConfig();
    }

    function setStructHash(address structHash_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        structHash = structHash_;
        _emitConfig();
    }

    /// @notice Sets the operator-path module the fallback delegates to; zero disables the operator path.
    function setAutomationModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAutomationModule(module);
    }

    function _setAutomationModule(address module) internal {
        automationModule = module;
        emit AutomationModuleUpdated(module);
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

    /// @notice Claim the position's AERO emissions, take the performance fee and add the rest back to the position (Base only).
    /// Requires the caller to have approved this helper with `approveForClaim` on the gauge.
    function compound(address gauge, uint256 tokenId, CompoundParams memory p) external nonReentrant whenNotPaused {
        _compound(msg.sender, gauge, tokenId, p, false);
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
        address v = v3utils;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] != address(0)) IERC20(tokens[i]).forceApprove(v, reset ? 0 : amounts[i]);
        }
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

    /// @dev Only accepts native coin from WETH (unwrap).
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedNative();
    }

    /// @dev Delegates every unknown selector to `automationModule` and bubbles its return or revert data.
    fallback() external payable {
        address module = automationModule;
        if (module == address(0)) revert ModuleNotSet();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
