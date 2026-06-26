# Official Fray contract deploys.
#
# Every deploy goes through this Makefile and signs with an ENCRYPTED keystore
# account (no plaintext keys). One-time setup:
#
#   ~/.foundry/bin/cast wallet import fray-deployer --interactive   # reuse existing key
#   # or: ~/.foundry/bin/cast wallet new ~/.foundry/keystores fray-deployer
#
# Then fund the printed address with a little Base ETH for gas. See DEPLOY.md.
#
# Required env: BASE_RPC_URL, ETHERSCAN_API_KEY (a Basescan key, for --verify).
# Per-deploy env is documented in each script's NatSpec.

FORGE   := $(HOME)/.foundry/bin/forge
RPC     ?= $(BASE_RPC_URL)
ACCOUNT ?= fray-deployer
SCRIPT  := $(FORGE) script
# --broadcast sends txs; --verify publishes source to Basescan.
FLAGS    = --rpc-url $(RPC) --account $(ACCOUNT) --broadcast --verify -vvv
# Simulation only (no broadcast) — same script, dry.
DRYFLAGS = --rpc-url $(RPC) --account $(ACCOUNT) -vvv

.PHONY: build test fmt \
        deploy-markets dry-markets \
        deploy-registry deploy-factory deploy-migrate upgrade-registry

build:
	$(FORGE) build

test:
	$(FORGE) test

fmt:
	$(FORGE) fmt

# ---- Public markets settlement (CTF + CTFExchange + FrayMarketResolver) ----
# Env: USDC_ADDRESS, ARBITER_ADDRESS, [OPERATOR_ADDRESS], [CTF_ADDRESS].
deploy-markets:
	$(SCRIPT) script/DeployMarkets.s.sol:DeployMarkets $(FLAGS)

dry-markets:
	$(SCRIPT) script/DeployMarkets.s.sol:DeployMarkets $(DRYFLAGS)

# ---- Agent-to-agent escrow (existing stack) ----
deploy-registry:
	$(SCRIPT) script/Deploy.s.sol $(FLAGS)

deploy-factory:
	$(SCRIPT) script/DeployFactory.s.sol $(FLAGS)

deploy-migrate:
	$(SCRIPT) script/DeployMigrate.s.sol $(FLAGS)

upgrade-registry:
	$(SCRIPT) script/UpgradeRegistry.s.sol $(FLAGS)
