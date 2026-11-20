# V3UtilsRouter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `V3UtilsRouter`: one fixed router that manages every v3-style position for users and the bot,
across all of V3Utils' protocols, whether the position is staked in a farm or not.

**Architecture:**
- A fixed router (roles, registries, orders, NFT guard) delegatecalls core modules chosen by selector.
- Modules delegatecall a per-NFPM protocol adapter and an optional per-NFPM operator-only farm.
- Shared state lives in one ERC-7201 slot.
- Params, swaps and fees follow v4utils' `IV4Utils`, with three fixes that scope everything to the call's own
  balances.

**Tech Stack:** Solidity 0.8.15, Foundry (fork tests), OpenZeppelin 4.9.6, v3-core/v3-periphery from `lib/`.

**Spec:** `docs/superpowers/specs/2026-11-18-v3utils-router-design.md` (approved 2026-11-19). Read it first; section
references below (§n) point into it.

**Reference code:**
- **PR #64**, branch `feat/aero-farming-helper` (`git show origin/feat/aero-farming-helper:<path>`):
  - `src/aero/AeroFarmingRouter.sol`: roles, orders, initialize guard, NFT guard;
  - `src/aero/AeroFarmingLogic.sol` and `src/aero/AeroGauge.sol`: Aero farm logic;
  - `src/aero/IAero.sol`;
  - `test/aero/*`.
- **v4utils** (`~/projects/v4utils/src`):
  - `univ4/V4Utils.sol`: `_swap`, `_takeFees`, flow shapes;
  - `univ4/interfaces/IV4Utils.sol`: structs;
  - `libraries/NativeCurrency.sol`.
- **This repo:**
  - `src/Nfpm.sol`: per-protocol mint structs and `getPosition` decoding;
  - `src/Common.sol`: fee caps, native config.

## Refinements to the spec (within what §9 leaves to the builder)

1. **No separate Automation module.**
   - `executeAutomation` records `account` and the target `(nfpm, tokenId)`, then delegatecalls the flow function
     for the action, with the bot's `actionData` as its params:
     - AUTO_ADJUST → `adjustRange`
     - AUTO_EXIT → `decreaseAndSwap`
     - AUTO_COMPOUND → `compound`
     - AUTO_HARVEST → `harvest`
   - Flows get the account from `_account(nfpm, tokenId)`. It returns the recorded account and requires the params'
     `nfpm`/`tokenId` to match the recorded target when automation is active; otherwise it returns `msg.sender`.
     So the four flows serve users and the bot alike.
