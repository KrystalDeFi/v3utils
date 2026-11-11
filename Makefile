ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# HyperEVM (999) runs two block types: small blocks (3M gas) and big blocks (30M gas). A deployer
# with big blocks enabled (eth_usingBigBlocks) lands its txs in big blocks, but forge simulates
# against the forked block's gas limit, which is a small block's 3M: V3Utils's ~7.5M-gas creation
# then fails with OutOfGas locally before anything is sent. Lift the simulation cap there only.
ifeq ($(CHAIN_ID),999)
    DEPLOY_EXTRA_FLAGS = --disable-block-gas-limit
endif
DEPLOY_CMD = forge script script/$(CONTRACT).s.sol:$(CONTRACT)Script --rpc-url $(RPC_URL) --broadcast $(DEPLOY_EXTRA_FLAGS)
VERIFY_CMD = forge script script/Verify.s.sol:Verify$(CONTRACT)Script | awk 'END{print}' | bash

# The appended solc metadata hash covers forge-computed remappings, so the forge version is part of
# every CREATE2 address: v1.7.1, v1.8.x and v1.9.0 each produce a different address for the same
# sources and salt. check-forge.sh pins the toolchain to the v1.8.3 release (commit cae51ad) that
# produced the deployed bytecode and rejects anything else before it can build or broadcast.
forge-check:
	@script/check-forge.sh

build: src/V3Utils.sol clean forge-check
	forge build
test: src/V3Utils.sol test/* forge-check
	forge test
.PHONY: clean v3utils v3automation structhash libs-check-v3utils libs-check-v3automation forge-check
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
deploy-%: forge-check %
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
