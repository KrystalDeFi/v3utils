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
v3automation-check:
	forge script script/V3Automation.s.sol:BeforeV3AutomationScript
	@if [[ $$(cast co $(STRUCT_HASH_ADDRESS) --rpc-url $(RPC_URL) | wc -m) -eq 3 ]]; then echo 'structhash not deployed yet. =>> `make deploy-structhash` first'; exit 1; fi
structhash:
	$(eval CONTRACT=StructHash)
nfpm:
	$(eval CONTRACT=Nfpm)
deploy-%: %
	$(DEPLOY_CMD)
deploy-v3utils:
deploy-structhash:
deploy-nfpm:
deploy-v3automation:

verify-%: %
	$(VERIFY_CMD)
verify-v3utils:
verify-structhash:
verify-nfpm:
verify-v3automation: v3automation-check v3automation
	$(VERIFY_CMD)
init-v3utils:
init-v3automation:
init-%: %
	forge script script/Init.s.sol:$(CONTRACT)InitializeScript --rpc-url $(RPC_URL) --broadcast --legacy --gas-price 0
grant-role: v3automation
	forge script script/GrantRole.s.sol:V3AutomationGrantRoleScript --rpc-url $(RPC_URL) --broadcast --legacy --gas-price 0
deploy-everything:
	make deploy-nfpm
	make deploy-structhash
	make deploy-v3utils
	make deploy-v3automation
	make verify-nfpm
	make verify-structhash
	make verify-v3utils
	make verify-v3automation
	make init-v3utils
	make init-v3automation
	make grant-role
