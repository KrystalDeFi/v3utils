# Aero Farming Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `AeroFarmingHelper`, an upgradeable contract that lets users, and Krystal's operator acting on
signed orders, manage Aero CL positions staked in new‑Aero CLGauges. It handles only the gauge steps
(unstake, restake, claim) and delegates all liquidity work to the already‑deployed V3Utils.

**Architecture:** UUPS proxy (OZ 4.9.6) around one contract.
- The user stays the gauge stake owner. The helper acts through `withdrawFrom` / `depositFor` /
  `claimEmissions` using the user's gauge approvals.
- Each flow: unstake into the helper, call V3Utils with `recipient = helper`, restake with
  `depositFor(id, user)`, then forward every token *delta* to the user.
- Operator entry points verify a V3Automation‑style EIP‑712 order. Hashing goes through the chain's deployed
  StructHash library.

**Tech Stack:** Solidity 0.8.15, Foundry (forge 1.7.1), OpenZeppelin 4.9.6 (non‑upgradeable package:
`proxy/utils/UUPSUpgradeable.sol`, `proxy/utils/Initializable.sol`, `proxy/ERC1967/ERC1967Proxy.sol`),
`@krystal/util-contracts` `SignatureValidator`. Fork tests on Base and OP.

**Spec:** `docs/superpowers/specs/2026-11-12-aero-farming-helper-design.md`. Read it first; this plan
argues from it.

## Global Constraints

- **solc 0.8.15. Add no submodules or dependencies.** Do **not** edit `remappings.txt`, `foundry.toml`
  `libraries`, or any existing `src/*.sol`. Changing remappings or settings moves the pinned CREATE2 library
  addresses (see the `foundry.toml` comments).
- **The helper links no library.** `out/AeroFarmingHelper.sol/AeroFarmingHelper.json` must have empty
  `bytecode.linkReferences`. Do not call `CommonLib`, `Nfpm` or the external `StructHash._hash(bytes)` as
  linked libraries. Importing their *types* is fine.
- **Runtime size < 24,576 bytes** (`forge build --sizes`).
- **Account rule.** Every path that acts on a stake requires either `msg.sender == account` (user entry
  points derive `account = msg.sender` and take no account argument), or `OPERATOR_ROLE` plus a valid,
  uncancelled order signed by `account`, where `account` is the gauge stake owner of the tokenId.
- **Leftovers by delta only.** Snapshot balances before any transfer‑in; forward only `balance − snapshot`.
  After every flow the helper holds no NFT or token it didn't hold before.
- **Gauge check.** Require `gaugeFactory.isGauge(gauge)` and `gauge.nft() == gaugeFactory.nft()`. Stake
  only if `ILeafVoter(gaugeFactory.leafVoter()).isActivated(gauge)`; otherwise revert `GaugeNotLive()`.
  Exit and harvest skip the liveness check.
- **Fee caps** (same as `Common`): GAS `5534023222112865280` (30%), PERFORMANCE `5902958103587057000`
  (32%). The fee goes to `V3Utils(v3utils).FEE_TAKER()`, read live.
- **Upgrade safety.** Storage is append‑only. Never add a parent contract in a later version. The
  implementation constructor calls `_disableInitializers()`.
- **Native coin.** Native in and out only when the `weth` config is non‑zero. On Arc the deploy sets
  `weth = 0`, so `msg.value != 0` or `unwrap == true` reverts `NativeDisabled()`.
- **Compound.** Only when `compoundEnabled` (true on Base only). Otherwise revert `CompoundDisabled()`.
- Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Fixtures (verified live 2026‑11‑12)

| | Base (8453), block `56384489` | OP (10), block `159434366` |
|---|---|---|
| RPC env var | `BASE_RPC_URL` | `OP_RPC_URL` |
| NFPM | `0x4857DB576eE0e45F10525eC59527BfD10beeC60b` (whitelisted on V3Utils) | same (whitelisted) |
| CLGaugeFactory | `0xf437f62053acb121665b8fdbfea8f214fb8e589d` | same |
| LeafVoter | `0x382409fad8503FbCdbB27A4211551fa03e884078` | same |
| V3Utils | `0xb4acbc082b5e7ded571c98ee4257778a9d784b36` | same |
| StructHash lib | `0xb486f83280f19cf652843b8f79e52572d589bbf9` | same |
| Reward token | AERO `0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee` | xAERO `0xbdEaeA5205d16f34Cb40038052d91235D87B4C54` |
| WETH | `0x4200000000000000000000000000000000000006` | `0x4200000000000000000000000000000000000006` |
| Gauge A | WETH/USDC ts50: gauge `0x46a9dCa72D78366571bE583aa69C1DC16E6889fB`, pool `0x4A7af46bC8aBc00048c6c7920a1488DAF568366c` | USDC/WETH: gauge `0x8F6a9ea8304Fe2c16a6a11f31ABa71F2c526cFd9`, pool `0xcA231D91eC00385a54e541f504617d2197f9B7c3` |
| Gauge B | AERO/WETH ts200 (AERO is token0): gauge `0xb1b27a2fa4E67a6d0Ee1aA9De97c8b1DDF54FDD4`, pool `0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3` | — |
| Base USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | |

