// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Fee labels, in v4utils' order so the backend's `TakeFees` decoding applies unchanged.
enum FeeType {
    GAS_FEE,
    PERFORMANCE_FEE,
    PROTOCOL_FEE
}

/// @notice What the operator runs under a signed order. Each maps to one flow (see `V3UtilsRouter`).
enum AutoAction {
    AUTO_ADJUST,
    AUTO_EXIT,
    AUTO_COMPOUND,
    AUTO_HARVEST
}

/// @notice One swap through the router's `swapRouter`. Native is `address(0)`.
struct SwapParams {
    address tokenIn;
    uint256 amountIn;
    address tokenOut;
    uint256 amountOutMin;
    bytes swapData;
}

/// @notice A token the caller brings into a flow. Native is `address(0)`.
struct InputTokenParams {
    address token;
    uint256 amount;
}

/// @notice A pool, protocol-neutral: v3 (`fee`), Algebra/Aero (`tickSpacing`) and Algebra Integral (`deployer`)
/// each read the fields they need.
struct PoolKey {
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    address deployer;
}

/// @notice A position as an adapter decodes it from its NFPM.
struct Position {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

struct MintParams {
    int24 tickLower;
    int24 tickUpper;
    uint256 minLiquidity;
    uint256 deadline;
}

struct IncreaseParams {
    uint256 minLiquidity;
    uint256 deadline;
}

struct DecreaseParams {
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

struct SwapAndMintParams {
    address nfpm;
    PoolKey key;
    MintParams mint;
    InputTokenParams[] inputTokens;
    SwapParams[] swaps;
    bool stake;
    uint64 protocolFeeX64;
    uint64 gasFeeX64;
}

struct SwapAndIncreaseParams {
    address nfpm;
    uint256 tokenId;
    IncreaseParams increase;
    InputTokenParams[] inputTokens;
    SwapParams[] swaps;
    uint64 protocolFeeX64;
    /// @dev PERFORMANCE_FEE on the farm rewards an unstake of a staked position pays the router (v4utils field order).
    uint64 performanceFeeX64;
    uint64 gasFeeX64;
}

struct DecreaseAndSwapParams {
    address nfpm;
    uint256 tokenId;
    DecreaseParams decrease;
    SwapParams[] swaps;
    address destToken;
    uint64 protocolFeeX64;
    uint64 performanceFeeX64;
    uint64 gasFeeX64;
}

struct AdjustRangeParams {
    address nfpm;
    uint256 tokenId;
    SwapParams[] swaps;
    MintParams mint;
    bool compoundFees;
    uint64 protocolFeeX64;
    uint64 performanceFeeX64;
    uint64 gasFeeX64;
}

struct CompoundParams {
    address nfpm;
    uint256 tokenId;
    SwapParams[] swaps;
    IncreaseParams increase;
    uint64 performanceFeeX64;
}

struct HarvestParams {
    address nfpm;
    uint256 tokenId;
    SwapParams[] swaps;
    address destToken;
    uint64 performanceFeeX64;
}
