// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {NativeCurrency} from "../../src/router/base/NativeCurrency.sol";

/// @dev Minimal WETH9: deposit/withdraw 1:1.
contract NCMockWeth {
    mapping(address => uint256) public balanceOf;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/// @dev Enshrined view: balanceOf is native balance / 1e12 (6 decimals).
contract NCMockEnshrined {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }

    function balanceOf(address a) external view returns (uint256) {
        return a.balance / (10 ** (18 - decimals));
    }
}

contract NCHarness {
    receive() external payable {}

    function toTokenUnits(address weth, bool e, uint256 v) external returns (uint256) {
        return NativeCurrency.toTokenUnits(weth, e, v);
    }

    function toNativeUnits(address weth, bool e, uint256 v) external returns (uint256) {
        return NativeCurrency.toNativeUnits(weth, e, v);
    }

    function scaleOf(address weth) external view returns (uint256) {
        return NativeCurrency.scaleOf(weth);
    }
}

contract NativeCurrencyTest is Test {
    NCHarness h;
    NCMockWeth weth;
    NCMockEnshrined arc;

    function setUp() public {
        h = new NCHarness();
        weth = new NCMockWeth();
        arc = new NCMockEnshrined(6);
    }

    function test_wrapped_roundTrip() public {
        vm.deal(address(h), 3 ether);
        assertEq(h.toTokenUnits(address(weth), false, 2 ether), 2 ether);
        assertEq(weth.balanceOf(address(h)), 2 ether);
        assertEq(address(h).balance, 1 ether);
        assertEq(h.toNativeUnits(address(weth), false, 2 ether), 2 ether);
        assertEq(weth.balanceOf(address(h)), 0);
        assertEq(address(h).balance, 3 ether);
    }

    function test_wrapped_scaleIsOne() public view {
        assertEq(h.scaleOf(address(weth)), 1);
    }

    function test_enshrined_scale() public view {
        assertEq(h.scaleOf(address(arc)), 1e12);
    }

    function test_enshrined_toTokenUnits_truncates_dustStaysNative() public {
        vm.deal(address(h), 1e12 + 5);
        assertEq(h.toTokenUnits(address(arc), true, 1e12 + 5), 1);
        assertEq(address(h).balance, 1e12 + 5);
    }

    function test_enshrined_toNativeUnits() public {
        vm.deal(address(h), 1e12);
        assertEq(h.toNativeUnits(address(arc), true, 1), 1e12);
    }

    function test_enshrined_toTokenUnits_insufficientBalance_reverts() public {
        vm.deal(address(h), 1e12 - 1);
        vm.expectRevert(NativeCurrency.InsufficientNativeBalance.selector);
        h.toTokenUnits(address(arc), true, 1e12);
    }

    function test_enshrined_toNativeUnits_insufficientBalance_reverts() public {
        vm.deal(address(h), 1e12 - 1);
        vm.expectRevert(NativeCurrency.InsufficientNativeBalance.selector);
        h.toNativeUnits(address(arc), true, 1);
    }

    function test_moreThan18Decimals_reverts() public {
        NCMockEnshrined bad = new NCMockEnshrined(19);
        vm.expectRevert(NativeCurrency.UnsupportedNativeDecimals.selector);
        h.scaleOf(address(bad));
    }

    function test_zeroWeth_reverts() public {
        vm.expectRevert(NativeCurrency.ZeroNativeToken.selector);
        h.toTokenUnits(address(0), false, 1);
        vm.expectRevert(NativeCurrency.ZeroNativeToken.selector);
        h.toNativeUnits(address(0), true, 1);
    }
}
