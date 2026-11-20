// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SignatureValidator} from "@krystal/util-contracts/contracts/SignatureValidator.sol";
import {StructHash} from "../StructHash.sol";
import {FeeType} from "./RouterTypes.sol";
import {RouterStorage} from "./RouterStorage.sol";
import {IRouterErrors} from "./IRouterErrors.sol";
import {IFarm} from "./interfaces/IFarm.sol";

/// @notice Fixed (non-upgradeable) entry point for every v3-style position, staked or not; it is the address users
/// approve on NFPMs and farms. Flows run in modules chosen by selector, by DELEGATECALL, through two entry points:
/// `execute` (users; msg.sender is the account) and `executeAutomation` (operator, under a signed order). Modules
/// delegatecall a per-NFPM adapter and an optional per-NFPM farm. Roles, pause, reentrancy, order checks, cancel,
/// rescue and the NFT receive guard live here.
/// @dev Shared config and flow state is in the `RouterStorage` slot. The router's own storage (roles, pause,
/// reentrancy, cancelled orders) is never written by delegatecalled code, which declares no storage.
///
/// Roles: DEFAULT_ADMIN_ROLE administers roles; ADMIN_ROLE sets registries and config, pauses and locks;
/// OPERATOR_ROLE runs signed orders; WITHDRAWER_ROLE rescues stray assets.
/// @custom:security ADMIN_ROLE has custody-level power over every approving user's positions until `lock()`, and
/// DEFAULT_ADMIN_ROLE can grant itself ADMIN_ROLE, so it carries the same power; hold both behind a timelock.
/// A signed order binds only the chain and the NFPM, not the action, tokenId or actionData: OPERATOR_ROLE is trusted to
/// run only what the account's order describes.
contract V3UtilsRouter is AccessControl, Pausable, ReentrancyGuard, IERC721Receiver, IRouterErrors {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 internal constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 domain separator of signed orders (name "V3UtilsRouter", version "1", this router).
    bytes32 public immutable DOMAIN_SEPARATOR;
    /// @dev The deploying tx.origin: the only address allowed to call `initialize` (front-run guard, as in Common).
    address private immutable _initializer;

    bool private _initialized;
    mapping(bytes32 => bool) private _cancelledOrder;

    event ModuleSet(bytes4 indexed selector, address module);
    event AdapterSet(address indexed nfpm, address adapter);
    event FarmSet(address indexed nfpm, address farm);
    event AutoSelectorSet(uint8 indexed action, bytes4 selector);
    event SwapRouterSet(address swapRouter);
    event FeeTakerSet(address feeTaker);
    event NativeConfigSet(address weth, uint8 nativeMode, uint256 nativeScale);
    event MaxFeeSet(FeeType feeType, uint64 maxFeeX64);
    event LockedForever();
    event CancelOrder(address user, bytes32 hash, bytes signature);

    constructor() {
        _initializer = tx.origin;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPE_HASH, keccak256("V3UtilsRouter"), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @notice Grants DEFAULT_ADMIN_ROLE + ADMIN_ROLE to `admin`, OPERATOR_ROLE to `operator` and WITHDRAWER_ROLE
    /// to `withdrawer`; the caller gets no role of its own (the deploy script passes itself as `admin`, registers, then
    /// hands both admin roles to the real admin and renounces them). Sets the config and the default fee caps.
    /// @param nativeMode_ 0 = WRAPPED (`weth` is a WETH9-style wrapper), 1 = ENSHRINED (`weth` is an ERC20 view of
    /// native; the scale comes from its decimals).
    function initialize(
        address admin,
        address operator,
        address withdrawer,
        address swapRouter_,
        address feeTaker_,
        address weth_,
        uint8 nativeMode_
    ) external {
        if (msg.sender != _initializer) revert NotInitializer();
        if (_initialized) revert AlreadyInitialized();
        if (admin == address(0) || feeTaker_ == address(0)) revert ZeroAddress();
        _initialized = true;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(WITHDRAWER_ROLE, withdrawer);
        _setNativeConfig(weth_, nativeMode_);
        _checkSwapRouter(swapRouter_);
        RouterStorage.Layout storage s = RouterStorage.layout();
        s.swapRouter = swapRouter_;
        s.feeTaker = feeTaker_;
        s.maxFeeX64[uint8(FeeType.GAS_FEE)] = 5534023222112865280; // 30%
        s.maxFeeX64[uint8(FeeType.PROTOCOL_FEE)] = 5534023222112865280; // 30%
        s.maxFeeX64[uint8(FeeType.PERFORMANCE_FEE)] = 5902958103587057000; // 32% = 30% gas + 2% protocol
        emit SwapRouterSet(swapRouter_);
        emit FeeTakerSet(feeTaker_);
    }

    // ---------------------------------------------------------------- entry points

    /// @notice User entry point: DELEGATECALLs the module registered for `data`'s selector with `data` and returns its
    /// raw return data; reverts bubble unchanged.
    function execute(bytes calldata data) external payable nonReentrant whenNotPaused returns (bytes memory) {
        // truncating to the selector is the point; data shorter than 4 bytes pads with zeros and finds no module
        // forge-lint: disable-next-line(unsafe-typecast)
        return _delegate(bytes4(data), data);
    }

    /// @notice Operator entry point: runs `action` on `account`'s position `tokenId` of `nfpm` under an order `account`
    /// signed. The flow mapped to `action` (`autoSelector`) gets `actionData` as its params and reads `account` from the
    /// record set here. `action` is a `uint8` (off-chain: `AutoAction`), so new actions or param structs need only a
    /// module and a mapping, never a new router.
    /// @dev The order binds the chain and `nfpm`, not the tokenId (recurring rebalances mint new ids); flows check
    /// that their params target the recorded `(nfpm, tokenId)`. An unmapped action, or a mapped selector with no
    /// module, reverts `UnknownSelector()`.
    function executeAutomation(
        address account,
        address nfpm,
        uint256 tokenId,
        uint8 action,
        bytes calldata actionData,
        bytes calldata order,
        bytes calldata signature
    ) external onlyRole(OPERATOR_ROLE) nonReentrant whenNotPaused returns (bytes memory ret) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        if (s.adapter[nfpm] == address(0)) revert UnsupportedNfpm();
        if (!_isHolder(s.farm[nfpm], account, nfpm, tokenId)) revert NotPositionHolder();
        _validateOrder(account, nfpm, order, signature);

        bytes4 sel = s.autoSelector[action];
        if (sel == bytes4(0)) revert UnknownSelector();

        s.automationAccount = account;
        s.automationTarget = keccak256(abi.encode(nfpm, tokenId));
        ret = _delegate(sel, abi.encodePacked(sel, actionData));
        s.automationAccount = address(0);
        s.automationTarget = bytes32(0);
    }

    // ---------------------------------------------------------------- orders

    /// @notice EIP-712 digest of an abi-encoded `StructHash.Order`.
    function hashOrder(bytes calldata order) external view returns (bytes32) {
        return _digest(abi.decode(order, (StructHash.Order)));
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

    // ---------------------------------------------------------------- registries (frozen by lock)

    /// @notice Registers the module `execute` delegatecalls for `selector`; `address(0)` unregisters.
    function setModule(bytes4 selector, address module_) external onlyRole(ADMIN_ROLE) {
        _checkTarget(module_);
        RouterStorage.layout().module[selector] = module_;
        emit ModuleSet(selector, module_);
    }

    /// @notice Registers the protocol adapter for `nfpm`; `address(0)` unregisters.
    function setAdapter(address nfpm, address adapter_) external onlyRole(ADMIN_ROLE) {
        _checkTarget(adapter_);
        RouterStorage.layout().adapter[nfpm] = adapter_;
        emit AdapterSet(nfpm, adapter_);
    }

    /// @notice Registers the farm for `nfpm`; `address(0)` unregisters.
    function setFarm(address nfpm, address farm_) external onlyRole(ADMIN_ROLE) {
        _checkTarget(farm_);
        RouterStorage.layout().farm[nfpm] = farm_;
        emit FarmSet(nfpm, farm_);
    }

    /// @notice Maps automation `action` (off-chain: `uint8(AutoAction)`) to the flow selector `executeAutomation`
    /// runs; `bytes4(0)` unmaps it. The selector's module comes from `module`, as for `execute`.
    function setAutoSelector(uint8 action, bytes4 selector) external onlyRole(ADMIN_ROLE) {
        if (RouterStorage.layout().locked) revert Locked();
        RouterStorage.layout().autoSelector[action] = selector;
        emit AutoSelectorSet(action, selector);
    }

    // ---------------------------------------------------------------- config

    /// @dev Frozen by lock: swaps run `swapRouter.call(swapData)` as the router, which holds users' approvals.
    /// `address(0)` turns swaps off; any other address needs code.
    function setSwapRouter(address swapRouter_) external onlyRole(ADMIN_ROLE) {
        if (RouterStorage.layout().locked) revert Locked();
        _checkSwapRouter(swapRouter_);
        RouterStorage.layout().swapRouter = swapRouter_;
        emit SwapRouterSet(swapRouter_);
    }

    function setNativeConfig(address weth_, uint8 nativeMode_) external onlyRole(ADMIN_ROLE) {
        if (RouterStorage.layout().locked) revert Locked();
        _setNativeConfig(weth_, nativeMode_);
    }

    /// @dev Never frozen: the fee taker only receives capped fees and holds no custody.
    function setFeeTaker(address feeTaker_) external onlyRole(ADMIN_ROLE) {
        if (feeTaker_ == address(0)) revert ZeroAddress();
        RouterStorage.layout().feeTaker = feeTaker_;
        emit FeeTakerSet(feeTaker_);
    }

    /// @notice After lock, a cap can only go down.
    function setMaxFeeX64(FeeType feeType, uint64 maxFeeX64_) external onlyRole(ADMIN_ROLE) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        if (s.locked && maxFeeX64_ > s.maxFeeX64[uint8(feeType)]) revert Locked();
        s.maxFeeX64[uint8(feeType)] = maxFeeX64_;
        emit MaxFeeSet(feeType, maxFeeX64_);
    }

    /// @notice One-way: freezes the registries (module, adapter, farm, autoSelector), `swapRouter` and the native config;
    /// fee caps can then only go down.
    function lock() external onlyRole(ADMIN_ROLE) {
        RouterStorage.layout().locked = true;
        emit LockedForever();
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------- rescue

    function withdrawERC20(IERC20 token, address to) external onlyRole(WITHDRAWER_ROLE) {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    function withdrawERC721(IERC721 nft, uint256 tokenId, address to) external onlyRole(WITHDRAWER_ROLE) {
        nft.safeTransferFrom(address(this), to, tokenId);
    }

    function withdrawNative(address to) external onlyRole(WITHDRAWER_ROLE) {
        (bool ok,) = to.call{value: address(this).balance}("");
        if (!ok) revert NativeTransferFailed();
    }

    // ---------------------------------------------------------------- views

    function module(bytes4 selector) external view returns (address) {
        return RouterStorage.layout().module[selector];
    }

    function adapter(address nfpm) external view returns (address) {
        return RouterStorage.layout().adapter[nfpm];
    }

    function farm(address nfpm) external view returns (address) {
        return RouterStorage.layout().farm[nfpm];
    }

    function autoSelector(uint8 action) external view returns (bytes4) {
        return RouterStorage.layout().autoSelector[action];
    }

    function swapRouter() external view returns (address) {
        return RouterStorage.layout().swapRouter;
    }

    function feeTaker() external view returns (address) {
        return RouterStorage.layout().feeTaker;
    }

    function maxFeeX64(FeeType feeType) external view returns (uint64) {
        return RouterStorage.layout().maxFeeX64[uint8(feeType)];
    }

    function weth() external view returns (address) {
        return RouterStorage.layout().weth;
    }

    function locked() external view returns (bool) {
        return RouterStorage.layout().locked;
    }

    function nativeMode() external view returns (uint8) {
        return RouterStorage.layout().nativeMode;
    }

    function nativeScale() external view returns (uint256) {
        return RouterStorage.layout().nativeScale;
    }

    // ---------------------------------------------------------------- receivers

    /// @dev Accepts an NFT only from a registered NFPM and only the one a farm recorded in `expectedNft` before
    /// bringing it in.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        RouterStorage.Layout storage s = RouterStorage.layout();
        if (s.adapter[msg.sender] == address(0) || s.expectedNft != keccak256(abi.encode(msg.sender, from, tokenId))) {
            revert UnexpectedNft();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev While a flow runs (`execute` / `executeAutomation` hold the reentrancy guard), accepts native from anyone:
    /// an aggregator step that outputs native, a swap router's native refund, a farm or NFPM paying native. The flow's
    /// ledger credits the call only its own balance delta, and `_close` sweeps it to the account when native is tracked
    /// (a swap's `tokenOut` always is); native an untracking flow receives stays in the router as stray (rescue).
    /// Outside a flow, only `weth` unwrapping, so only while WRAPPED.
    receive() external payable {
        if (_reentrancyGuardEntered()) return;
        RouterStorage.Layout storage s = RouterStorage.layout();
        if (msg.sender != s.weth || s.nativeMode != RouterStorage.NATIVE_WRAPPED) revert UnexpectedNative();
    }

    // ---------------------------------------------------------------- internals

    /// @dev DELEGATECALLs the module for `selector` with `data`; reverts bubble unchanged.
    /// Clears `expectedNft` afterwards, so a record a module left behind never outlives the call.
    function _delegate(bytes4 selector, bytes memory data) private returns (bytes memory ret) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        address target = s.module[selector];
        if (target == address(0)) revert UnknownSelector();
        bool ok;
        (ok, ret) = target.delegatecall(data);
        if (!ok) _bubble(ret);
        s.expectedNft = bytes32(0);
    }

    /// @dev `account` holds `tokenId` if it owns the NFT or, failing that, the farm reports it staked by `account`.
    /// The wallet check comes first, so a farm that reverts never blocks a wallet holder.
    function _isHolder(address farm_, address account, address nfpm, uint256 tokenId) private returns (bool) {
        if (IERC721(nfpm).ownerOf(tokenId) == account) return true;
        if (farm_ == address(0)) return false;
        (bool ok, bytes memory ret) = farm_.delegatecall(abi.encodeCall(IFarm.isStakedBy, (nfpm, tokenId, account)));
        if (!ok) _bubble(ret);
        return abi.decode(ret, (bool));
    }

    function _setNativeConfig(address weth_, uint8 nativeMode_) private {
        if (weth_ == address(0)) revert ZeroAddress();
        uint256 scale = 1;
        if (nativeMode_ == RouterStorage.NATIVE_ENSHRINED) {
            uint8 decimals = IERC20Metadata(weth_).decimals();
            if (decimals > 18) revert InvalidNativeConfig();
            scale = 10 ** (18 - decimals);
        } else if (nativeMode_ != RouterStorage.NATIVE_WRAPPED) {
            revert InvalidNativeConfig();
        }
        RouterStorage.Layout storage s = RouterStorage.layout();
        s.weth = weth_;
        s.nativeMode = nativeMode_;
        s.nativeScale = scale;
        emit NativeConfigSet(weth_, nativeMode_, scale);
    }

    /// @dev `address(0)` (swaps off) or an address with code. Swaps re-check for code, since this can change later.
    function _checkSwapRouter(address swapRouter_) private view {
        if (swapRouter_ != address(0) && swapRouter_.code.length == 0) revert InvalidTarget();
    }

    /// @dev Non-zero targets need code; any target is refused after lock.
    function _checkTarget(address target) private view {
        if (RouterStorage.layout().locked) revert Locked();
        if (target != address(0) && target.code.length == 0) revert InvalidTarget();
    }

    /// @dev Chain and position manager binding, then: `account` signed the order and has not cancelled it.
    function _validateOrder(address account, address nfpm, bytes calldata order, bytes calldata signature)
        private
        view
    {
        StructHash.Order memory o = abi.decode(order, (StructHash.Order));
        if (o.chainId != int64(int256(block.chainid))) revert WrongChainId();
        if (o.nfpmAddress != nfpm) revert WrongPositionManager();
        bytes32 digest = _digest(o);
        if (!SignatureValidator.isValidSignatureNow(account, digest, signature)) revert InvalidSignature();
        if (_cancelledOrder[_cancelKey(account, digest)]) revert OrderCancelled();
    }

    function _digest(StructHash.Order memory o) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, StructHash._hash(o)));
    }

    /// @dev Keyed on the digest (not the signature bytes, which can be re-encoded) and scoped per actor.
    function _cancelKey(address actor, bytes32 digest) private pure returns (bytes32) {
        return keccak256(abi.encode(actor, digest));
    }

    function _bubble(bytes memory ret) private pure {
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }
}