- Penalty on Base gauge A: `effectivePenaltyConfig` returned `(70, 1e6)`, i.e. 70 blocks at 100%. Read it
  live in tests; don't hardcode 70.
- Fork tests use **the deployed V3Utils bytecode**, not a fresh `new V3Utils()`. Swaps need recorded router
  calldata, so the fork tests use swap‑free paths (`targetToken = 0`, `swapData = ""`, both tokens supplied).
  Swap bytes are passed through untouched.
- Emissions on the fork: after staking, `vm.roll(+N)` and `vm.warp(+2N)` with N > the penalty blocks. If
  `gauge.earned(account, [tokenId])` stays 0, impersonate an existing staker instead. Get one from
  `gauge.stakedByIndex` on a depositor found in the gauge's `Deposit` logs before the pinned block.
- v3utils test gotchas: `vm.prank` and `vm.expectRevert` bind to the next *external* call. Build calldata
  (and do any `NPM.approve`) **before** the prank or expectRevert line.

## Review Focus

1. **Stray assets.** An NFT or token sent to the helper outside a flow must neither break a flow nor reach
   the next user. Pinned by `test_rebalance_withStrayNftHeld` (Task 4) and
   `test_zapIn_preexistingBalanceNotForwarded` (Task 2).
2. **A user with `approveForClaim(helper)` doing a non‑compound flow.** The emissions and the position's
   owed pool tokens land on the helper and must reach the user. Pinned by
   `test_remove_withClaimApproval_forwardsRewardAndPoolTokens` (Task 3).
3. **The deployed StructHash library must hash exactly like the source.** Otherwise every signed order is
   rejected. Pinned by `test_structHashParity_deployedLibMatchesSource` (Task 6).
4. **Acting inside the early‑unstake window must still succeed.** The emissions are forfeited and nothing
   reverts. Pinned by `test_rebalance_insidePenaltyWindow_succeedsAndForfeits` (Task 4).
5. **Orders signed before an upgrade stay valid after it.** The domain is bound to the proxy address, not
   the implementation. Pinned by `test_orderValidAcrossUpgrade` (Task 6).

---

## File Structure

- `src/aero/IAero.sol`: minimal interfaces `ICLGauge`, `ICLGaugeFactory`, `ILeafVoter`, `IStructHash`
  (only the functions used), plus `IWETH9Min { deposit(); withdraw(uint256); }`.
- `src/aero/AeroFarmingHelper.sol`: the contract (config, flows, operator path, rescue).
- `script/AeroFarmingHelper.s.sol`: deploys the implementation and an `ERC1967Proxy` with initialize calldata.
- `test/aero/AeroForkBase.sol`: abstract fork base (fixtures, proxy deploy, approval and mint helpers).
- `test/aero/AeroFarmingHelper.admin.t.sol` (Task 1), `.zap.t.sol` (2), `.modify.t.sol` (3, 4),
  `.compound.t.sol` (5), `.automation.t.sol` (6, 7), `.op.t.sol` (8).
- `Makefile`: add the `aerohelper` deploy target (Task 9).

---

### Task 1: Skeleton, config, upgradeability, gauge validation

**Files:** Create `src/aero/IAero.sol`, `src/aero/AeroFarmingHelper.sol`, `test/aero/AeroForkBase.sol`,
`test/aero/AeroFarmingHelper.admin.t.sol`.

