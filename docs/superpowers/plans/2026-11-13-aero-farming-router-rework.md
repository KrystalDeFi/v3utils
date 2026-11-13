# Aero Farming Router Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the UUPS proxy + fallback module with a v4utils‑style fixed router + stateless logic, keeping every flow and test behaviour.

**Architecture:** `AeroFarmingRouter` (fixed, users approve it) delegatecalls `AeroFarmingLogic` via explicit `execute` / `executeAutomation`; shared state in a namespaced `AeroStorage` slot.

**Tech Stack:** Solidity 0.8.15, Foundry, OZ 4.9.6, `@krystal/util-contracts` SignatureValidator. Fork tests on Base/OP.

**Spec:** `docs/superpowers/specs/2026-11-12-aero-farming-helper-design.md` — §12 is authoritative where it conflicts with earlier sections.

## Global Constraints

- Everything in the previous plan's Global Constraints still holds (`docs/superpowers/plans/2026-11-12-aero-farming-helper.md`), **except** the UUPS/storage‑append rules, which §12 replaces.
- No edits to existing `src/*.sol` outside `src/aero/`, `remappings.txt`, `foundry.toml`. No linked libraries in either contract (`linkReferences` == {}). Both runtimes < 24,576 B (`forge build --sizes --skip test --skip script`).
- Fork tests: `BASE_RPC_URL=https://mainnet.base.org OP_RPC_URL=https://mainnet.optimism.io FOUNDRY_EVM_VERSION=cancun`.
- Behaviour parity: every assertion in today's 88 aero tests must still hold (adapted only for the new call path).
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A user calling the automated entry through `execute` must revert (automation account not recorded). → `test_execute_cannotReachAutomatedEntry` (Task 1).
2. Calling any logic function directly on the logic contract must revert (`onlyDelegateCall`). → `test_logic_directCallReverts` (Task 1).
3. Orders for another chain or another NFPM must revert. → `test_order_wrongChainId_reverts`, `test_order_wrongNfpm_reverts` (Task 1).
4. Swapping the logic keeps config and already‑signed orders valid; after `lockImplementation`, `setImplementation` reverts. → `test_setImplementation_keepsStateAndOrders`, `test_lockImplementation` (Task 1).
5. `initialize` can only be called by the deploying `tx.origin`, once. → `test_initialize_onlyDeployerOrigin` (Task 1).

---

### Task 1: Router + logic + namespaced storage; migrate all tests

