// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../../src/V3Automation.sol";

/// @dev A 7702 delegate that ONLY accepts a signature over its OWN wrapped hash — so a RAW signature
///      fails its isValidSignature. Etched onto an EOA to give it code AND a controlling key. A raw
///      root-key signature must therefore be accepted via the ECDSA leg, not the ERC-1271 leg.
///      Uses OZ 4.9.6's 2-value ECDSA.tryRecover.
contract Wrapped7702Delegate {
    bytes4 constant MAGIC = 0x1626ba7e;

    function wrap(bytes32 hash) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Delegate:", block.chainid, address(this), hash));
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err) = ECDSA.tryRecover(wrap(hash), sig);
        return (err == ECDSA.RecoverError.NoError && rec == address(this)) ? MAGIC : bytes4(0xffffffff);
    }
}

/// @dev Minimal ERC-1271 smart wallet: accepts signatures recovered to `owner` (OZ 4.9.6 tryRecover).
contract Mock1271Wallet {
    bytes4 constant MAGIC = 0x1626ba7e;
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err) = ECDSA.tryRecover(hash, sig);
        return (err == ECDSA.RecoverError.NoError && rec == owner) ? MAGIC : bytes4(0xffffffff);
    }
}

/// @notice Fork-free coverage of the vendored SignatureValidator integration in V3Automation,
///         exercised through cancelOrder/isOrderCancelled (which call the exact same
///         SignatureValidator.isValidSignatureNow used by _validateOrder / execute).
contract V3AutomationSignatureValidatorTest is Test {
    V3Automation internal automation;

    function setUp() external {
        automation = new V3Automation();
    }

    function _rawSign(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev EIP-2098 compact (r, vs) 64-byte encoding of the same signature.
    function _compactSign(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes32 vs = bytes32((uint256(v - 27) << 255) | uint256(s));
        return abi.encodePacked(r, vs);
    }

    function test_eoa_cancel_success() external {
        (address user, uint256 pk) = makeAddrAndKey("eoaUser");
        bytes32 orderHash = keccak256("order-eoa");
        bytes memory sig = _rawSign(orderHash, pk);

        vm.prank(user);
        automation.cancelOrder(orderHash, sig);

        assertTrue(automation.isOrderCancelled(user, orderHash));
    }

    function test_eoa_eip2098_compact_cancel_success() external {
        (address user, uint256 pk) = makeAddrAndKey("eoaCompact");
        bytes32 orderHash = keccak256("order-compact");
        bytes memory sig = _compactSign(orderHash, pk);
        assertEq(sig.length, 64);

        vm.prank(user);
        automation.cancelOrder(orderHash, sig);

        assertTrue(automation.isOrderCancelled(user, orderHash));
    }

    function test_7702_rawSig_accepted_via_ecdsa_leg() external {
        uint256 ownerPk = 0x7702BEEF;
        address account = vm.addr(ownerPk);
        Wrapped7702Delegate impl = new Wrapped7702Delegate();
        vm.etch(account, address(impl).code); // 7702: contract code + controlling EOA key

        bytes32 orderHash = keccak256("order-7702");
        bytes memory rawSig = _rawSign(orderHash, ownerPk);
        // Sanity: the account's OWN isValidSignature rejects a raw signature over the digest.
        assertEq(Wrapped7702Delegate(account).isValidSignature(orderHash, rawSig), bytes4(0xffffffff));

        // But the router accepts it via the always-on ECDSA leg.
        vm.prank(account);
        automation.cancelOrder(orderHash, rawSig);
        assertTrue(automation.isOrderCancelled(account, orderHash));
    }

    function test_erc1271_wallet_accepted_via_1271_leg() external {
        (address walletOwner, uint256 ownerPk) = makeAddrAndKey("walletOwner");
        Mock1271Wallet wallet = new Mock1271Wallet(walletOwner);

        bytes32 orderHash = keccak256("order-1271");
        bytes memory sig = _rawSign(orderHash, ownerPk); // signed by the wallet's owner key

        // msg.sender is the wallet (has code, no key at its own address) -> only the 1271 leg can accept.
        vm.prank(address(wallet));
        automation.cancelOrder(orderHash, sig);
        assertTrue(automation.isOrderCancelled(address(wallet), orderHash));
    }

    function test_wrongKey_reverts() external {
        (address user,) = makeAddrAndKey("realUser");
        bytes32 orderHash = keccak256("order-bad");
        bytes memory badSig = _rawSign(orderHash, 0xBAD5); // signed by a different key

        vm.prank(user);
        vm.expectRevert(V3Automation.InvalidSignature.selector);
        automation.cancelOrder(orderHash, badSig);
    }

    function test_cancel_isPerDigest_notPerSignatureBytes() external {
        (address user, uint256 pk) = makeAddrAndKey("perDigestUser");
        bytes32 orderHash = keccak256("order-per-digest");

        vm.prank(user);
        automation.cancelOrder(orderHash, _rawSign(orderHash, pk));

        // Cancellation is keyed on (signer, digest), independent of the signature encoding used.
        assertTrue(automation.isOrderCancelled(user, orderHash));
        // A fresh, different digest from the same signer is NOT cancelled.
        assertFalse(automation.isOrderCancelled(user, keccak256("some-other-order")));
    }
}