**Interfaces (Produces):**
```solidity
contract AeroFarmingHelper is Initializable, UUPSUpgradeable, AccessControl, Pausable, ReentrancyGuard, IERC721Receiver {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    uint64 internal constant MAX_GAS_FEE_X64 = 5534023222112865280;
    uint64 internal constant MAX_PERFORMANCE_FEE_X64 = 5902958103587057000;

    // storage (append-only, in this order)
    address public v3utils;
    ICLGaugeFactory public gaugeFactory;
    address public rewardToken;      // AERO on Base, xAERO elsewhere
    bool public compoundEnabled;     // true only on Base
    address public weth;             // 0 => native disabled (Arc)
    address public structHash;       // deployed StructHash library on this chain
    address internal _activeGauge;   // non-zero only inside a flow (NFT receive guard)
    mapping(bytes32 => bool) internal _cancelledOrder;

    enum Action { ZAP_IN, ADD_LIQUIDITY, REMOVE_LIQUIDITY, REBALANCE, EXIT, COMPOUND, HARVEST }

    event FarmAction(address indexed user, address indexed gauge, uint256 indexed tokenId, uint256 newTokenId, Action action, bool automated);
    event DeductFees(address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, Common.DeductFeesEventData data);
    event CancelOrder(address user, bytes32 hash, bytes signature);
    event ConfigUpdated(address v3utils, address structHash);

    error InvalidGauge(); error GaugeNotLive(); error NativeDisabled(); error CompoundDisabled();
    error UnexpectedNft(); error NotStakeOwner(); error InvalidSignature(); error OrderCancelled();
    error InvalidInstructions(); error FeeTooHigh(); error NotSupportedAction();

    constructor() { _disableInitializers(); }
    function initialize(address admin, address operator, address withdrawer, address v3utils_, address gaugeFactory_,
        address rewardToken_, bool compoundEnabled_, address weth_, address structHash_) external initializer;
    function setV3Utils(address) external;        // DEFAULT_ADMIN_ROLE, emits ConfigUpdated
    function setStructHash(address) external;     // DEFAULT_ADMIN_ROLE, emits ConfigUpdated
    function pause() external; function unpause() external;  // DEFAULT_ADMIN_ROLE
    function withdrawERC20(IERC20 token, address to) external;                     // WITHDRAWER_ROLE
    function withdrawERC721(IERC721 nft, uint256 tokenId, address to) external;    // WITHDRAWER_ROLE
    function withdrawNative(address to) external;                                  // WITHDRAWER_ROLE
    function _authorizeUpgrade(address) internal override;                         // DEFAULT_ADMIN_ROLE
    function _validateGauge(address gauge) internal view returns (INonfungiblePositionManager nfpm);
    function _requireLive(address gauge) internal view;
    receive() external payable;   // only accept from weth (unwrap)
}
```
`AeroForkBase` produces: `_forkBase()`, `_forkOp()`, `_deployHelper(rewardToken, compoundEnabled, weth) returns (AeroFarmingHelper)` (deploys impl and proxy, with admin/operator/withdrawer = `makeAddr("admin")`/`makeAddr("operator")`/`makeAddr("withdrawer")`), and `_approveGauge(user, gauge, bool claim)` (sets `setApprovalForAll`, plus `approveForClaim` if `claim` is true).

- [ ] **Step 1: Write the failing tests** in `AeroFarmingHelper.admin.t.sol`:
  - `test_initialize_setsConfig`: every getter equals the init args; admin has `DEFAULT_ADMIN_ROLE`;
    operator has `OPERATOR_ROLE`.
  - `test_initialize_twiceReverts`: a second `initialize` on the proxy reverts.
  - `test_implementation_initializeReverts`: calling `initialize` on the implementation directly reverts.
  - `test_upgrade_nonAdminReverts` and `test_upgrade_adminPreservesState`: after `upgradeTo(newImpl)`, the
    getters are unchanged.
  - `test_setV3Utils_onlyAdmin`.
  - `test_withdrawERC20_onlyWithdrawer`.
  - `test_pause_blocksFlows`: covered per flow in later tasks; here assert only admin can pause.
  - `test_validateGauge_rejectsNonGauge`: `address(0xdead)` reverts `InvalidGauge`.
  - `test_validateGauge_acceptsGaugeA`: `vm.mockCall` `isActivated` → false, and `_requireLive` reverts
    `GaugeNotLive`. Expose the internals through a small harness contract in the test file that inherits the
    helper.
- [ ] **Step 2:** Run `forge test --match-path test/aero/AeroFarmingHelper.admin.t.sol -vv`. Expected: compile
  failure (contract missing).
- [ ] **Step 3:** Implement the interfaces block above. `IAero.sol` declares only:
  - gauge: `deposit`, `depositFor`, `withdrawFrom`, `claimEmissions(address,address,uint256[])`,
    `stakedContains`, `stakedByIndex`, `nft`, `pool`, `earned(address,uint256[])`;
  - factory: `isGauge`, `nft`, `leafVoter`, `effectivePenaltyConfig`;
  - voter: `isActivated`, `RECEIPT_TOKEN`;
  - `IStructHash._hash(bytes) external pure returns (bytes32)`.
