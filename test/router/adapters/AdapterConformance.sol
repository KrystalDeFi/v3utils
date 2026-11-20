// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CoreBase} from "../../../src/router/base/CoreBase.sol";
import {IAdapter} from "../../../src/router/interfaces/IAdapter.sol";
import {PoolKey, Position} from "../../../src/router/RouterTypes.sol";
import {RouterTestBase} from "../RouterTestBase.sol";

/// @dev Test module: runs the adapter through the router the way a real module does (DELEGATECALL, so the adapter
/// acts as the router on the router's tokens). Registered behind a real router and reached via `execute`.
contract AdapterHarness is CoreBase {
    function mint(address nfpm, PoolKey calldata key, int24 lo, int24 hi, uint256 a0, uint256 a1)
        external
        onlyDelegateCall
        returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)
    {
        bytes memory r = _delegate(
            _adapter(nfpm), abi.encodeCall(IAdapter.mint, (nfpm, key, lo, hi, a0, a1, address(this), block.timestamp))
        );
        return abi.decode(r, (uint256, uint128, uint256, uint256));
    }

    function increase(address nfpm, uint256 tokenId, uint256 a0, uint256 a1)
        external
        onlyDelegateCall
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        bytes memory r = _delegate(
            _adapter(nfpm), abi.encodeCall(IAdapter.increase, (nfpm, tokenId, a0, a1, block.timestamp))
        );
        return abi.decode(r, (uint128, uint256, uint256));
    }

    function decrease(address nfpm, uint256 tokenId, uint128 liquidity)
        external
        onlyDelegateCall
        returns (uint256 a0, uint256 a1)
    {
        bytes memory r = _delegate(
            _adapter(nfpm), abi.encodeCall(IAdapter.decrease, (nfpm, tokenId, liquidity, 0, 0, block.timestamp))
        );
        return abi.decode(r, (uint256, uint256));
    }

    function collect(address nfpm, uint256 tokenId) external onlyDelegateCall returns (uint256 a0, uint256 a1) {
        bytes memory r = _delegate(_adapter(nfpm), abi.encodeCall(IAdapter.collect, (nfpm, tokenId)));
        return abi.decode(r, (uint256, uint256));
    }

    function position(address nfpm, uint256 tokenId) external onlyDelegateCall returns (Position memory) {
        return abi.decode(_delegate(_adapter(nfpm), abi.encodeCall(IAdapter.position, (nfpm, tokenId))), (Position));
    }

    function pool(address nfpm, PoolKey calldata key) external onlyDelegateCall returns (address) {
        return abi.decode(_delegate(_adapter(nfpm), abi.encodeCall(IAdapter.pool, (nfpm, key))), (address));
    }
}

