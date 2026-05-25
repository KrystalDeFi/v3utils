// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/StructHash.sol";
import "../src/V3Automation.sol";
import "./Helper.t.sol";

/// @title AutoEnterTest
/// @notice Unit tests for the v6.0 EIP-712 schema and signature round-trip.
///
/// Integration tests (full mint against a forked chain with real NFPM/V3Utils) live
/// in test/integration/AutoEnter.t.sol once added. This file is fast (no fork) and
/// covers the cross-repo invariant most likely to drift: type-hash computation.
contract AutoEnterTest is Test {
    V3AutomationHarness automation;
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    address internal signer;

    function setUp() public {
        automation = new V3AutomationHarness();
        signer = vm.addr(SIGNER_KEY);
    }

    function test_DomainSeparator_IsV6() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("V3AutomationOrder")),
                keccak256(bytes("6.0")),
                block.chainid,
                address(automation)
            )
        );
        assertEq(automation.DOMAIN_SEPARATOR(), expected, "DOMAIN_SEPARATOR must match v6.0");
    }

    function test_FollowUpTemplate_TypeHash_IsStable() public {
        // Frontend computes the SAME hash via viem's keccak256(toUtf8Bytes(...)). If the
        // string drifts between repos, signatures stop verifying.
        bytes32 expected = keccak256("FollowUpTemplate(uint8 followUpType,bytes32 templateConfigHash)");
        assertEq(StructHash.FollowUpTemplate_TYPEHASH, expected);
    }

    function test_PoolSelection_Hash_IsDeterministic() public {
        StructHash.PoolSelection memory ps = _samplePoolSelection();
        bytes32 h1 = StructHash._hash(ps);
        bytes32 h2 = StructHash._hash(ps);
        assertEq(h1, h2, "hash must be deterministic");
        // Sanity: changing one field changes the hash.
        ps.fee = 3000;
        assertTrue(StructHash._hash(ps) != h1, "fee field must affect hash");
    }

    function test_AutoEnterAction_Hash_IsDeterministic() public {
        StructHash.AutoEnterAction memory act = _sampleAction();
        bytes32 h1 = StructHash._hash(act);
        assertEq(h1, StructHash._hash(act));
        act.sourceAmount += 1;
        assertTrue(StructHash._hash(act) != h1);
    }

    /// @notice The whole point of v6: a signed AUTO_ENTER order round-trips through
    /// StructHash._hash → _hashTypedDataV4 → ECDSA.recover and yields the original signer.
    function test_AutoEnterOrder_SignAndRecover() public {
        StructHash.Order memory order = _sampleOrder();
        bytes memory encoded = abi.encode(order);

        bytes32 structHash = StructHash._hash(encoded);
        bytes32 digest = automation.hashTypedDataV4(structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recovered = ECDSA.recover(digest, signature);
        assertEq(recovered, signer, "signature must round-trip");
    }

    /// @notice Tampering with any field invalidates the signature. This guards against
    /// the operator silently changing pool/ticks/source-amount.
    function test_TamperedOrder_FailsRecovery() public {
        StructHash.Order memory order = _sampleOrder();
        bytes32 structHash = StructHash._hash(abi.encode(order));
        bytes32 digest = automation.hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Tamper: change one field on the action
        order.config.autoEnterConfig.action.sourceAmount += 1;
        bytes32 tamperedStructHash = StructHash._hash(abi.encode(order));
        bytes32 tamperedDigest = automation.hashTypedDataV4(tamperedStructHash);

        address recovered = ECDSA.recover(tamperedDigest, signature);
        assertTrue(recovered != signer, "tampered order must not recover original signer");
    }

    function test_FollowUps_AffectOrderHash() public {
        StructHash.Order memory orderNoFollowUps = _sampleOrder();
        bytes32 h1 = StructHash._hash(abi.encode(orderNoFollowUps));

        StructHash.Order memory orderWithFollowUps = _sampleOrder();
        orderWithFollowUps.config.autoEnterConfig.followUps = new StructHash.FollowUpTemplate[](1);
        orderWithFollowUps.config.autoEnterConfig.followUps[0] = StructHash.FollowUpTemplate({
            followUpType: 1, // AUTO_COMPOUND
            templateConfigHash: keccak256("dummy follow-up config")
        });
        bytes32 h2 = StructHash._hash(abi.encode(orderWithFollowUps));

        assertTrue(h1 != h2, "follow-ups must be part of the signed digest");
    }

    // ===== TODO (Foundry tests deferred — listed in plan §4.5) =====
    // test_AutoEnter_Wallet_V3_HappyPath
    // test_AutoEnter_Wallet_V3_WithSingleZap
    // test_AutoEnter_Wallet_V3_WithFollowUpRebalance
    // test_FollowUp_RejectsWrongTokenId
    // test_FollowUp_RejectsWrongHash
    // test_FollowUp_RejectsWrongType
    // test_FollowUp_RejectsBeforeParentMint
    // test_AutoEnter_ExpiredOrder
    // test_AutoEnter_WrongSigner
    // test_AutoEnter_SourceAmountExceeded
    // test_AutoEnter_TickMismatch
    // test_AutoEnter_SlippageFloorMissed
    // test_AutoEnter_Cancelled
    // test_AutoEnter_NotOperator
    // test_AutoEnter_BackwardCompat_V5RebalanceStillWorks
    // testFuzz_AutoEnter_RandomTicks
    // These require either a forked chain or extensive mocking; see integration test file.

    // ============ helpers ============

    function _samplePoolSelection() internal pure returns (StructHash.PoolSelection memory) {
        return StructHash.PoolSelection({
            mode: 0, // STATIC
            protocol: 0, // UNI_V3
            token0: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            token1: address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // WETH
            fee: 500,
            tickSpacing: 10,
            hooks: address(0),
            poolManagerOrNfpm: address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88),
            filterHash: bytes32(0)
        });
    }

    function _sampleAction() internal pure returns (StructHash.AutoEnterAction memory) {
        return StructHash.AutoEnterAction({
            sourceToken: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            sourceAmount: 1000e6, // 1000 USDC
            tickLower: -202000,
            tickUpper: -197000,
            swapSlippageX64: int256(uint256(184467440737)), // ~1% in X64
            liquiditySlippageX64: int256(uint256(184467440737)),
            maxGasProportionX64: int256(uint256(1844674407370)), // ~10%
            gasFeeX64: 0,
            protocolFeeX64: 0,
            deadlineWindowSeconds: 7 days
        });
    }

    function _sampleCondition() internal pure returns (StructHash.Condition memory c) {
        c._type = "TICK_OFFSET";
        c.sqrtPriceX96 = 0;
        c.timeBuffer = 0;
        c.tickOffsetCondition = StructHash.TickOffsetCondition({gteTickOffset: 100, lteTickOffset: 100});
        // priceOffsetCondition + tokenRatioCondition stay zero-initialized
    }

    function _sampleOrder() internal view returns (StructHash.Order memory) {
        StructHash.AutoEnterConfig memory ae = StructHash.AutoEnterConfig({
            condition: _sampleCondition(),
            poolSelection: _samplePoolSelection(),
            action: _sampleAction(),
            followUps: new StructHash.FollowUpTemplate[](0)
        });

        StructHash.OrderConfig memory cfg;
        cfg.autoEnterConfig = ae;
        // other oneof variants stay zero-initialized

        return StructHash.Order({
            chainId: int64(int256(block.chainid)),
            nfpmAddress: address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88),
            tokenId: 0,
            orderType: "ORDER_TYPE_AUTO_ENTER",
            config: cfg,
            signatureTime: int64(int256(block.timestamp))
        });
    }
}