- [ ] **Step 4:** Run the same command. Expected: all PASS.
- [ ] **Step 5:** Run `forge build --sizes | grep AeroFarmingHelper` and
  `jq '.bytecode.linkReferences' out/AeroFarmingHelper.sol/AeroFarmingHelper.json`. Expected: size < 24,576
  and `{}`.
- [ ] **Step 6:** Commit `feat(aero): helper skeleton, config, UUPS, gauge validation`.

---

### Task 2: Flow plumbing and zap‑in‑and‑stake

**Interfaces:**
- Consumes: Task 1.
- Produces (internal, used by Tasks 3–7):
```solidity
function _unstake(address gauge, uint256 tokenId, address account) internal;   // sets _activeGauge, withdrawFrom, clears
function _stake(address gauge, INonfungiblePositionManager nfpm, uint256 tokenId, address account) internal; // _requireLive, approve gauge, depositFor
function _snapshot(address[] memory tokens) internal view returns (uint256[] memory);
function _sweep(address[] memory tokens, uint256[] memory before, address to, bool unwrap) internal; // forwards deltas; unwrap WETH->native iff unwrap
function _pullInputs(address[3] memory tokens, uint256[3] memory amounts) internal;  // msg.value wraps into the WETH slot
function onERC721Received(address operator, address from, uint256, bytes calldata) external returns (bytes4);
```
- External:
  `zapInAndStake(address gauge, Common.SwapAndMintParams calldata params, bool unwrap) external payable nonReentrant whenNotPaused returns (uint256 tokenId)`.

**Decisions:**
- Copy `params` to memory and force `recipient = address(this)`. Require `params.nfpm == nfpm` and
  `params.protocol == Nfpm.Protocol.AERODROME` (else `InvalidInstructions`).
- Pull `amount0` of token0, `amount1` of token1, and `amount2` of `swapSourceToken` (when it isn't token0 or
  token1).
- If `msg.value > 0`: require `weth != 0`, call `deposit{value}`, and reduce the pull for the slot whose
  token is `weth` by `msg.value`. Revert `NativeDisabled` if no slot is `weth`, or if `msg.value` exceeds
  that slot's amount.
- Approve V3Utils for each pulled amount. Call `swapAndMint` with `value: 0`. Reset approvals to 0.
- New tokenId is `result.tokenId`, from the `swapAndMint` return value. Then `_stake`. Emit
  `FarmAction(user, gauge, tokenId, tokenId, ZAP_IN, false)`.
- The receive guard accepts only when `msg.sender == gaugeFactory.nft()`, `_activeGauge != 0`, and
  `operator == from == _activeGauge`. Otherwise revert `UnexpectedNft`.

- [ ] **Step 1: Write the failing tests** in `AeroFarmingHelper.zap.t.sol`, on Base gauge A, user funded with
  WETH and USDC via `deal`:
  - `test_zapIn_stakesForUser`:
    - `gauge.stakedContains(user, id)`;
    - `NFPM.ownerOf(id) == gauge`;
    - the helper's WETH, USDC and NFT balances equal their pre‑test values;
    - user WETH + USDC decreased by at most the supplied amounts;
    - `FarmAction` is emitted.
  - `test_zapIn_withNativeEth`: `msg.value` covers the WETH slot; same assertions.
  - `test_zapIn_nativeDisabledReverts`: helper deployed with `weth = 0`, `msg.value > 0`, reverts
    `NativeDisabled`.
  - `test_zapIn_wrongProtocolReverts`: `protocol = UNI_V3` reverts `InvalidInstructions`.
  - `test_zapIn_deadGaugeReverts`: `isActivated` mocked false reverts `GaugeNotLive`.
  - `test_zapIn_preexistingBalanceNotForwarded`: `deal` 5 USDC to the helper first. After the zap the
    helper still holds exactly 5 USDC.
  - `test_onERC721Received_rejectsUnsolicited`: a user calls `NFPM.safeTransferFrom(user, helper, id)`,
    which reverts.
- [ ] **Step 2:** Run `forge test --match-path test/aero/AeroFarmingHelper.zap.t.sol -vv`. Expected: FAIL
  (function missing).
- [ ] **Step 3:** Implement the Produces block.
- [ ] **Step 4:** Run again. Expected: PASS. Repeat the Task 1 Step 5 size and link check.
- [ ] **Step 5:** Commit `feat(aero): zap in and stake`.

---

