// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/Common.sol";

contract MockToken is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A Ramses v3 position manager reduced to what the reward forward touches. The gauge reward goes to whoever holds
///      the NFT, both through `getReward` and on every liquidity change, and a claim the reward validator flags is
///      forfeited. `collect` pays what the position owes.
contract MockRamsesNfpm {
    address public constant FORFEIT_SINK = address(0xF0F0);

    MockToken public immutable reward;
    MockToken public immutable token0;
    MockToken public immutable token1;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public pending;
    mapping(uint256 => uint256) public principal0;
    mapping(uint256 => uint256) public owed0;
    mapping(uint256 => uint256) public owed1;
    // getReward reverts (a pool without a gauge, or any other claim failure) while a liquidity change still claims
    bool public claimReverts;
    // the reward validator flags every claim (made too soon after the last liquidity change)
    bool public forfeits;

    constructor(MockToken _reward, MockToken _token0, MockToken _token1) {
        reward = _reward;
        token0 = _token0;
        token1 = _token1;
    }

    function setPosition(
        uint256 tokenId,
        address holder,
        uint256 _pending,
        uint256 _principal0,
        uint256 _owed0,
        uint256 _owed1
    ) external {
        ownerOf[tokenId] = holder;
        pending[tokenId] = _pending;
        principal0[tokenId] = _principal0;
        owed0[tokenId] = _owed0;
        owed1[tokenId] = _owed1;
    }

    function setFlags(bool _claimReverts, bool _forfeits) external {
        claimReverts = _claimReverts;
        forfeits = _forfeits;
    }

    function getReward(uint256 tokenId, address[] calldata tokens) external {
        require(msg.sender == ownerOf[tokenId], "not authorized");
        require(!claimReverts, "no gauge");
        require(tokens.length == 1 && tokens[0] == address(reward), "unexpected tokens");
        _claim(tokenId);
    }

    function decreaseLiquidity(IUniV3NonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        require(msg.sender == ownerOf[params.tokenId], "not authorized");
        // Ramses claims the reward for the holder on every liquidity change
        _claim(params.tokenId);
        return (principal0[params.tokenId], 0);
    }

    function collect(IUniV3NonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        require(msg.sender == ownerOf[params.tokenId], "not authorized");
        amount0 = owed0[params.tokenId];
        amount1 = owed1[params.tokenId];
        owed0[params.tokenId] = 0;
        owed1[params.tokenId] = 0;
        if (amount0 != 0) token0.mint(params.recipient, amount0);
        if (amount1 != 0) token1.mint(params.recipient, amount1);
    }

    function _claim(uint256 tokenId) private {
        uint256 amount = pending[tokenId];
        pending[tokenId] = 0;
        if (amount != 0) reward.mint(forfeits ? FORFEIT_SINK : ownerOf[tokenId], amount);
    }
}

/// @dev Common's custody step, exposed: like V3Utils and V3Automation, it only runs on a whitelisted position manager,
///      while it holds the NFT.
contract RewardForwardHarness is Common {
    constructor(address admin) {
        _grantRole(ADMIN_ROLE, admin);
    }

    function decreaseAndCollect(
        INonfungiblePositionManager nfpm,
        address user,
        IERC20 token0,
        IERC20 token1,
        uint256 tokenId,
        uint128 liquidity,
        uint64 performanceFeeX64
    ) external returns (uint256 collected0, uint256 collected1, uint256 fee0, uint256 fee1) {
        require(_isWhitelistedNfpm(address(nfpm)));
        return _decreaseLiquidityAndCollectFees(
            DecreaseAndCollectFeesParams(
                nfpm, user, token0, token1, tokenId, liquidity, block.timestamp, 0, 0, false, performanceFeeX64
            )
        );
    }
}

