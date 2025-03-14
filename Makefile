ifneq (,$(wildcard ./.env))
    include .env
    export
endif

DEPLOY_CMD = forge script script/$(CONTRACT).s.sol:$(CONTRACT)Script --rpc-url $(RPC_URL) --broadcast --legacy --gas-price 0
VERIFY_CMD = forge script script/Verify.s.sol:Verify$(CONTRACT)Script

build: src/V3Utils.sol clean
	forge build
test: src/V3Utils.sol test/*
	forge test
.PHONY: clean v3utils v3automation structhash
clean:
	forge clean && rm -rf cache
v3utils:
	$(eval CONTRACT=V3Utils)
v3automation:
	$(eval FOUNDRY_PROFILE=linker)
	$(eval CONTRACT=V3Automation)
v3automation-check:
	forge script script/V3Automation.s.sol:BeforeV3AutomationScript
	@if [[ $$(cast co $(STRUCT_HASH_ADDRESS) --rpc-url $(RPC_URL) | wc -m) -eq 3 ]]; then echo 'structhash not deployed yet. =>> `make deploy-structhash` first'; exit 1; fi
structhash:
	$(eval CONTRACT=StructHash)
deploy-%: %
	$(DEPLOY_CMD)
deploy-v3utils:
deploy-structhash:
deploy-v3automation:

verify-%: %
	$(VERIFY_CMD)
verify-v3utils:
verify-structhash:
verify-v3automation: v3automation-check v3automation
	$(VERIFY_CMD)
init-v3utils:
init-v3automation:
init-%: %
	forge script script/Init.s.sol:$(CONTRACT)InitializeScript --rpc-url $(RPC_URL) --broadcast --legacy --gas-price 0