### Task 3: Add liquidity, remove liquidity, exit

**Interfaces:**
- Consumes: Task 2 internals.
- Produces:
```solidity
function addLiquidity(address gauge, Common.SwapAndIncreaseLiquidityParams calldata params, bool unwrap) external payable;
function removeLiquidity(address gauge, uint256 tokenId, V3Utils.Instructions calldata ins) external;
function exit(address gauge, uint256 tokenId, V3Utils.Instructions calldata ins) external;
// shared core, reused by Task 6 with an explicit account:
function _modify(address account, address gauge, uint256 tokenId, V3Utils.Instructions memory ins, Action action) internal returns (uint256 tokenIdAfter);
```
All three are `nonReentrant whenNotPaused`, with `account = msg.sender`.

**Decisions:**
- Track `{token0, token1, rewardToken}` plus `ins.targetToken` or `swapSourceToken` in the
  snapshot/sweep set (de‑duplicated). Snapshot before `_unstake`, so emissions and owed pool tokens routed
  to the helper by `approveForClaim` are forwarded too.
- `_modify` flow:
  1. Force `ins.recipient = address(this)` and `ins.unwrap = false`. The helper unwraps in `_sweep` using
     the caller's `ins.unwrap`, and `ins.unwrap` with `weth == 0` reverts `NativeDisabled`.
  2. `_unstake`.
  3. `nfpm.safeTransferFrom(address(this), v3utils, tokenId, abi.encode(ins))`.
  4. Then:
     - REMOVE: `_stake` the same id.
     - EXIT: `nfpm.transferFrom(helper, account, tokenId)`.
     - REBALANCE: see Task 4.
  5. `_sweep` to `account`.
  6. Emit `FarmAction`.
- Validation:
  - `removeLiquidity` requires `WITHDRAW_AND_COLLECT_AND_SWAP` with `0 < ins.liquidity <` the position's
    liquidity.
  - `exit` requires `WITHDRAW_AND_COLLECT_AND_SWAP` with `ins.liquidity ==` the position's liquidity.
  - `COMPOUND_FEES` always reverts `InvalidInstructions`.
  - Read the position's liquidity via `nfpm.positions(tokenId)`.
- `addLiquidity` flow:
  1. Snapshot, then `_unstake`, then `_pullInputs`.
  2. Approve V3Utils, then `swapAndIncreaseLiquidity`, with `params` copied to memory and
     `recipient = helper`.
  3. `_stake`, then `_sweep`.
- No function takes an `account` argument.

- [ ] **Step 1: Write the failing tests** in `AeroFarmingHelper.modify.t.sol`. Setup: the user zaps in via
  the helper (Task 2), then `vm.roll` past the penalty blocks.
  - `test_add_increasesLiquidityAndRestakes`: liquidity goes up, `stakedContains` is still true, and the
    helper's balances are unchanged.
  - `test_add_withoutGaugeApprovalReverts`: no `setApprovalForAll`; expect revert `"NW"`.
  - `test_remove_partialRestakesSameId`: liquidity becomes `L − ins.liquidity`; still staked; the user
    received token0/token1 > 0.
  - `test_remove_fullLiquidityReverts`: `InvalidInstructions`.
  - `test_remove_withClaimApproval_forwardsRewardAndPoolTokens`: with `approveForClaim(helper)` the user's
    AERO increases by > 0, and the helper's AERO, WETH and USDC are unchanged.
  - `test_exit_returnsNftUnstaked`: `ownerOf(id) == user`; `!stakedContains`; liquidity is 0.
  - `test_exit_onDeadGaugeStillWorks`: `isActivated` mocked false, and the exit succeeds.
  - `test_compoundFeesInstructionReverts`: `InvalidInstructions`.
- [ ] **Step 2:** Run `forge test --match-path test/aero/AeroFarmingHelper.modify.t.sol -vv`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS. Repeat the size and link check.
- [ ] **Step 5:** Commit `feat(aero): add, remove, exit for staked positions`.

---

### Task 4: Rebalance

**Interfaces:**
- Consumes: `_modify` (Task 3).
- Produces:
  `function rebalance(address gauge, uint256 tokenId, V3Utils.Instructions calldata ins) external returns (uint256 newTokenId);`
  and the REBALANCE branch of `_modify`.

**Decisions:**
- Require `CHANGE_RANGE`.
- V3Utils returns NFTs with plain `transferFrom`. It sends the **new** NFT first and returns the **old** one
  last (`V3Utils.sol:419`), so the helper's enumeration ends `[…, new, old]`. Compute
  `newId = nfpm.tokenOfOwnerByIndex(address(this), nfpm.balanceOf(address(this)) - 2)`. Require
  `newId != tokenId` and `nfpm.ownerOf(newId) == address(this)`.
