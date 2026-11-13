# Aero Farming Helper — Design

Date: 2026-11-12 · Repo: `v3utils` · Branch: `feat/aero-farming-helper`

## 1. Intent

V3Utils manages Uniswap‑v3‑style positions that sit in the user's wallet. Once a user stakes an Aero
(MetaDEX03 / "new Aero") CL position in its gauge, the NFT belongs to the gauge, and V3Utils can no longer
act on it. Users who farm must then unstake by hand, act, and restake, which means several transactions
and lost emissions whenever they forget to restake.

We want a small **Aero‑only** contract, `AeroFarmingHelper`, that does only the farming part: unstake,
restake and claim. It hands every liquidity operation to the **existing, unchanged V3Utils**. Each
user action becomes one transaction, and the position ends up staked again.

Rollout order (user decision): **user‑signed actions first**, then **automation** (Krystal's operator runs
the same flows from signed orders, the way V3Automation does for positions held in wallets). The first version
must not block the automation phase.

## 2. Goals / non‑goals / anti‑goals

**Goals (first version)**
- One‑tx flows for staked Aero CL positions:
  - zap in and stake
  - add liquidity
  - remove liquidity (partial, position stays staked)
  - rebalance (change range)
  - exit (unstake, withdraw, optionally swap)
  - harvest
  - compound
- Reuse V3Utils for all liquidity, swap and fee logic.
- Same fee model as V3Utils (user decision). No fee on harvest (user decision).
- Compound on **Base only**. Other chains get harvest only (user decision, see §5.6).

**Non‑goals**
- Supporting other protocols, gauges or legacy Slipstream/Aerodrome gauges. This is for new Aero only (user
  decision: "Aero only, we don't need much extensibility").
- Changing or redeploying V3Utils. The helper calls the **currently deployed** V3Utils on each chain (user
  decision). Whitelisting the Aero NFPM on it is an ops step, not a code change.
- xAERO redemption or bridging.

**Anti‑goals (failure even if it "works")**
- **Any path where caller A can act on caller B's stake.** The helper will hold blanket gauge approvals from
  many users. Every path that names an account must require either `msg.sender == account`, or
  `OPERATOR_ROLE` plus a valid order signed by `account` for exactly this action (§7).
- Leaving tokens or NFTs on the helper after a transaction, or letting a later caller sweep someone else's
  leftovers.
- Silently restaking into the wrong gauge, or a gauge that is not genuine.

## 3. Background: what the new CLGauge offers (verified in source)

Source: `dromos-labs/metadex-slipstream-public`, `contracts/gauge/{Gauge,CLGauge}.sol`. Canonical deployment
from https://app.aero.xyz/docs/security/: NFPM `0x4857DB57…C60b`, CLGaugeFactory `0xf437f620…589d`, both the
same on all chains.

- `deposit(tokenId)` and `depositFor(tokenId, owner)`. The caller must own the NFT and have approved the gauge
  for it. The stake is credited to `owner`, and the pool fees collected at deposit go to `owner`.
- `withdraw(tokenId)` and `withdrawFrom(tokenId, account)`. `withdrawFrom` requires the caller to have either
  per‑token approval (`gauge.approve(op, tokenId)`, set by the stake owner) or blanket approval
  (`gauge.setApprovalForAll(op, true)`). The NFT goes to **msg.sender** via `safeTransferFrom`. Emissions
  go to msg.sender if `approvedForClaim[account][msg.sender]`, otherwise to `account`. If minting
  emissions reverts, they are **deferred** to `deferredEmissions[account]` and claimable later.
- `claimEmissions(account, recipient[, tokenIds])`. The caller must be `account`, or have
  `approveForClaim(op, true)` from `account`.
- The early‑unstake penalty uses `depositBlock[tokenId]` and the factory's penalty config. On Base it is
  read it live from `CLGaugeFactory.effectivePenaltyConfig(gauge)`. On 2026‑11‑12 Base returned 70 blocks
  at 100% of the position's accrued emissions.
- While a position is staked its trading fees go to the gauge (voting rewards), so a staked LP earns
  emissions only. The new gauge has no "increase staked liquidity" function. To change liquidity you
  unstake, modify and restake.
