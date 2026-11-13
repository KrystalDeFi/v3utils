// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SignatureValidator} from "@krystal/util-contracts/contracts/SignatureValidator.sol";
import "../StructHash.sol";
import "./IAero.sol";
import "./IAeroFarmingLogic.sol";
import "./AeroStorage.sol";

/// @notice Fixed (non-upgradeable) entry point for Aero CL positions staked in CLGauges; it is the address users
/// approve on gauges. Flows run in the AeroFarmingLogic set as `implementation`, by DELEGATECALL through two
/// explicit entry points: `execute` (users; msg.sender is the account) and `executeAutomation` (operator, under a
/// signed order). Roles, pause, reentrancy, order checks, cancel, rescue and the NFT receive guard live here.
/// @dev Shared config/flow state is in the AeroStorage slot. The router's own storage (roles, pause, reentrancy,
/// implementation, cancelled orders) is never written by the logic, which declares no storage.
contract AeroFarmingRouter is AccessControl, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 internal constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 domain separator of signed orders (name "AeroFarmingRouter", version "1", this router).
    bytes32 public immutable DOMAIN_SEPARATOR;
    /// @dev The deploying tx.origin: the only address allowed to call `initialize` (front-run guard, as in Common).
    address private immutable _initializer;

    address public implementation;
    bool public implementationLocked;
    bool private _initialized;
    mapping(bytes32 => bool) private _cancelledOrder;

    event ConfigUpdated(address v3utils);
    event ImplementationSet(address implementation);
    event ImplementationLockedForever(address implementation);
    event CancelOrder(address user, bytes32 hash, bytes signature);

    error NotInitializer();
    error AlreadyInitialized();
    error ImplementationNotSet();
    error InvalidImplementation();
    error ImplementationLocked();
    error WrongChainId();
    error WrongPositionManager();

    constructor() {
        _initializer = tx.origin;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPE_HASH, keccak256("AeroFarmingRouter"), keccak256("1"), block.chainid, address(this))
        );
    }

    function initialize(
        address admin,
        address operator,
        address withdrawer,
        address implementation_,
        address v3utils_,
        address gaugeFactory_,
        address rewardToken_,
        bool compoundEnabled_,
        address weth_
    ) external {
        if (msg.sender != _initializer) revert NotInitializer();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(WITHDRAWER_ROLE, withdrawer);
        _setImplementation(implementation_);
        AeroStorage.Layout storage s = AeroStorage.layout();
        s.v3utils = v3utils_;
        s.gaugeFactory = gaugeFactory_;
        s.rewardToken = rewardToken_;
        s.compoundEnabled = compoundEnabled_;
        s.weth = weth_;
        emit ConfigUpdated(v3utils_);
    }

    // ---------------------------------------------------------------- entry points

    /// @notice User entry point: DELEGATECALLs the logic with `data` (an `abi.encodeCall(IAeroFarmingLogic.<fn>, ...)`)
    /// and returns its raw return data; reverts bubble unchanged.
    function execute(bytes calldata data) external payable nonReentrant whenNotPaused returns (bytes memory result) {
        address impl = implementation;
        if (impl == address(0)) revert ImplementationNotSet();
        bool ok;
        (ok, result) = impl.delegatecall(data);
        if (!ok) _bubble(result);
    }

    /// @notice Operator entry point: runs `action` on `account`'s staked `tokenId` under an order `account` signed.
    /// The order must be for this chain and the gauge's position manager; its tokenId is not bound (recurring
    /// rebalances mint new ids), the operator is trusted to target the right token of the account.
    function executeAutomation(
        address account,
        address gauge,
        uint256 tokenId,
        IAeroFarmingLogic.AutoAction action,
        bytes calldata actionData,
        bytes calldata order,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) returns (uint256 tokenIdAfter) {
        _checkAutomation(account, gauge, tokenId, order, signature);
        tokenIdAfter = _runAutomated(action, account, gauge, tokenId, actionData);
    }

    // ---------------------------------------------------------------- orders

    /// @notice EIP-712 digest of an abi-encoded `StructHash.Order`.
    function hashOrder(bytes calldata order) external view returns (bytes32 digest) {
        digest = _digest(abi.decode(order, (StructHash.Order)));
    }

    /// @notice Cancel an order (identified by its EIP-712 digest) signed by the caller.
    function cancelOrder(bytes32 hash, bytes calldata signature) external {
        if (!SignatureValidator.isValidSignatureNow(msg.sender, hash, signature)) {
            revert IAeroFarmingLogic.InvalidSignature();
        }
        _cancelledOrder[_cancelKey(msg.sender, hash)] = true;
        emit CancelOrder(msg.sender, hash, signature);
    }

    function isOrderCancelled(address actor, bytes32 hash) external view returns (bool) {
        return _cancelledOrder[_cancelKey(actor, hash)];
    }

    // ---------------------------------------------------------------- admin

    /// @notice Replace the logic. Config, roles, approvals and signed orders are untouched (they live in the router).
    function setImplementation(address implementation_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setImplementation(implementation_);
    }

    /// @notice One-way: no further `setImplementation`.
    function lockImplementation() external onlyRole(DEFAULT_ADMIN_ROLE) {
        implementationLocked = true;
        emit ImplementationLockedForever(implementation);
    }

    function setV3Utils(address v3utils_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AeroStorage.layout().v3utils = v3utils_;
        emit ConfigUpdated(v3utils_);
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
        if (!ok) revert IAeroFarmingLogic.NativeTransferFailed();
    }

    // ---------------------------------------------------------------- config views

    function v3utils() external view returns (address) {
        return AeroStorage.layout().v3utils;
    }

    function gaugeFactory() external view returns (address) {
        return AeroStorage.layout().gaugeFactory;
    }

    function rewardToken() external view returns (address) {
        return AeroStorage.layout().rewardToken;
    }

    function compoundEnabled() external view returns (bool) {
        return AeroStorage.layout().compoundEnabled;
    }

    function weth() external view returns (address) {
        return AeroStorage.layout().weth;
    }

    // ---------------------------------------------------------------- receivers

    /// @dev Accepts the NFT only while a flow is withdrawing it from the active gauge.
    function onERC721Received(address operator, address from, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        AeroStorage.Layout storage s = AeroStorage.layout();
        address active = s.activeGauge;
        if (
            msg.sender != ICLGaugeFactory(s.gaugeFactory).nft() || active == address(0) || operator != active
                || from != active
        ) {
            revert IAeroFarmingLogic.UnexpectedNft();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Only accepts native coin from WETH (unwrap).
    receive() external payable {
        if (msg.sender != AeroStorage.layout().weth) revert IAeroFarmingLogic.UnexpectedNative();
    }

    // ---------------------------------------------------------------- internals

    /// @dev Gauge check, `account` owns the stake, then the order checks.
    function _checkAutomation(
        address account,
        address gauge,
        uint256 tokenId,
        bytes calldata order,
        bytes calldata signature
    ) internal view {
        address nfpm = _validateGauge(gauge);
        if (!ICLGauge(gauge).stakedContains(account, tokenId)) revert IAeroFarmingLogic.NotStakeOwner();
        _validateOrder(account, nfpm, order, signature);
    }

    /// @dev Records `account` as the automation account, delegatecalls the logic's automated entry with calldata
    /// built here, clears the record and bubbles any revert unchanged.
    function _runAutomated(
        IAeroFarmingLogic.AutoAction action,
        address account,
        address gauge,
        uint256 tokenId,
        bytes calldata actionData
    ) internal returns (uint256) {
        address impl = implementation;
        if (impl == address(0)) revert ImplementationNotSet();
        AeroStorage.Layout storage s = AeroStorage.layout();
        s.automationAccount = account;
        (bool ok, bytes memory ret) = impl.delegatecall(
            abi.encodeCall(IAeroFarmingLogic.executeAutomated, (action, account, gauge, tokenId, actionData))
        );
        s.automationAccount = address(0);
        if (!ok) _bubble(ret);
        return abi.decode(ret, (uint256));
    }

    function _setImplementation(address implementation_) internal {
        if (implementationLocked) revert ImplementationLocked();
        if (implementation_.code.length == 0) revert InvalidImplementation();
        implementation = implementation_;
        emit ImplementationSet(implementation_);
    }

    /// @dev Chain and position manager binding, then: `account` signed the order and has not cancelled it.
    function _validateOrder(address account, address nfpm, bytes calldata order, bytes calldata signature)
        internal
        view
    {
        StructHash.Order memory o = abi.decode(order, (StructHash.Order));
        if (o.chainId != int64(int256(block.chainid))) revert WrongChainId();
        if (o.nfpmAddress != nfpm) revert WrongPositionManager();
        bytes32 digest = _digest(o);
        if (!SignatureValidator.isValidSignatureNow(account, digest, signature)) {
            revert IAeroFarmingLogic.InvalidSignature();
        }
        if (_cancelledOrder[_cancelKey(account, digest)]) revert IAeroFarmingLogic.OrderCancelled();
    }

    function _digest(StructHash.Order memory o) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, StructHash._hash(o)));
    }

    /// @dev Keyed on the digest (not the signature bytes, which can be re-encoded) and scoped per actor.
    function _cancelKey(address actor, bytes32 digest) private pure returns (bytes32) {
        return keccak256(abi.encode(actor, digest));
    }

    /// @dev Same gauge check as the logic's: a factory gauge whose NFT manager is the factory's. Returns the NFPM.
    function _validateGauge(address gauge) internal view returns (address nfpm) {
        ICLGaugeFactory f = ICLGaugeFactory(AeroStorage.layout().gaugeFactory);
        if (!f.isGauge(gauge)) revert IAeroFarmingLogic.InvalidGauge();
        nfpm = ICLGauge(gauge).nft();
        if (nfpm != f.nft()) revert IAeroFarmingLogic.InvalidGauge();
    }

    function _bubble(bytes memory ret) private pure {
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }
}
