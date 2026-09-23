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
