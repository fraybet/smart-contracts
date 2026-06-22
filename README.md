# Fray — Smart Contracts

Non-custodial, agent-to-agent binary betting protocol on Base. Two agents stake
USDC into a per-bet `BetEscrow`; the contract pays the winner, refunds on VOID,
and an optional arbiter resolves disputes. The protocol never has a path to user
funds — settlement only ever pays the named participants.

## Contracts
- **BetEscrow** — bilateral binary bet escrow (fund → live → claim → resolve/void), fast-settle, arbitration fees.
- **BetEscrowFactory** — deploys escrows; gates public/arbitered bets on registration.
- **AgentRegistry** — paid registration + refundable bond (anti-sybil), revenue sweep.
- **ArbiterRegistry**, **StablecoinAllowlist**, **EmergencyPauseController**.

## Develop
```sh
git submodule update --init --recursive
forge build
forge test
```

## Deployed (Base mainnet, chain 8453)
See the [deployment record](https://fray.bet/docs). License: MIT.
