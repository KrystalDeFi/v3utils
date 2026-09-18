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
.PHONY: clean v3utils v3automation structhash
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
# check, so the call reverts.) Assert, for each linked library, that .env agrees with the address
# foundry.toml links against and that code exists there on the target chain.
libs-check: libs-check-config libs-check-code

# Config consistency needs no network, so check it first and fail fast.
libs-check-config:
	@for pair in "Nfpm:$(NFPM_LIB_ADDRESS)" "CommonLib:$(COMMON_LIB_ADDRESS)"; do \
		name=$${pair%%:*}; addr=$${pair#*:}; \
		if [ -z "$$addr" ]; then echo "$$name address is not set in .env"; exit 1; fi; \
		if ! grep -iq "$$name:$$addr" foundry.toml; then \
			echo "MISMATCH $$name: .env says $$addr, foundry.toml links:"; \
			grep -i "$$name:0x" foundry.toml; \
			echo "deploy links against foundry.toml while verify passes .env, so these must agree"; \
			exit 1; fi; \
		echo "$$name config ok  $$addr"; \
	done

libs-check-code:
	@for pair in "Nfpm:$(NFPM_LIB_ADDRESS)" "CommonLib:$(COMMON_LIB_ADDRESS)"; do \
		name=$${pair%%:*}; addr=$${pair#*:}; \
		if [ $$(cast co $$addr --rpc-url $(RPC_URL) | wc -m) -le 3 ]; then \
			echo "$$name is not deployed at $$addr on this chain =>> deploy it first"; exit 1; fi; \
		echo "$$name deployed ok  $$addr"; \
	done

v3automation-check: libs-check
	forge script script/V3Automation.s.sol:BeforeV3AutomationScript
	@if [[ $$(cast co $(STRUCT_HASH_ADDRESS) --rpc-url $(RPC_URL) | wc -m) -eq 3 ]]; then echo 'structhash not deployed yet. =>> `make deploy-structhash` first'; exit 1; fi
structhash:
	$(eval CONTRACT=StructHash)
nfpm:
	$(eval CONTRACT=Nfpm)
commonlib:
	$(eval CONTRACT=CommonLib)
deploy-%: %
	$(DEPLOY_CMD)
deploy-v3utils: libs-check
deploy-structhash:
deploy-nfpm:
deploy-commonlib:
deploy-v3automation: libs-check

verify-%: %
	$(VERIFY_CMD)
verify-v3utils: libs-check
verify-structhash:
verify-nfpm:
verify-commonlib:
verify-v3automation: v3automation-check v3automation
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