- Then `_stake(newId)`, `nfpm.transferFrom(helper, account, tokenId)` (the empty old NFT), `_sweep`, and
  emit `FarmAction(account, gauge, tokenId, newId, REBALANCE, automated)`.

- [ ] **Step 1: Write the failing tests** in `AeroFarmingHelper.modify.t.sol`:
  - `test_rebalance_restakesNewId`: new id staked for the user; old id owned by the user with liquidity 0;
    the helper holds no NFTs (other than strays) and no token deltas.
  - `test_rebalance_withStrayNftHeld`: before the rebalance, mint an unrelated position to an EOA and
    `transferFrom` it (not safe) to the helper. The rebalance succeeds, the stray is still owned by the
    helper, and the new id is the one staked.
  - `test_rebalance_insidePenaltyWindow_succeedsAndForfeits`: rebalance in the block after the zap. It
    succeeds, and the user's AERO delta is 0.
  - `test_rebalance_wrongWhatToDoReverts`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(aero): rebalance staked position`.

---

### Task 5: Compound (Base only) with the helper‑side performance fee

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces:
```solidity
struct CompoundParams {
    uint256 amountIn0; uint256 amountOut0Min; bytes swapData0;
    uint256 amountIn1; uint256 amountOut1Min; bytes swapData1;
    uint256 amountAddMin0; uint256 amountAddMin1; uint256 deadline;
    uint64 performanceFeeX64; uint64 gasFeeX64; bool unwrap;
}
function compound(address gauge, uint256 tokenId, CompoundParams calldata p) external;
function _compound(address account, address gauge, uint256 tokenId, CompoundParams memory p, bool automated) internal; // reused in Task 6
function _takeFee(address nfpm, uint256 tokenId, address account, address token0, address token1, uint256 amount, uint64 feeX64, Common.FeeType t) internal returns (uint256 fee);
```

**Decisions:**
- Require `compoundEnabled`, else `CompoundDisabled`.
- `_compound` order of operations:
  1. Snapshot.
  2. `claimEmissions(account, address(this), [tokenId])`. `claimed` is the delta of `rewardToken`.
  3. `_unstake`.
  4. `fee = _takeFee(..., claimed, p.performanceFeeX64, PERFORMANCE_FEE)`.
  5. Call `swapAndIncreaseLiquidity`:
     - `protocolFeeX64 = 0`, `gasFeeX64 = p.gasFeeX64`, `recipient = helper`;
     - if `rewardToken` is token0 (or token1), pass `claimed − fee` as `amount0` (or `amount1`) and
       `swapSourceToken = rewardToken`;
     - otherwise pass it as `amount2`.
  6. `_stake`, `_sweep`, emit `FarmAction(..., COMPOUND, automated)`.
- `_takeFee`:
  - `fee = FullMath.mulDiv(amount, feeX64, 2**64)`;
  - revert `FeeTooHigh` above the cap for the fee type;
  - transfer to `V3Utils(payable(v3utils)).FEE_TAKER()`;
  - emit `DeductFees` with `userAddress = account`, the reward token in the token0/token1 slot if it is one
    of them (else `token2`), and `feeType = t`.

- [ ] **Step 1: Write the failing tests** in `AeroFarmingHelper.compound.t.sol`. Accrue emissions first (see
  Fixtures).
  - `test_compound_gaugeB_aeroIsToken0`:
    - on gauge B with no swap, liquidity increases;
    - `FEE_TAKER` AERO increases by `mulDiv(claimed, feeX64, 2^64)`;
    - `DeductFees` is emitted with `feeType == PERFORMANCE_FEE` and `userAddress == user`;
    - the helper's balances are unchanged;
    - the position is still staked.
  - `test_compound_requiresClaimApproval`: without `approveForClaim`, expect revert `"NA"`.
  - `test_compound_feeAboveCapReverts`: `performanceFeeX64 = MAX + 1` reverts `FeeTooHigh`.
  - `test_compound_disabledReverts`: helper deployed with `compoundEnabled = false` reverts
    `CompoundDisabled`.
  - `test_compound_quoteAboveClaimReverts`: `amountIn0 > claimed − fee` reverts, and the position is still
    staked for the user.
- [ ] **Step 2:** Run `forge test --match-path test/aero/AeroFarmingHelper.compound.t.sol -vv`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. Repeat the size and link check.
- [ ] **Step 5:** Commit `feat(aero): compound AERO with performance fee`.

---

### Task 6: Operator path — order validation, cancel, AUTO_ADJUST / AUTO_EXIT / AUTO_COMPOUND

**Interfaces:**
- Consumes: `_modify` (Tasks 3–4) and `_compound` (Task 5).
- Produces:
```solidity
enum AutoAction { AUTO_ADJUST, AUTO_EXIT, AUTO_COMPOUND, AUTO_HARVEST }   // same order as V3Automation.Action
struct OrderParams { AutoAction action; address account; address gauge; uint256 tokenId; bytes actionData; bytes order; bytes signature; }
function executeOrder(OrderParams calldata p) external returns (uint256 tokenIdAfter); // OPERATOR_ROLE, whenNotPaused, nonReentrant
function cancelOrder(bytes32 hash, bytes calldata signature) external;
function isOrderCancelled(address actor, bytes32 hash) external view returns (bool);
function domainSeparator() public view returns (bytes32);
function hashOrder(bytes calldata order) public view returns (bytes32 digest);
```

**Decisions:**
- `domainSeparator()` is computed at each call:
  `keccak256(abi.encode(TYPE_HASH, keccak256("AeroFarmingHelper"), keccak256("1"), block.chainid, address(this)))`.
  Never store it as immutable; the proxy address is `address(this)`.
- `hashOrder(order) = toTypedDataHash(domainSeparator(), IStructHash(structHash)._hash(order))`. This is a
  staticcall into the deployed library, with no linking.
- Validation copies `V3Automation._validateOrder` and `cancelOrder`:
  - `SignatureValidator.isValidSignatureNow(account, digest, sig)`;
  - the cancel key is `keccak256(abi.encode(actor, digest))`.
- `executeOrder`:
  1. Require `gauge.stakedContains(p.account, p.tokenId)`, else `NotStakeOwner`.
  2. Validate the order against `p.account`.
  3. Dispatch on `p.action`:
     - AUTO_ADJUST: `abi.decode(actionData, (V3Utils.Instructions))`, then `_modify(..., REBALANCE)`.
     - AUTO_EXIT: same decode, then `_modify(..., EXIT)`.
     - AUTO_COMPOUND: decode `CompoundParams`, then `_compound(..., true)`.
     - AUTO_HARVEST: Task 7.
- The order's tokenId, NFPM and action are **not** checked on‑chain (spec §7).

- [ ] **Step 1: Write the failing tests** in `AeroFarmingHelper.automation.t.sol`. Sign with `vm.sign` on a
  `StructHash.Order` built in the test and abi‑encoded.
  - `test_structHashParity_deployedLibMatchesSource`:
    `IStructHash(0xb486…)._hash(encoded) == StructHash._hash(abi.decode(encoded,(StructHash.Order)))`.
    Use the internal overload in a test harness.
  - `test_autoAdjust_validOrder`: as in `test_rebalance_restakesNewId`, plus `FarmAction.automated == true`.
  - `test_autoExit_validOrder`.
  - `test_autoCompound_validOrder` (gauge B).
  - `test_execute_nonOperatorReverts`.
  - `test_execute_wrongSignerReverts`: signed by another key, reverts `InvalidSignature`.
  - `test_execute_signerNotStakeOwnerReverts`: `p.account` is not the staker, reverts `NotStakeOwner`.
  - `test_execute_cancelledReverts`: user `cancelOrder(digest, sig)`, then `OrderCancelled`.
  - `test_orderValidAcrossUpgrade`: sign, `upgradeTo(newImpl)`, execute, and it succeeds.
  - `test_execute_whenPausedReverts`.
- [ ] **Step 2:** Run `forge test --match-path test/aero/AeroFarmingHelper.automation.t.sol -vv`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. Repeat the size and link check.
- [ ] **Step 5:** Commit `feat(aero): operator orders for adjust, exit, compound`.

---

### Task 7: AUTO_HARVEST

**Interfaces:**
- Consumes: Task 6 dispatch and `_takeFee` (Task 5).
- Produces:
```solidity
struct HarvestParams { address targetToken; uint256 amountOutMin; bytes swapData; uint64 gasFeeX64; }
function _harvest(address account, address gauge, uint256 tokenId, HarvestParams memory p) internal;
function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData) internal returns (uint256 amountInDelta, uint256 amountOutDelta);
```

**Decisions:**
- Flow:
  1. Snapshot.
  2. `claimEmissions(account, helper, [tokenId])`. The position stays staked.
  3. `fee = _takeFee(..., claimed, p.gasFeeX64, GAS_FEE)`. No performance fee.
  4. Swap if `p.targetToken != 0 && p.targetToken != rewardToken`. This needs `compoundEnabled`, i.e. Base,
     else `CompoundDisabled`.
  5. `_sweep` `{rewardToken, targetToken}` to the account.
  6. Emit `FarmAction(..., HARVEST, true)`.
- `_swap` copies `CommonLib.swap` logic inline, without linking:
  - router is `V3Utils(payable(v3utils)).swapRouter()`;
  - approve the exact amount, `call(swapData)`, then reset the approval;
  - compute the deltas and revert on `amountOut < amountOutMin`.

- [ ] **Step 1: Write the failing tests:**
  - `test_autoHarvest_noSwap_paysAeroMinusGasFee`:
    - user AERO delta equals `claimed − gasFee`;
    - `FEE_TAKER` delta equals `gasFee`;
    - `DeductFees.feeType == GAS_FEE`;
    - the position is still staked.
  - `test_autoHarvest_gasFeeAboveCapReverts`.
  - `test_autoHarvest_swapPath_routerCalled`: `vm.mockCall` and `vm.etch` a trivial router that pays
    `targetToken`, then assert the user receives `targetToken`. This is the only test of the swap mechanics.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(aero): auto-harvest`.

