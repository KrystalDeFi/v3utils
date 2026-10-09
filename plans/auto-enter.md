# Auto-Enter — v3utils Implementation Plan

> **This is one of 5 coordinated per-repo plans.** Master plan: `/Users/maddie/.claude/plans/i-want-to-implement-elegant-sky.md`. Sister plans:
> - `krystal-services/plans/auto-enter.md`
> - `krystal-web/plans/auto-enter.md`
> - `v4utils/plans/auto-enter.md`
> - `krystal-vault-contracts-v2/plans/auto-enter.md`
>
> **§2 Cross-Repo Interface Contracts** below is the source of truth. If you change any struct field, type-hash, or selector, propagate to the other four plans.

## 0. Context

This repo owns the Solidity contracts that the Krystal automation worker calls for **wallet-mode** Uniswap v3 position management. Existing contracts:

- `src/V3Automation.sol` — operator-gated entrypoint for `AUTO_ADJUST | AUTO_EXIT | AUTO_COMPOUND | AUTO_HARVEST`, validates EIP-712 `Order` signed by user.
- `src/V3Utils.sol` — direct `swapAndMint`, `swapAndIncrease`, etc. (user-facing, pulls from `msg.sender`).
- `src/StructHash.sol` — EIP-712 typed-data hashing.

**Auto-enter** adds a new action `AUTO_ENTER` plus a follow-up dispatch `executeFollowUp`. Domain version bumps **5.0 → 6.0**. The contract is **redeployed** (not proxy-upgraded — current deploy uses CREATE2 with no proxy).

## 1. Scope decisions (locked)

- New `Action.AUTO_ENTER` enum value.
- New top-level entrypoints `executeAutoEnter`, `executeFollowUp`.
- EIP-712 domain stays `"V3AutomationOrder"`; version → `"6.0"`.
- Single-token funding (sourceToken/sourceAmount).
- User approves source token to **V3Automation v6** (not V3Utils). Different spender than today's user-direct mint flow.
- Follow-up authorization: parent EIP-712 signature carries `FollowUpTemplate[]` of `(type, configHash)`; child executions verify against parent hash + minted tokenId.
- Storage: `mapping(bytes32 => uint256) _mintedTokenIds`, `mapping(bytes32 => address) _mintedSigner`.

## 2. Cross-Repo Interface Contracts

### 2.1 EIP-712 Order schema v6.0

```
Domain:
  name:              "V3AutomationOrder"
  version:           "6.0"
  chainId:           <runtime>
  verifyingContract: <V3Automation v6 address per chain>

Order(int64 chainId, address nfpmAddress, uint256 tokenId, string orderType,
      OrderConfig config, int64 signatureTime)

OrderConfig(RebalanceConfig rebalanceConfig, RangeOrderConfig rangeOrderConfig,
            AutoCompoundConfig autoCompoundConfig, AutoExitConfig autoExitConfig,
            AutoHarvestConfig autoHarvestConfig, AutoEnterConfig autoEnterConfig)

AutoEnterConfig(Condition condition, PoolSelection poolSelection,
                AutoEnterAction action, FollowUpTemplate[] followUps)

PoolSelection(uint8 mode, uint8 protocol, address token0, address token1,
              uint24 fee, int24 tickSpacing, address hooks,
              address poolManagerOrNfpm, bytes32 filterHash)

AutoEnterAction(address sourceToken, uint256 sourceAmount,
                int24 tickLower, int24 tickUpper,
                int256 swapSlippageX64, int256 liquiditySlippageX64,
                int256 maxGasProportionX64, uint64 gasFeeX64, uint64 protocolFeeX64,
                uint64 deadlineWindowSeconds)

FollowUpTemplate(uint8 followUpType, bytes32 templateConfigHash)
```

For AUTO_ENTER orders: `tokenId == 0` in signed payload.

`followUpType`: 1=AUTO_COMPOUND, 2=AUTO_REBALANCE, 3=AUTO_EXIT, 4=AUTO_HARVEST.
`PoolSelection.mode`: 0=STATIC (v1), 1=DYNAMIC (Phase 2).
`protocol`: 0=UNI_V3, 1=UNI_V4, 2=PANCAKE_V4.

`templateConfigHash` = `keccak256(abi.encode(concreteConfig))` where `concreteConfig` is the same struct used today for the respective automation type.

### 2.2 Entry-point function signatures

