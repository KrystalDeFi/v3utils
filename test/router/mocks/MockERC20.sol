// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain mintable ERC20 with configurable decimals. Named apart from MockModule.sol's `MockERC20`.
contract MockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer token: every transfer burns `feeBps` of the amount, so the recipient gets less than sent.
contract MockFeeOnTransferToken is MockToken {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) MockToken("FOT", 18) {
        feeBps = feeBps_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = (amount * feeBps) / 10000;
        if (fee != 0) _burn(from, fee);
        super._transfer(from, to, amount - fee);
    }
}

/// @dev Token that reverts on `approve(spender, 0)`, as some tokens do (e.g. BNB on Ethereum).
contract MockNoZeroApproveToken is MockToken {
    constructor() MockToken("NZA", 18) {}

    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount != 0, "no zero approve");
        return super.approve(spender, amount);
    }
}

/// @dev WETH9 stand-in: an 18-decimal ERC20 with deposit/withdraw 1:1 against native.
contract MockWETH is MockToken {
    constructor() MockToken("WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

interface IDealCheat {
    function deal(address who, uint256 newBalance) external;
}

/// @dev ENSHRINED native view (Arc-style): an ERC20 whose balance IS the holder's native balance, rescaled to
/// `decimals` and truncated. `transfer` moves `amount * scale` native, as Arc's precompile does; a plain contract
/// cannot move another account's native, so it does that through forge's `deal` cheatcode (tests only).
contract MockEnshrinedNative {
    IDealCheat private constant VM = IDealCheat(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function _scale() private view returns (uint256) {
        return 10 ** (18 - decimals);
    }

    function balanceOf(address a) public view returns (uint256) {
        return a.balance / _scale();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 value = amount * _scale();
        require(msg.sender.balance >= value, "balance");
        VM.deal(msg.sender, msg.sender.balance - value);
        VM.deal(to, to.balance + value);
        return true;
    }
}
