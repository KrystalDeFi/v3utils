// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function depositFor(uint256 tokenId, address recipient) external;
    function withdrawFrom(uint256 tokenId, address account) external;
    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external;
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
    function stakedByIndex(address depositor, uint256 index) external view returns (uint256);
    function nft() external view returns (address);
    function pool() external view returns (address);
    function earned(address account, uint256[] calldata tokenIds) external view returns (uint256);
}

interface ICLGaugeFactory {
    function isGauge(address gauge) external view returns (bool);
    function nft() external view returns (address);
    function leafVoter() external view returns (address);
    function effectivePenaltyConfig(address gauge) external view returns (uint256 minStakeBlocks, uint256 penaltyRate);
}

/// @dev Aero CL position manager: `positions` returns tickSpacing where Uniswap v3 returns fee.
interface IAeroNfpm {
    function factory() external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface ICLPool {
    function gauge() external view returns (address);
}

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

interface ILeafVoter {
    function isActivated(address gauge) external view returns (bool);
    function RECEIPT_TOKEN() external view returns (address);
}

interface IStructHash {
    function _hash(bytes memory abiEncodedUserOrder) external pure returns (bytes32);
}