```solidity
// V3Automation.sol — new functions, OPERATOR_ROLE gated

function executeAutoEnter(ExecuteAutoEnterParams calldata p)
    external payable onlyRole(OPERATOR_ROLE) whenNotPaused;

function executeFollowUp(ExecuteFollowUpParams calldata p)
    external payable onlyRole(OPERATOR_ROLE) whenNotPaused;

function setV3Utils(address newV3Utils) external onlyRole(DEFAULT_ADMIN_ROLE);

struct ExecuteAutoEnterParams {
    Nfpm.Protocol protocol;
    INonfungiblePositionManager nfpm;
    address signer;            // expected = order signer
    address sourceToken;
    uint256 sourceAmount;      // <= order.action.sourceAmount
    int24 tickLower;           // == order.action.tickLower
    int24 tickUpper;
    uint24 fee;
    int24 tickSpacing;
    address poolDeployer;      // address(0) for Uniswap; non-zero for Pancake-style forks (only used to disambiguate pool)
    uint256 amountIn0;
    uint256 amountOut0Min;
    bytes   swapData0;
    uint256 amountIn1;
    uint256 amountOut1Min;
    bytes   swapData1;
    uint256 amountAddMin0;
    uint256 amountAddMin1;
    uint256 deadline;
    uint64  gasFeeX64;         // == order.action.gasFeeX64
    uint64  protocolFeeX64;    // == order.action.protocolFeeX64
    bytes   abiEncodedUserOrder;
    bytes   orderSignature;
}

struct ExecuteFollowUpParams {
    bytes parentOrder;             // abi-encoded parent AUTO_ENTER Order
    bytes parentSignature;
    uint8 followUpIndex;
    bytes followUpConfigEncoded;   // abi.encoded concrete config
    ExecuteParams execute;         // existing struct used today for rebalance/etc
}

event AutoEnterExecuted(bytes32 indexed orderHash, address indexed signer,
                        uint256 indexed mintedTokenId, address pool,
                        uint128 liquidity, uint256 amount0, uint256 amount1);

event FollowUpExecuted(bytes32 indexed parentHash, uint8 followUpIndex,
                       uint256 mintedTokenId);
```

### 2.3 Storage additions

```solidity
address public V3UTILS;
mapping(bytes32 parentOrderHash => uint256 mintedTokenId) internal _mintedTokenIds;
mapping(bytes32 parentOrderHash => address signer)       internal _mintedSigner;
```

Existing `mapping(bytes32 => bool) _cancelledOrder` is reused — cancellation of parent cascades to all follow-ups.

## 3. v3utils implementation

### 3.1 New files

| File | Purpose |
|---|---|
| `src/auto-enter/IAutoEnter.sol` | Interface: `ExecuteAutoEnterParams`, `ExecuteFollowUpParams`, events, errors. |
| `test/AutoEnter.t.sol` | Foundry tests (18+ scenarios; see §3.6). |
| `script/UpgradeV6.s.sol` | Deploy v6 V3Automation per chain. Hardcoded WETH, NFPM, feeTaker per chain in env or constructor args mapping. |

### 3.2 Modified files

#### `src/StructHash.sol`

Add the following Solidity (after existing struct/typehash definitions):

