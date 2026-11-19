// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

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

    /// @dev Sets the NFT receive record, as a farm does before a `safeTransferFrom` into the router.
    function expectNft(bytes32 record) external {
        RouterStorage.layout().expectedNft = record;
    }

    /// @dev Catches the automation flow selectors: returns the recorded automation state and the calldata it got.
    fallback(bytes calldata data) external returns (bytes memory) {
        RouterStorage.Layout storage s = RouterStorage.layout();
        return abi.encode(s.automationAccount, s.automationTarget, data);
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

/// @dev NFPM stand-in: an ownerOf table.
contract MockNfpm {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
}

/// @dev ERC20 stand-in with configurable decimals (for the ENSHRINED native scale).
contract MockDecimalsToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}
