// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../src/V3Utils.sol";
import "../Helper.t.sol";

interface IRamsesV3Positions {
    function positions(uint256 tokenId)
        external
        view
        returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IRamsesV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint24 feeProtocol, bool);
}

interface IRamsesGaugeV3 {
    function earned(address token, uint256 tokenId) external view returns (uint256);
}

// a forge cheatcode this forge-std doesn't declare yet
interface IVmEvmVersion {
    function setEvmVersion(string calldata evm) external;
}

/// @notice Ramses v3 pays a position's RAM to whoever holds its NFT, and claims it on every liquidity change, so an
/// operation holding the NFT must pass the RAM on. Runs against the live Ramses deployment on HyperEVM (through
/// HYPEREVM_RPC_URL, or the public RPC). WHYPE/USDC is a gauged pool.
contract RamsesRewardsTest is Test {
    uint256 constant FORK_BLOCK = 49_899_000;

    INonfungiblePositionManager constant RAMSES_NFPM =
        INonfungiblePositionManager(0xB3F77C5134D643483253D22E0Ca24627aE42ED51);
    address constant RAM = 0x555570a286F15EbDFE42B66eDE2f724Aa1AB5555;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant WHYPE_USDC_POOL = 0x5a177cF0EfFB7e0e7115D792E587c1A5a9CbC9D4;
    IRamsesGaugeV3 constant GAUGE = IRamsesGaugeV3(0x1d21655d65f8ab051eC16010c8F548f0D5C446BC);
    int24 constant TICK_SPACING = 5;

    address constant ADMIN = address(0xAD);

    uint256 constant Q64 = 2 ** 64;

    event ForwardPositionReward(
        address indexed nfpm,
        uint256 indexed tokenId,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 fee
    );

    V3Utils v3utils;
    V3AutomationHarness v3automation;
    StructHash.Order emptyUserConfig;

    address owner;
    uint256 ownerKey;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() external {
        vm.createSelectFork(vm.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm")), FORK_BLOCK);
        // solc 0.8.15 caps the EVM at london, but Ramses uses newer opcodes (PUSH0)
        IVmEvmVersion(address(vm)).setEvmVersion("cancun");

        address swapRouter = makeAddr("swapRouter");
        address[] memory nfpms = new address[](1);
        nfpms[0] = address(RAMSES_NFPM);

        vm.startPrank(ADMIN, ADMIN);
        v3utils = new V3Utils();
        v3utils.initialize(swapRouter, ADMIN, ADMIN, WHYPE, Common.NativeMode.WRAPPED, nfpms);
        v3utils.setPositionRewardToken(address(RAMSES_NFPM), RAM);
        v3automation = new V3AutomationHarness();
        v3automation.initialize(swapRouter, ADMIN, ADMIN, WHYPE, Common.NativeMode.WRAPPED, nfpms);
        v3automation.setPositionRewardToken(address(RAMSES_NFPM), RAM);
        vm.stopPrank();

        (, int24 tick,,,,,) = IRamsesV3Pool(WHYPE_USDC_POOL).slot0();
        tickLower = (tick / TICK_SPACING - 100) * TICK_SPACING;
        tickUpper = (tick / TICK_SPACING + 100) * TICK_SPACING;

        (owner, ownerKey) = makeAddrAndKey("positionOwner");
        tokenId = _mint(owner);
        // earn RAM, well past the anti-sybil window
        vm.warp(block.timestamp + 1 days);
    }

    function testWithdrawForwardsRamToOwner() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        assertGt(earned, 0);

        V3Utils.Instructions memory instructions =
            _instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, tokenId);
        vm.prank(owner);
        RAMSES_NFPM.approve(address(v3utils), tokenId);

        vm.expectEmit(true, true, true, true, address(v3utils));
        emit ForwardPositionReward(address(RAMSES_NFPM), tokenId, owner, RAM, earned, 0);
        vm.prank(owner);
        v3utils.execute(RAMSES_NFPM, tokenId, instructions);

        assertEq(IERC20(RAM).balanceOf(owner), earned, "owner got the RAM");
        assertEq(IERC20(RAM).balanceOf(address(v3utils)), 0, "V3Utils kept none");
        assertEq(GAUGE.earned(RAM, tokenId), 0);
        assertEq(RAMSES_NFPM.ownerOf(tokenId), owner);
        assertEq(_liquidity(tokenId), 0);
    }

    // the leak this fixes: without a reward token set, the withdrawal's own claim pays V3Utils
    function testWithdrawWithoutRewardTokenLeavesRamInV3Utils() external {
        vm.prank(ADMIN);
        v3utils.setPositionRewardToken(address(RAMSES_NFPM), address(0));
        uint256 earned = GAUGE.earned(RAM, tokenId);

        _sendToV3Utils(_instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, tokenId));

        assertEq(IERC20(RAM).balanceOf(address(v3utils)), earned, "V3Utils got the RAM");
        assertEq(IERC20(RAM).balanceOf(owner), 0);
    }

    // like the collected fees, the RAM goes to the recipient the instructions name
    function testRamGoesToTheInstructionsRecipient() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        address recipient = makeAddr("recipient");
        V3Utils.Instructions memory instructions =
            _instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, tokenId);
        instructions.recipient = recipient;

        _sendToV3Utils(instructions);

        assertEq(IERC20(RAM).balanceOf(recipient), earned);
        assertEq(IERC20(RAM).balanceOf(owner), 0);
        assertEq(RAMSES_NFPM.ownerOf(tokenId), owner);
    }

    function testChangeRangeForwardsRamToOwner() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        V3Utils.Instructions memory instructions = _instructions(V3Utils.WhatToDo.CHANGE_RANGE, tokenId);
        instructions.tickLower = tickLower - 10 * TICK_SPACING;
        instructions.tickUpper = tickUpper + 10 * TICK_SPACING;

        _sendToV3Utils(instructions);

        assertEq(IERC20(RAM).balanceOf(owner), earned, "owner got the RAM");
        assertEq(IERC20(RAM).balanceOf(address(v3utils)), 0, "V3Utils kept none");
        assertEq(RAMSES_NFPM.balanceOf(owner), 2, "the emptied position and the new one");
    }

    // an operation that leaves the liquidity unchanged also passes the RAM on
    function testCollectOnlyForwardsRamToOwner() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        uint128 liquidity = _liquidity(tokenId);
        V3Utils.Instructions memory instructions =
            _instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, tokenId);
        instructions.liquidity = 0;

        _sendToV3Utils(instructions);

        assertEq(IERC20(RAM).balanceOf(owner), earned);
        assertEq(IERC20(RAM).balanceOf(address(v3utils)), 0);
        assertEq(_liquidity(tokenId), liquidity);
    }

    // the claim reverts for a pool without a gauge: the operation must still go through
    function testClaimFailureDoesNotBlockTheOperation() external {
        vm.mockCallRevert(
            address(RAMSES_NFPM), abi.encodeWithSelector(IRewardsPositionManager.getReward.selector), "no gauge"
        );
        uint256 earned = GAUGE.earned(RAM, tokenId);

        _sendToV3Utils(_instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, tokenId));

        assertEq(RAMSES_NFPM.ownerOf(tokenId), owner);
        assertEq(_liquidity(tokenId), 0);
        // nothing was claimed up front, so the withdrawal's own claim paid V3Utils, as without the fix
        assertEq(IERC20(RAM).balanceOf(address(v3utils)), earned);
    }

    // a claim made too soon after the position's last liquidity change is forfeited, with or without the fix
    function testForfeitedClaimDoesNotBlockTheOperation() external {
        uint256 freshTokenId = _mint(owner);
        vm.warp(block.timestamp + 60);
        assertGt(GAUGE.earned(RAM, freshTokenId), 0);

        _sendToV3Utils(_instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, freshTokenId), freshTokenId);

        assertEq(RAMSES_NFPM.ownerOf(freshTokenId), owner);
        assertEq(_liquidity(freshTokenId), 0);
        assertEq(IERC20(RAM).balanceOf(owner), 0, "forfeited");
        assertEq(IERC20(RAM).balanceOf(address(v3utils)), 0, "forfeited");
        assertEq(GAUGE.earned(RAM, freshTokenId), 0);
    }

    function testAutoExitForwardsRamToOwner() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        vm.prank(owner);
        RAMSES_NFPM.setApprovalForAll(address(v3automation), true);

        V3Automation.ExecuteParams memory params;
        params.action = V3Automation.Action.AUTO_EXIT;
        params.protocol = Nfpm.Protocol.RAMSES_V3;
        params.nfpm = RAMSES_NFPM;
        params.tokenId = tokenId;
        params.liquidity = _liquidity(tokenId);
        params.deadline = block.timestamp;
        params.abiEncodedUserOrder = abi.encode(emptyUserConfig);
        params.orderSignature = _signOrder(emptyUserConfig, ownerKey);

        vm.expectEmit(true, true, true, true, address(v3automation));
        emit ForwardPositionReward(address(RAMSES_NFPM), tokenId, owner, RAM, earned, 0);
        vm.prank(ADMIN);
        v3automation.execute(params);

        assertEq(IERC20(RAM).balanceOf(owner), earned, "owner got the RAM");
        assertEq(IERC20(RAM).balanceOf(address(v3automation)), 0, "V3Automation kept none");
        assertEq(RAMSES_NFPM.ownerOf(tokenId), owner);
        assertEq(_liquidity(tokenId), 0);
    }

    // like the collected fees, the RAM pays the operation's performance fee (ADMIN is the fee taker)
    function testWithdrawTakesThePerformanceFeeOnRam() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        uint64 feeX64 = uint64(Q64 / 10);
        uint256 fee = earned * feeX64 / Q64;
        V3Utils.Instructions memory instructions =
            _instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP, tokenId);
        instructions.performanceFeeX64 = feeX64;

        vm.expectEmit(true, true, true, true, address(v3utils));
        emit ForwardPositionReward(address(RAMSES_NFPM), tokenId, owner, RAM, earned - fee, fee);
        _sendToV3Utils(instructions);

        assertGt(fee, 0);
        assertEq(IERC20(RAM).balanceOf(owner), earned - fee, "owner got the RAM less the fee");
        assertEq(IERC20(RAM).balanceOf(ADMIN), fee, "the fee taker got the fee");
        assertEq(IERC20(RAM).balanceOf(address(v3utils)), 0, "V3Utils kept none");
    }

    function testAutoExitTakesThePerformanceFeeOnRam() external {
        uint256 earned = GAUGE.earned(RAM, tokenId);
        uint64 feeX64 = uint64(Q64 / 10);
        uint256 fee = earned * feeX64 / Q64;
        vm.prank(owner);
        RAMSES_NFPM.setApprovalForAll(address(v3automation), true);

        V3Automation.ExecuteParams memory params;
        params.action = V3Automation.Action.AUTO_EXIT;
        params.protocol = Nfpm.Protocol.RAMSES_V3;
        params.nfpm = RAMSES_NFPM;
        params.tokenId = tokenId;
        params.liquidity = _liquidity(tokenId);
        params.deadline = block.timestamp;
        params.performanceFeeX64 = feeX64;
        params.abiEncodedUserOrder = abi.encode(emptyUserConfig);
        params.orderSignature = _signOrder(emptyUserConfig, ownerKey);

        vm.prank(ADMIN);
        v3automation.execute(params);

        assertGt(fee, 0);
        assertEq(IERC20(RAM).balanceOf(owner), earned - fee, "owner got the RAM less the fee");
        assertEq(IERC20(RAM).balanceOf(ADMIN), fee, "the fee taker got the fee");
        assertEq(IERC20(RAM).balanceOf(address(v3automation)), 0, "V3Automation kept none");
    }

    function testSetPositionRewardToken() external {
        assertEq(v3utils.positionRewardToken(address(RAMSES_NFPM)), RAM);

        vm.expectRevert();
        vm.prank(owner);
        v3utils.setPositionRewardToken(address(RAMSES_NFPM), address(0));

        vm.prank(ADMIN);
        v3utils.setPositionRewardToken(address(RAMSES_NFPM), address(0));
        assertEq(v3utils.positionRewardToken(address(RAMSES_NFPM)), address(0));
    }

    /// A WHYPE/USDC position minted on the Ramses position manager for `to`.
    function _mint(address to) internal returns (uint256 id) {
        deal(WHYPE, to, 10 ether);
        deal(USDC, to, 2000e6);
        vm.startPrank(to);
        IERC20(WHYPE).approve(address(RAMSES_NFPM), type(uint256).max);
        IERC20(USDC).approve(address(RAMSES_NFPM), type(uint256).max);
        (id,,,) = RAMSES_NFPM.mint(
            INonfungiblePositionManager.RamsesV3MintParams(
                WHYPE, USDC, TICK_SPACING, tickLower, tickUpper, 10 ether, 2000e6, 0, 0, to, block.timestamp
            )
        );
        vm.stopPrank();
    }

    /// Removes all of the position's liquidity, swaps nothing and sends everything to the owner.
    function _instructions(V3Utils.WhatToDo whatToDo, uint256 id)
        internal
        view
        returns (V3Utils.Instructions memory instructions)
    {
        instructions.whatToDo = whatToDo;
        instructions.protocol = Nfpm.Protocol.RAMSES_V3;
        instructions.liquidity = _liquidity(id);
        instructions.deadline = block.timestamp;
        instructions.recipient = owner;
    }

    function _sendToV3Utils(V3Utils.Instructions memory instructions) internal {
        _sendToV3Utils(instructions, tokenId);
    }

    function _sendToV3Utils(V3Utils.Instructions memory instructions, uint256 id) internal {
        vm.prank(owner);
        RAMSES_NFPM.safeTransferFrom(owner, address(v3utils), id, abi.encode(instructions));
    }

    function _liquidity(uint256 id) internal view returns (uint128 liquidity) {
        (,,,,, liquidity,,,,) = IRamsesV3Positions(address(RAMSES_NFPM)).positions(id);
    }

    function _signOrder(StructHash.Order memory order, uint256 privateKey)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = v3automation.hashTypedDataV4(StructHash._hash(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