2. **The NFT receive guard is a generic record, not a farm hook.**
   - Before a call that brings an NFT in by `safeTransferFrom` (an Aero gauge's `withdrawFrom`), the farm sets
     `RouterStorage.expectedNft = keccak256(abi.encode(nfpm, from, tokenId))`, and clears it after.
   - The router accepts an NFT only when the record matches `(msg.sender, from, tokenId)`.
   - This replaces the spec's `expectsNft` hook and keeps the router farm-agnostic, with less code.
3. **"Router selectors can never be registered"** is enforced by a test that checks module ABIs against the router
   ABI, not by router code. `execute` only ever delegatecalls modules, so a collision is harmless at runtime.
4. **No `unwrap` flag.** To unwrap, the caller ends `swaps[]` with a `WETH → address(0)` conversion step, as in
   v4utils.

## Global Constraints

- `solc = "0.8.15"`, default foundry profile, optimizer 200 runs.
- No `require(cond, CustomError())`: that needs solc ≥ 0.8.26. Use `if (!cond) revert CustomError();`.
- No linked libraries in any new contract. Only `internal` library functions; `linkReferences` must be `{}`.
- Every deployed contract is ≤ 24,576 bytes (`forge build --sizes`).
- New code lives under `src/router/`, tests under `test/router/`.
- Do not modify `src/V3Utils.sol`, `src/V3Automation.sol`, `src/Common.sol`, `src/CommonLib.sol`, `src/Nfpm.sol`,
  `src/StructHash.sol`, `src/EIP712.sol`, `foundry.toml` or `remappings.txt`.
- Native is `address(0)` in all token fields.
- `FeeType` ordinals: `GAS_FEE = 0`, `PERFORMANCE_FEE = 1`, `PROTOCOL_FEE = 2` (v4utils order).
- Default caps: gas `5534023222112865280` (30%), protocol `5534023222112865280` (30%), performance
  `5902958103587057000` (32%).
- EIP-712 domain: name `"V3UtilsRouter"`, version `"1"`, `verifyingContract` = the router. The order struct is
  `StructHash.Order`, hashed with `StructHash._hash(Order memory)` (internal; never the deployed library).
- ERC-7201 namespace: `"krystal.v3utils.router.storage"`.
- Roles:
  - `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE = keccak256("ADMIN_ROLE")` go to the admin (multisig);
  - `OPERATOR_ROLE = keccak256("OPERATOR_ROLE")`;
  - `WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE")`.
- **Fork tests:**
  - RPC env vars `ARBITRUM_RPC_URL`, `BSC_RPC_URL`, `BASE_RPC_URL`, `OP_RPC_URL`, plus one per extra chain a task
    adds.
  - Pin every fork block as a constant.
  - Aero tests need `FOUNDRY_EVM_VERSION=cancun`.
  - `makeAddr("user")` is an EIP-7702 account on Base; use other labels.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Tokens already sitting in the router before a call** (stray ERC20s, dust, native) must be neither swept to the
   caller nor consumed by an `amountIn == 0` swap. Test `test_preexistingBalances_untouched` (Task 3, and again
   end-to-end in Task 5).
2. **A caller acting on a position that is not theirs** must revert before anything moves. This covers both kinds
   of position: in someone else's wallet, even though the router has that owner's approval, and staked by someone
   else. Tests `test_notHolder_wallet_reverts` (Task 5) and `test_notHolder_staked_reverts` (Task 9).
3. **Fee-on-transfer or surcharge input tokens:**
   - if the router receives less than `amount`, revert `TransferError`;
   - nothing may be computed from the declared amount.

   Test `test_feeOnTransferInput_reverts` (Task 3), using the repo's surcharge-token mock pattern
   (`test/integration/SurchargeToken.t.sol`).
4. **`msg.value` that does not match the native inputs** (sent when no native input is declared, or a different
   amount) reverts `AmountError`. Native the call did not use comes back to the caller. Tests
   `test_msgValueMismatch_reverts` and `test_unusedNative_refunded` (Task 3).
5. **The same token twice in `inputTokens[]`, or a swap with `tokenIn == tokenOut`**, reverts `SameToken`. Test
   `test_duplicateInputOrSelfSwap_reverts` (Task 3).

---

## File Structure

```
src/router/
  V3UtilsRouter.sol          fixed router: roles, initialize, registries, config, lock, execute, executeAutomation,
                             orders, NFT guard, rescue, receive
  RouterStorage.sol          ERC-7201 Layout + layout()
  RouterTypes.sol            FeeType, SwapParams, InputTokenParams, PoolKey, Position, MintParams, IncreaseParams,
                             DecreaseParams, flow param structs, AutoAction
  IRouterErrors.sol          shared errors + events (TakeFees, flow events)
  interfaces/IAdapter.sol    protocol adapter ABI (delegatecalled)
  interfaces/IFarm.sol       farm ABI (delegatecalled)
  interfaces/ICoreMint.sol   swapAndMint, swapAndIncrease
  interfaces/ICoreModify.sol decreaseAndSwap, adjustRange, compound, harvest
  base/CoreBase.sol          abstract: onlyDelegateCall, _account, Ledger (open/held/close), _takeInputs, _takeFees,
                             _swaps, native conversion, adapter/farm delegate helpers, take/putBack custody
  base/NativeCurrency.sol    port of v4utils NativeCurrency to 0.8.15
  modules/CoreMint.sol       ICoreMint
  modules/CoreModify.sol     ICoreModify
  adapters/UniV3Adapter.sol, AlgebraV1Adapter.sol, AerodromeAdapter.sol, RamsesV3Adapter.sol,
  adapters/AlgebraIntegralAdapter.sol
  farms/AeroGaugeFarm.sol    IFarm for new Aero CL gauges (immutables: gaugeFactory, rewardToken, compoundEnabled)
  farms/AeroGauge.sol        gauge derivation (from PR #64, adapted)
script/V3UtilsRouter.s.sol   deploy + register per chain
test/router/
  RouterTestBase.sol, mocks/*, Router.t.sol, CoreBase.t.sol, adapters/*.t.sol, flows/*.t.sol, farms/*.t.sol,
  Automation.t.sol, Deploy.t.sol
```

---

### Task 1: Types, storage and the fixed router (admin, registries, execute, orders, NFT guard)

**Files:**
- Create: `src/router/RouterTypes.sol`, `src/router/RouterStorage.sol`, `src/router/IRouterErrors.sol`,
  `src/router/interfaces/IAdapter.sol`, `src/router/interfaces/IFarm.sol`, `src/router/V3UtilsRouter.sol`
- Test: `test/router/Router.t.sol`, `test/router/mocks/MockModule.sol`

**Interfaces:**
- Produces (`RouterTypes.sol`; exact names, used by every later task):
  - `enum FeeType { GAS_FEE, PERFORMANCE_FEE, PROTOCOL_FEE }`
  - `enum AutoAction { AUTO_ADJUST, AUTO_EXIT, AUTO_COMPOUND, AUTO_HARVEST }`
  - `struct SwapParams { address tokenIn; uint256 amountIn; address tokenOut; uint256 amountOutMin; bytes swapData; }`
  - `struct InputTokenParams { address token; uint256 amount; }`
  - `struct PoolKey { address token0; address token1; uint24 fee; int24 tickSpacing; address deployer; }`
  - `struct Position { PoolKey key; int24 tickLower; int24 tickUpper; uint128 liquidity; }`
  - `struct MintParams { int24 tickLower; int24 tickUpper; uint256 minLiquidity; uint256 deadline; }`
  - `struct IncreaseParams { uint256 minLiquidity; uint256 deadline; }`
  - `struct DecreaseParams { uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }`
  - `struct SwapAndMintParams { address nfpm; PoolKey key; MintParams mint; InputTokenParams[] inputTokens; SwapParams[] swaps; bool stake; uint64 protocolFeeX64; uint64 gasFeeX64; }`
  - `struct SwapAndIncreaseParams { address nfpm; uint256 tokenId; IncreaseParams increase; InputTokenParams[] inputTokens; SwapParams[] swaps; uint64 protocolFeeX64; uint64 gasFeeX64; }`
  - `struct DecreaseAndSwapParams { address nfpm; uint256 tokenId; DecreaseParams decrease; SwapParams[] swaps; address destToken; uint64 protocolFeeX64; uint64 performanceFeeX64; uint64 gasFeeX64; }`
  - `struct AdjustRangeParams { address nfpm; uint256 tokenId; SwapParams[] swaps; MintParams mint; bool compoundFees; uint64 protocolFeeX64; uint64 performanceFeeX64; uint64 gasFeeX64; }`
  - `struct CompoundParams { address nfpm; uint256 tokenId; SwapParams[] swaps; IncreaseParams increase; uint64 performanceFeeX64; }`
  - `struct HarvestParams { address nfpm; uint256 tokenId; SwapParams[] swaps; address destToken; uint64 performanceFeeX64; }`
- Produces (`RouterStorage.sol`): `library RouterStorage { struct Layout { address swapRouter; address feeTaker; address weth; uint8 nativeMode; uint256 nativeScale; mapping(uint8 => uint64) maxFeeX64; mapping(bytes4 => address) module; mapping(address => address) adapter; mapping(address => address) farm; bool locked; address automationAccount; bytes32 automationTarget; bytes32 expectedNft; } function layout() internal pure returns (Layout storage); }`
  - Slot = `keccak256(abi.encode(uint256(keccak256("krystal.v3utils.router.storage")) - 1)) & ~bytes32(uint256(0xff))`,
    written as a literal constant, with a `/// @custom:storage-location erc7201:krystal.v3utils.router.storage`
    comment.
  - `nativeMode`: 0 = WRAPPED, 1 = ENSHRINED.
  - `automationTarget` = `keccak256(abi.encode(nfpm, tokenId))`.
- Produces (`IAdapter.sol`; all called by delegatecall with the NFPM passed in):
  - `position(address nfpm, uint256 tokenId) returns (Position)`
  - `pool(address nfpm, PoolKey key) returns (address)`
  - `mint(address nfpm, PoolKey key, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, address recipient, uint256 deadline) returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1)`
  - `increase(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline) returns (uint128 liquidity, uint256 used0, uint256 used1)`
  - `decrease(address nfpm, uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, uint256 deadline) returns (uint256 amount0, uint256 amount1)` (amounts become owed; `collect` takes them)
  - `collect(address nfpm, uint256 tokenId) returns (uint256 amount0, uint256 amount1)` (collects everything owed to the router)
  - Adapters approve the NFPM for exactly `amount0`/`amount1` inside mint/increase and reset the allowance to 0
    after.
- Produces (`IFarm.sol`; delegatecalled):
  - `isStakedBy(address nfpm, uint256 tokenId, address account) returns (bool)`. This is a yes/no check, not an
    address lookup: new Aero CLGauges only expose `stakedContains(depositor, tokenId)`, and MasterChef exposes
    `userPositionInfos(id).user`, so both can answer it.
  - `canUnstake() returns (bool)`, `canIncreaseStaked() returns (bool)`, `earnsTradingFees() returns (bool)`
  - `rewardToken() returns (address)`
  - `checkStakeable(address nfpm, PoolKey key)` (reverts if no live farm for that pool)
  - `stake(address nfpm, uint256 tokenId, address account)`
  - `unstake(address nfpm, uint256 tokenId, address account)`
  - `claim(address nfpm, uint256 tokenId, address account) returns (uint256 amount)`
  - `increaseStaked(address nfpm, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 deadline) returns (uint128 liquidity, uint256 used0, uint256 used1)`
- Produces (`V3UtilsRouter.sol`):
  - **Setup and admin:**
    - `initialize(address admin, address operator, address withdrawer, address swapRouter, address feeTaker, address weth, uint8 nativeMode)`:
      only the deploying `tx.origin`, once; rejects zero `admin`/`feeTaker`/`weth`; ENSHRINED scale comes from
      `weth.decimals()` (reject > 18).
    - `setModule(bytes4 selector, address module)`, `setAdapter(address nfpm, address adapter)`,
      `setFarm(address nfpm, address farm)`: `ADMIN_ROLE`; non-zero targets need code; zero unregisters; revert
      `Locked()` after lock.
    - `setSwapRouter(address)`, `setNativeConfig(address weth, uint8 nativeMode)`: revert `Locked()` after lock.
    - `setFeeTaker(address)`: always allowed.
    - `setMaxFeeX64(FeeType, uint64)`: after lock, only a value ≤ the current one.
    - `lock()`: one-way.
    - `pause()`/`unpause()` (`ADMIN_ROLE`); `withdrawERC20/ERC721/Native` (`WITHDRAWER_ROLE`).
    - Getters: `module(bytes4)`, `adapter(address)`, `farm(address)`, `swapRouter()`, `feeTaker()`,
      `maxFeeX64(FeeType)`, `weth()`, `locked()`.
  - **Entry points:**
    - `execute(bytes data) payable returns (bytes)`: `nonReentrant whenNotPaused`; delegatecall
      `module[bytes4(data)]`; revert `UnknownSelector()` when unset; bubble reverts.
    - `executeAutomation(address account, address nfpm, uint256 tokenId, AutoAction action, bytes actionData, bytes order, bytes signature) returns (bytes)`.
      Checks, in this order:
      1. `OPERATOR_ROLE`, `nonReentrant`, `whenNotPaused`.
      2. `adapter[nfpm] != 0`, else `UnsupportedNfpm()`.
      3. Holder check: `account` must be staked per the farm (if `farm[nfpm] != 0`, delegatecall
         `isStakedBy(nfpm, tokenId, account)`) or be `IERC721(nfpm).ownerOf(tokenId)`, else
         `NotPositionHolder()`.
      4. Order check: `order.chainId == block.chainid`, else `WrongChainId()`; `order.nfpmAddress == nfpm`, else
         `WrongPositionManager()`; the signature verifies through `SignatureValidator`; not cancelled.

      Then it records `automationAccount`/`automationTarget`, delegatecalls `module[sel]` with
      `abi.encodePacked(sel, actionData)` (`sel` per Refinement 1), clears both, and bubbles reverts.
  - **Orders and receiving:**
    - `hashOrder(bytes)`, `cancelOrder(bytes32, bytes)`, `isOrderCancelled(address, bytes32)`,
      `DOMAIN_SEPARATOR` (immutable). Port these from PR #64.
    - `onERC721Received`: accept only if `adapter[msg.sender] != 0` and
      `expectedNft == keccak256(abi.encode(msg.sender, from, tokenId))`, else `UnexpectedNft()`.
    - `receive()`: only from `weth` while WRAPPED.

- [ ] **Step 1: Write the failing tests** in `test/router/Router.t.sol`. No fork; `MockModule` returns
  `abi.encode(msg.sender, address(this))` from `ping()`, and has a `poke()` that writes
  `RouterStorage.layout().feeTaker`.
  - `test_storageSlot_matchesErc7201`: the constant equals the formula above.
  - `test_feeTypeOrdinals`: `uint8(FeeType.GAS_FEE) == 0`, `PERFORMANCE_FEE == 1`, `PROTOCOL_FEE == 2`.
  - `test_initialize_onlyDeployerOnce_andDefaults`:
    - initialize from a non-`tx.origin` sender reverts `NotInitializer()`;
    - a second initialize reverts `AlreadyInitialized()`;
    - the default caps equal the three Global Constraints values;
    - zero admin, feeTaker or weth reverts `ZeroAddress()`.
  - `test_execute_dispatchesBySelector_preservesSender`: after `setModule(MockModule.ping.selector, m)`,
    `execute(abi.encodeCall(MockModule.ping, ()))` from `alice` decodes to `(alice, router)`.
  - `test_execute_unknownSelector_reverts`: `UnknownSelector()`.
  - `test_registries_requireCode_andAdminRole`:
    - an EOA target reverts `InvalidTarget()`;
    - a non-admin caller gets the AccessControl revert;
    - `address(0)` unregisters.
  - `test_lock_freezesRegistriesSwapRouterNative_capsOnlyDown`:
    - after `lock()`, `setModule`/`setAdapter`/`setFarm`/`setSwapRouter`/`setNativeConfig` revert `Locked()`;
    - `setMaxFeeX64(PERFORMANCE_FEE, 1 << 60)` succeeds, then raising it back reverts `Locked()`;
    - `setFeeTaker` still works.
  - `test_onERC721Received_onlyExpected`:
    - an unregistered NFPM, or a registered one with no or a mismatched `expectedNft`, reverts `UnexpectedNft()`;
    - with a matching record it returns the selector.
  - `test_receive_onlyWeth`.
  - `test_pause_blocksExecuteAndAutomation`.
  - `test_cancelOrder_andHashOrder_domain`: the domain separator equals the EIP-712 formula with name
    `"V3UtilsRouter"`, version `"1"`; cancel works per actor (port from PR #64).

- [ ] **Step 2: Run them and confirm they fail.**
  Run: `forge test --match-path test/router/Router.t.sol`. Expected: compile errors / FAIL.

- [ ] **Step 3: Implement the files above.** Port roles, the initialize guard, orders and rescue from PR #64's
  `AeroFarmingRouter.sol`. `executeAutomation` is implemented here, but its end-to-end tests are in Task 10.

- [ ] **Step 4: Run them and confirm they pass**, and check the size with
  `forge build --sizes | grep V3UtilsRouter` (≤ 24,576).

- [ ] **Step 5: Commit.** `feat(router): fixed router, storage, types, adapter/farm interfaces`

### Task 2: NativeCurrency port

**Files:**
- Create: `src/router/base/NativeCurrency.sol`
- Test: `test/router/NativeCurrency.t.sol`

**Interfaces:**
- Produces: `library NativeCurrency` (internal functions only), ported from v4utils with `require(c, E())` →
  `if (!c) revert E();`:
  - `toTokenUnits(address weth, bool enshrined, uint256 nativeAmount) returns (uint256)`
  - `toNativeUnits(address weth, bool enshrined, uint256 tokenAmount) returns (uint256)`
  - `scaleOf(address weth) returns (uint256)`

- [ ] **Step 1: Write the failing tests**, porting v4utils' native tests where they exist, plus this repo's
  `test/EnshrinedNative.t.sol` cases:
  - WRAPPED: 1:1 through `deposit`/`withdraw`;
  - ENSHRINED with a 6-decimal mock: `toTokenUnits(1e12 + 5)` gives `1`, and the dust stays as native;
    `toNativeUnits(1)` gives `1e12`;
  - more than 18 decimals reverts `UnsupportedNativeDecimals()`.
- [ ] **Step 2: Run and confirm the failure.** Run: `forge test --match-path test/router/NativeCurrency.t.sol`.
- [ ] **Step 3: Port the library.**
- [ ] **Step 4: Run and confirm they pass.**
- [ ] **Step 5: Commit.** `feat(router): NativeCurrency port`

### Task 3: CoreBase: ledger, inputs, fees, swaps, account, custody helpers

**Files:**
- Create: `src/router/base/CoreBase.sol`
- Test: `test/router/CoreBase.t.sol`, `test/router/mocks/CoreHarness.sol` (exposes the internals, deployed behind
  the router via `setModule`), `test/router/mocks/MockSwapRouter.sol` (`swap(tokenIn, tokenOut, amountOut)` pulls
  its full allowance of `tokenIn` and pays `amountOut` from a pre-dealt balance), `test/router/mocks/MockERC20.sol`
  (includes a fee-on-transfer variant)

**Interfaces:**
- Consumes: Task 1 types and storage; Task 2 `NativeCurrency`.
- Produces (`abstract contract CoreBase is IRouterErrors`; internal unless noted):
  - `modifier onlyDelegateCall`.
  - `struct Ledger { address[] tokens; uint256[] start; }`
    - `_open(address[] memory candidates) returns (Ledger memory)` de-duplicates, skips zero-length candidates
      except native, and snapshots `start`. For native, `start = address(this).balance - msg.value`.
    - `_held(Ledger memory, address token) returns (uint256)` is `balanceNow - start`, saturating at 0. It reverts
      `NotTracked()` for a token not in the ledger.
    - `_close(Ledger memory, address to)` sends `_held` of every ledger token to `to`; native is sent with a call.
  - `_account(address nfpm, uint256 tokenId) returns (address)` (Refinement 1).
  - `_takeInputs(InputTokenParams[] memory inputs)`:
    - pulls the ERC20s with `safeTransferFrom` from `msg.sender` and checks the balance delta equals `amount`,
      else `TransferError()`;
    - native inputs must sum to exactly `msg.value`, and `msg.value` must be 0 when there are none, else
      `AmountError()`;
    - a duplicate token reverts `SameToken()`.
  - `_takeFees(address nfpm, uint256 tokenId, address account, address[] memory tokens, uint256[] memory amounts, uint64 feeX64, FeeType t) returns (uint256[] memory taken)`:
    - checks `feeX64 <= maxFeeX64[uint8(t)]`, else `TooMuchFee()`;
    - each fee is `FullMath.mulDiv(amount, feeX64, 2**64)`, sent to `feeTaker`;
    - emits `TakeFees(nfpm, tokenId, account, TakeFeesEventData(feeTokens, feeX64, t))` with v4utils' shape;
    - `feeX64 == 0` does nothing and emits nothing.
  - `_swaps(Ledger memory, SwapParams[] memory)` runs the steps in order:
    - `tokenIn == tokenOut` reverts `SameToken()`;
    - `amountIn == 0` means `_held(ledger, tokenIn)`;
    - a native↔`weth` pair is a conversion through `NativeCurrency`, and `swapData` is ignored;
    - otherwise it approves `swapRouter` for exactly `amountIn`, calls `swapRouter.call{value}(swapData)`
      (`SwapFailed(swapData, i)` on failure), and resets the allowance;
    - it checks the `tokenOut` delta ≥ `amountOutMin`, else `SwapSlippage()`, and emits
      `Swap(tokenIn, tokenOut, amountInDelta, amountOutDelta)`;
    - `swapRouter == address(0)` reverts `ZeroSwapRouter()`.
  - `_adapter(address nfpm) returns (address)` reverts `UnsupportedNfpm()` when unset.
  - `_farm(address nfpm) returns (address)` may return zero.
  - `_delegate(address target, bytes memory data) returns (bytes memory)` bubbles reverts.
  - **Custody**, implemented with farm calls stubbed by a mock farm here and exercised for real in Task 9:
    - `_take(address nfpm, uint256 tokenId, address account) returns (bool staked)`:
      - if the farm's `isStakedBy(nfpm, tokenId, account)` is true: require `canUnstake`, else
        `FarmUnsupported()`; then `unstake`;
      - else if `ownerOf == account`: `transferFrom(account, router, id)`;
      - else `NotPositionHolder()`.
    - `_putBack(address nfpm, uint256 tokenId, address account, bool staked)`: `staked` → farm `stake`, else
      `transferFrom(router, account, id)`.

- [ ] **Step 1: Write the failing tests** (no fork; mocks; the harness runs behind a real `V3UtilsRouter`):
  - `test_ledger_heldIsDeltaOnly`: seed the router with 7 units of token A, open, receive 5: `_held` is 5, and
    `_close` sends 5 and leaves 7.
  - `test_preexistingBalances_untouched` (Review Focus 1): router pre-seeded with A and native. A call with an
    `amountIn == 0` A→B swap swaps only the call's A, and `_close` returns only the call's tokens. The router's A
    and native are unchanged afterwards.
  - `test_feeOnTransferInput_reverts` (Review Focus 3): `TransferError()`.
  - `test_msgValueMismatch_reverts` (Review Focus 4): no native input with `msg.value > 0`, and native input 1 ether
    with `msg.value` 2 ether, both revert `AmountError()`.
  - `test_unusedNative_refunded` (Review Focus 4): native input 1 ether, a swap consumes 0.4: `_close` returns 0.6.
  - `test_duplicateInputOrSelfSwap_reverts` (Review Focus 5): `SameToken()` for both.
  - `test_takeFees_capsAndEvent`:
    - cap + 1 reverts `TooMuchFee()`;
    - 25% of [100, 40] sends [25, 10] to `feeTaker`;
    - the emitted `TakeFees` decodes to those tokens and amounts, with `feeType` PROTOCOL_FEE;
    - fee 0 emits nothing.
  - `test_swaps_sequenceMultiHop_andSlippage`: A→B then B→C with `amountIn == 0` on the second step ends with C
    only. `amountOutMin` above the payout reverts `SwapSlippage()`.
  - `test_swaps_nativeConversion_wrappedAndEnshrined`: on a WRAPPED mock WETH, native→weth and weth→native move
    1:1. On an ENSHRINED 6-decimal mock, `swapData` is ignored and the units convert.
  - `test_take_wallet_and_notHolder`:
    - owner `alice` with approval: the NFT moves to the router;
    - `bob` calling for alice's token: `NotPositionHolder()`, even with alice's approval to the router.
  - `test_take_stakedFarmCannotUnstake_reverts`: a mock farm with `isStakedBy(…, alice) == true` and
    `canUnstake == false` reverts `FarmUnsupported()`.
- [ ] **Step 2: Run and confirm the failure.** Run: `forge test --match-path test/router/CoreBase.t.sol`.
- [ ] **Step 3: Implement `CoreBase`.**
- [ ] **Step 4: Run and confirm they pass.**
- [ ] **Step 5: Commit.** `feat(router): CoreBase ledger, inputs, fees, swaps, custody`

### Task 4: UniV3Adapter and the shared adapter conformance suite

**Files:**
- Create: `src/router/adapters/UniV3Adapter.sol`
- Test: `test/router/RouterTestBase.sol`, `test/router/adapters/AdapterConformance.sol` (abstract),
  `test/router/adapters/UniV3Adapter.t.sol`

**Interfaces:**
- Consumes: `IAdapter` (Task 1).
- Produces:
  - `contract UniV3Adapter is IAdapter` with `onlyDelegateCall`. `position` decodes v3-periphery's `positions()`
    (`fee` set, `tickSpacing` read from the pool, `deployer = 0`). `pool` uses
    `IUniswapV3Factory(nfpm.factory()).getPool(token0, token1, fee)`.
  - `RouterTestBase` provides:
    - fork helpers: `_forkArbitrum()`, `_forkBsc()`, `_forkBase()`, `_forkOp()`, each with a pinned block
      constant;
    - `_deployRouter()`: deploys and initializes with test roles;
    - `_register(nfpm, adapter, farm)`;
    - `_dealAndApprove(token, who, amount)`.
  - `abstract contract AdapterConformance is RouterTestBase` has a virtual fixture `(nfpm, adapter, key, ticks)` and
    tests mint → increase → decrease → collect → `position` → `pool` through a harness module. Every adapter task
    inherits it.

- [ ] **Step 1: Write the failing conformance tests:**
  - `test_conformance_mintIncreaseDecreaseCollect`: amounts reconcile with balance deltas, and `position` reflects
    each change.
  - `test_conformance_poolLookup`: `pool(key)` equals the fork pool constant.
  - `test_conformance_allowanceReset`: the router's allowance to the NFPM is 0 after mint and increase.

  Fixtures:
  - Uniswap v3 on Arbitrum: NFPM `0xC36442b4a4522E871399CD717aBDD847Ab11FE88`, WETH
    `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`, USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, fee 500.
  - Pancake v3 on BSC with the same adapter: NFPM `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`, a liquid pair at a
    pinned block.
- [ ] **Step 2: Run and confirm the failure.** Run:
  `ARBITRUM_RPC_URL=… BSC_RPC_URL=… forge test --match-path 'test/router/adapters/UniV3Adapter.t.sol'`.
- [ ] **Step 3: Implement `UniV3Adapter`.**
- [ ] **Step 4: Run and confirm they pass.**
- [ ] **Step 5: Commit.** `feat(router): UniV3 adapter + adapter conformance suite`

### Task 5: CoreMint: swapAndMint and swapAndIncrease (unstaked)

**Files:**
- Create: `src/router/interfaces/ICoreMint.sol`, `src/router/modules/CoreMint.sol`
- Test: `test/router/flows/CoreMint.t.sol`

**Interfaces:**
- Consumes: `CoreBase` (Task 3), the adapters (Task 4), `RouterTestBase`.
- Produces:
  - `swapAndMint(SwapAndMintParams) payable returns (uint256 tokenId, uint128 liquidity)`
  - `swapAndIncrease(SwapAndIncreaseParams) payable returns (uint128 liquidity)`
  - Events `SwapAndMint(address indexed nfpm, uint256 indexed tokenId, uint256 liquidity, uint256 amount0, uint256 amount1)`
    and `SwapAndIncrease(...)`, same fields.
  - Pipeline (spec §6.6):
    1. open the ledger over inputs, swap legs and pool tokens;
    2. take the inputs;
    3. take `PROTOCOL_FEE`, then `GAS_FEE`, on the inputs;
    4. swaps;
    5. mint or increase with `_held` of token0/token1, and revert `LiquiditySlippage()` if below `minLiquidity`;
    6. mint to the router;
    7. put back (`stake == false`: send to the account; `stake == true` is handled in Task 9, and reverts
       `FarmUnsupported()` when the NFPM has no farm);
    8. `_close` to the account.

    For increase, take the position (Task 3 `_take`) and put it back.

- [ ] **Step 1: Write the failing fork tests** (Arbitrum Uniswap v3):
  - Set `swapRouter` to Uniswap SwapRouter `0xE592427A0AEce92De3Edee1F18E0157C05861564`. Build `swapData` in the
    test as `abi.encodeCall(ISwapRouter.exactInputSingle, (... recipient: address(router) ...))`.
  - `test_swapAndMint_twoInputsOneSwap`:
    - inputs WETH and USDC, one USDC→WETH swap;
    - the NFT goes to the user, the router ends with zero of every token;
    - the fee-taker deltas equal the protocol and gas fee math;
    - one `TakeFees` per non-zero fee type.
  - `test_swapAndMint_thirdTokenInput_multiHop`: the only input is ARB, swapped ARB→WETH and WETH→USDC (the
    second step with `amountIn == 0`); a position is minted.
  - `test_swapAndMint_nativeIn_unwrapLeftover`: native input, `native→WETH` conversion first, and the swap list
    ends with `WETH→native` `amountIn == 0`. The user receives the leftover as native.
  - `test_swapAndMint_minLiquidity_reverts`: `LiquiditySlippage()`.
  - `test_swapAndIncrease_ownerOnly`, which is `test_notHolder_wallet_reverts` (Review Focus 2): `bob`, with
    alice's NFT approved to the router, gets `NotPositionHolder()`; alice succeeds and gets the NFT back.
  - `test_preexistingBalances_untouched` end-to-end: pre-seed the router with WETH and USDC; afterwards both are
    unchanged.
  - `test_parity_swapAndMint_vsV3Utils`:
    - the same inputs through the deployed V3Utils `0xb4acbc082b5e7ded571c98ee4257778a9d784b36` (whitelist the
      NFPM in-test via the admin, or skip if V3Utils is not on the fork chain);
    - liquidity within 0.01% and equal fee amounts.
- [ ] **Step 2: Run and confirm the failure.**
- [ ] **Step 3: Implement `CoreMint`,** registering both selectors in the test base.
- [ ] **Step 4: Run and confirm they pass,** and check the size is ≤ 24,576.
- [ ] **Step 5: Commit.** `feat(router): CoreMint swapAndMint/swapAndIncrease`

### Task 6: CoreModify: decreaseAndSwap and adjustRange (unstaked)

**Files:**
- Create: `src/router/interfaces/ICoreModify.sol`, `src/router/modules/CoreModify.sol`
- Test: `test/router/flows/CoreModify.t.sol`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:
  - `decreaseAndSwap(DecreaseAndSwapParams) returns (uint256 amountOut)`
  - `adjustRange(AdjustRangeParams) returns (uint256 newTokenId, uint128 liquidity)`
  - Events `DecreaseAndSwap(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, address token, uint256 amount)`
    and `AdjustRange(address indexed nfpm, uint256 indexed tokenId, uint256 newTokenId, uint256 liquidity, uint256 added0, uint256 added1)`.
  - **decreaseAndSwap:**
    1. take the position;
    2. collect the earned fees first, and take `PERFORMANCE_FEE` on them (plus `GAS_FEE` when
       `liquidity == 0`, as in v4utils);
    3. decrease and collect the principal, and take `PROTOCOL_FEE` + `GAS_FEE` on it;
    4. swaps;
    5. put back: liquidity remaining keeps the position's state; full withdraw always goes to the wallet (§6.4);
    6. `_close`.

    `amountOut` is the `destToken` delta.
  - **adjustRange:**
    1. take the position;
    2. collect the fees and take `PERFORMANCE_FEE`; if `!compoundFees`, send the net fees to the account
       *before* the swaps (v4utils GHSA-v6cm);
    3. decrease all, collect, and take `PROTOCOL_FEE` + `GAS_FEE`;
    4. swaps;
    5. mint the new range;
    6. the new NFT goes back to the old one's state, and the old empty NFT goes to the wallet;
    7. `_close`.

- [ ] **Step 1: Write the failing fork tests** (Arbitrum Uniswap v3, alice's minted position from Task 5's
  helper):
  - `test_decrease_partial_keepsNftInWallet`.
  - `test_decrease_full_toDestToken_amountOutIsDelta`: pre-seed the router with `destToken`; `amountOut` equals
    the user's delta (v4utils GHSA-m36p).
  - `test_decrease_zeroLiquidity_collectsFeesOnly_performanceFee`: after a fork swap that generates fees,
    `liquidity: 0` collects; `TakeFees` has feeType PERFORMANCE_FEE.
  - `test_adjustRange_notCompounding_returnsFeesBeforeSwaps`: the user receives the net fees, and the swaps only see
    principal (a swap with `amountIn == 0` sells only principal).
  - `test_adjustRange_newRange_oldNftReturnedEmpty`.
  - `test_parity_decrease_vsV3Utils`: as in Task 5.
- [ ] **Step 2: Run and confirm the failure.**
- [ ] **Step 3: Implement both flows** in `CoreModify`.
- [ ] **Step 4: Run and confirm they pass,** and check the size.
- [ ] **Step 5: Commit.** `feat(router): CoreModify decreaseAndSwap/adjustRange`

### Task 7: CoreModify: compound and harvest (unstaked trading fees)

**Files:**
- Modify: `src/router/modules/CoreModify.sol`, `src/router/interfaces/ICoreModify.sol`
- Test: `test/router/flows/CompoundHarvest.t.sol`

**Interfaces:**
- Produces:
  - `compound(CompoundParams) returns (uint128 liquidity)`
  - `harvest(HarvestParams) returns (uint256 amountOut)`
  - Events `CompoundFees(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)`
    and `Harvest(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount)`.
  - **Unstaked path:** take, collect fees, `PERFORMANCE_FEE`, swaps, increase (compound) or `_close` with
    `destToken` (harvest), put back.
  - **Staked path:** added in Task 9.
- [ ] **Step 1: Write the failing tests:**
  - `test_compound_tradingFees_increasesLiquidity_performanceFee`.
  - `test_harvest_tradingFees_toDestToken`.
  - `test_harvest_destTokenNoSwaps_reverts`: with `destToken` set and different from both pool tokens,
    `swaps.length == 0` and fees > 0, revert `MissingSwapData()` (carried over from PR #64).
- [ ] **Step 2: Run and confirm the failure.**
- [ ] **Step 3: Implement both flows.** If `CoreModify` exceeds 24,576 bytes, move `compound`/`harvest` to
  `src/router/modules/CoreRewards.sol` and register them there.
- [ ] **Step 4: Run and confirm they pass,** and check the sizes.
- [ ] **Step 5: Commit.** `feat(router): compound/harvest of trading fees`

### Task 8: Remaining adapters (AlgebraV1, Aerodrome, RamsesV3, AlgebraIntegral)

**Files:**
- Create: `src/router/adapters/AlgebraV1Adapter.sol`, `AerodromeAdapter.sol`, `RamsesV3Adapter.sol`,
  `AlgebraIntegralAdapter.sol`
- Test: one `test/router/adapters/<Name>.t.sol` per adapter, each inheriting `AdapterConformance`

**Interfaces:**
- Produces: one `IAdapter` per protocol. Mint structs and `positions()` layouts come from `src/Nfpm.sol`:
  - **AlgebraV1:** no fee or tickSpacing in mint; `positions()` has no fee field; `pool` via
    `IAlgebraFactory(nfpm.factory()).poolByPair`.
  - **Aerodrome:** mint uses `tickSpacing`, with `sqrtPriceX96 = 0`; `positions()` slot 5 is `tickSpacing`; `pool`
    via `ICLFactory(nfpm.factory()).getPool(t0, t1, tickSpacing)` (as PR #64's `AeroGauge`).
  - **RamsesV3:** `positions()` has no nonce or operator; mint uses `tickSpacing`.
  - **AlgebraIntegral:** mint uses `deployer`; `positions()` slot 5 is `deployer`; `pool` via
    `poolByPair`/`customPoolByPair(deployer, …)`.

- [ ] **Step 1: Write the failing conformance tests per adapter.** Fixtures:
  - AlgebraV1: Camelot V3 on Arbitrum, NFPM `0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15`.
  - Aerodrome: Base, NFPM `0x4857DB576eE0e45F10525eC59527BfD10beeC60b`, WETH/USDC pool
    `0x4A7af46bC8aBc00048c6c7920a1488DAF568366c` (tickSpacing 50), block `56384489`, `cancun`.
  - RamsesV3 and AlgebraIntegral: find a live NFPM by enumerating the deployed V3Utils whitelist on the chains in
    `contracts.json`:
    1. `_whitelistedNfpm` is the EnumerableSet whose length is at slot 2 and whose entries are at
       `keccak256(2) + i`. Read them with `cast storage`.
    2. Classify each NFPM by probing `positions(id)`'s return length.
    3. Record the chain, NFPM and block in the test.
    4. **If no live NFPM exists for a protocol, stop and report it.** Do not ship an adapter without a fork test.
- [ ] **Step 2: Run each test and confirm it fails.**
- [ ] **Step 3: Implement the adapters.**
- [ ] **Step 4: Run them and confirm they pass,** with every adapter ≤ 24,576.
- [ ] **Step 5: Commit, once per adapter.** `feat(router): <Name> adapter`

### Task 9: AeroGaugeFarm and staked paths in every flow

**Files:**
- Create: `src/router/farms/AeroGauge.sol` (adapted from PR #64's `src/aero/AeroGauge.sol`, reading the factory
  from an immutable passed in), `src/router/farms/AeroGaugeFarm.sol`
- Modify: `src/router/modules/CoreMint.sol`, `src/router/modules/CoreModify.sol` (or `CoreRewards.sol`)
- Test: `test/router/farms/AeroGaugeFarm.t.sol`, `test/router/flows/Staked.t.sol` (port PR #64's
  `test/aero/AeroFarmingRouter.{zap,modify,compound,op}.t.sol` cases to the new ABI)

**Interfaces:**
- Consumes: `IFarm` (Task 1), the custody helpers (Task 3), the Aerodrome adapter (Task 8).
- Produces: `contract AeroGaugeFarm is IFarm`:
  - **Constructor and immutables:** `constructor(address gaugeFactory, address rewardToken, bool compoundEnabled)`,
    all immutable.
  - **Capabilities:** `canUnstake() == true`, `canIncreaseStaked() == false`, `earnsTradingFees() == false`.
  - **`isStakedBy`:** derive the gauge with `AeroGauge.ofToken(nfpm, id)`. It returns false when the pool has no
    gauge, instead of reverting, so wallet positions in gauge-less pools still work. Otherwise it returns
    `gauge.stakedContains(account, id)`, as in PR #64.
  - **`stake`:** `checkStakeable`, `approve(gauge, id)`, `depositFor(id, account)`.
  - **`unstake`:**
    1. set `expectedNft = keccak256(abi.encode(nfpm, gauge, id))`;
    2. `withdrawFrom(id, account)`;
    3. clear the record.

    Emissions follow PR #64: the router receives them when the user has called `approveForClaim`, and the ledger
    sweeps them to the user.
  - **`claim`:** `claimEmissions(account, router, [id])`; returns the `rewardToken` delta.
  - **`checkStakeable`:** `AeroGauge.ofPool` plus a live check.
- **Staked behaviour in the modules (spec §6.4–§6.7):**
  - `swapAndMint` with `stake` calls `checkStakeable` before minting, mints to the router, then calls `stake`.
  - `swapAndIncrease` on a staked position: if `canIncreaseStaked`, it calls `farm.increaseStaked` in place, with
    no take or put back. Otherwise it unstakes, increases and restakes. Aero takes the second path; the first is
    for a future MasterChef farm, tested with a mock farm here.
  - Every flow on an existing position uses `_take`/`_putBack`, keeping the staking state. A full withdraw always
    goes to the wallet.
  - `compound`/`harvest` on a staked position: `claim` (requires `canUnstake`), `PERFORMANCE_FEE` on the reward,
    then swaps, then increase (unstake → increase → restake) for compound, or pay out for harvest. The trading-fee
    path is skipped when `earnsTradingFees` is false.
  - Compound on a staked position requires `compoundEnabled`, else `CompoundDisabled()`.

- [ ] **Step 1: Write the failing tests** (Base block `56384489`, `cancun`; gauge
  `0x46a9dCa72D78366571bE583aa69C1DC16E6889fB`; OP block `159434366` for xAERO):
  - `test_mintAndStake_stakedForUser_routerHoldsNothing`.
  - `test_mintAndStake_poolWithoutGauge_reverts`.
  - `test_mint_noStake_poolWithoutGauge_ok`.
  - `test_increase_staked_restaked`.
  - `test_increase_staked_inPlaceFarm_mock`: a mock farm with `canIncreaseStaked == true` receives exactly one
    `increaseStaked` call, and the NFT never leaves it.
  - `test_harvest_staked_destTokenNoSwaps_reverts`: `MissingSwapData()` when `destToken` is not the reward token,
    the claim is non-zero and `swaps` is empty.
  - `test_decrease_partial_staked_staysStaked`.
  - `test_decrease_full_staked_endsInWallet`.
  - `test_adjustRange_staked_newNftStaked_oldToWallet`.
  - `test_compound_staked_rewards_performanceFee`.
  - `test_harvest_staked_rewards_staysStaked`.
  - `test_harvest_staked_requiresApproveForClaim`.
  - `test_notHolder_staked_reverts` (Review Focus 2).
  - `test_unsolicitedNft_rejected`.
  - `test_op_compoundDisabled_harvestPaysXAero`.
- [ ] **Step 2: Run and confirm the failure.**
- [ ] **Step 3: Implement the farm and the staked branches.**
- [ ] **Step 4: Run all `test/router` tests and confirm they pass,** with module sizes ≤ 24,576.
- [ ] **Step 5: Commit.** `feat(router): AeroGaugeFarm + staked paths`

### Task 10: Automation end-to-end

**Files:**
- Test: `test/router/Automation.t.sol` (port PR #64's `AeroFarmingRouter.automation.t.sol` and `router.t.sol`
  order cases)
- Modify: `src/router/V3UtilsRouter.sol` and `src/router/base/CoreBase.sol` only if the tests expose a gap.

**Interfaces:**
- Consumes: `executeAutomation` (Task 1), `_account` (Task 3), the flows (Tasks 5–9).

- [ ] **Step 1: Write the failing tests** (Arbitrum for an unstaked Uniswap position; Base for a staked Aero one):
  - `test_auto_adjust_unstaked_and_staked`: AUTO_ADJUST with `AdjustRangeParams` `actionData`; the new NFT keeps
    the old one's state.
  - `test_auto_exit_staked_toWallet`.
  - `test_auto_compound_staked_rewards`.
  - `test_auto_harvest_unstaked_tradingFees`.
  - `test_auto_paramsTargetMismatch_reverts`: `actionData` names a different `tokenId` than the checked one, and
    reverts `NotAutomation()`.
  - `test_auto_notHolder_reverts`.
  - `test_auto_wrongChainOrNfpm_reverts`.
  - `test_auto_cancelledOrder_reverts`.
  - `test_auto_onlyOperator`.
  - `test_execute_cannotSpoofAutomation`: a user calling `execute(adjustRange(params for someone else's token))`
    reverts `NotPositionHolder()`.
  - `test_automationRecordCleared`: after a run, `automationAccount` and `automationTarget` are 0.
- [ ] **Step 2: Run and confirm the failure.**
- [ ] **Step 3: Fix any gaps.**
- [ ] **Step 4: Run and confirm they pass.**
- [ ] **Step 5: Commit.** `test(router): automation end-to-end`

### Task 11: Deploy script, verify, sizes, docs

**Files:**
- Create: `script/V3UtilsRouter.s.sol`
- Modify: `script/Verify.s.sol` (append only), `Makefile` (add targets), `sample.env` (commented keys)
- Test: `test/router/Deploy.t.sol`, `test/router/Selectors.t.sol`
- Modify: the spec (§6 refinements from this plan's header, marked "as built")

**Interfaces:**
- **The deploy script (`V3UtilsRouterScript.run()`):**
  - reads `ADMIN`, `OPERATOR`, `WITHDRAWER`, `SWAP_ROUTER`, `FEE_TAKER`, `NATIVE_WETH`, `NATIVE_MODE`,
    `ADAPTERS` (`nfpm:kind` pairs), and optionally `AERO_GAUGE_FACTORY`, `AERO_REWARD_TOKEN`,
    `AERO_COMPOUND_ENABLED`;
  - deploys the router and the modules, plus the adapters and the farm a chain needs;
  - initializes the router and registers every module selector, adapter and farm in one broadcast;
  - never calls `lock()`.
- `make deploy-v3router` and `make verify-v3router` (prints `forge verify-contract` for each address).

- [ ] **Step 1: Write the failing tests:**
  - `test_deploy_base_registersEverything`: run the script on a Base fork, then
    - every `ICoreMint`/`ICoreModify` selector maps to a module with code;
    - the Aero NFPM has the Aerodrome adapter and the farm;
    - the caps are the defaults;
    - the deployer holds no role.
  - `test_moduleSelectors_neverCollideWithRouter` (Refinement 3): no selector of `ICoreMint`, `ICoreModify`,
    `IAdapter` or `IFarm` equals any external selector of `V3UtilsRouter`.
  - `test_sizes`: every contract under `src/router` has `deployedBytecode` length ≤ 24,576 and empty
    `linkReferences` (read `out/*.json`).
- [ ] **Step 2: Run and confirm the failure.**
- [ ] **Step 3: Implement the script, Verify and Makefile entries, and the `sample.env` keys,** and update the spec
  with the refinements.
- [ ] **Step 4: Run the full router suite and confirm it passes:** `forge test --match-path 'test/router/*'` with
  all RPC vars and `FOUNDRY_EVM_VERSION=cancun`. Run `git diff origin/main -- <protected files>` and confirm it is
  empty.
- [ ] **Step 5: Commit, then push to `feat/v3-router` (PR #65).** `feat(router): deploy script, verify, size and
  selector guards`