/// @notice Fork-free checks of the Ramses reward forward in Common._decreaseLiquidityAndCollectFees. forge fuzzes them,
///         and halmos proves them: `halmos --contract RamsesRewardForwardTest --function testFuzz`. Expected amounts come
///         from the mock's ledger, not from the contract.
contract RamsesRewardForwardTest is Test {
    struct Op {
        uint96 pending;
        uint96 principal0;
        uint96 owed0;
        uint96 owed1;
        uint128 liquidity;
        bool configured;
        bool claimReverts;
        bool forfeits;
        bool overlap;
        uint64 feeX64;
    }

    address constant USER = address(0xBEEF);
    address constant FEE_TAKER = address(0xFEE);
    uint64 constant MAX_PERFORMANCE_FEE_X64 = 5902958103587057000; // 32%, Common's maximum
    uint256 constant TOKEN_ID = 1;

    MockToken reward;
    MockRamsesNfpm nfpm; // the reward token isn't one of the position's tokens
    MockRamsesNfpm overlapNfpm; // the reward token is also token0
    RewardForwardHarness harness;

    function setUp() public {
        reward = new MockToken("RAM");
        MockToken other0 = new MockToken("T0");
        MockToken other1 = new MockToken("T1");
        nfpm = new MockRamsesNfpm(reward, other0, other1);
        overlapNfpm = new MockRamsesNfpm(reward, reward, other1);
        harness = new RewardForwardHarness(address(this));
        address[] memory nfpms = new address[](2);
        nfpms[0] = address(nfpm);
        nfpms[1] = address(overlapNfpm);
        harness.setWhitelistNfpm(nfpms, true);
        harness.setFeeTaker(FEE_TAKER);
    }

    /// flags: 1 = the claim reverts, 2 = the claim is forfeited, 4 = the reward token is also token0,
    /// 8 = the reward token is configured
    function testFuzz_forward(
        uint96 pending,
        uint96 held,
        uint96 principal0,
        uint96 owed0,
        uint96 owed1,
        uint128 liquidity,
        uint8 flags
    ) public {
        Op memory op;
        op.pending = pending;
        op.principal0 = principal0;
        op.owed0 = owed0;
        op.owed1 = owed1;
        op.liquidity = liquidity;
        op.claimReverts = flags & 1 != 0;
        op.forfeits = flags & 2 != 0;
        op.overlap = flags & 4 != 0;
        op.configured = flags & 8 != 0;
        MockRamsesNfpm m = op.overlap ? overlapNfpm : nfpm;
        if (op.configured) harness.setPositionRewardToken(address(m), address(reward));
        // a stray reward balance (earlier leaks): an operation must never pay it out
        reward.mint(address(harness), held);
        _run(m, op);
    }

    // like the collected fees, the reward pays the operation's performance fee: the fee taker gets it, the user the rest
    function testFeeIsTakenOnTheForwardedReward(uint96 pending, uint96 held, uint64 feeX64) public {
        vm.assume(feeX64 <= MAX_PERFORMANCE_FEE_X64);
        Op memory op;
        op.pending = pending;
        op.liquidity = 1;
        op.configured = true;
        op.feeX64 = feeX64;
        harness.setPositionRewardToken(address(nfpm), address(reward));
        reward.mint(address(harness), held);
        _run(nfpm, op);
    }

    function testRevertsWhenTheFeeIsAboveTheMaximum(uint64 feeX64) public {
        vm.assume(feeX64 > MAX_PERFORMANCE_FEE_X64);
        harness.setPositionRewardToken(address(nfpm), address(reward));
        nfpm.setPosition(TOKEN_ID, address(harness), 1e18, 0, 0, 0);
        (IERC20 token0, IERC20 token1) = (nfpm.token0(), nfpm.token1());
        vm.expectRevert(Common.TooMuchFee.selector);
        harness.decreaseAndCollect(
            INonfungiblePositionManager(address(nfpm)), USER, token0, token1, TOKEN_ID, 1, feeX64
        );
    }

    function testFuzz_onlyAdminSetsRewardToken(address caller, address someNfpm, address token) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        try harness.setPositionRewardToken(someNfpm, token) {
            assertTrue(false, "a non-admin set the reward token");
        } catch {}
        harness.setPositionRewardToken(someNfpm, token);
        assertEq(harness.positionRewardToken(someNfpm), token);
    }

    function _run(MockRamsesNfpm m, Op memory op) internal {
        m.setPosition(TOKEN_ID, address(harness), op.pending, op.principal0, op.owed0, op.owed1);
        m.setFlags(op.claimReverts, op.forfeits);
        uint256 held = reward.balanceOf(address(harness));

        try harness.decreaseAndCollect(
            INonfungiblePositionManager(address(m)), USER, m.token0(), m.token1(), TOKEN_ID, op.liquidity, op.feeX64
        ) returns (
            uint256 collected0, uint256 collected1, uint256 fee0, uint256
        ) {
            // the user gets exactly the pending reward when its claim goes through, less the performance fee, which
            // goes to the fee taker; nothing otherwise
            bool claimed = op.configured && !op.claimReverts;
            uint256 fee = (claimed && !op.forfeits ? uint256(op.pending) * op.feeX64 : 0) >> 64;
            assertEq(reward.balanceOf(USER), (claimed && !op.forfeits ? op.pending : 0) - fee, "user's reward");
            assertEq(reward.balanceOf(FEE_TAKER), fee, "fee");
            // the contract keeps what it already held. It gains only what a liquidity change claims when nothing was
            // claimed first (the old leak) and, when the reward token is token0, the collected token0
            uint256 leaked = !claimed && op.liquidity != 0 && !op.forfeits ? op.pending : 0;
            assertEq(reward.balanceOf(address(harness)), held + leaked + (op.overlap ? op.owed0 : 0), "kept reward");
            // the collect is still measured exactly, even when the reward token is token0
            assertEq(collected0, op.owed0, "collected0");
            assertEq(collected1, op.owed1, "collected1");
            uint256 principal = op.liquidity != 0 ? op.principal0 : 0;
            assertEq(fee0, op.owed0 - (principal < op.owed0 ? principal : op.owed0), "fee0");
        } catch {
            // a failed or forfeited claim never blocks the operation
            assertTrue(false, "the operation reverted");
        }
    }
}
