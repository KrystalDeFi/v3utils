// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {RouterStorage} from "../../../src/router/RouterStorage.sol";

/// @dev Module stand-in, delegatecalled by the router.
contract MockModule {
    error Boom(uint256 code);

    /// @dev Returns the sender the module sees and the address it runs as.
    function ping() external payable returns (address sender, address self) {
        return (msg.sender, address(this));
    }

    /// @dev Writes router storage, to show the module runs in the router's context.
    function poke(address feeTaker) external {
        RouterStorage.layout().feeTaker = feeTaker;
    }

    /// @dev Reverts with a custom error, to show reverts bubble unchanged.
    function boom() external pure {
        revert Boom(42);
    }

    /// @dev Sets the NFT receive record and returns without clearing it (the router must clear it).
    function expectNft(bytes32 record) external {
        RouterStorage.layout().expectedNft = record;
    }

    /// @dev Sets `record`, then has `nfpm` deliver `tokenId` from `from` into the router by its receiver hook, as a
    /// farm does around a gauge withdraw. Clears the record after.
    function receiveNft(MockNfpm nfpm, address from, uint256 tokenId, bytes32 record) external returns (bytes4 ret) {
        RouterStorage.layout().expectedNft = record;
        ret = nfpm.deliver(address(this), from, tokenId);
        RouterStorage.layout().expectedNft = bytes32(0);
    }

    /// @dev Has `payer` send `amount` of native into the router mid-flow (as an aggregator or NFPM paying native does).
    function receiveNative(MockNativePayer payer, uint256 amount) external {
        payer.pay(address(this), amount);
    }

    /// @dev Catches the automation flow selectors: returns the recorded automation state and the calldata it got.
    /// Leaves a stale NFT record behind, which the router must clear.
    fallback(bytes calldata data) external returns (bytes memory) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        s.expectedNft = keccak256(data);
        return abi.encode(s.automationAccount, s.automationTarget, data);
    }
}

/// @dev Pays native to `to` from a balance the test dealt it; reverts bubble unchanged.
contract MockNativePayer {
    function pay(address to, uint256 amount) external {
        (bool ok, bytes memory ret) = to.call{value: amount}("");
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @dev Farm stand-in (delegatecalled): reports `staker` as the holder of every token.
contract MockFarm {
    address public immutable staker;

    constructor(address staker_) {
        staker = staker_;
    }

    function isStakedBy(address, uint256, address account) external view returns (bool) {
        return account == staker;
    }
}

/// @dev Farm stand-in (delegatecalled) whose holder check always reverts.
contract MockRevertingFarm {
    error FarmDown();

    function isStakedBy(address, uint256, address) external pure returns (bool) {
        revert FarmDown();
    }
}

/// @dev NFPM stand-in: an ownerOf table (reverting for unknown tokens, as ERC721 does) and a hook-calling delivery.
contract MockNfpm {
    mapping(uint256 => address) private _owners;

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert("ERC721: invalid token ID");
    }

    /// @dev Calls `to`'s receiver hook as `safeTransferFrom` would, with the caller as operator.
    function deliver(address to, address from, uint256 tokenId) external returns (bytes4) {
        return IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
    }
}

/// @dev Module that calls back into the router (it runs as the router, so `address(this)` is the router).
/// `reenter(call)` makes `call` from `execute`; the fallback (registered under an automation flow selector) makes the
/// call abi-encoded in its params, from `executeAutomation`.
contract MockReentrantModule {
    function reenter(bytes calldata call) external {
        _call(call);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        _call(abi.decode(data[4:], (bytes)));
        return "";
    }

    function _call(bytes memory call) private {
        (bool ok, bytes memory ret) = address(this).call(call);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC721 is ERC721 {
    constructor() ERC721("MockNft", "MNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev ERC20 stand-in with configurable decimals (for the ENSHRINED native scale).
contract MockDecimalsToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}