- Rewards: on **Base**, claims pay **AERO** (RootEmissionsHandler auto‑redeems). On every other chain they pay
  **xAERO** (`LeafVoter.RECEIPT_TOKEN()`). xAERO redeems 1:1 only by bridging to Base through Hyperlane, so
  it cannot be turned into tokens on the same chain within one transaction.
- Genuineness check: `CLGaugeFactory.isGauge(gauge)`. `gauge.nft()` and `gauge.pool()` give the NFPM and pool.

V3Utils facts this design relies on (`src/V3Utils.sol`, `src/Common.sol`, `src/CommonLib.sol`):
- `execute(nfpm, tokenId, instructions)` and `onERC721Received`:
  - the **original NFT returns to `from`** (the helper);
  - any **new NFT** (CHANGE_RANGE) and **leftover tokens** go to `instructions.recipient`.
  - Every NFT is returned with plain `transferFrom` (`V3Utils.sol:419`, `Common.sol:379`), so the helper's
    `onERC721Received` never fires for them.
  - The new tokenId is not returned to the caller. The helper has to find it itself, for example through
    NFPM enumeration or by checking balances before and after.
- `swapAndMint` and `swapAndIncreaseLiquidity`:
  - they pull tokens from **msg.sender** (the helper), so the helper must pull from the user and approve
    V3Utils first;
  - `swapAndIncreaseLiquidity` requires `ownerOf(tokenId) == msg.sender`;
  - the new NFT and leftovers go to `params.recipient`.
- `Nfpm.Protocol.AERODROME` mint params match the new NFPM's `MintParams` (same 12 fields, including
  `sqrtPriceX96`). The `positions()` layout matches Slipstream.
- The NFPM whitelist is required (`_isWhitelistedNfpm`). As of 2026‑10‑22, `0x4857…` was **not** whitelisted
  on any chain.

## 4. Shape of the solution (decided)

```
user ──tx──▶ AeroFarmingHelper ──withdrawFrom──▶ CLGauge ──NFT──▶ helper
                       │
                       ├──safeTransferFrom / swapAndMint / swapAndIncreaseLiquidity──▶ V3Utils
                       │                                       (NFT + leftovers back to helper)
                       └──depositFor(tokenId, user)──▶ CLGauge          leftovers ──▶ user
```

- **The helper is upgradeable** (user decision), using a proxy and OZ upgradeable contracts. The builder
  picks UUPS or Transparent. The V3Utils address is stored in state, settable by admin, so the helper can
  move to a new V3Utils without users approving again. The proxy address is what users approve on gauges,
  so it must never change.
- The user stays the staker on record in the gauge at all times. The helper is only an **operator**.
- Approvals the user grants per gauge, once:
  - `gauge.setApprovalForAll(helper, true)`, needed for any flow that unstakes;
  - `gauge.approveForClaim(helper, true)`, needed **only for compound**.
- Zap‑in needs no gauge approval: the helper mints to itself and calls `depositFor(newId, user)`. The usual
  ERC20 approvals to the helper apply for tokens the user provides.
- The helper takes the gauge address as a parameter and checks
  `CLGaugeFactory(factory).isGauge(gauge)` and `gauge.nft() == nfpm`. `factory` is fixed per deployment.
- Leftovers are measured as **balance deltas within the call**, never as the helper's whole balance.

## 5. Flows (first version)

All flows: `msg.sender` is the account (the stake owner). The gauge is validated as in §4. There is a
deadline. Leftover tokens are returned to the user, with optional unwrap to native, mirroring V3Utils `unwrap`.

### 5.1 Zap in and stake
1. Pull the user's input tokens, or take `msg.value`, then approve V3Utils.
2. Call `V3Utils.swapAndMint(params)` with `recipient = helper`, `protocol = AERODROME`, `nfpm = gauge.nft()`.
   Pool parameters must match the gauge's pool.
3. Approve the gauge for `newId` and call `depositFor(newId, user)`.
4. Forward the leftover tokens to the user.

### 5.2 Add liquidity to a staked position
1. `withdrawFrom(tokenId, user)`. Emissions go straight to the user. If the user has granted
   `approveForClaim(helper)`, they land on the helper instead, and the helper forwards them (§8).
2. Pull the user's tokens and call `V3Utils.swapAndIncreaseLiquidity` with `recipient = helper`.
3. `depositFor(tokenId, user)`. Forward the leftovers.

