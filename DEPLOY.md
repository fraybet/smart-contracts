# Deploying Fray contracts

All deploys are driven by the **Makefile** and signed with an **encrypted Foundry
keystore** — no plaintext private keys, ever. This replaces the old ad-hoc
`forge script … --broadcast` invocations; the process now lives in the repo.

## 1. One-time: the deployer wallet

Deploys sign with the keystore account `fray-deployer`
(`~/.foundry/keystores/fray-deployer`, AES-encrypted behind a password).

Reuse the existing deployer (`0x057d7c69311f24386700e6ef080b95319c0d6c0d`, which
deployed the A2A stack) — keeps one identity:

```sh
~/.foundry/bin/cast wallet import fray-deployer --interactive   # paste key, set password
```

…or create a fresh one:

```sh
~/.foundry/bin/cast wallet new ~/.foundry/keystores fray-deployer
```

Then fund the printed address with a little **Base ETH** for gas (~0.02–0.05 ETH
covers the markets stack).

## 2. Environment

```sh
export BASE_RPC_URL=https://…            # Base mainnet RPC (QuikNode)
export ETHERSCAN_API_KEY=…               # a Basescan key, for --verify
```

Per-deploy variables are documented in each script's NatSpec. For markets:

```sh
export USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913   # Base USDC
export ARBITER_ADDRESS=0x…               # the Fray arbiter signer (resolver authority)
export OPERATOR_ADDRESS=0x…              # optional: the off-chain matcher (operator role)
# export CTF_ADDRESS=0x…                 # optional: reuse an existing ConditionalTokens;
                                         # omit to deploy our own
```

## 3. Deploy

Dry-run first (simulates, no broadcast):

```sh
make dry-markets
```

Then broadcast + verify:

```sh
make deploy-markets
```

The script prints the deployed addresses and writes them to
`deployments/<chainid>-markets.json` (chain 8453 = Base mainnet), which the
indexer / CLI / backend read instead of hardcoding addresses.

## Targets

| Target | Deploys |
|---|---|
| `make deploy-markets` | ConditionalTokens (or reuse) + CTFExchange + FrayMarketResolver |
| `make dry-markets` | the above, simulated (no broadcast) |
| `make deploy-registry` / `deploy-factory` / `deploy-migrate` | agent-to-agent escrow stack |
| `make upgrade-registry` | UUPS upgrade of the AgentRegistry |
| `make build` / `make test` | compile / run the Foundry suite |

## Notes

- **Deploy-our-own CTF** compiles the Gnosis `ConditionalTokens` (Solidity 0.5.1)
  and deploys it via `vm.getCode`; set `CTF_ADDRESS` to skip and reuse one.
- Every deploy verifies source on Basescan (`--verify`); drop it with
  `make deploy-markets VERIFY=` if a verification backend is unavailable.