```solidity
bytes32 constant TargetPool_TYPEHASH = keccak256(
    "TargetPool(uint8 mode,uint8 protocol,address token0,address token1,uint24 fee,int24 tickSpacing,address hooks,address poolManagerOrNfpm,bytes32 filterHash)"
);

struct TargetPool {
    uint8 mode;                      // 0=STATIC, 1=DYNAMIC (Phase 2)
    uint8 protocol;                  // 0=UNI_V3, 1=UNI_V4, 2=PANCAKE_V4
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;                   // address(0) for v3
    address poolManagerOrNfpm;
    bytes32 filterHash;              // 0x00 for STATIC
}

function _hash(TargetPool memory obj) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        TargetPool_TYPEHASH,
        obj.mode, obj.protocol, obj.token0, obj.token1, obj.fee,
        obj.tickSpacing, obj.hooks, obj.poolManagerOrNfpm, obj.filterHash
    ));
}

bytes32 constant AutoEnterAction_TYPEHASH = keccak256(
    "AutoEnterAction(address sourceToken,uint256 sourceAmount,int24 tickLower,int24 tickUpper,int256 swapSlippageX64,int256 liquiditySlippageX64,int256 maxGasProportionX64,uint64 gasFeeX64,uint64 protocolFeeX64,uint64 deadlineWindowSeconds)"
);

struct AutoEnterAction {
    address sourceToken;
    uint256 sourceAmount;
    int24 tickLower;
    int24 tickUpper;
    int256 swapSlippageX64;
    int256 liquiditySlippageX64;
    int256 maxGasProportionX64;
    uint64 gasFeeX64;
    uint64 protocolFeeX64;
    uint64 deadlineWindowSeconds;
}

function _hash(AutoEnterAction memory obj) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        AutoEnterAction_TYPEHASH,
        obj.sourceToken, obj.sourceAmount, obj.tickLower, obj.tickUpper,
        obj.swapSlippageX64, obj.liquiditySlippageX64, obj.maxGasProportionX64,
        obj.gasFeeX64, obj.protocolFeeX64, obj.deadlineWindowSeconds
    ));
}

bytes32 constant FollowUpTemplate_TYPEHASH = keccak256(
    "FollowUpTemplate(uint8 followUpType,bytes32 templateConfigHash)"
);

struct FollowUpTemplate {
    uint8 followUpType;
    bytes32 templateConfigHash;
}

function _hash(FollowUpTemplate memory obj) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        FollowUpTemplate_TYPEHASH, obj.followUpType, obj.templateConfigHash
    ));
}

function _hashFollowUps(FollowUpTemplate[] memory arr) internal pure returns (bytes32) {
    bytes32[] memory hashes = new bytes32[](arr.length);
    for (uint256 i; i < arr.length; ++i) hashes[i] = _hash(arr[i]);
    return keccak256(abi.encodePacked(hashes));
}

bytes32 constant AutoEnterConfig_TYPEHASH = keccak256(
    "AutoEnterConfig(Condition condition,TargetPool targetPool,AutoEnterAction action,FollowUpTemplate[] followUps)"
    "AutoEnterAction(address sourceToken,uint256 sourceAmount,int24 tickLower,int24 tickUpper,int256 swapSlippageX64,int256 liquiditySlippageX64,int256 maxGasProportionX64,uint64 gasFeeX64,uint64 protocolFeeX64,uint64 deadlineWindowSeconds)"
    "Condition(string type,int160 sqrtPriceX96,int64 timeBuffer,TickOffsetCondition tickOffsetCondition,PriceOffsetCondition priceOffsetCondition,TokenRatioCondition tokenRatioCondition)"
    "FollowUpTemplate(uint8 followUpType,bytes32 templateConfigHash)"
    "PriceOffsetCondition(uint32 baseToken,uint256 gteOffsetSqrtPriceX96,uint256 lteOffsetSqrtPriceX96)"
    "TargetPool(uint8 mode,uint8 protocol,address token0,address token1,uint24 fee,int24 tickSpacing,address hooks,address poolManagerOrNfpm,bytes32 filterHash)"
    "TickOffsetCondition(uint32 gteTickOffset,uint32 lteTickOffset)"
    "TokenRatioCondition(int256 lteToken0RatioX64,int256 gteToken0RatioX64)"
);

struct AutoEnterConfig {
    Condition condition;
    TargetPool targetPool;
    AutoEnterAction action;
    FollowUpTemplate[] followUps;
}

function _hash(AutoEnterConfig memory obj) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        AutoEnterConfig_TYPEHASH,
        _hash(obj.condition),
        _hash(obj.targetPool),
        _hash(obj.action),
        _hashFollowUps(obj.followUps)
    ));
}
```

Extend `OrderConfig` struct:

```solidity
struct OrderConfig {
    RebalanceConfig    rebalanceConfig;
    RangeOrderConfig   rangeOrderConfig;
    AutoCompoundConfig autoCompoundConfig;
    AutoExitConfig     autoExitConfig;
    AutoHarvestConfig  autoHarvestConfig;
    AutoEnterConfig    autoEnterConfig;   // NEW
}
```

**Recompute `OrderConfig_TYPEHASH` and `Order_TYPEHASH`** — they pick up the new nested type from `AutoEnterConfig`. Update the constant strings to include `AutoEnterConfig(...)` etc. per EIP-712 alphabetical-by-name rules.

#### `src/V3Automation.sol`