### 5.3 Remove liquidity (partial), rebalance, exit
1. `withdrawFrom(tokenId, user)`.
2. Call `nfpm.safeTransferFrom(helper, V3Utils, tokenId, abi.encode(instructions))`, with
   `instructions.recipient = helper`:
   - partial remove: `WITHDRAW_AND_COLLECT_AND_SWAP` with `liquidity < full`;
   - rebalance: `CHANGE_RANGE`;
   - exit: `WITHDRAW_AND_COLLECT_AND_SWAP` with full liquidity.
3. Then:
   - **Partial remove:** restake the same `tokenId` with `depositFor`.
   - **Rebalance:** restake the **new** NFT with `depositFor(newId, user)`. Send the old, empty NFT to the
     user's wallet.
   - **Exit:** send the NFT to the user's wallet, unstaked.
4. Forward the withdrawn and leftover tokens to the user.

### 5.4 Harvest (all chains, no fee)
Harvest is a direct call by the user's wallet to `gauge.claimEmissions(user, user, tokenIds)`. It needs no
helper and no approval. *(Builder's call, §8: whether the helper also offers a multi‑gauge batch harvest.)*

### 5.5 Compound (Base only)
1. `claimEmissions(user, helper, [tokenId])`. This needs `approveForClaim`. The helper receives AERO and
   measures the delta.
2. `withdrawFrom(tokenId, user)`. The emissions were just claimed, so nothing more is paid here. Any
   deferred amounts were included in step 1.
3. Approve AERO and call `V3Utils.swapAndIncreaseLiquidity` with `swapSourceToken = AERO`, amount = the
   claimed delta, swap data from the app, and the fee in `protocolFeeX64` (see §6).
4. `depositFor(tokenId, user)`. Forward the leftovers.
5. Revert on chains where the reward token is not AERO. The builder decides how; a guard on `block.chainid`
   or a configured reward token are both fine.

Notes (verified against the sources):
- V3Utils deducts `protocolFeeX64` from the swap-source amount **before** swapping (`V3Utils.sol:571-591`,
  then `Common.sol:484-499`). The entry check uses the amount before the fee (`V3Utils.sol:552-556`), and
  `Common.sol:491` checks again after it. So the app must quote `amountIn0 + amountIn1` to fit inside the
  claimed amount *after* the fee. Surplus AERO comes back as a leftover.
- If AERO is one of the pool's own tokens (e.g. AERO/USDC), V3Utils takes the token0/token1 branch
  (`Common.sol:464-483`), so the claim goes in `amount0`/`amount1`, not `amount2`.
- The claim also sweeps the user's **deferred** emissions in that gauge, from any of their positions
  (`CLGauge.sol:402-407`). *(My call: that's fine. It is the user's AERO, and it gets compounded into the
  chosen position.)*
- `claimEmissions` does not catch a failed emissions mint (`CLGauge.sol:418`), so compound reverts while
  minting is broken. *(My call: acceptable. Harvest and other flows still work, because withdraw defers
  emissions instead of reverting.)*

### 5.6 Why compound is Base‑only
On non‑Base chains the reward is xAERO, and the only way to redeem it is a cross‑chain bridge, so it cannot
be swapped into the pair in the same transaction unless the chain has xAERO DEX liquidity. That is unknown.
Revisit if xAERO markets appear.

## 6. Fees
Same as V3Utils (user decision). For zap, add, remove, rebalance and exit, the app passes V3Utils's
existing fee fields, the helper passes them through, and V3Utils takes and records the fee as it does
today. Harvest has no fee.

**Compound is the exception: the helper takes the fee itself**, so it is labelled `PERFORMANCE_FEE`
(user asked for the correct label). The deployed V3Utils can't do this: `swapAndIncreaseLiquidity` has
only `protocolFeeX64`, hardcoded as `FeeType.LIQUIDITY_FEE` (`V3Utils.sol:578`). The helper:
1. Deducts `performanceFeeX64` from the claimed AERO. Use the same X64 math and the same cap as V3Utils's
   performance fee (`Common.sol` caps).
2. Sends the fee to `V3Utils.FEE_TAKER()`, read live so it follows V3Utils.
3. Emits `DeductFees` with the same struct and semantics as `Common`, with `FeeType.PERFORMANCE_FEE`, and
   `userAddress` set to the **user**.
4. Calls `swapAndIncreaseLiquidity` with `protocolFeeX64 = 0`. `gasFeeX64` is still passed through.

The backend should index the helper's `DeductFees` the same way it indexes V3Utils's.

Because the helper is V3Utils's `recipient`, every V3Utils event and `DeductFees.userAddress` names the
**helper**, not the user. *(My call: the helper emits its own events for each flow. Each event carries the
user, the gauge, the old and new tokenId, and the action, so the backend can attribute it.)*

## 7. Automation entry point (ships in the first version)
User decision: the operator entry point ships **now**, so one audit covers it, and users never approve
again. Upgradeability (§4) is a backstop, not the plan for automation.

- Every flow runs through internal functions that take `account` explicitly.
  - User entry points set `account = msg.sender`.
  - Operator entry points require the `OPERATOR_ROLE` (mirror V3Automation) **and** a valid user-signed
    order for `account`.
- Order signing and checks **mirror V3Automation**: the same EIP‑712 domain style, `StructHash` order
  types, and signature, cancel and expiry handling. Read `src/V3Automation.sol` and `src/StructHash.sol`.
  - The helper hashes orders by calling the chain's **deployed** StructHash library (`structHash` in
    `contracts.json`) via staticcall, so hashing is byte‑identical to V3Automation and costs no code
    size. *(My call.)*
  - EIP‑712 domain: name `AeroFarmingHelper`, version `1`. `verifyingContract` is the **proxy**,
    computed at call time and not stored as an immutable, so upgrades don't invalidate signed orders.
  - Like V3Automation, the contract does **not** check that the order's tokenId, NFPM or action match
    the call. The operator is trusted for that, and a recurring order must keep working after
    AUTO_ADJUST creates a new tokenId. The contract checks only that the signer is the gauge stake
    owner of the tokenId being acted on, and that the order is not cancelled.
  - Whatever V3Automation verifies on-chain for its rebalance and compound orders, the helper verifies too.
  - Whatever V3Automation leaves to the off-chain operator, the helper leaves too.