---

### Task 8: Non‑Base behaviour (OP fork)

**Files:** `test/aero/AeroFarmingHelper.op.t.sol`. There is no new src code unless a test exposes a bug.

**Interfaces:** Consumes everything above. Deploy with `rewardToken = xAERO`, `compoundEnabled = false`,
and `weth = 0x4200…0006`.

- [ ] **Step 1: Write the tests:**
  - `test_op_zapInAndStake`;
  - `test_op_compoundReverts` (`CompoundDisabled`);
  - `test_op_autoHarvest_paysXAero`: no swap; user xAERO delta > 0; the helper's xAERO is unchanged;
  - `test_op_autoHarvest_swapReverts` (`CompoundDisabled`);
  - `test_op_removeWithClaimApproval_forwardsXAero`.
- [ ] **Step 2:** Run `forge test --match-path test/aero/AeroFarmingHelper.op.t.sol -vv`. Expected: PASS. If
  any fail, fix the src, rerun the whole `test/aero` suite, and commit the fix with the tests.
- [ ] **Step 3:** Commit `test(aero): OP fork coverage`.

---

### Task 9: Deploy script, Makefile target, final checks

**Files:** Create `script/AeroFarmingHelper.s.sol` (`AeroFarmingHelperScript`). Modify `Makefile` and
`sample.env`.