```solidity
// Constructor change
constructor() EIP712("V3AutomationOrder", "6.0") {}

// New state
address public V3UTILS;
mapping(bytes32 parentOrderHash => uint256 mintedTokenId) internal _mintedTokenIds;
mapping(bytes32 parentOrderHash => address signer)       internal _mintedSigner;

// New action
enum Action {
    AUTO_ADJUST,
    AUTO_EXIT,
    AUTO_COMPOUND,
    AUTO_HARVEST,
    AUTO_ENTER          // NEW
}

// Admin
function setV3Utils(address newV3Utils) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newV3Utils != address(0));
    V3UTILS = newV3Utils;
    emit V3UtilsUpdated(newV3Utils);
}
```

`executeAutoEnter` body:

```solidity
function executeAutoEnter(ExecuteAutoEnterParams calldata p)
    external payable onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant
{
    // 1. Allowlist NFPM
    require(_whitelistNfpms[address(p.nfpm)], "NFPM not whitelisted");

    // 2. Decode and validate signature
    StructHash.Order memory order = abi.decode(p.abiEncodedUserOrder, (StructHash.Order));
    bytes32 orderStructHash = StructHash._hash(order);
    bytes32 digest = _hashTypedDataV4(orderStructHash);
    require(!_cancelledOrder[digest], "Order cancelled");
    address recovered = ECDSA.recover(digest, p.orderSignature);
    require(recovered == p.signer, "Bad signer");

    // 3. Consistency checks
    require(keccak256(bytes(order.orderType)) == keccak256(bytes("ORDER_TYPE_AUTO_ENTER")), "Wrong type");
    require(order.tokenId == 0, "tokenId must be 0 for AUTO_ENTER");
    require(order.config.autoEnterConfig.targetPool.mode == 0, "Only STATIC in v1");
    StructHash.AutoEnterAction memory act = order.config.autoEnterConfig.action;
    require(act.sourceToken == p.sourceToken, "sourceToken mismatch");
    require(p.sourceAmount > 0 && p.sourceAmount <= act.sourceAmount, "sourceAmount oob");
    require(p.tickLower == act.tickLower && p.tickUpper == act.tickUpper, "ticks mismatch");
    require(p.gasFeeX64 == act.gasFeeX64 && p.protocolFeeX64 == act.protocolFeeX64, "fees mismatch");
    require(uint64(block.timestamp) <= uint64(order.signatureTime) + act.deadlineWindowSeconds, "Order expired");
    // pool token consistency
    require(order.config.autoEnterConfig.targetPool.token0 == p.protocol /* dummy */, ""); // see SwapAndMintParams builder

    // 4. Pull tokens from signer
    SafeERC20.safeTransferFrom(IERC20(act.sourceToken), p.signer, address(this), p.sourceAmount);

    // 5. Approve V3Utils
    IERC20(act.sourceToken).safeIncreaseAllowance(V3UTILS, p.sourceAmount);

    // 6. Build SwapAndMintParams and call V3Utils
    Common.SwapAndMintParams memory smParams = _buildAutoEnterSwapAndMintParams(p, order);
    Common.SwapAndMintResult memory result = V3Utils(V3UTILS).swapAndMint(smParams);

    // 7. Reset allowance to 0 (defense-in-depth)
    IERC20(act.sourceToken).forceApprove(V3UTILS, 0);

    // 8. Persist for follow-ups
    _mintedTokenIds[digest] = result.tokenId;
    _mintedSigner[digest] = p.signer;

    emit AutoEnterExecuted(digest, p.signer, result.tokenId,
                            _computePoolAddr(order.config.autoEnterConfig.targetPool),
                            result.liquidity, result.added0, result.added1);
}
```

`executeFollowUp` body:

```solidity
function executeFollowUp(ExecuteFollowUpParams calldata p)
    external payable onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant
{
    StructHash.Order memory parent = abi.decode(p.parentOrder, (StructHash.Order));
    bytes32 parentStructHash = StructHash._hash(parent);
    bytes32 parentDigest = _hashTypedDataV4(parentStructHash);

    require(!_cancelledOrder[parentDigest], "Parent cancelled");

    uint256 mintedTokenId = _mintedTokenIds[parentDigest];
    require(mintedTokenId != 0, "Parent not minted");
    require(p.execute.tokenId == mintedTokenId, "TokenId mismatch");

    address parentSigner = ECDSA.recover(parentDigest, p.parentSignature);
    require(parentSigner == _mintedSigner[parentDigest], "Parent signer mismatch");

    require(p.followUpIndex < parent.config.autoEnterConfig.followUps.length, "OOB followUpIndex");
    StructHash.FollowUpTemplate memory tmpl = parent.config.autoEnterConfig.followUps[p.followUpIndex];

    // Verify concrete config hash
    require(keccak256(p.followUpConfigEncoded) == tmpl.templateConfigHash, "Config hash mismatch");

    // Verify action type matches template type
    Action expected = _actionForFollowUpType(tmpl.followUpType);
    require(p.execute.action == expected, "Action type mismatch");

    // Dispatch with parent-signer auth (skip per-execute sig verify)
    _executeWithParentAuth(p.execute, p.followUpConfigEncoded, parentSigner);

    emit FollowUpExecuted(parentDigest, p.followUpIndex, mintedTokenId);
}

function _actionForFollowUpType(uint8 t) internal pure returns (Action) {
    if (t == 1) return Action.AUTO_COMPOUND;
    if (t == 2) return Action.AUTO_ADJUST;
    if (t == 3) return Action.AUTO_EXIT;
    if (t == 4) return Action.AUTO_HARVEST;
    revert("Invalid follow-up type");
}
```

`_executeWithParentAuth` is extracted from the existing `execute` body: same logic minus the per-execution signature verification step (replaced by parent auth above).

#### `src/EIP712.sol`

No change. `_hashTypedDataV4` continues to use the contract's EIP-712 domain (now v6.0).

#### `src/V3Utils.sol`

No change. V3Automation handles the `transferFrom + safeIncreaseAllowance` dance before calling V3Utils.

### 3.3 Errors (new)

```solidity
error OrderCancelled();
error InvalidSigner();
error InvalidOrderType();
error InvalidTokenId();
error UnsupportedPoolMode();
error SourceTokenMismatch();
error SourceAmountOutOfBounds();
error TickMismatch();
error FeeMismatch();
error OrderExpired();
error ParentNotMinted();
error ParentSignerMismatch();
error FollowUpIndexOOB();
error FollowUpConfigHashMismatch();
error FollowUpActionTypeMismatch();
```

Prefer custom errors over revert strings (gas savings + matches existing patterns in this repo).

### 3.4 Token-pull design rationale

V3Utils' `swapAndMint` pulls from `msg.sender`. When V3Automation calls it, `msg.sender == V3Automation` — so tokens would come from V3Automation, not the user. The fix: V3Automation does `safeTransferFrom(user → V3Automation)` first, then `safeIncreaseAllowance(V3UTILS, amount)`, then calls `swapAndMint`. After, allowance is reset to 0 for defense-in-depth.

Trade-off: users must approve **V3Automation v6** (new spender), distinct from existing `swapAndMint` flows that approve V3Utils. Frontend gates on order type and uses the right spender.

### 3.5 Re-entrancy

`executeAutoEnter` and `executeFollowUp` are `nonReentrant`. V3Utils' swap calldata routes through 0x and may callback; existing `nonReentrant` on V3Utils protects there.

### 3.6 Foundry test scenarios (`test/AutoEnter.t.sol`)

1. `test_AutoEnter_Wallet_V3_HappyPath` — user approves V3Automation, signs v6 Order, operator executes, NFT minted to user.
2. `test_AutoEnter_Wallet_V3_WithSingleZap` — sourceToken=USDC, mint into ETH/USDC, one swap leg.
3. `test_AutoEnter_Wallet_V3_TwoZap` — split swap into both legs.
4. `test_AutoEnter_NoFollowUps` — followUps[] empty.
5. `test_AutoEnter_WithFollowUpRebalance` — mint + followUps[0]=AUTO_REBALANCE; later execute followUp[0].
6. `test_AutoEnter_WithMultipleFollowUps` — compound + rebalance + exit (3 distinct).
7. `test_FollowUp_RejectsWrongTokenId` — non-minted tokenId, reverts.
8. `test_FollowUp_RejectsWrongHash` — tampered config, reverts.
9. `test_FollowUp_RejectsWrongType` — execute.action=AUTO_EXIT but template.type=AUTO_COMPOUND, reverts.
10. `test_FollowUp_RejectsBeforeParentMint` — try before parent executed.
11. `test_AutoEnter_ExpiredOrder` — block.timestamp > signatureTime + window.
12. `test_AutoEnter_WrongSigner` — mismatched signer param.
13. `test_AutoEnter_SourceAmountExceeded` — p.sourceAmount > order.action.sourceAmount.
14. `test_AutoEnter_TickMismatch` — p.tickLower != order.action.tickLower.
15. `test_AutoEnter_SlippageFloorMissed` — amountAddMin0 not met by V3Utils.
16. `test_AutoEnter_Cancelled` — cancelOrder(parent) → follow-ups also fail.
17. `test_AutoEnter_NotOperator` — non-operator EOA, AccessControl revert.
18. `test_AutoEnter_DomainV6` — assert `_domainSeparatorV4()` matches expected v6.0 hash.
19. `test_AutoEnter_BackwardCompat_V5Still` — old v5 contract still validates v5 rebalance orders (proves cutover non-destructive).
20. `test_AutoEnter_ResetsAllowance` — after execute, V3Automation's allowance to V3Utils == 0.
21. `testFuzz_AutoEnter_RandomTicks` — random valid ticks, mint succeeds.

