// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {V3UtilsRouter, IAutomationFlows} from "../../src/router/V3UtilsRouter.sol";
import {RouterStorage} from "../../src/router/RouterStorage.sol";
import {IRouterErrors} from "../../src/router/IRouterErrors.sol";
import {FeeType, AutoAction} from "../../src/router/RouterTypes.sol";
import {StructHash} from "../../src/StructHash.sol";
import {
    MockModule,
    MockFarm,
    MockRevertingFarm,
    MockNfpm,
    MockDecimalsToken,
    MockReentrantModule,
    MockERC20,
    MockERC721
} from "./mocks/MockModule.sol";

contract RouterTest is Test {
    uint64 constant GAS_CAP = 5534023222112865280;
    uint64 constant PROTOCOL_CAP = 5534023222112865280;
    uint64 constant PERFORMANCE_CAP = 5902958103587057000;

    event CancelOrder(address user, bytes32 hash, bytes signature);

    V3UtilsRouter router;
    MockModule module;
    MockNfpm nfpm;

    address deployer = makeAddr("routerDeployer");
    address admin = makeAddr("routerAdmin");
    address operator = makeAddr("routerOperator");
    address withdrawer = makeAddr("routerWithdrawer");
    address swapRouter = makeAddr("routerSwapRouter");
    address feeTaker = makeAddr("routerFeeTaker");
    address weth = makeAddr("routerWeth");
    address alice;
    uint256 aliceKey;
    address bob;
    uint256 bobKey;

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("routerAlice");
        (bob, bobKey) = makeAddrAndKey("routerBob");
        router = _deploy();
        vm.prank(deployer, deployer);
        router.initialize(admin, operator, withdrawer, swapRouter, feeTaker, weth, 0);
        module = new MockModule();
        nfpm = new MockNfpm();
    }

    // ------------------------------------------------------------------ helpers

    function _deploy() internal returns (V3UtilsRouter r) {
        vm.prank(deployer, deployer);
        r = new V3UtilsRouter();
    }

    function _missingRole(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        );
    }

    function _slot(uint256 offset) internal view returns (bytes32) {
        return vm.load(address(router), bytes32(uint256(RouterStorage.SLOT) + offset));
    }

    function _order(address nfpm_, uint256 tokenId) internal view returns (bytes memory) {
        StructHash.Order memory o;
        o.chainId = int64(int256(block.chainid));
        o.nfpmAddress = nfpm_;
        o.tokenId = tokenId;
        o.orderType = "ORDER_TYPE_REBALANCE";
        o.signatureTime = int64(int256(block.timestamp));
        return abi.encode(o);
    }

    function _sign(uint256 key, bytes memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, router.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

    function _setModule(bytes4 sel) internal {
        vm.prank(admin);
        router.setModule(sel, address(module));
    }

    // ------------------------------------------------------------------ storage and types

    function test_storageSlot_matchesErc7201() public view {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("krystal.v3utils.router.storage")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(RouterStorage.SLOT, expected);
        // layout() points at the slot: config written by initialize sits at its field offsets
        assertEq(address(uint160(uint256(_slot(0)))), swapRouter);
        assertEq(address(uint160(uint256(_slot(1)))), feeTaker);
        assertEq(address(uint160(uint256(_slot(2)))), weth);
        assertEq(uint256(_slot(3)), 1); // nativeScale (WRAPPED)
    }

    function test_feeTypeOrdinals() public pure {
        assertEq(uint8(FeeType.GAS_FEE), 0);
        assertEq(uint8(FeeType.PERFORMANCE_FEE), 1);
        assertEq(uint8(FeeType.PROTOCOL_FEE), 2);
    }

    // ------------------------------------------------------------------ initialize

    function test_initialize_onlyDeployerOnce_andDefaults() public {
        V3UtilsRouter r = _deploy();
        address rando = makeAddr("routerFrontRunner");

        // a front-runner, also when the deployer is only the tx.origin and not the caller, cannot initialize
        vm.prank(rando, rando);
        vm.expectRevert(IRouterErrors.NotInitializer.selector);
        r.initialize(rando, rando, rando, rando, rando, rando, 0);
        vm.prank(rando, deployer);
        vm.expectRevert(IRouterErrors.NotInitializer.selector);
        r.initialize(rando, rando, rando, rando, rando, rando, 0);

        vm.startPrank(deployer, deployer);
        vm.expectRevert(IRouterErrors.ZeroAddress.selector);
        r.initialize(address(0), operator, withdrawer, swapRouter, feeTaker, weth, 0);
        vm.expectRevert(IRouterErrors.ZeroAddress.selector);
        r.initialize(admin, operator, withdrawer, swapRouter, address(0), weth, 0);
        vm.expectRevert(IRouterErrors.ZeroAddress.selector);
        r.initialize(admin, operator, withdrawer, swapRouter, feeTaker, address(0), 0);
        vm.expectRevert(IRouterErrors.InvalidNativeConfig.selector);
        r.initialize(admin, operator, withdrawer, swapRouter, feeTaker, weth, 2);
        address token19 = address(new MockDecimalsToken(19));
        vm.expectRevert(IRouterErrors.InvalidNativeConfig.selector);
        r.initialize(admin, operator, withdrawer, swapRouter, feeTaker, token19, 1);

        r.initialize(admin, operator, withdrawer, swapRouter, feeTaker, weth, 0);
        vm.expectRevert(IRouterErrors.AlreadyInitialized.selector);
        r.initialize(admin, operator, withdrawer, swapRouter, feeTaker, weth, 0);
        vm.stopPrank();

        assertEq(r.maxFeeX64(FeeType.GAS_FEE), GAS_CAP);
        assertEq(r.maxFeeX64(FeeType.PROTOCOL_FEE), PROTOCOL_CAP);
        assertEq(r.maxFeeX64(FeeType.PERFORMANCE_FEE), PERFORMANCE_CAP);
        assertEq(r.swapRouter(), swapRouter);
        assertEq(r.feeTaker(), feeTaker);
        assertEq(r.weth(), weth);
        assertEq(r.nativeMode(), 0);
        assertEq(r.nativeScale(), 1);
        assertFalse(r.locked());
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(r.hasRole(r.ADMIN_ROLE(), admin));
        assertTrue(r.hasRole(r.OPERATOR_ROLE(), operator));
        assertTrue(r.hasRole(r.WITHDRAWER_ROLE(), withdrawer));
        // the deployer gets no role
        assertFalse(r.hasRole(r.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(r.hasRole(r.ADMIN_ROLE(), deployer));

        // ENSHRINED derives the scale from the token's decimals
        V3UtilsRouter e = _deploy();
        address token6 = address(new MockDecimalsToken(6));
        vm.prank(deployer, deployer);
        e.initialize(admin, operator, withdrawer, swapRouter, feeTaker, token6, 1);
        assertEq(e.nativeMode(), 1);
        assertEq(e.nativeScale(), 1e12);
    }

    // ------------------------------------------------------------------ execute

    function test_execute_dispatchesBySelector_preservesSender() public {
        _setModule(MockModule.ping.selector);
        assertEq(router.module(MockModule.ping.selector), address(module));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bytes memory ret = router.execute{value: 1 wei}(abi.encodeCall(MockModule.ping, ()));
        (address sender, address self) = abi.decode(ret, (address, address));
        assertEq(sender, alice);
        assertEq(self, address(router));

        // the module writes the router's RouterStorage
        _setModule(MockModule.poke.selector);
        address newTaker = makeAddr("routerPokedTaker");
        vm.prank(alice);
        router.execute(abi.encodeCall(MockModule.poke, (newTaker)));
        assertEq(router.feeTaker(), newTaker);

        // reverts bubble unchanged
        _setModule(MockModule.boom.selector);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockModule.Boom.selector, 42));
        router.execute(abi.encodeCall(MockModule.boom, ()));
    }

    function test_execute_unknownSelector_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.UnknownSelector.selector);
        router.execute(abi.encodeCall(MockModule.ping, ()));
        // shorter than a selector
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.UnknownSelector.selector);
        router.execute(hex"01");
    }

    // ------------------------------------------------------------------ registries and lock

    function test_registries_requireCode_andAdminRole() public {
        address eoa = makeAddr("routerEoaTarget");
        address n = address(nfpm);
        address code = address(module);

        vm.startPrank(admin);
        vm.expectRevert(IRouterErrors.InvalidTarget.selector);
        router.setModule(MockModule.ping.selector, eoa);
        vm.expectRevert(IRouterErrors.InvalidTarget.selector);
        router.setAdapter(n, eoa);
        vm.expectRevert(IRouterErrors.InvalidTarget.selector);
        router.setFarm(n, eoa);
        vm.stopPrank();

        bytes memory err = _missingRole(alice, router.ADMIN_ROLE());
        vm.startPrank(alice);
        vm.expectRevert(err);
        router.setModule(MockModule.ping.selector, code);
        vm.expectRevert(err);
        router.setAdapter(n, code);
        vm.expectRevert(err);
        router.setFarm(n, code);
        vm.expectRevert(err);
        router.setSwapRouter(code);
        vm.expectRevert(err);
        router.setFeeTaker(code);
        vm.expectRevert(err);
        router.setNativeConfig(code, 0);
        vm.expectRevert(err);
        router.setMaxFeeX64(FeeType.GAS_FEE, 0);
        vm.expectRevert(err);
        router.lock();
        vm.stopPrank();

        vm.startPrank(admin);
        router.setModule(MockModule.ping.selector, code);
        router.setAdapter(n, code);
        router.setFarm(n, code);
        assertEq(router.module(MockModule.ping.selector), code);
        assertEq(router.adapter(n), code);
        assertEq(router.farm(n), code);
        router.setModule(MockModule.ping.selector, address(0));
        router.setAdapter(n, address(0));
        router.setFarm(n, address(0));
        vm.stopPrank();
        assertEq(router.module(MockModule.ping.selector), address(0));
        assertEq(router.adapter(n), address(0));
        assertEq(router.farm(n), address(0));
    }

    function test_lock_freezesRegistriesSwapRouterNative_capsOnlyDown() public {
        address code = address(module);
        vm.startPrank(admin);
        // before lock, caps can go up
        router.setMaxFeeX64(FeeType.GAS_FEE, GAS_CAP + 1);
        assertEq(router.maxFeeX64(FeeType.GAS_FEE), GAS_CAP + 1);

        router.lock();
        assertTrue(router.locked());
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setModule(MockModule.ping.selector, code);
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setModule(MockModule.ping.selector, address(0));
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setAdapter(address(nfpm), code);
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setFarm(address(nfpm), code);
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setSwapRouter(code);
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setNativeConfig(weth, 0);

        router.setMaxFeeX64(FeeType.PERFORMANCE_FEE, 1 << 60);
        assertEq(router.maxFeeX64(FeeType.PERFORMANCE_FEE), 1 << 60);
        router.setMaxFeeX64(FeeType.PERFORMANCE_FEE, 1 << 60); // equal is not a raise
        vm.expectRevert(IRouterErrors.Locked.selector);
        router.setMaxFeeX64(FeeType.PERFORMANCE_FEE, PERFORMANCE_CAP);
        assertEq(router.maxFeeX64(FeeType.PERFORMANCE_FEE), 1 << 60);

        address newTaker = makeAddr("routerNewTaker");
        router.setFeeTaker(newTaker);
        assertEq(router.feeTaker(), newTaker);
        vm.expectRevert(IRouterErrors.ZeroAddress.selector);
        router.setFeeTaker(address(0));
        vm.stopPrank();
        assertEq(router.swapRouter(), swapRouter);
        assertEq(router.weth(), weth);
    }

    // ------------------------------------------------------------------ receivers

    /// @dev `execute` calldata: `n` delivers `tokenId` from `from` into the router while a module holds `record`.
    function _receiveCall(MockNfpm n, address from, uint256 tokenId, bytes32 record)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(MockModule.receiveNft, (n, from, tokenId, record));
    }

    function test_onERC721Received_onlyExpected() public {
        address from = makeAddr("routerNftFrom");
        bytes32 record = keccak256(abi.encode(address(nfpm), from, uint256(7)));
        _setModule(MockModule.receiveNft.selector);

        // unregistered NFPM, even with a matching record
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        router.execute(_receiveCall(nfpm, from, 7, record));

        // registered, no record
        vm.prank(admin);
        router.setAdapter(address(nfpm), address(module));
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        nfpm.deliver(address(router), from, 7);
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        router.execute(_receiveCall(nfpm, from, 7, bytes32(0)));

        // mismatched token, sender or NFPM
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        router.execute(_receiveCall(nfpm, from, 8, record));
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        router.execute(_receiveCall(nfpm, alice, 7, record));
        MockNfpm other = new MockNfpm();
        vm.prank(admin);
        router.setAdapter(address(other), address(module));
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        router.execute(_receiveCall(other, from, 7, record));

        // match
        bytes memory ret = router.execute(_receiveCall(nfpm, from, 7, record));
        assertEq(abi.decode(ret, (bytes4)), IERC721Receiver.onERC721Received.selector);
    }

    /// A record a module leaves behind is cleared by the router when the module returns.
    function test_expectedNft_clearedAfterModuleCall() public {
        address from = makeAddr("routerNftFrom");
        bytes32 record = keccak256(abi.encode(address(nfpm), from, uint256(7)));
        vm.prank(admin);
        router.setAdapter(address(nfpm), address(module));
        _setModule(MockModule.expectNft.selector);
        router.execute(abi.encodeCall(MockModule.expectNft, (record)));
        assertEq(_slot(10), bytes32(0));
        vm.expectRevert(IRouterErrors.UnexpectedNft.selector);
        nfpm.deliver(address(router), from, 7);
        // the executeAutomation path is covered in test_executeAutomation_dispatchesEachAction
    }

    function test_receive_onlyWeth() public {
        vm.deal(alice, 1 ether);
        vm.deal(weth, 1 ether);

        vm.prank(alice);
        (bool sent, bytes memory ret) = address(router).call{value: 1}("");
        assertFalse(sent);
        assertEq(ret, abi.encodeWithSelector(IRouterErrors.UnexpectedNative.selector));

        vm.prank(weth);
        (sent,) = address(router).call{value: 1}("");
        assertTrue(sent);
        assertEq(address(router).balance, 1);

        // ENSHRINED: there is no wrapper to unwrap from, so nothing is accepted
        address token6 = address(new MockDecimalsToken(6));
        vm.prank(admin);
        router.setNativeConfig(token6, 1);
        assertEq(router.weth(), token6);
        assertEq(router.nativeMode(), 1);
        assertEq(router.nativeScale(), 1e12);
        vm.deal(token6, 1 ether);
        vm.prank(token6);
        (sent, ret) = address(router).call{value: 1}("");
        assertFalse(sent);
        assertEq(ret, abi.encodeWithSelector(IRouterErrors.UnexpectedNative.selector));
    }

    // ------------------------------------------------------------------ pause and rescue

    function test_pause_blocksExecuteAndAutomation() public {
        _setModule(MockModule.ping.selector);
        bytes memory err = _missingRole(alice, router.ADMIN_ROLE());
        vm.prank(alice);
        vm.expectRevert(err);
        router.pause();

        vm.prank(admin);
        router.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        router.execute(abi.encodeCall(MockModule.ping, ()));
        bytes memory order = _order(address(nfpm), 1);
        vm.prank(operator);
        vm.expectRevert("Pausable: paused");
        router.executeAutomation(alice, address(nfpm), 1, AutoAction.AUTO_EXIT, "", order, "");

        vm.prank(admin);
        router.unpause();
        vm.prank(alice);
        router.execute(abi.encodeCall(MockModule.ping, ()));
    }

    function test_withdraw_onlyWithdrawer() public {
        address to = makeAddr("routerRescueTo");
        MockERC20 token = new MockERC20();
        MockERC721 nft = new MockERC721();
        token.mint(address(router), 100);
        nft.mint(address(router), 3);
        vm.deal(address(router), 1 ether);

        bytes memory err = _missingRole(alice, router.WITHDRAWER_ROLE());
        vm.startPrank(alice);
        vm.expectRevert(err);
        router.withdrawERC20(IERC20(address(token)), to);
        vm.expectRevert(err);
        router.withdrawERC721(IERC721(address(nft)), 3, to);
        vm.expectRevert(err);
        router.withdrawNative(to);
        vm.stopPrank();
        // the admin is not a withdrawer either
        err = _missingRole(admin, router.WITHDRAWER_ROLE());
        vm.prank(admin);
        vm.expectRevert(err);
        router.withdrawERC20(IERC20(address(token)), to);

        vm.startPrank(withdrawer);
        router.withdrawERC20(IERC20(address(token)), to);
        router.withdrawERC721(IERC721(address(nft)), 3, to);
        router.withdrawNative(to);
        vm.stopPrank();
        assertEq(token.balanceOf(to), 100);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(nft.ownerOf(3), to);
        assertEq(to.balance, 1 ether);
        assertEq(address(router).balance, 0);
    }

    // ------------------------------------------------------------------ orders

    function test_cancelOrder_andHashOrder_domain() public {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("V3UtilsRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        assertEq(router.DOMAIN_SEPARATOR(), domain);

        bytes memory order = _order(address(nfpm), 1);
        bytes32 digest = router.hashOrder(order);
        assertEq(
            digest,
            keccak256(abi.encodePacked("\x19\x01", domain, StructHash._hash(abi.decode(order, (StructHash.Order)))))
        );

        // a signature by someone else cannot cancel alice's order
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        vm.prank(alice);
        vm.expectRevert(IRouterErrors.InvalidSignature.selector);
        router.cancelOrder(digest, abi.encodePacked(r, s, v));

        (v, r, s) = vm.sign(aliceKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertFalse(router.isOrderCancelled(alice, digest));
        vm.expectEmit(address(router));
        emit CancelOrder(alice, digest, sig);
        vm.prank(alice);
        router.cancelOrder(digest, sig);
        // scoped per actor
        assertTrue(router.isOrderCancelled(alice, digest));
        assertFalse(router.isOrderCancelled(bob, digest));
    }

    // ------------------------------------------------------------------ automation checks (unit; e2e in Task 10)

    uint256 constant TOKEN_ID = 5;
    bytes aOrder;
    bytes aSig;
    bytes aData = abi.encode(uint256(123), address(0xBEEF));

    function _setUpAutomation() internal {
        nfpm.setOwner(TOKEN_ID, alice);
        aOrder = _order(address(nfpm), TOKEN_ID);
        aSig = _sign(aliceKey, aOrder);
    }

    /// @dev The operator runs `action` for `account` on TOKEN_ID with the given order and signature.
    function _auto(address account, AutoAction action, bytes memory order, bytes memory sig)
        internal
        returns (bytes memory)
    {
        vm.prank(operator);
        return router.executeAutomation(account, address(nfpm), TOKEN_ID, action, aData, order, sig);
    }

    function test_executeAutomation_checksInOrder() public {
        _setUpAutomation();
        AutoAction a = AutoAction.AUTO_ADJUST;

        // 1. operator only
        bytes memory err = _missingRole(alice, router.OPERATOR_ROLE());
        vm.prank(alice);
        vm.expectRevert(err);
        router.executeAutomation(alice, address(nfpm), TOKEN_ID, a, aData, aOrder, aSig);

        // 2. adapter registered; checked before the holder (ownerOf of token 999 reverts) and the order
        vm.expectRevert(IRouterErrors.UnsupportedNfpm.selector);
        _auto(alice, a, aOrder, aSig);
        bytes memory bobSig = _sign(bobKey, aOrder);
        vm.prank(operator);
        vm.expectRevert(IRouterErrors.UnsupportedNfpm.selector);
        router.executeAutomation(alice, address(nfpm), 999, a, aData, aOrder, bobSig);
        vm.prank(admin);
        router.setAdapter(address(nfpm), address(module));

        // 3. holder: bob neither owns nor (no farm) stakes it, even with a valid order of his own; and the holder
        // check comes before the signature check
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        _auto(bob, a, aOrder, bobSig);
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        _auto(bob, a, aOrder, aSig);

        // 4. order: chain, NFPM, signature
        StructHash.Order memory o = abi.decode(aOrder, (StructHash.Order));
        o.chainId = 999;
        bytes memory bad = abi.encode(o);
        bytes memory badSig = _sign(aliceKey, bad);
        vm.expectRevert(IRouterErrors.WrongChainId.selector);
        _auto(alice, a, bad, badSig);
        vm.expectRevert(IRouterErrors.WrongChainId.selector); // chain is checked before the signature
        _auto(alice, a, bad, bobSig);
        o.chainId = int64(int256(block.chainid));
        o.nfpmAddress = makeAddr("routerOtherNfpm");
        bad = abi.encode(o);
        badSig = _sign(aliceKey, bad);
        vm.expectRevert(IRouterErrors.WrongPositionManager.selector);
        _auto(alice, a, bad, badSig);
        vm.expectRevert(IRouterErrors.WrongPositionManager.selector); // NFPM is checked before the signature
        _auto(alice, a, bad, bobSig);
        vm.expectRevert(IRouterErrors.InvalidSignature.selector);
        _auto(alice, a, aOrder, bobSig);

        // all checks pass, but no module for the action's flow yet
        vm.expectRevert(IRouterErrors.UnknownSelector.selector);
        _auto(alice, a, aOrder, aSig);

        // ... and not cancelled
        _setModule(IAutomationFlows.adjustRange.selector);
        _auto(alice, a, aOrder, aSig);
        bytes32 digest = router.hashOrder(aOrder);
        vm.prank(alice);
        router.cancelOrder(digest, aSig);
        vm.expectRevert(IRouterErrors.OrderCancelled.selector);
        _auto(alice, a, aOrder, aSig);
    }

    /// Each action dispatches its flow's selector with the bot's actionData, under the recorded account and target,
    /// and the record is cleared afterwards.
    function test_executeAutomation_dispatchesEachAction() public {
        _setUpAutomation();
        vm.prank(admin);
        router.setAdapter(address(nfpm), address(module));
        bytes4[4] memory sels = [
            IAutomationFlows.adjustRange.selector,
            IAutomationFlows.decreaseAndSwap.selector,
            IAutomationFlows.compound.selector,
            IAutomationFlows.harvest.selector
        ];
        for (uint256 i; i < 4; ++i) {
            _setModule(sels[i]);
            bytes memory ret = _auto(alice, AutoAction(i), aOrder, aSig);
            (address account, bytes32 target, bytes memory data) = abi.decode(ret, (address, bytes32, bytes));
            assertEq(account, alice);
            assertEq(target, keccak256(abi.encode(address(nfpm), TOKEN_ID)));
            assertEq(data, abi.encodePacked(sels[i], aData));
            // slot 8 packs `locked` (false here) with automationAccount; slot 9 is automationTarget
            assertEq(_slot(8), bytes32(0));
            assertEq(_slot(9), bytes32(0));
            // the stale NFT record the module left is cleared by the router
            assertEq(_slot(10), bytes32(0));
        }
    }

    /// With a farm registered, the staker passes (the NFT is not in their wallet), and the wallet owner still does.
    function test_executeAutomation_farmHolder() public {
        _setUpAutomation();
        vm.startPrank(admin);
        router.setAdapter(address(nfpm), address(module));
        router.setModule(IAutomationFlows.decreaseAndSwap.selector, address(module));
        router.setFarm(address(nfpm), address(new MockFarm(bob)));
        vm.stopPrank();
        bytes memory ret = _auto(bob, AutoAction.AUTO_EXIT, aOrder, _sign(bobKey, aOrder));
        (address account,,) = abi.decode(ret, (address, bytes32, bytes));
        assertEq(account, bob);
        ret = _auto(alice, AutoAction.AUTO_EXIT, aOrder, aSig);
        (account,,) = abi.decode(ret, (address, bytes32, bytes));
        assertEq(account, alice);
        address carol = makeAddr("routerCarol");
        vm.expectRevert(IRouterErrors.NotPositionHolder.selector);
        _auto(carol, AutoAction.AUTO_EXIT, aOrder, aSig);
    }

    /// The wallet check comes first, so a farm whose holder check reverts never blocks the wallet holder.
    function test_executeAutomation_revertingFarm_walletHolderPasses() public {
        _setUpAutomation();
        vm.startPrank(admin);
        router.setAdapter(address(nfpm), address(module));
        router.setModule(IAutomationFlows.decreaseAndSwap.selector, address(module));
        router.setFarm(address(nfpm), address(new MockRevertingFarm()));
        vm.stopPrank();
        bytes memory ret = _auto(alice, AutoAction.AUTO_EXIT, aOrder, aSig);
        (address account,,) = abi.decode(ret, (address, bytes32, bytes));
        assertEq(account, alice);
        // a non-owner falls through to the farm, whose revert bubbles
        bytes memory bobSig = _sign(bobKey, aOrder);
        vm.expectRevert(MockRevertingFarm.FarmDown.selector);
        _auto(bob, AutoAction.AUTO_EXIT, aOrder, bobSig);
    }

    function test_reentrancy_blocked() public {
        _setUpAutomation();
        MockReentrantModule re = new MockReentrantModule();
        bytes32 operatorRole = router.OPERATOR_ROLE();
        vm.startPrank(admin);
        router.setModule(MockReentrantModule.reenter.selector, address(re));
        router.setModule(IAutomationFlows.adjustRange.selector, address(re));
        router.setModule(MockModule.ping.selector, address(module));
        router.setAdapter(address(nfpm), address(module));
        // the router holds OPERATOR_ROLE so an inner executeAutomation passes onlyRole and meets the guard
        router.grantRole(operatorRole, address(router));
        vm.stopPrank();

        bytes memory pingCall = abi.encodeCall(V3UtilsRouter.execute, (abi.encodeCall(MockModule.ping, ())));
        bytes memory autoCall = abi.encodeCall(
            V3UtilsRouter.executeAutomation, (alice, address(nfpm), TOKEN_ID, AutoAction.AUTO_EXIT, aData, aOrder, aSig)
        );

        // positive control: the module's call-back path works for a non-guarded function
        router.execute(abi.encodeCall(MockReentrantModule.reenter, (abi.encodeCall(V3UtilsRouter.feeTaker, ()))));

        // execute -> execute, execute -> executeAutomation
        vm.expectRevert("ReentrancyGuard: reentrant call");
        router.execute(abi.encodeCall(MockReentrantModule.reenter, (pingCall)));
        vm.expectRevert("ReentrancyGuard: reentrant call");
        router.execute(abi.encodeCall(MockReentrantModule.reenter, (autoCall)));

        // executeAutomation -> execute, executeAutomation -> executeAutomation
        vm.prank(operator);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        router.executeAutomation(
            alice, address(nfpm), TOKEN_ID, AutoAction.AUTO_ADJUST, abi.encode(pingCall), aOrder, aSig
        );
        vm.prank(operator);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        router.executeAutomation(
            alice, address(nfpm), TOKEN_ID, AutoAction.AUTO_ADJUST, abi.encode(autoCall), aOrder, aSig
        );
    }
}
