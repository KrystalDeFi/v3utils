# V3UtilsRouter: one router for every v3-style position, staked or not

Status: draft for approval, 2026-11-18. Branch `feat/v3-router`, based on `main`.

**PR #64** (`AeroFarmingRouter`, branch `feat/aero-farming-helper`) stays open, unmerged, as a fallback (user
decision). This router supersedes it once it ships. The Aero farm here ports PR #64's code and tests from that
branch.

## 1. Intent

Today a v3-style position is managed by different contracts depending on where it sits:

- **V3Utils** handles a position in the user's wallet. Users call it themselves.
- **V3Automation** runs bot actions on a position in the wallet.
- **AeroFarmingRouter** (PR #64) handles an Aero position staked in a gauge. Users call it, and so does the bot.

The user wants one contract that manages a position whatever its protocol and whether it is farming or not. A
position should not need a different contract because it was staked. New farms should plug in later without touching
the core position logic.

**The router is an operator only, never the staker** (user decision). A farm can plug in only if it lets a third party
act for the staker. A farm that records whoever deposits as the owner, and gates everything on `msg.sender`, gets only
the operations it allows from an operator (§6.5). The router never holds a staked NFT on a user's behalf.

The shape follows v4utils' `V4UtilsRouter`:

- a **fixed router** that users approve and the bot calls;
- **stateless modules** that the router delegatecalls;
- **admin = the Krystal multisig** (user decision), which can swap the modules.

V3Utils' position logic becomes modules of the router. It is no longer an external contract the router calls.

## 2. Goals

1. **Feature parity with V3Utils and V3Automation, for every protocol they support today.** The protocols are
   `UNI_V3` (and its forks: Pancake v3, Sushi, …), `ALGEBRA_V1`, `RAMSES_V3`, `AERODROME`, `ALGEBRA_INTEGRAL`.
   - **User flows:**
     - swap and mint;
     - swap and increase;
     - withdraw, with collect and an optional swap to a target token;
     - change range;
     - compound;
     - harvest (farm rewards when staked, trading fees when not), with a `PERFORMANCE_FEE` (§6.8).
   - **Bot actions:** AUTO_ADJUST, AUTO_EXIT, AUTO_COMPOUND, AUTO_HARVEST, under user-signed EIP-712 orders.
2. **Farming as a plug-in.** One farm per position manager, optional. The first farm is Aero's CL gauge, ported
   from PR #64. Every flow works on staked and unstaked positions.
3. **Protocol differences live in adapters**, one per protocol and selected by position manager. This replaces
   V3Utils' runtime `Nfpm.Protocol` enum and its branching `Nfpm` library.
4. **No module over 24 KB** and **no linked libraries** (no CREATE2 library pinning).

## 3. Non-goals

- Replacing V3Utils or V3Automation on-chain. Both stay deployed. The backend already supports several automation
  contracts, and the frontend sends each user to the right contract.
- Migrating existing signed orders. Users sign new orders for the router's EIP-712 domain.
- On-chain guards for the farm's early-unstake window. This stays a bot rule, as decided in PR #64.
- Binding signed orders to an action, gauge or tokenId. The trust model stays the same as V3Automation and v4utils.
- Stake-only or unstake-only actions. Users call the farm (gauge) directly for those, with no fee.
- Upgrading the router itself. The router is fixed, as in v4utils.
- Building the Pancake MasterChef v3 farm. It is planned as the second farm, with the reduced capabilities in §6.5,
  and the farm interface must support it. It is not built in this project.

## 4. Anti-goals

These would count as failure even if everything technically works:

- **Custody moving out of the router.** Adapters or farms must never hold users' NFTs or tokens. Everything runs
  as the router.
- **The router becoming the recorded staker of a farm position.** Not even for farms that would allow nothing else.
  No stake ledger.
- **A generic "execute this calldata" primitive** inside the router. Only typed adapter and farm code touches
  position managers and farms.
- **A fallback-based dispatch.** The user rejected this in PR #64. Every entry point is explicit.
- **A flow that changes a position's staking state when the user did not ask for it.** The one rule-based
  exception is a full withdraw (§6.4).

## 5. Approaches considered (decided: B, with delegatecalled adapters)

- **A. One module per protocol, assembled at compile time** (`Core + ProtocolAdapter (+ Farm)`). Core is typed
  against the adapter inside one contract.
  - Rejected on size. V3Utils is already 23,840 B, and it only fits by moving `CommonLib` (4,186 B) and `Nfpm`
    (5,691 B) out into libraries. So Core alone exceeds 24 KB.
  - Under A, every protocol would need its own copy of every Core piece. Five protocols and three Core modules
    would mean 15 deployments, and every Core fix would mean redeploying all of them.
- **B. Core modules written once, plus per-protocol adapters and per-protocol farms, all delegatecalled.**
  **Chosen.**
  - Core is split by flow once. Each protocol adds one small adapter, and each farm adds one small farm contract.
  - Trust is the same as for modules, since the admin sets both.
  - The extra delegatecalls cost little gas.
  - Adapters **must be delegatecalled, not called.** A called adapter would either have to hold the NFT and the
    tokens, or return raw calldata for the router to run, which is an arbitrary-call gadget (see §4).
- **C. Keep the `Nfpm` library and the `Protocol` enum.** Rejected. It keeps the runtime branching and the library
  pinning that this redesign removes.

## 6. Design

### 6.1 Contracts

```
V3UtilsRouter (fixed; users approve it; holds roles, orders, registries)
 ├─ modules   selector → module        CoreMint · CoreModify · Automation   (split by flow, size-driven)
 ├─ adapters  nfpm → adapter           UniV3 · AlgebraV1 · RamsesV3 · Aerodrome · AlgebraIntegral
 └─ farms     nfpm → farm (optional)   AeroGaugeFarm   (later: Pancake MasterChef, …)
shared state: ERC-7201 slot (RouterStorage), append-only
```

All modules, adapters and farms follow the same rules:

- They are stateless. Immutables are allowed: an immutable lives in the code, so it works under delegatecall.
  Per-chain settings such as a farm's gauge factory or reward token can be immutables of that chain's deployment.
- They are `onlyDelegateCall`.
- They declare no storage. Any shared state goes in `RouterStorage`.

### 6.2 Router

The router carries over from PR #64's `AeroFarmingRouter`, generalized.

**Roles:**

| Role | Can call |
|---|---|
| `DEFAULT_ADMIN_ROLE` | role administration |
| `ADMIN_ROLE` (multisig) | registries, config, pause and unpause, lock |
| `OPERATOR_ROLE` | `executeAutomation` |
| `WITHDRAWER_ROLE` | rescue (`withdrawERC20/ERC721/Native`) |

**Entry points:**

- **`execute(bytes data)`** is for users. The router looks up `module[selector(data)]` and delegatecalls it.
  `msg.sender` (the account) is preserved.
  - An unknown selector reverts.
  - Router-own selectors can never be registered.
  - This is a selector registry, not a fallback.
- **`executeAutomation(account, nfpm, tokenId, action, actionData, order, signature)`** is for `OPERATOR_ROLE`.
  The router runs these checks in order:
  1. `nfpm` has an adapter.
  2. `account` is the position's holder. The router asks the NFPM's farm (delegatecall to `farm.stakedBy`) and
     accepts `account` if the farm reports the token as staked by it; otherwise `nfpm.ownerOf(tokenId)` must be
     `account`. The router's fixed code holds no farm-specific holder logic.
  3. The order binds this chain and this `nfpm`, the signature is valid, and the order is not cancelled. This is the
     same check as PR #64 and v4utils.
  4. The router records `account` and delegatecalls the Automation module with calldata it builds itself.
  5. It clears the record afterwards.
- **Registries:**
  - `setModule(selector, module)`, `setAdapter(nfpm, adapter)` and `setFarm(nfpm, farm)` require code at the
    address. Passing `address(0)` unregisters.
  - `lock()` is optional, as in v4utils, and one-way. It freezes the three registries **and `swapRouter` and the
    native config**. After lock, the max-fee caps can only go down. `feeTaker` stays settable, because it only
    receives capped fees and holds no custody. *(Builder's call.)* The swap helper runs `swapRouter.call(swapData)`
    as the router, and users give the router NFPM and gauge approvals. So an admin who could repoint `swapRouter`
    after lock could turn a swap into `transferFrom(victim, …)`. PR #64's lock froze `setV3Utils` for the same
    reason. `initialize` sets `swapRouter`; the setter exists only until lock.
- **Config** sits in `RouterStorage`, with admin setters for each item:
  - `swapRouter` (aggregator);
  - `feeTaker`;
  - per-`FeeType` max fee (`setMaxFeeX64`);
  - the native config (`weth`, WRAPPED or ENSHRINED, and the scale, derived from token decimals as in `Common`).
- **Other router functions:** EIP-712 orders (`hashOrder`, `cancelOrder`, `isOrderCancelled`), the NFT receive guard
  (§6.7), `receive()` (only from `weth`), and pause.

The EIP-712 domain is name `V3UtilsRouter`, version `1`, with the router as `verifyingContract`. The order struct is
`StructHash.Order`, hashed internally with no deployed StructHash library.

### 6.3 Adapters (protocol-specific; delegatecalled by modules)

An adapter is everything that differs between protocols, behind one generic interface. Module code never sees a
protocol enum. A sketch of the interface follows; the builder finalizes it.

- `position(nfpm, tokenId) → Position {token0, token1, fee, tickSpacing, deployer, tickLower, tickUpper, liquidity}`.
  A protocol leaves out the fields it does not have, for example Algebra has no `fee`.
- `mint(nfpm, MintParams generic) → (tokenId, liquidity, amount0, amount1)`, which encodes the protocol's own mint
  struct.
- `increase`, `decrease` and `collect`.
- `pool(nfpm, token0, token1, fee/tickSpacing/deployer) → pool`, which farms need to find a pool's gauge or pool id.

One adapter serves every position manager of its protocol. For example, the UniV3 adapter is registered for Uniswap,
Pancake, Sushi and other forks. The `nfpm → adapter` registry is also the whitelist: an NFPM with no adapter is
unsupported.

### 6.4 Custody: take, act, put back (staked or not)

Every flow on an existing position follows the same shape:

1. **Take.**
   - If the NFPM's farm reports `tokenId` staked by `account`, the router needs the farm to allow unstake
     (`canUnstake`), or the flow reverts `FarmUnsupported`. When it does, `farm.unstake` brings the NFT to the
     router. For Aero, `withdrawFrom` also handles emissions, as in PR #64.
   - Otherwise require `ownerOf(tokenId) == account` and `nfpm.transferFrom(account, router, tokenId)`. This needs an
     NFPM approval to the router (`setApprovalForAll` or a per-token approval).
2. **Act** on the position as its owner, using adapter calls.
3. **Put back** to wherever the position came from: `farm.stake(tokenId, account)` if it was staked, otherwise
   transfer it to `account`.
   - **Full-withdraw rule** (user decision): a withdraw that leaves the position at zero liquidity always ends with
     the NFT in the wallet, unstaked.
   - **Change range:** the new NFT goes back to the state the old one came from. The old, empty NFT goes to the
     wallet.

**Add liquidity to a staked position** skips take and put back when the farm can add in place (`canIncreaseStaked`).
After the usual swaps and fees, the final increase goes through `farm.increaseStaked`, and leftovers are swept to the
user. Otherwise it uses take, act, put back.

**Swap and mint** gets a `stake` flag (user decision).
- With `stake = true`, the new NFT is staked for `msg.sender` through `farm.stake`. It reverts if the NFPM has no
  farm, or the pool has no live farm. The farm checks this before minting where it can.
- With `stake = false`, the NFT goes to the wallet, and pools without a farm work too.

### 6.5 Farms (delegatecalled; one per NFPM, optional)

A farm handles everything specific to staking, and declares what it allows an operator to do. The interface sketch is
below; the builder finalizes it.

- `stakedBy(tokenId) → account` (zero if not staked). The router uses it for the automation holder check, and
  modules use it for take.
- `stake(tokenId, account)`. The NFT is with the router when this is called. The farm stakes it with `account` as
  the recorded staker, and checks that the pool's farm is live.
- `canUnstake() → bool`, plus `unstake(tokenId, account)`, which brings the NFT to the router.
- `canIncreaseStaked() → bool`, plus `increaseStaked(params)`, which adds liquidity without unstaking.
- `claim(tokenId, account) → (rewardToken, amount)`, with the reward paid to the router. It is only available when
  `canUnstake` is true, because an operator that cannot unstake cannot claim either.
- `earnsTradingFees() → bool`. For Aero this is false, because staked liquidity's trading fees go to voters.
- `expectsNft(...)`: lets the router's NFT receive guard ask the farm whether an incoming NFT is expected, for example
  a gauge returning a position on unstake. This keeps the router's fixed code farm-agnostic.

| Capability | AeroGaugeFarm (this project) | MasterChefV3Farm (planned, not built) |
|---|---|---|
| `stakedBy` | `gauge.stakedContains` (gauge derived from the position) | `userPositionInfos(id).user` |
| `stake` | `approve` + `gauge.depositFor(id, account)` | send the NFT to `account`, then `nfpm.safeTransferFrom(account, masterChef, id)` with the user's NFPM approval, so MasterChef records `_from = account` |
| unstake / claim | yes (`withdrawFrom`, `claimEmissions`) | **no**: MasterChef's `withdraw`, `decreaseLiquidity`, `collect`, `harvest` and `burn` require `msg.sender` to be the recorded staker |
| `increaseStaked` | no (uses take, act, put back) | **yes**: `MasterChefV3.increaseLiquidity` has no owner check; it pulls from the router and refunds leftovers to it |

**MasterChef v3, for reference** (`pancake-v3-contracts/projects/masterchef-v3/contracts/MasterChefV3.sol`):
- Farm ownership is a storage field (`userPositionInfos[tokenId].user`), not a token, so it can never be transferred.
- **Never mint straight to MasterChef.** The position manager's `mint` uses `_mint`, so MasterChef's
  `onERC721Received` would never run, and the NFT would be stuck there unregistered.
- A MasterChef-staked position therefore supports zap-in with stake and add liquidity. Withdraw, change range,
  compound, harvest and automation on it revert `FarmUnsupported`, and the user unstakes on Pancake first.
- The same positions unstaked get every flow, because they are plain Pancake v3 positions.

**AeroGaugeFarm** ports PR #64's Aero code:

- **Gauge:** derived from the position (`AeroGauge.ofPool`/`ofToken`), never passed in.
- **Gauge API:** `depositFor`, `withdrawFrom` and `claimEmissions`, with the gauge approvals the user grants.
- **Per-chain config as immutables:** the gauge factory, the reward token (AERO on Base, xAERO elsewhere) and
  `compoundEnabled` (Base only, because xAERO cannot be compounded).
- **Behaviour carried over unchanged from PR #64:** live-gauge check, rebalance, `MissingSwapData`, and the
  penalty-window note.

### 6.6 Params, swaps and the flow pipeline (v4utils style)

Decided 2026-11-19 (user): user-facing params and swaps follow v4utils' `IV4Utils` (`v4utils/src/univ4`), with three
fixes listed under "Swaps" below.

**One params struct per action.** This replaces V3Utils' single `Instructions` struct, whose fields mean different
things per `whatToDo`. Each module function names exactly what it uses:

| Function | Params (sketch; mirrors v4utils) |
|---|---|
| `swapAndMint(SwapAndMintParams)` | `nfpm`, pool key (`token0`, `token1`, `fee`/`tickSpacing`/`deployer`), `MintParams {tickLower, tickUpper, minLiquidity, deadline}`, `inputTokens[]`, `swaps[]`, `stake`, `protocolFeeX64`, `gasFeeX64` |
| `swapAndIncrease(SwapAndIncreaseParams)` | `nfpm`, `tokenId`, `IncreaseParams {minLiquidity, deadline}`, `inputTokens[]`, `swaps[]`, `protocolFeeX64`, `gasFeeX64` |
| `decreaseAndSwap(DecreaseAndSwapParams)` | `nfpm`, `tokenId`, `DecreaseParams {liquidity, amount0Min, amount1Min, deadline}`, `swaps[]`, `destToken`, `protocolFeeX64`, `performanceFeeX64`, `gasFeeX64` (partial or full withdraw; full withdraw unstakes, §6.4) |
| `adjustRange(AdjustRangeParams)` | `nfpm`, `tokenId`, `swaps[]`, `MintParams`, `compoundFees`, `protocolFeeX64`, `performanceFeeX64`, `gasFeeX64` |
| `compound(CompoundParams)` | `nfpm`, `tokenId`, `swaps[]`, `IncreaseParams`, `performanceFeeX64` (farm rewards, or trading fees when unstaked) |
| `harvest(HarvestParams)` | `nfpm`, `tokenId`, `swaps[]`, `destToken`, `performanceFeeX64` |

- Liquidity slippage is checked as `minLiquidity`, as in v4utils, instead of V3Utils' `amountAddMin0/1`.
- The bot's `actionData` is the same struct as the user's for that action (AUTO_ADJUST uses `AdjustRangeParams`,
  AUTO_EXIT uses a full `DecreaseAndSwapParams`, and so on).

**Swaps** are a list of steps: `SwapParams {tokenIn, amountIn, tokenOut, amountOutMin, swapData}`, run in order
through `swapRouter`, with slippage checked per step. This gives any number of input tokens, multi-hop routes, and
any exit token, which V3Utils' fixed `swapSourceToken` → token0/token1 slots could not. A native↔WETH step is a
conversion, not a trade (v4utils' `NativeCurrency`, including ENSHRINED native on Arc). Three changes from v4utils:
1. **`amountIn == 0` means "everything *this call* holds of `tokenIn`"**, measured by balance delta from the start
   of the call. It never means the router's whole balance. v4utils' whole-balance meaning lets a swap consume tokens
   from outside the call; v4utils' own GHSA-m36p-ffh3-mvmc and GHSA-v6cm-hp8p-f37m fixes deal with this area.
2. **No caller-chosen `sweepTokens[]`.** At the end of every flow the router sweeps, by balance delta, every token
   the call touched to the account: input tokens, both legs of every swap, the pool's tokens, and the reward token.
   Nothing the call brought in stays behind, and nothing it did not bring in leaves.
3. **`destToken` amounts are measured as deltas**, as v4utils does after GHSA-m36p.

**The flow pipeline.** Every flow reads top to bottom in the same order:

1. take the inputs or the position (wallet or farm, §6.4);
2. collect fees or claim rewards;
3. take fees;
4. swaps;
5. the position operation (adapter);
6. put the position back (§6.4);
7. sweep (above);
8. emit the event.

### 6.7 Flows

All flows follow the pipeline in §6.6. Every flow except mint uses take, act, put back (§6.4).

| Flow | Unstaked position | Staked position |
|---|---|---|
| `swapAndMint` (`stake` flag) | mint to the wallet | mint, then `farm.stake` |
| `swapAndIncrease` | increase | in place through the farm if `canIncreaseStaked`, otherwise between unstake and restake |
| `decreaseAndSwap` (partial or full) | decrease, collect, swap to `destToken` | the same; restake if liquidity remains |
| `adjustRange` | collect, decrease all, swap, mint | the same; restake the new NFT |
| `compound` | **trading fees** (collect, swap, increase) | **farm rewards** (claim, fee, swap and add; PR #64 compound); plus trading fees if `earnsTradingFees` |
| `harvest` (user and bot) | **trading fees** (collect, `PERFORMANCE_FEE`, swap to `destToken`) | **farm rewards** (claim, `PERFORMANCE_FEE`, optional swap); position stays staked |

- **Harvest is a user entry point too** (2026‑11‑19, user decision: rewards are fee-collectible for Krystal).
  This replaces PR #64's "no fee on harvest", where users claimed on the gauge directly.
  - `harvest(HarvestParams)` claims a staked position's farm rewards, or collects an unstaked position's trading
    fees. It takes `performanceFeeX64` (`PERFORMANCE_FEE`), runs `swaps[]`, and pays the user.
  - A staked position stays staked. Harvest on a staked position needs the farm to allow claim (Aero needs
    `approveForClaim`; MasterChef reverts `FarmUnsupported`).
  - AUTO_HARVEST is the same flow, run by the bot.
  - A user can still claim on the farm directly, outside Krystal's contracts. That path has no fee; the app routes
    harvests through the router.
- **Bot actions** use the same flows: AUTO_ADJUST is change range, AUTO_EXIT is a full withdraw, and AUTO_COMPOUND
  and AUTO_HARVEST map to the table above. One signed order covers a position in either state.
- **Flows on a staked position whose farm cannot unstake** revert `FarmUnsupported`, except add liquidity when the
  farm can add in place.
- **NFT receive guard:** the router accepts an NFT only from a registered NFPM, and only while a flow expects one: a
  mint by the router, a transfer the router itself started, or a farm unstake (decided by the farm through
  `expectsNft`). PR #64's `activeGauge` guard generalizes to an "expected NFT" record in `RouterStorage`.

### 6.8 Fees

- **Fee mechanics follow v4utils' `_takeFees`:**
  - A fee is taken per token on a list of tokens, with `FullMath.mulDiv(amount, feeX64, 2^64)`, and sent to
    `feeTaker`.
  - **Event:** v4utils' `TakeFees(posm, tokenId, userAddress, {feeTokens[], feeX64, feeType})`, with `posm` = the
    NFPM. The backend already indexes it for v4utils. This replaces V3Utils' 3-slot `DeductFees`, which cannot
    describe fees on any number of tokens.
  - **`FeeType` uses v4utils' enum and ordering** (`GAS_FEE`, `PERFORMANCE_FEE`, `PROTOCOL_FEE`), so the backend's
    `TakeFees` decoding applies unchanged. V3Utils' `LIQUIDITY_FEE` (a fee on liquidity inputs and outputs)
    becomes `PROTOCOL_FEE`, which is what v4utils charges on the same flows. *(Builder's call; flag it to the
    backend.)*
  - **Which fee applies where follows v4utils:**
    - mint and increase charge `PROTOCOL_FEE` and `GAS_FEE` on the inputs;
    - decrease charges `PROTOCOL_FEE` and `GAS_FEE` on the principal and `PERFORMANCE_FEE` on collected fees;
    - farm rewards charge `PERFORMANCE_FEE` (below).
  - **Caps** are per `FeeType` in `RouterStorage`, with the same defaults as `Common`: gas 30%, protocol 30%,
    performance 32%.
- **Rewards are always fee-collectible, as `PERFORMANCE_FEE`** (user decision; V3Utils labels its fee on collected
  trading fees `PERFORMANCE_FEE` the same way). That covers:
  - farm rewards on compound and harvest, one `performanceFeeX64` with gas folded in (PR #64);
  - trading fees collected by harvest or compound on an unstaked position, and the fee portion of a withdraw;
  - user calls and bot calls alike.
- **Labels are correct by construction.** The router takes the fees itself, so no label is hardcoded the way V3Utils'
  `swapAndIncreaseLiquidity` hardcodes `LIQUIDITY_FEE`.

### 6.9 Storage (`RouterStorage`, ERC-7201, append-only)

**Config:** `swapRouter`, `feeTaker`, `maxFeeX64[FeeType]`, `weth`, `nativeMode`, `nativeScale`.

**Registries:** `module[selector]`, `adapter[nfpm]`, `farm[nfpm]`, `locked`.

**Per-call flow state** (always cleared before the call returns): `automationAccount`, the expected-NFT flag.

Router-own storage (roles, pause, reentrancy, cancelled orders) is never written by modules.

### 6.10 Invariants for future modules, adapters and farms

- The account always comes from `msg.sender` (user flows) or from the router-recorded `automationAccount`, never
  from calldata alone.
- Gauges and pools are derived from the position or the mint params, never taken from calldata.
- There is no self-delegatecall multicall, because it would reuse `msg.value`.
- Swap amounts and sweeps are scoped to the call's own balance deltas, never the router's whole balance (§6.6).
- `RouterStorage` fields are append-only.
- Adapters and farms never transfer custody out of the router except to the account, the farm (for its own
  stake), or the fee taker.

## 7. Constraints

- **Toolchain:**
  - solc 0.8.15, OZ 4.9.6, london EVM;
  - fork tests that touch Aero need `FOUNDRY_EVM_VERSION=cancun`, because LeafVoter uses PUSH0;
  - no `require(cond, Error())`.
- **Chains:** every chain in `contracts.json` where V3Utils runs. Each chain registers the adapters for the NFPMs
  it supports, and the Aero farm where new Aero is live. On Arc the native mode is ENSHRINED.
- **Code reuse:** port the logic of `Common`, `CommonLib` and `Nfpm` instead of linking to them. Do not change
  the existing V3Utils and V3Automation sources or their CREATE2 addresses.
- **Deploy:** the router uses plain CREATE with per-chain initialize, as in PR #64's script. Modules, adapters and
  farms are also plain CREATE, with addresses taken from the broadcast.

## 8. Testing

- **Fork tests per adapter** on one representative chain each: Uniswap v3 and Pancake v3 (UniV3 adapter), an Algebra
  v1 chain, Ramses, an Algebra Integral chain, and Aero on Base and OP. Each tests mint, increase, withdraw (partial
  and full), change range, compound and harvest, staked and unstaked where a farm exists.
- **PR #64's Aero test suite** ports over to the farm.
- **Parity tests:** for the same inputs, the router's position outcome and fee amounts match V3Utils' and
  V3Automation's on the same fork block. Events differ by design (`TakeFees`, §6.8).
- **Swap tests:**
  - several input tokens;
  - a multi-hop route;
  - native in and out on WRAPPED and ENSHRINED chains;
  - `amountIn == 0` touches only the call's own balance (pre-seed the router with the same token);
  - no token the call touched is left on the router.
- **Router tests:**
  - registry guards (no router selectors, code required, lock);
  - the automation account cannot be reached through `execute`;
  - the NFT receive guard;
  - reentrancy;
  - pause.

## 9. Left to the builder

- **How Core is split into modules.** Split by flow; the size budget decides.
- **The exact adapter and farm interfaces**, within §6.3 and §6.5.
- **Exact struct fields**, within §6.6's table. The pool key per protocol comes from the adapter.
- **Native details**, ported from `Common` and `CommonLib`.
