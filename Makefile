ifneq (,$(wildcard ./.env))
    include .env
    export
endif

DEPLOY_CMD = forge script script/$(CONTRACT).s.sol:$(CONTRACT)Script --rpc-url $(RPC_URL) --broadcast
VERIFY_CMD = forge script script/Verify.s.sol:Verify$(CONTRACT)Script | awk 'END{print}' | bash

build: src/V3Utils.sol clean
	forge build
test: src/V3Utils.sol test/*
	forge test
.PHONY: clean v3utils v3automation structhash libs-check-v3utils libs-check-v3automation
clean:
	forge clean && rm -rf cache
v3utils:
	$(eval FOUNDRY_PROFILE=v3utilslinker)
	$(eval CONTRACT=V3Utils)
v3automation:
	$(eval FOUNDRY_PROFILE=linker)
	$(eval CONTRACT=V3Automation)
# Libraries are reached by DELEGATECALL, so a linked address that holds the wrong code runs the
# wrong logic silently - exactly what happened on Arc, where a stale CommonLib stayed pinned after
# its source changed. (A *missing* address is safe: solc guards library calls with an extcodesize
# check, so the call reverts.) foundry.toml's `libraries` is the only source of truth for what gets
# linked; check-libs.sh asserts each pinned address holds the bytecode we build, on the target chain.
# The profile is spelled out rather than read from $(FOUNDRY_PROFILE): that variable is set by an
# $(eval) in a sibling prerequisite's recipe, so its value here would depend on prerequisite order.
libs-check-v3utils:
	@script/check-libs.sh v3utilslinker

libs-check-v3automation:
	@script/check-libs.sh linker

structhash:
	$(eval CONTRACT=StructHash)
nfpm:
	$(eval CONTRACT=Nfpm)
commonlib:
	$(eval CONTRACT=CommonLib)
deploy-%: %
	$(DEPLOY_CMD)
deploy-v3utils: libs-check-v3utils
deploy-structhash:
deploy-nfpm:
deploy-commonlib:
deploy-v3automation: libs-check-v3automation

verify-%: %
	$(VERIFY_CMD)
verify-v3utils: libs-check-v3utils
verify-structhash:
verify-nfpm:
verify-commonlib:
verify-v3automation: libs-check-v3automation v3automation
	$(VERIFY_CMD)
init-v3utils:
init-v3automation:
init-%: %
	forge script script/Init.s.sol:$(CONTRACT)InitializeScript --rpc-url $(RPC_URL) --broadcast
grant-role-v3automation: v3automation
	forge script script/GrantRole.s.sol:V3AutomationGrantRoleScript --rpc-url $(RPC_URL) --broadcast 
grant-role-v3utils: v3utils
	forge script script/GrantRole.s.sol:$(CONTRACT)GrantRoleScript --rpc-url $(RPC_URL) --broadcast
deploy-everything:
	make deploy-nfpm
	make deploy-commonlib
	make deploy-structhash
	make deploy-v3utils
	make deploy-v3automation
	make verify-nfpm
	make verify-commonlib
	make verify-structhash
	make verify-v3utils
	make verify-v3automation
	make init-v3utils
	make init-v3automation
	make grant-role

# --- Aero farming router (src/aero) ---------------------------------------------------------------
# Plain CREATE, not CREATE2 (the init args differ per chain), and no linked libraries, so the generic
# deploy-%/verify-% rules above do not fit. The verify targets read the deployed addresses from the
# deploy broadcast for CHAIN_ID unless .env sets AERO_ROUTER / AERO_LOGIC.
# FOUNDRY_EVM_VERSION=cancun is required to simulate against Aero's LeafVoter, which uses Cancun
# opcodes. It does not change the bytecode: solc 0.8.15 still emits london. The verify targets run
# without it, so the explorer gets the real (london) settings.
#   make dryrun-aerorouter   simulate the deploy against RPC_URL (no transactions)
#   make deploy-aerorouter   deploy the logic + router and initialize the router
#   make verify-aero         verify both on the explorer (VERIFIER / VERIFIER_URL / VERIFIER_API_KEY)
#   make deploy-aero         all of the above except the dry run
.PHONY: dryrun-aerorouter deploy-aerorouter verify-aerorouter verify-aerologic verify-aero deploy-aero
AERO_DEPLOY_CMD = FOUNDRY_EVM_VERSION=cancun forge script script/AeroFarmingRouter.s.sol:AeroFarmingRouterScript --rpc-url $(RPC_URL)
AERO_BROADCAST = broadcast/AeroFarmingRouter.s.sol/$(CHAIN_ID)/run-latest.json
aero_deployed = $(shell jq -r '[.transactions[] | select(.transactionType == "CREATE" and .contractName == "$(1)")][0].contractAddress // empty' $(AERO_BROADCAST) 2>/dev/null)
AERO_ROUTER ?= $(call aero_deployed,AeroFarmingRouter)
AERO_LOGIC ?= $(call aero_deployed,AeroFarmingLogic)

dryrun-aerorouter:
	$(AERO_DEPLOY_CMD)
deploy-aerorouter:
	$(AERO_DEPLOY_CMD) --broadcast
verify-aerorouter:
	@test -n "$(AERO_ROUTER)" || { echo "no AeroFarmingRouter in $(AERO_BROADCAST); set AERO_ROUTER"; exit 1; }
	AERO_ROUTER=$(AERO_ROUTER) forge script script/Verify.s.sol:VerifyAeroFarmingRouterScript | awk 'END{print}' | bash
verify-aerologic:
	@test -n "$(AERO_LOGIC)" || { echo "no AeroFarmingLogic in $(AERO_BROADCAST); set AERO_LOGIC"; exit 1; }
	AERO_LOGIC=$(AERO_LOGIC) forge script script/Verify.s.sol:VerifyAeroFarmingLogicScript | awk 'END{print}' | bash
verify-aero: verify-aerorouter verify-aerologic
deploy-aero:
	make deploy-aerorouter
	make verify-aero