**Files:**
- Create: `src/aero/AeroStorage.sol`, `src/aero/AeroFarmingLogic.sol`, `src/aero/AeroFarmingRouter.sol`, `src/aero/IAeroFarmingLogic.sol` (the logic's external functions + shared structs/enums/events/errors, for app encoding and tests).
- Delete: `src/aero/AeroFarmingCore.sol`, `src/aero/AeroFarmingHelper.sol`, `src/aero/AeroAutomationModule.sol`, `src/aero/IAeroAutomation.sol`.
- Keep: `src/aero/IAero.sol` (add `INonfungiblePositionManager`-free bits only if needed).
- Modify: `test/aero/*` (rename files to `AeroFarming*.t.sol` is optional; keep names if simpler).

**Interfaces (Produces):**
```solidity
library AeroStorage {
    struct Layout {
        address v3utils; address gaugeFactory; address rewardToken; bool compoundEnabled; address weth;
        address activeGauge;        // non-zero only inside withdrawFrom (NFT receive guard)
        address automationAccount;  // non-zero only inside executeAutomation
    }
    // slot = keccak256(abi.encode(uint256(keccak256("krystal.aero.farming.storage")) - 1)) & ~bytes32(uint256(0xff))
    function layout() internal pure returns (Layout storage l);
}

contract AeroFarmingRouter is AccessControl, Pausable, ReentrancyGuard, IERC721Receiver {
    bytes32 OPERATOR_ROLE, WITHDRAWER_ROLE;
    address public implementation; bool public implementationLocked;
    bytes32 public immutable DOMAIN_SEPARATOR; // name "AeroFarmingRouter", version "1", address(this)
    constructor();  // records tx.origin as the only allowed initializer; computes DOMAIN_SEPARATOR
    function initialize(address admin, address operator, address withdrawer, address implementation_,
        address v3utils_, address gaugeFactory_, address rewardToken_, bool compoundEnabled_, address weth_) external;
    function execute(bytes calldata data) external payable nonReentrant whenNotPaused returns (bytes memory);
    function executeAutomation(address account, address gauge, uint256 tokenId, IAeroFarmingLogic.AutoAction action,
        bytes calldata actionData, bytes calldata order, bytes calldata signature)
        external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) returns (uint256 tokenIdAfter);
    function hashOrder(bytes calldata order) external view returns (bytes32 digest);
    function cancelOrder(bytes32 hash, bytes calldata signature) external;
    function isOrderCancelled(address actor, bytes32 hash) external view returns (bool);
    function setImplementation(address) external; function lockImplementation() external;   // DEFAULT_ADMIN_ROLE
    function setV3Utils(address) external; function pause() external; function unpause() external; // DEFAULT_ADMIN_ROLE
    function withdrawERC20(IERC20, address) external; function withdrawERC721(IERC721, uint256, address) external;
    function withdrawNative(address) external;                                                    // WITHDRAWER_ROLE
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4); // guard only
    receive() external payable;   // only from AeroStorage.weth
}

contract AeroFarmingLogic is IAeroFarmingLogic {
    // user flows, same signatures as today's helper: zapInAndStake, addLiquidity, removeLiquidity, rebalance, exit, compound
    // automated entry (router-built calldata only):
    function executeAutomated(AutoAction action, address account, address gauge, uint256 tokenId, bytes calldata actionData)
        external returns (uint256 tokenIdAfter); // requires AeroStorage.automationAccount == account != 0
    // all external functions: onlyDelegateCall (address(this) != immutable self)
}
```

**Decisions:**
- Move code, don't rewrite it: internals from `AeroFarmingCore` (`_unstake/_stake/_snapshot/_sweep/_modify/_compound/_claim/_takeFee/_validateGauge/_requireLive/...`) and the module's `_harvest/_swap` go into the logic, reading config from `AeroStorage.layout()` instead of state variables.
- `executeAutomation` order: `_validateGauge(gauge)` (router may call a small internal copy or `IAero` views) → `ICLGauge(gauge).stakedContains(account, tokenId)` else `NotStakeOwner` → decode `StructHash.Order`, require `chainId == int64(int256(block.chainid))` (`WrongChainId`) and `nfpmAddress == ICLGauge(gauge).nft()` (`WrongPositionManager`) → signature (`SignatureValidator.isValidSignatureNow`) → cancel check → set `automationAccount = account` → delegatecall `abi.encodeCall(IAeroFarmingLogic.executeAutomated, (action, account, gauge, tokenId, actionData))` → clear → decode `tokenIdAfter`. Revert data bubbles unchanged.
- `execute`: require `implementation != 0`; delegatecall; bubble revert data; return the raw return bytes.
- Fee caps, events (`FarmAction`, `DeductFees` — emitted by the router address under delegatecall), errors: unchanged names.
- `DOMAIN_SEPARATOR` immutable in the router; `StructHash._hash(Order)` internal overload (import `src/StructHash.sol` types; do not call the external `_hash(bytes)` — linkReferences must stay {}).

- [ ] **Step 1:** Write the new router‑specific failing tests (Review Focus 1–5) plus `test_execute_unsetImplementation_reverts` and `test_setImplementation_requiresCode`.
- [ ] **Step 2:** Implement storage, logic, router; delete the old contracts; update `AeroForkBase` (`_deployRouter(...)` deploys logic + router + initialize; `_approveGauge` targets the router) and every test file to call `router.execute(abi.encodeCall(IAeroFarmingLogic.<fn>, (...)))` and `router.executeAutomation(...)`; signed orders use the router's `hashOrder` and must set `chainId`/`nfpmAddress` correctly.
- [ ] **Step 3:** Run all of `test/aero` → every previous test (adapted) + the new ones pass; sizes; linkReferences; `git diff eed62f1 --` protected files empty.
- [ ] **Step 4:** Commit `refactor(aero): v4utils-style router + stateless logic`.

### Task 2: Deploy script, Makefile, sample.env

**Files:** Modify `script/AeroFarmingHelper.s.sol` → rename to `script/AeroFarmingRouter.s.sol` (`AeroFarmingRouterScript`); Makefile `aerohelper`/`deploy-aerohelper` → `aerorouter`/`deploy-aerorouter`; `sample.env` keys (drop `STRUCT_HASH`).

**Decisions:** deploy logic, then router, then `initialize` in the same broadcast (deployer EOA is `tx.origin`); keep every existing env validation (`_required`, REWARD_TOKEN vs RECEIPT_TOKEN off Base, COMPOUND_ENABLED only on Base). Log logic + router.

- [ ] **Step 1:** Adapt `test/aero/*deploy*.t.sol`: deployer holds no role; roles exact; config matches env; `implementation()` has code; zero‑address and reward‑token checks still revert.
- [ ] **Step 2:** Implement; run the deploy tests and the full aero suite; `make -n deploy-aerorouter`.
- [ ] **Step 3:** Commit `feat(aero): router deploy script`.