### 3.7 Foundry-Go digest cross-check

Add a special test that emits the EIP-712 digest of a canonical fixture to stdout. The corresponding `lp-auto-txn/version/v6/sig_helper_v6_test.go` test computes the same digest in Go. Both must match — protects against type-string drift.

```solidity
function test_DigestFixture() public {
    // Build canonical fixture matching backend's testdata
    StructHash.Order memory o = _canonicalFixture();
    bytes32 digest = _hashTypedDataV4(StructHash._hash(o));
    console2.logBytes32(digest);
}
```

### 3.8 Deployment

```bash
# Per chain
forge script script/UpgradeV6.s.sol \
    --rpc-url <chain_rpc> \
    --broadcast \
    --verify \
    --etherscan-api-key <key>

# Then admin txs:
cast send $V3AUTOMATION_V6 "setV3Utils(address)" $V3UTILS_EXISTING --rpc-url <chain>
cast send $V3AUTOMATION_V6 "grantRole(bytes32,address)" $OPERATOR_ROLE $WORKER_EOA --rpc-url <chain>
# Whitelist NFPMs per chain (existing pattern)
```

Coordinate with backend team: after deployment, share the v6 address so they can update `chainConfigs[chainId].AutomationContractV6` and flip `SignatureVersion="6.0"` for that chain.

### 3.9 Chain rollout order

Lower-risk first: Base Sepolia → Base → Arbitrum → Optimism → BNB → ETH mainnet.

### 3.10 Risk register

- **Allowance race**: V3Automation's allowance to V3Utils between `safeIncreaseAllowance` and `swapAndMint` could be drained by a malicious V3Utils. Mitigation: V3Utils is allowlisted (admin-set), only one tx-atomic call, allowance reset to 0 after.
- **Re-entrancy via swapData**: 0x routes callback into V3Utils. Existing `nonReentrant` on V3Automation entrypoint blocks re-entry into other entrypoints. `swapAndMint` is also `nonReentrant`.
- **Operator-controlled swap routing**: operator picks `swapData0/1` after order signed. Mitigation: V3Utils enforces `amountOut0Min`, `amountOut1Min`, `amountAddMin0/1` all derived from user's signed `swapSlippageX64`/`liquiditySlippageX64`.
- **Type-hash drift**: backend and contract computing different type-hashes. Mitigation: cross-check test (§3.7) in CI.

## 4. Verification

```bash
forge test --match-path test/AutoEnter.t.sol -vvv
forge coverage --match-path test/AutoEnter.t.sol
forge fmt --check
forge inspect V3Automation methodIdentifiers | grep -i autoEnter   # confirm selectors
```

End-to-end on testnet:
1. Deploy v6 on Base Sepolia.
2. Approve USDC to V3Automation v6 from test wallet.
3. Backend signs and broadcasts an AUTO_ENTER + 1 follow-up.
4. Observe `AutoEnterExecuted` event with correct tokenId.
5. Later, backend broadcasts `executeFollowUp` against the new tokenId.
6. Observe `FollowUpExecuted` and the underlying rebalance event.

## 5. Open questions

- **PoolDeployer for Pancake forks**: existing rebalance flow uses `pool.deployer()` for some chains. Confirm whether `executeAutoEnter` needs this field or it's resolved via `nfpm` alone.
- **Allowance cleanup on revert**: if `swapAndMint` reverts mid-allowance, allowance stays. Add cleanup in catch path? OpenZeppelin `Address.functionCall` doesn't expose catch. Decision: rely on `forceApprove(V3UTILS, 0)` AT START of function (before increasing) — idempotent and clears any stale allowance.