**Decisions:**
- The script reads env `ADMIN` (multisig), `OPERATOR`, `WITHDRAWER`, `V3UTILS`, `GAUGE_FACTORY`,
  `REWARD_TOKEN`, `COMPOUND_ENABLED` (bool), `NATIVE_WETH` (0 on Arc) and `STRUCT_HASH`.
- It deploys the implementation, then `new ERC1967Proxy(impl, abi.encodeCall(initialize, …))`, and logs
  both addresses.
- Plain CREATE, not CREATE2, since per‑chain init args differ anyway. *(Spec §8: take addresses from the
  real broadcast.)*
- Makefile: add an `aerohelper:` target with `$(eval CONTRACT=AeroFarmingHelper)` under the default profile
  (no libraries). Add the new env keys to `sample.env`, commented, with the Base values from Fixtures.
- Don't touch `contracts.json` here. Ops adds `aeroFarmingHelper` per chain after each real deploy.

- [ ] **Step 1:** Write a fork test `test_deployScript_base`: run the script's `run()` on the Base fork with
  env set via `vm.setEnv`. Assert that the proxy's `v3utils()`, `rewardToken()`, `compoundEnabled()` and
  roles match the env.
- [ ] **Step 2:** Implement the script and the Makefile target.
- [ ] **Step 3:** Run the full suite, `forge test --match-path 'test/aero/*' -vv`, then the existing suite
  `forge test --no-match-path 'test/aero/*'`. Expected: all PASS, and the existing suite is unchanged.
- [ ] **Step 4:** Repeat the size and link check. Run `git diff origin/main -- src/V3Utils.sol src/Common.sol
  src/CommonLib.sol src/Nfpm.sol src/StructHash.sol src/V3Automation.sol src/EIP712.sol remappings.txt
  foundry.toml`. Expected: empty.
- [ ] **Step 5:** Commit `feat(aero): deploy script`.
