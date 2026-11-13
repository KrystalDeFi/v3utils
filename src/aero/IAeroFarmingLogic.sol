// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../Common.sol";
import "../V3Utils.sol";

/// @notice ABI of AeroFarmingLogic. Never call these on the logic itself: users encode a call with
/// `abi.encodeCall(IAeroFarmingLogic.<fn>, (...))` and pass it to `AeroFarmingRouter.execute`, which delegatecalls
/// the logic, so `msg.sender` is the user and events are emitted by the router address.
/// `executeAutomated` is reachable only through `AeroFarmingRouter.executeAutomation` (operator path).
interface IAeroFarmingLogic {
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
    error SlippageError();
    error SwapFailed(bytes swapData, uint256 index);
    /// @dev A logic function was called on the logic contract itself instead of through the router.
    error NotDelegateCall();
    /// @dev `executeAutomated` was reached without the router's executeAutomation recording `account`.
    error NotAutomation();
    /// @dev After a rebalance V3Utils did not return exactly the old NFT plus one new position with the requested range.
    error RebalanceMismatch();

    /// @notice Zap tokens (and/or native coin) into a new Aero CL position and stake it in `gauge` for the caller.
    function zapInAndStake(address gauge, Common.SwapAndMintParams memory p, bool unwrap)
        external
        payable
        returns (uint256 tokenId);

    /// @notice Add liquidity to a staked position: unstake, increase through V3Utils, restake. Leftovers go back to
    /// the caller.
    function addLiquidity(address gauge, Common.SwapAndIncreaseLiquidityParams memory p, bool unwrap) external payable;

    /// @notice Withdraw part of a staked position's liquidity (and collect fees); the NFT is restaked under the same id.
    /// @dev Reverts GaugeNotLive on a dead gauge because the restake needs a live gauge; `exit` is the way out.
    function removeLiquidity(address gauge, uint256 tokenId, V3Utils.Instructions memory ins) external;

    /// @notice Withdraw all liquidity of a staked position and return the (empty) NFT, unstaked, to the caller.
    function exit(address gauge, uint256 tokenId, V3Utils.Instructions memory ins) external;

    /// @notice Move a staked position to a new range: V3Utils mints the new position, which is staked for the caller.
    /// The old (emptied) NFT is returned, unstaked, to the caller.
    function rebalance(address gauge, uint256 tokenId, V3Utils.Instructions memory ins)
        external
        returns (uint256 newTokenId);

    /// @notice Claim the position's AERO emissions, take the performance fee and add the rest back to the position
    /// (Base only). Requires the caller to have approved the router with `approveForClaim` on the gauge.
    function compound(address gauge, uint256 tokenId, CompoundParams memory p) external;

    /// @notice Operator path; the router builds this call itself after checking the gauge, the stake owner and the
    /// signed order, and records `account` for the duration of the call.
    function executeAutomated(
        AutoAction action,
        address account,
        address gauge,
        uint256 tokenId,
        bytes calldata actionData
    ) external returns (uint256 tokenIdAfter);
}
