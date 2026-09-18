// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/V3Utils.sol";
import "../src/CommonLib.sol";

/// @notice Models an Arc-style enshrined native asset: an ERC20 *view* over the account's native
/// balance, 6 decimals against 18-decimal native, sharing one balance with it. Transfers through
/// either interface move the same value, and `balanceOf` truncates anything below one 6-dec unit.
/// `vm.deal` is what lets the mock move a balance it does not custody, exactly as the predeploy does.
contract MockEnshrinedNative {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant SCALE = 1e12; // 18-dec native per 1 smallest unit of the 6-dec view

    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function balanceOf(address account) public view returns (uint256) {
        return account.balance / SCALE; // truncates sub-unit dust, as Arc's predeploy does
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 native = amount * SCALE;
        require(from.balance >= native, "balance");
        VM.deal(from, from.balance - native);
        VM.deal(to, to.balance + native);
    }
}

/// @dev Only needs to answer decimals(): initialize's scale validation reads nothing else.
/// @notice A WETH9-shaped mock with no decimals(): reaching for one on the wrapped path would revert.
contract MockNoDecimals {
    function deposit() external payable {}

    function withdraw(uint256) external {}
}

contract MockDecimals {
    uint8 private immutable _decimals;

    constructor(uint8 d) {
        _decimals = d;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

/// @dev Exposes Common's internal native helpers so the two conversion directions can be pinned
/// independently of a full mint flow.
contract NativeHarness is V3Utils {
    function receiveNative() external payable returns (uint256) {
        return CommonLib.receiveNative(_nativeConfig(), msg.value);
    }

    function sendNative(address to, uint256 tokenAmount) external {
        _sendNative(to, tokenAmount);
    }

    function transferToken(address to, IERC20 token, uint256 amount, bool unwrap) external {
        _transferToken(to, token, amount, unwrap);
    }

    // nativeMode/nativeScale are internal on Common (a public getter is bytecode V3Utils cannot
    // spare), so surface them here for assertions.
    function nativeModeView() external view returns (Common.NativeMode) {
        return nativeMode;
    }

    function nativeScaleView() external view returns (uint256) {
        return nativeScale;
    }

    function test() external {}
}

contract EnshrinedNativeTest is Test {
    uint256 constant SCALE = 1e12;

    address router = address(0x9011);
    address owner = address(0xA11CE);
    address recipient = address(0xB0B);

    MockEnshrinedNative usdc;
    NativeHarness harness;

    function setUp() public {
        usdc = new MockEnshrinedNative();
        harness = _deploy(address(usdc), Common.NativeMode.ENSHRINED, SCALE);
    }

    /// @param scale ignored - the contract derives nativeScale itself; kept so call sites read clearly
    function _deploy(address weth, Common.NativeMode mode, uint256 scale) internal returns (NativeHarness h) {
        scale;
        address[] memory nfpms = new address[](0);
        vm.startBroadcast(owner);
        h = new NativeHarness();
        h.initialize(router, owner, owner, weth, mode, nfpms);
        vm.stopBroadcast();
    }

    // --- initialize validation ------------------------------------------------
    function testInitializeRejectsEnshrinedWithoutToken() public {
        address[] memory nfpms = new address[](0);
        vm.startBroadcast(owner);
        NativeHarness h = new NativeHarness();
        vm.expectRevert(Common.InvalidNativeConfig.selector);
        h.initialize(router, owner, owner, address(0), Common.NativeMode.ENSHRINED, nfpms);
        vm.stopBroadcast();
    }

    function testInitializeStoresNativeConfig() public view {
        assertEq(uint8(harness.nativeModeView()), uint8(Common.NativeMode.ENSHRINED));
        assertEq(harness.nativeScaleView(), SCALE);
        assertEq(harness.WETH(), address(usdc));
    }

    /// nativeScale is derived from the token, not supplied, so a wrong value is unrepresentable.
    function testInitializeDerivesScaleFromTokenDecimals() public {
        assertEq(_deploy(address(new MockDecimals(6)), Common.NativeMode.ENSHRINED, 0).nativeScaleView(), 1e12);
        assertEq(_deploy(address(new MockDecimals(18)), Common.NativeMode.ENSHRINED, 0).nativeScaleView(), 1);
        assertEq(_deploy(address(new MockDecimals(0)), Common.NativeMode.ENSHRINED, 0).nativeScaleView(), 1e18);
    }

    function testInitializeRejectsTokenOverEighteenDecimals() public {
        address token = address(new MockDecimals(19));
        address[] memory nfpms = new address[](0);
        vm.startBroadcast(owner);
        NativeHarness h = new NativeHarness();
        vm.expectRevert(Common.InvalidNativeConfig.selector);
        h.initialize(router, owner, owner, token, Common.NativeMode.ENSHRINED, nfpms);
        vm.stopBroadcast();
    }

    /// WRAPPED never reads decimals: a WETH9 wrapper is 1:1 with native by definition.
    function testWrappedScaleIsOneWithoutReadingDecimals() public {
        assertEq(_deploy(address(new MockNoDecimals()), Common.NativeMode.WRAPPED, 0).nativeScaleView(), 1);
    }

    // --- native -> token (truncating direction) -------------------------------

    function testReceiveNativeConvertsToTokenUnits() public {
        vm.deal(address(this), 100 * SCALE);
        // 100e12 wei of native == 100 units of the 6-decimal view. No deposit() is called: the mock
        // has no such function, so reaching for one would revert here.
        assertEq(harness.receiveNative{value: 100 * SCALE}(), 100);
    }

    function testReceiveNativeRejectsDust() public {
        vm.deal(address(this), 100 * SCALE + 1);
        vm.expectRevert(CommonLib.NativeDustNotAllowed.selector);
        harness.receiveNative{value: 100 * SCALE + 1}();
    }

    function testReceiveNativeRejectsSubUnitValue() public {
        vm.deal(address(this), 1 ether);
        // below one 6-dec unit the whole amount would truncate to zero and be stranded
        vm.expectRevert(CommonLib.NativeDustNotAllowed.selector);
        harness.receiveNative{value: SCALE - 1}();
    }

    function testReceiveNativeCreditIsVisibleAsTokenBalance() public {
        vm.deal(address(this), 100 * SCALE);
        uint256 credited = harness.receiveNative{value: 100 * SCALE}();
        // the defining property of the enshrined model: the native value it just received *is* its
        // ERC20 balance, with no wrapping step in between
        assertEq(usdc.balanceOf(address(harness)), credited);
    }

    // --- token -> native (exact direction) ------------------------------------

    function testSendNativeScalesUp() public {
        vm.deal(address(harness), 100 * SCALE);
        uint256 before = recipient.balance;
        // no withdraw() is called - the mock has none, so an attempt would revert
        harness.sendNative(recipient, 100);
        assertEq(recipient.balance - before, 100 * SCALE);
    }

    function testSendNativeRoundTripsReceiveNative() public {
        vm.deal(address(this), 7 * SCALE);
        uint256 credited = harness.receiveNative{value: 7 * SCALE}();
        uint256 before = recipient.balance;
        harness.sendNative(recipient, credited);
        assertEq(recipient.balance - before, 7 * SCALE); // exact, no value lost either way
    }

    // --- _transferToken dispatch ----------------------------------------------

    function testTransferTokenUnwrapDeliversNative() public {
        vm.deal(address(harness), 50 * SCALE);
        uint256 before = recipient.balance;
        harness.transferToken(recipient, IERC20(address(usdc)), 50, true);
        assertEq(recipient.balance - before, 50 * SCALE);
    }

    function testTransferTokenWithoutUnwrapUsesErc20Path() public {
        vm.deal(address(harness), 50 * SCALE);
        uint256 before = usdc.balanceOf(recipient);
        harness.transferToken(recipient, IERC20(address(usdc)), 50, false);
        // same asset either way on an enshrined chain - only the mechanism differs
        assertEq(usdc.balanceOf(recipient) - before, 50);
    }

    // --- the zero-WETH guard in _transferToken --------------------------------

    /// A zero WETH is rejected at initialize, which is what makes the unwrap branch in
    /// _transferToken safe against a zero token address without its own guard.
    function testInitializeRejectsZeroWethInEitherMode() public {
        address[] memory nfpms = new address[](0);
        vm.startBroadcast(owner);
        NativeHarness a = new NativeHarness();
        vm.expectRevert(Common.InvalidNativeConfig.selector);
        a.initialize(router, owner, owner, address(0), Common.NativeMode.WRAPPED, nfpms);
        NativeHarness b = new NativeHarness();
        vm.expectRevert(Common.InvalidNativeConfig.selector);
        b.initialize(router, owner, owner, address(0), Common.NativeMode.ENSHRINED, nfpms);
        vm.stopBroadcast();
    }

    /// With WETH guaranteed non-zero, a zero token address simply takes the ERC20 branch.
    function testTransferTokenWithZeroTokenTakesErc20Path() public {
        vm.deal(address(harness), 50 * SCALE);
        vm.expectRevert("Address: call to non-contract");
        harness.transferToken(recipient, IERC20(address(0)), 50, true);
    }

    function test() external {}

    receive() external payable {}
}