/// @notice Conformance suite every protocol adapter inherits: mint -> increase -> decrease -> collect -> position ->
/// pool, through a harness module behind a real router, on a fork. A subclass provides the fork, the adapter and the
/// fixture; it must also leave the `weth` it deploys the router with usable (any address works, no swaps run here).
abstract contract AdapterConformance is RouterTestBase {
    struct Fixture {
        address nfpm;
        address adapter;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0; // budget for mint and for increase
        uint256 amount1;
        address expectedPool;
    }

    AdapterHarness internal harness;

    /// @dev Selects the fork (and anything chain-specific) and returns the fixture.
    function _setUpFixture() internal virtual returns (Fixture memory);

    Fixture internal f;

    function setUp() public virtual {
        f = _setUpFixture();
        _deployRouter(makeAddr("rtWeth"));
        harness = new AdapterHarness();
        _register(f.nfpm, f.adapter, address(0));
        bytes4[6] memory sels = [
            AdapterHarness.mint.selector,
            AdapterHarness.increase.selector,
            AdapterHarness.decrease.selector,
            AdapterHarness.collect.selector,
            AdapterHarness.position.selector,
            AdapterHarness.pool.selector
        ];
        for (uint256 i; i < sels.length; i++) {
            _registerModule(sels[i], address(harness));
        }
        deal(f.key.token0, address(router), f.amount0 * 2);
        deal(f.key.token1, address(router), f.amount1 * 2);
    }

    function _exec(bytes memory data) internal returns (bytes memory) {
        return router.execute(data);
    }

    function _bal(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(router));
    }

    function _position(uint256 tokenId) internal returns (Position memory) {
        return abi.decode(_exec(abi.encodeCall(AdapterHarness.position, (f.nfpm, tokenId))), (Position));
    }

    function test_conformance_mintIncreaseDecreaseCollect() public {
        uint256 tokenId;
        uint128 liq;
        {
            uint256 b0 = _bal(f.key.token0);
            uint256 b1 = _bal(f.key.token1);
            uint256 u0;
            uint256 u1;
            (tokenId, liq, u0, u1) = abi.decode(
                _exec(
                    abi.encodeCall(AdapterHarness.mint, (f.nfpm, f.key, f.tickLower, f.tickUpper, f.amount0, f.amount1))
                ),
                (uint256, uint128, uint256, uint256)
            );
            assertGt(liq, 0, "mint liquidity");
            assertEq(IERC721(f.nfpm).ownerOf(tokenId), address(router), "router owns the NFT");
            assertEq(b0 - _bal(f.key.token0), u0, "mint used0 reconciles");
            assertEq(b1 - _bal(f.key.token1), u1, "mint used1 reconciles");
        }
        _checkPosition(tokenId, liq);

        uint128 liq2 = _increase(tokenId);
        assertEq(_position(tokenId).liquidity, liq + liq2, "position liquidity after increase");

        uint128 half = (liq + liq2) / 2;
        (uint256 d0, uint256 d1) = _decrease(tokenId, half);
        assertEq(_position(tokenId).liquidity, liq + liq2 - half, "position liquidity after decrease");

        _collect(tokenId, d0, d1);
    }

    function _checkPosition(uint256 tokenId, uint128 liq) internal {
        Position memory p = _position(tokenId);
        assertEq(p.liquidity, liq, "position liquidity after mint");
        assertEq(p.tickLower, f.tickLower);
        assertEq(p.tickUpper, f.tickUpper);
        assertEq(p.key.token0, f.key.token0);
        assertEq(p.key.token1, f.key.token1);
        assertEq(p.key.fee, f.key.fee);
        assertEq(p.key.deployer, f.key.deployer);
        assertEq(p.key.tickSpacing, f.key.tickSpacing, "tickSpacing read from the pool");
    }

    function _increase(uint256 tokenId) internal returns (uint128 liq2) {
        uint256 b0 = _bal(f.key.token0);
        uint256 b1 = _bal(f.key.token1);
        uint256 i0;
        uint256 i1;
        (liq2, i0, i1) = abi.decode(
            _exec(abi.encodeCall(AdapterHarness.increase, (f.nfpm, tokenId, f.amount0, f.amount1))),
            (uint128, uint256, uint256)
        );
        assertGt(liq2, 0, "increase liquidity");
        assertEq(b0 - _bal(f.key.token0), i0, "increase used0 reconciles");
        assertEq(b1 - _bal(f.key.token1), i1, "increase used1 reconciles");
    }

    /// @dev The amounts become owed to the position; nothing is paid yet.
    function _decrease(uint256 tokenId, uint128 liquidity) internal returns (uint256 d0, uint256 d1) {
        uint256 b0 = _bal(f.key.token0);
        uint256 b1 = _bal(f.key.token1);
        (d0, d1) = abi.decode(
            _exec(abi.encodeCall(AdapterHarness.decrease, (f.nfpm, tokenId, liquidity))), (uint256, uint256)
        );
        assertEq(_bal(f.key.token0), b0, "decrease pays nothing");
        assertEq(_bal(f.key.token1), b1, "decrease pays nothing");
    }

    /// @dev No swaps run, so no fees accrue: collect returns the decrease principal.
    function _collect(uint256 tokenId, uint256 d0, uint256 d1) internal {
        uint256 b0 = _bal(f.key.token0);
        uint256 b1 = _bal(f.key.token1);
        (uint256 c0, uint256 c1) =
            abi.decode(_exec(abi.encodeCall(AdapterHarness.collect, (f.nfpm, tokenId))), (uint256, uint256));
        assertEq(_bal(f.key.token0) - b0, c0, "collect0 reconciles");
        assertEq(_bal(f.key.token1) - b1, c1, "collect1 reconciles");
        assertGe(c0, d0, "collect covers decrease0");
        assertGe(c1, d1, "collect covers decrease1");
        assertGt(c0 + c1, 0, "something collected");
    }

    function test_conformance_poolLookup() public {
        address pool = abi.decode(_exec(abi.encodeCall(AdapterHarness.pool, (f.nfpm, f.key))), (address));
        assertEq(pool, f.expectedPool, "pool(key)");
    }

    function test_conformance_allowanceReset() public {
        (uint256 tokenId,,,) = abi.decode(
            _exec(abi.encodeCall(AdapterHarness.mint, (f.nfpm, f.key, f.tickLower, f.tickUpper, f.amount0, f.amount1))),
            (uint256, uint128, uint256, uint256)
        );
        assertEq(IERC20(f.key.token0).allowance(address(router), f.nfpm), 0, "allowance0 after mint");
        assertEq(IERC20(f.key.token1).allowance(address(router), f.nfpm), 0, "allowance1 after mint");

        _exec(abi.encodeCall(AdapterHarness.increase, (f.nfpm, tokenId, f.amount0, f.amount1)));
        assertEq(IERC20(f.key.token0).allowance(address(router), f.nfpm), 0, "allowance0 after increase");
        assertEq(IERC20(f.key.token1).allowance(address(router), f.nfpm), 0, "allowance1 after increase");
    }
}
