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
import "./IAero.sol";

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
        address indexed nfpm,
        uint256 indexed tokenId,
        address indexed userAddress,
        Common.DeductFeesEventData data
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

    /// @dev Task 2 replaces this with the real guard.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        revert UnexpectedNft();
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
