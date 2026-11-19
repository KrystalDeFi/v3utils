// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {V3UtilsRouter} from "../../../src/router/V3UtilsRouter.sol";
import {CoreModify} from "../../../src/router/modules/CoreModify.sol";
import {ICoreModify} from "../../../src/router/interfaces/ICoreModify.sol";
import {IRouterErrors} from "../../../src/router/IRouterErrors.sol";
import {
    PoolKey,
    Position,
    DecreaseParams,
    SwapParams,
    DecreaseAndSwapParams
} from "../../../src/router/RouterTypes.sol";
import {MockToken} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockModule.sol";

/// @dev Pool stand-in that short-pays: a decrease credits the gross amounts, and a collect pays them less `skimBps`
/// (a token that skims on transfer out of the pool). Holds its own state, so the delegatecalled adapter stays
/// stateless.
contract ShortPayPool {
    MockToken public immutable token0;
    MockToken public immutable token1;
    uint256 public immutable skimBps;
    uint256 public owed0;
    uint256 public owed1;

    constructor(MockToken token0_, MockToken token1_, uint256 skimBps_) {
        token0 = token0_;
        token1 = token1_;
        skimBps = skimBps_;
    }

    function credit(uint256 amount0, uint256 amount1) external {
        owed0 += amount0;
        owed1 += amount1;
    }

    function collect(address to) external returns (uint256 paid0, uint256 paid1) {
        paid0 = owed0 * (10_000 - skimBps) / 10_000;
        paid1 = owed1 * (10_000 - skimBps) / 10_000;
        owed0 = 0;
        owed1 = 0;
        token0.mint(to, paid0);
        token1.mint(to, paid1);
    }
}

/// @dev Adapter stand-in over a ShortPayPool (delegatecalled; config in immutables only). `decrease` behaves like a
/// v3 NFPM: it checks the minimums against the GROSS amounts it reports, then credits them to the pool.
contract ShortPayAdapter {
    ShortPayPool public immutable pool;
    uint128 public immutable liquidity;
    uint256 public immutable gross0;
    uint256 public immutable gross1;

    constructor(ShortPayPool pool_, uint128 liquidity_, uint256 gross0_, uint256 gross1_) {
        pool = pool_;
        liquidity = liquidity_;
        gross0 = gross0_;
        gross1 = gross1_;
    }

    function position(address, uint256) external payable returns (Position memory p) {
        p.key = PoolKey({
            token0: address(pool.token0()),
            token1: address(pool.token1()),
            fee: 500,
            tickSpacing: 10,
            deployer: address(0)
        });
        p.liquidity = liquidity;
    }

    function decrease(address, uint256, uint128, uint256 amount0Min, uint256 amount1Min, uint256)
        external
        payable
        returns (uint256, uint256)
    {
        require(gross0 >= amount0Min && gross1 >= amount1Min, "Price slippage check");
        pool.credit(gross0, gross1);
        return (gross0, gross1);
    }

    function collect(address, uint256) external payable returns (uint256, uint256) {
        return pool.collect(address(this));
    }
}

/// @notice decreaseAndSwap re-checks the decrease minimums against the principal that actually reached the router
/// (V3Utils #62), not only against the gross amounts the NFPM checks.
contract CoreModifySlippageTest is Test {
    uint128 internal constant LIQUIDITY = 1e18;
    uint256 internal constant GROSS0 = 1_000e18;
    uint256 internal constant GROSS1 = 2_000e6;
    uint256 internal constant SKIM_BPS = 100; // 1%
    uint256 internal constant TOKEN_ID = 1;

    address internal alice = makeAddr("slipAlice");
    address internal admin = makeAddr("slipAdmin");
    address internal deployer = makeAddr("slipDeployer");

    V3UtilsRouter internal router;
    MockERC721 internal nfpm;
    MockToken internal token0;
    MockToken internal token1;

    function setUp() public {
        token0 = new MockToken("T0", 18);
        token1 = new MockToken("T1", 6);
        nfpm = new MockERC721();
        ShortPayPool pool = new ShortPayPool(token0, token1, SKIM_BPS);
        address adapter = address(new ShortPayAdapter(pool, LIQUIDITY, GROSS0, GROSS1));

        vm.prank(deployer, deployer);
        router = new V3UtilsRouter();
        vm.prank(deployer, deployer);
        router.initialize(
            admin,
            makeAddr("slipOperator"),
            makeAddr("slipWithdrawer"),
            address(0),
            makeAddr("slipFeeTaker"),
            address(0xEE),
            0
        );
        CoreModify coreModify = new CoreModify();
        vm.startPrank(admin);
        router.setAdapter(address(nfpm), adapter);
        router.setModule(ICoreModify.decreaseAndSwap.selector, address(coreModify));
        vm.stopPrank();

        nfpm.mint(alice, TOKEN_ID);
        vm.prank(alice);
        nfpm.setApprovalForAll(address(router), true);
    }

    function _landed(uint256 gross) internal pure returns (uint256) {
        return gross * (10_000 - SKIM_BPS) / 10_000;
    }

    function _params(uint256 min0, uint256 min1) internal view returns (DecreaseAndSwapParams memory p) {
        p.nfpm = address(nfpm);
        p.tokenId = TOKEN_ID;
        p.decrease =
            DecreaseParams({liquidity: LIQUIDITY, amount0Min: min0, amount1Min: min1, deadline: block.timestamp});
        p.swaps = new SwapParams[](0);
        p.destToken = address(token1);
    }

    /// @dev Minimums at the gross amounts pass the NFPM-style check, but the collect delivers 1% less: revert,
    /// nothing moves.
    function test_decrease_shortPaidPrincipal_belowMins_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.SlippageError.selector);
        router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (_params(GROSS0, GROSS1))));
        assertEq(nfpm.ownerOf(TOKEN_ID), alice, "NFT stays with alice");

        // token1 alone short: still reverts
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.SlippageError.selector);
        router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (_params(_landed(GROSS0), GROSS1))));
    }

    /// @dev Minimums at what actually lands pass: the user gets the landed principal and the NFT back.
    function test_decrease_shortPaidPrincipal_withinMins_succeeds() public {
        vm.prank(alice);
        bytes memory ret =
            router.execute(abi.encodeCall(ICoreModify.decreaseAndSwap, (_params(_landed(GROSS0), _landed(GROSS1)))));

        assertEq(abi.decode(ret, (uint256)), _landed(GROSS1), "amountOut is the landed token1");
        assertEq(IERC20(address(token0)).balanceOf(alice), _landed(GROSS0), "landed token0 to the user");
        assertEq(IERC20(address(token1)).balanceOf(alice), _landed(GROSS1), "landed token1 to the user");
        assertEq(IERC721(address(nfpm)).ownerOf(TOKEN_ID), alice, "NFT back to the wallet");
    }
}