- Automated actions mirror V3Automation's `Action` enum (`V3Automation.sol:32-37`):
  - **AUTO_ADJUST** is rebalance (§5.3), restaking the new NFT.
  - **AUTO_EXIT** is exit (§5.3). The NFT goes to the user's wallet, unstaked. AUTO_EXIT was added by user
    decision, since V3Automation already supports it.
  - **AUTO_COMPOUND** is compound (§5.5), on Base only.
  - **AUTO_HARVEST** claims the emissions with `claimEmissions(user, helper, [tokenId])`. The position stays
    staked; nothing is unstaked.
    - **Base:** optionally swap the AERO into `targetToken`, as V3Automation's AUTO_HARVEST does
      (`V3Automation.sol:322-359`), then send it to the user.
    - **Other chains:** send the xAERO to the user unswapped. `targetToken` must be the reward token or
      zero.
    - **Fee:** gas fee only. There is no performance fee, consistent with "no fee on harvest".
      *(My call: the gas fee covers the operator's cost.)*
  - Add and remove liquidity stay user-only.
- Approvals: AUTO_COMPOUND and AUTO_HARVEST need `approveForClaim(helper)`. AUTO_ADJUST and AUTO_EXIT need
  only `setApprovalForAll`.
- Fees on operator calls follow V3Automation: gas fee plus the order's fee caps.
- The "user-signed actions first" priority now means build order and rollout order. Nothing is deferred
  out of the first contract.

## 8. Constraints and risks
- **Approval blast radius.** Users grant the helper blanket withdraw and claim approval per gauge, so a bug
  in the account check exposes every approving user. Mitigations:
  - the `msg.sender == account` invariant (§2);
  - Pausable plus AccessControl (mirror `Common`);
  - an audit before mainnet;
  - the app may prefer per‑token `gauge.approve` for users who want a narrower grant. `withdrawFrom`
    accepts either.
- **Claim routing in withdrawFrom.** If the user has `approveForClaim(helper)` (granted for compound), then
  `withdrawFrom` sends the emissions **and the position's owed pool tokens** to the helper. `_withdraw`
  collects both to the same recipient (`CLGauge.sol:344-348`, `Gauge.sol:64`). In every unstaking flow, the
  helper measures the token0, token1 and reward-token deltas around `withdrawFrom` and forwards them to the
  user. On non-Base chains the reward token is xAERO, a transferable ERC20, so forwarding it works the same
  way. *(My call.)*
- **Per-token approval is single-use.** Every withdraw deletes `gauge.approve` (`CLGauge.sol:340`), and
  a rebalance creates a new tokenId. A user who picks per-token approval therefore needs an extra approve
  transaction before every helper action, and that route can't support automation. The app should default
  to `setApprovalForAll`.
- **NFT receive guard.** The only safe transfers the helper receives come from the gauge during
  `withdrawFrom` (`CLGauge.sol:358`; operator and `from` are both the gauge). The guard must accept those
  while a flow is running and reject everything else.
- **Native coin on Arc.** On Arc, native and USDC share one balance (`Common.sol:81-96`), so counting
  leftovers in both would count them twice. *(My call: the helper is ERC20-only on Arc and accepts native
  input and unwrap only elsewhere. The builder can instead copy V3Utils's native-mode handling.)*
- **Dead gauges.** `isGauge` does not catch a killed or deactivated gauge. *(My call: zap-in and any restake
  revert if the gauge is not live. Exit and harvest still work. The builder picks the check, e.g.
  `LeafVoter.isActivated(gauge)` or `emissionCap`, after confirming what killing a gauge changes.)*
- **Early‑unstake penalty.** Any flow that restakes resets `depositBlock`. A second action within the
  window (70 blocks on Base as of 2026‑11‑12) forfeits that position's emissions. No contract guard. The app warns. *(My call.)*
- **Stray NFTs.** `onERC721Received` accepts NFTs only from the expected NFPM, and only during a flow, using a
  transient or reentrancy flag. Unsolicited NFTs revert. *(My call.)*
- **Leftovers via deltas only**, so stray balances can't be swept by the next caller. Admin rescue for
  stray ERC20/ERC721, like `Common.withdraw*`.
- **Ops prerequisite:** whitelist NFPM `0x4857…` on V3Utils on each chain where the helper is deployed.
  Check it with the storage‑slot recipe (`_whitelistedNfpm` positions mapping at slot 3).
- **Deployment:** Foundry script alongside the existing ones. Take addresses from the real deploy, since
  v3utils CREATE2 addresses are not reproducible from source.

## 9. Testing
- Fork tests on **Base** against a real gauge from the canonical factory. Cover:
  - each flow end‑to‑end;
  - compound (AERO);
  - claim routing with and without `approveForClaim`;
  - the penalty window;
  - a non‑genuine gauge rejected;
  - caller ≠ account rejected;
  - no residual balance on the helper after each flow.
  - the operator path: valid order, wrong signer, cancelled order (orders have no on-chain expiry, as in
    V3Automation), non-operator caller, and
    an order signed by someone other than the tokenId's stake owner;
  - the compound fee lands at `FEE_TAKER` with a `PERFORMANCE_FEE` event naming the user;
  - an upgrade keeps state, and the existing gauge approvals still work afterwards.
- One non‑Base fork (e.g. OP): harvest pays xAERO, and compound reverts.
- Unit tests for the account check and the NFT receive guard.

## 10. Chains
The helper points at the V3Utils already deployed on each chain:
- `0xb4ac…` on Base, OP, Arbitrum, Ethereum and Robinhood;
- `0x1ee3…` on Arc.

Take the exact addresses from `contracts.json`.
- The `0xb4ac…` build predates #61 and #62 (balance‑delta accounting). The helper must not rely on that
  fix, and the fork tests run against the deployed bytecode, not the current source.
- Parameter structs are identical between the two builds, so one helper ABI works with both.

**Ink is out until it has a V3Utils deploy.** *(My call.)* Compound is enabled on Base only. Roll out
Base first.

## 11. Left to the builder
- Contract and function naming, and the calldata structs. Prefer thin structs that embed the V3Utils params
  as is.
- Whether to add a multi‑gauge batch harvest (§5.4).
- How the compound chain guard is expressed (§5.5).
- The exact NFT‑receive guard mechanism (§8).
- Gas tuning, and whether to use OZ Multicall for batching.

## 12. Architecture revision (2026‑11‑13, user decision: "rework it like v4utils")

This section **supersedes** §4's "upgradeable proxy" bullet, §7's proxy-domain bullet and the delegatecall‑module
split (ruling R7). Everything else — flows, fees, account rule, chain rules, tests — is unchanged.

The model is `v4utils/src/V4UtilsRouter.sol`: a fixed router that users approve, plus a stateless logic contract
that the router delegatecalls through **explicit** entry points.

- **`AeroFarmingRouter`** — deployed directly (no proxy, not upgradeable). It is the address users approve on
  gauges, forever. Holds: AccessControl roles (`DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `PAUSER_ROLE`, `OPERATOR_ROLE`,
  `WITHDRAWER_ROLE`; see "Admin model" below), Pausable,
  ReentrancyGuard, `initialize` (front-run‑guarded like `Common`: only the deploying `tx.origin` may call it),
  config setters, rescue (`withdrawERC20/ERC721/Native`), the NFT receive guard, `receive()` (WETH only), order
  signing/cancel, and two entry points:
  - `execute(bytes data)` — users. Delegatecalls the logic with `data`; `msg.sender` (the account) is preserved.
  - `executeAutomation(address account, address gauge, uint256 tokenId, AutoAction action, bytes actionData,
    bytes order, bytes signature)` — `OPERATOR_ROLE`. Validates gauge, stake ownership, order, cancel; then the
    **router builds the calldata itself** for the logic's automated entry, records `account` as the authorised
    automation account in shared storage, delegatecalls, and clears it.
  - `setImplementation(address)` (`ADMIN_ROLE`; must have code) and `lockImplementation()` (`ADMIN_ROLE`, one‑way),
    as in v4utils. The lock also freezes `setV3Utils`.
- **`AeroFarmingLogic`** — stateless (immutables only). All flows from §5 and §7. Config and flow state live in a
  namespaced storage struct at a fixed slot (`AeroStorage`, ERC‑7201 style), so the router and any future logic
  share state without inheritance layout coupling. Every external function is `onlyDelegateCall` (reverts when
  called on the logic directly). The automated entry requires the account to equal the router‑recorded automation
  account, so it is unreachable through `execute`.
- **Orders:** EIP‑712 domain name `AeroFarmingRouter`, version `1`, `verifyingContract` = router (immutable, fine
  since the router is not proxied). Hashing uses the source `StructHash._hash(Order)` internally (no deployed‑library
  address, no linking). Like V4UtilsRouter, the router decodes the order and requires `order.chainId == block.chainid`
  and `order.nfpmAddress == gauge.nft()`; `tokenId` stays unbound (recurring rebalances mint new ids).
- **Upgrades:** replace the logic with `setImplementation`; optionally freeze with `lockImplementation`, which also
  freezes `setV3Utils` (one flag, `implementationLocked`, for both: V3Utils is the other contract users' NFTs pass
  through). Router code (roles, order checks, cancel) is fixed at deploy — accepted trade‑off, same as v4utils.
- **Admin model** (2026‑11‑13 final review). Roles split as in v4utils, plus a pauser:
  - `DEFAULT_ADMIN_ROLE` — role administration only (it is the admin role of every other role).
  - `ADMIN_ROLE` — `setImplementation`, `lockImplementation`, `setV3Utils`.
  - `PAUSER_ROLE` — `pause`, `unpause`.
  - `OPERATOR_ROLE` — `executeAutomation`; `WITHDRAWER_ROLE` — `withdrawERC20/ERC721/Native`.

  `initialize(admin, operator, withdrawer, pauser, implementation, v3utils, gaugeFactory, rewardToken,
  compoundEnabled, weth)` grants `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` to `admin` and one role to each of the others;
  the deployer gets nothing. ADMIN_ROLE has custody-level power over every approving user's stake until locked; hold
  it behind a timelock. Deployment: `ADMIN` should be a TimelockController in front of the Safe; `PAUSER` can be the
  Safe or an ops key (pausing must stay fast).
- **Invariants for future logic** (any `setImplementation` target must keep them):
  - every external function takes the account from `msg.sender` (user flows through `execute`) or from
    `AeroStorage.automationAccount` (the automated entry); never from calldata alone;
  - no self‑delegatecall multicall (it would reuse `msg.value` across calls);
  - `AeroStorage` fields are append‑only (never reorder, retype or remove);
  - the router's `_validateGauge` must stay in step with the logic's (same factory and NFT checks), since the router
    validates the gauge for `executeAutomation` before the logic runs.
- **Removed:** UUPS proxy, `AeroAutomationModule`, the fallback, `IAeroAutomation`, the `structHash` config.
