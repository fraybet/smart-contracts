# Vendor Report — `src/markets/`

Minimal fork of two audited, custody-critical Polymarket contract sets vendored into this Foundry repo. Goal: `forge build` green with the production contracts compiled, with the audited code kept byte-identical except for the three allowed edit categories listed below.

## Upstream repos + commits

Source trees were cloned (read-only reference) at `/tmp/fray-vendor/`:

| Set | Upstream | Notes |
| --- | --- | --- |
| CTF-Exchange | Polymarket `ctf-exchange` | original pragma `0.8.15` |
| UMA CTF adapter | Polymarket `uma-ctf-adapter` | original pragma `0.8.15` |

(Exact upstream commit hashes were not recorded in the clone; the clones were provided pre-checked-out. The copied source is reproduced verbatim except for the documented edits.)

## Dependency pins added (git submodules under `lib/`)

| Submodule path | URL | Commit |
| --- | --- | --- |
| `lib/openzeppelin-contracts-v4` | https://github.com/openzeppelin/openzeppelin-contracts | `8769b19860863ed14e82ac78eb0d09449a49290b` (v4.4.1-333) |
| `lib/solmate` | https://github.com/transmissions11/solmate | `bff24e835192470ed38bf15dbed6084c2d723ace` |
| `lib/solady` | https://github.com/vectorized/solady | `acd959aa4bd04720d640bf4e6a5c71037510cc4b` (v0.1.26) |

OZ v4 is required because the exchange imports `utils/cryptography/draft-EIP712.sol`, which does not exist in the repo's existing OZ v5 submodule (`lib/openzeppelin-contracts`). The existing v5 submodule and the `@openzeppelin/contracts/` remapping used by `src/custom/` were left untouched.

## Remappings appended to `remappings.txt`

Existing two lines unchanged. Appended:

```
openzeppelin-contracts/=lib/openzeppelin-contracts-v4/contracts/
openzeppelin/=lib/openzeppelin-contracts-v4/contracts/
solmate/=lib/solmate/src/
solady/=lib/solady/src/
common/=src/markets/common/
```

The markets fork routes `openzeppelin-contracts/` and `openzeppelin/` to OZ **v4**; the existing `@openzeppelin/contracts/` (v5) prefix is unchanged.

## Files copied (52 total)

Production contracts only — `test/`, `scripts/`, `dev/` excluded.

### `src/markets/exchange/` (from `ctf-exchange/src/exchange/`, minus `test/` and `scripts/`)
BaseExchange.sol, CTFExchange.sol, mixins/{AssetOperations, Assets, Auth, Fees, Hashing, NonceManager, Pausable, PolyFactoryHelper, Registry, Signatures, Trading}.sol, libraries/{CalculatorHelper, OrderStructs, PolyProxyLib, PolySafeLib, TransferHelper}.sol, interfaces/{IAssetOperations, IAssets, IAuth, IConditionalTokens, IFees, IHashing, INonceManager, IPausable, IRegistry, ISignatures, ITrading}.sol

### `src/markets/common/` (from `ctf-exchange/src/common/`)
ERC20.sol, ReentrancyGuard.sol, auth/{Authorized, Ownable, Owned}.sol, auth/interfaces/{IAuthorized, IOwned}.sol, interfaces/IERC20.sol, libraries/SafeTransferLib.sol

### `src/markets/uma/` (from `uma-ctf-adapter/src/`, selected)
UmaCtfAdapter.sol, interfaces/{IAddressWhitelist, IAuth, IBulletinBoard, IConditionalTokens, IFinder, IOptimisticOracleV2, IOptimisticRequester, IUmaCtfAdapter}.sol, libraries/{AncillaryDataLib, PayoutHelperLib, TransferHelper}.sol, mixins/{Auth, BulletinBoard}.sol

## Complete list of edits made

### 1. Pragma bumps (`pragma solidity 0.8.15;` → `pragma solidity 0.8.24;`) — 13 files
Required because the repo pins `solc_version = "0.8.24"`. Only files carrying the **exact literal pin** `0.8.15` were changed. Floating pragmas already present in some copied files (`^0.8.15`, `^0.8.10`, `>=0.8.0`, `<0.9.0`) are all satisfied by 0.8.24 and were left untouched (minimal-edit principle).

Files bumped:
- `exchange/CTFExchange.sol`
- `uma/UmaCtfAdapter.sol`
- `uma/interfaces/{IAddressWhitelist, IBulletinBoard, IConditionalTokens, IFinder, IOptimisticOracleV2, IOptimisticRequester}.sol`
- `uma/libraries/{AncillaryDataLib, PayoutHelperLib, TransferHelper}.sol`
- `uma/mixins/{Auth, BulletinBoard}.sol`

### 2. Import-path normalization — 5 imports across 5 files (UMA adapter only)
The exchange + common files used remapping-style imports (`common/`, `openzeppelin-contracts/`, `solmate/`, `solady/`) that all resolve under the added remappings, so **no exchange/common import was rewritten**. Only the UMA adapter used literal `lib/...` / `src/...` paths. Each rewrite changes path syntax only — never which file is imported.

| File | Before | After |
| --- | --- | --- |
| `uma/UmaCtfAdapter.sol` | `lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol` | `openzeppelin-contracts/token/ERC20/IERC20.sol` |
| `uma/interfaces/IConditionalTokens.sol` | `lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol` | `openzeppelin-contracts/token/ERC20/IERC20.sol` |
| `uma/interfaces/IOptimisticOracleV2.sol` | `lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol` | `openzeppelin-contracts/token/ERC20/IERC20.sol` |
| `uma/libraries/TransferHelper.sol` | `lib/solmate/src/utils/SafeTransferLib.sol` | `solmate/utils/SafeTransferLib.sol` |
| `uma/mixins/BulletinBoard.sol` | `src/interfaces/IBulletinBoard.sol` | `../interfaces/IBulletinBoard.sol` |

### 3. EIP-712 domain rename — 1 file (sole intentional behavioral change)
`exchange/CTFExchange.sol`: constructor base `Hashing("Polymarket CTF Exchange", "1")` → `Hashing("Fray CTF Exchange", "1")`. Version string `"1"` unchanged.

## Edits NOT made
No validation, signature-verification, transfer, fee, matching, or settlement logic was altered. PolyProxy/PolySafe/PolyFactoryHelper and all signature types were kept. `foundry.toml`, the existing OZ v5 submodule, and `src/custom/` were not modified.

## Build status
`forge build` → **Compiler run successful!** Zero compile errors. Both `out/CTFExchange.sol/CTFExchange.json` and `out/UmaCtfAdapter.sol/UmaCtfAdapter.json` produced. Remaining output is lint warnings only (`block-timestamp`, `erc20-unchecked-transfer`), pre-existing in the upstream audited code and also present in existing `src/custom/` files.

## STOP conditions hit
None. Green build reached using only the three allowed edit categories.
