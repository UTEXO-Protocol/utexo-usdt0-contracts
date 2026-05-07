# Utexo USDT0 Contracts

Smart contracts for the USDT0/LayerZero integration layer of the Utexo bridge. This repository covers the **source-chain side** of cross-chain deposits: user-facing entrypoints that accept USDT (or USDT0) on chains such as Ethereum, OP, and Base, and forward them to Arbitrum via the USDT0 OFT and LayerZero V2.

The Arbitrum hub contracts (Bridge, CommissionManager, MultisigProxy, BtcRelay) live in a separate repository, included here as a git submodule at `lib/utexo-smart-contracts`.

## Repository structure

```
ethereum/   — EVM contracts (Solidity, Foundry)
lib/
  utexo-smart-contracts/   — core bridge repo (git submodule)
```

## Architecture

```
  Source chain (Ethereum / OP / Base / …)
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   User ──► UtexoSourceEntrypoint ──► USDT0 OFT               │
  │                                           │                  │
  └───────────────────────────────────────────┼──────────────────┘
                                              │ LayerZero V2
                                              ▼
  Arbitrum
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   UtexoLZAdapter ──► Bridge ◀── MultisigProxy (TEE + Fed)    │
  │                          │                                   │
  │                   CommissionManager                          │
  │                          ▲                                   │
  │                       BtcRelay                               │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```

### Flow

1. The user calls `UtexoSourceEntrypoint.deposit()` on the source chain, paying the LayerZero native fee.
2. The entrypoint pulls the user's tokens and forwards them into the USDT0 OFT via `OFT.send()`, attaching a `composeMsg` produced by the Utexo backend.
3. LayerZero delivers the tokens to Arbitrum and triggers `UtexoLZAdapter.lzCompose()`.
4. `UtexoLZAdapter` calls `Bridge.fundsIn()` on Arbitrum, locking the funds. The Utexo backend then initiates the RGB-side release.

## Contracts

### `UtexoSourceEntrypoint` (`ethereum/src/UtexoSourceEntrypoint.sol`)

Deployed once per source chain. Stateless, non-upgradeable — all routing parameters are immutable:

| Immutable | Description |
|---|---|
| `token` | ERC-20 pulled from the user (canonical USDT on Ethereum; USDT0 on other chains) |
| `oft` | USDT0 OFT (adapter or native) on this source chain |
| `dstEid` | LayerZero endpoint id of the destination chain (Arbitrum = 30110) |
| `lzAdapter` | `UtexoLZAdapter` address on the destination chain, encoded as `bytes32` |

Key properties:
- Re-quotes the LayerZero fee on-chain — protects against stale off-chain quotes.
- Surplus `msg.value` is refunded to the caller.
- No owner, no pause, no admin functions. Upgrade = redeploy.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge + cast)
- Git

## Setup

```sh
# Clone with submodules
git clone --recurse-submodules https://github.com/UTEXO-Protocol/utexo-usdt0-contracts.git
cd utexo-usdt0-contracts

# Install Foundry dependencies
cd ethereum && forge install
```

If you already cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

## Commands

```sh
cd ethereum

forge build                                                          # compile
forge test                                                           # run all tests
forge test --match-path "test/UtexoSourceEntrypoint.t.sol" -vvv    # run one file with traces
forge coverage                                                        # coverage report
forge clean                                                           # delete out/ + cache/
```

## Deployment

Copy `.env.example` to `.env` and fill in the values:

| Variable | Description |
|---|---|
| `RPC_URL` | RPC endpoint of the source chain |
| `PRIVATE_KEY` | Deployer private key |
| `TOKEN_ADDRESS` | ERC-20 to pull from users |
| `OFT_ADDRESS` | USDT0 OFT on this source chain |
| `DST_EID` | LayerZero endpoint id of destination (Arbitrum = 30110) |
| `LZ_ADAPTER` | `UtexoLZAdapter` address on destination, left-padded to `bytes32` |

```sh
forge script script/deploy/DeployUtexoSourceEntrypoint.s.sol \
  --rpc-url $RPC_URL --broadcast --verify
```

The contract is stateless — no ownership transfer is needed after deployment.

## Post-deployment checklist

1. Verify immutables: `token`, `oft`, `dstEid`, `lzAdapter` match expected values.
2. Call `quote(params)` to confirm the OFT is reachable and returns a non-zero fee.
3. Do a test `deposit()` with a small amount on testnet to confirm token flow and event emission.
