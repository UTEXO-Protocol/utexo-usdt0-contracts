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

1. The user calls `UtexoSourceEntrypoint.deposit()` on the source chain, paying the LayerZero native fee. The caller supplies a `bytes payload` shaped as `abi.encode(string destinationChain, string destinationAddress, uint256 operationId)`.
2. The entrypoint decodes `payload` on the source chain (a malformed blob reverts here, before any LZ fee is paid), then re-encodes the actual `composeMsg` as `abi.encode(block.chainid, destinationChain, destinationAddress, operationId)` and forwards the tokens into the USDT0 OFT via `OFT.send()`. The `sourceChainId` half is captured from `block.chainid` and is therefore non-spoofable by the caller.
3. LayerZero delivers the tokens to Arbitrum and triggers `UtexoLZAdapter.lzCompose()`.
4. `UtexoLZAdapter` calls the adapter-only overload of `Bridge.fundsIn()` on Arbitrum, threading `sourceChainId` through for commission routing and locking the funds. If `Bridge.fundsIn` reverts (paused, duplicate `operationId`, native-value mismatch, …) the inbound payload is parked on the adapter and recoverable via federation governance — see [Stuck funds](#stuck-funds).

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

### `UtexoLZAdapter` (`ethereum/src/UtexoLZAdapter.sol`)

Deployed once on Arbitrum. Non-upgradeable — all five participating addresses (`endpoint`, `oft`, `token`, `bridge`, `multisigProxy`) are immutable. To repoint any of them the adapter must be redeployed and the reference rotated through `MultisigProxy` federation governance.

Two flows:

- **Inbound (`lzCompose`)** — invoked by the LayerZero endpoint when a USDT0 OFT message addressed to the adapter arrives on Arbitrum. The adapter approves the `Bridge` and forwards the deposit into `Bridge.fundsIn`. The call is wrapped in `try/catch`: on revert the funds are stored on the adapter and a `ComposeFundsInFailed` event is emitted (see [Stuck funds](#stuck-funds)). The adapter's outer call always returns successfully so the LayerZero endpoint clears its compose queue.
- **Outbound (`sendOut`)** — restricted to `MultisigProxy`. Called from a TEE-signed `executeBatch` immediately after `Bridge.fundsOut(recipient = adapter)`. Re-quotes the LayerZero fee on-chain; any surplus `msg.value` is refunded to `tx.origin` (the backend relayer EOA that submitted the batch — `MultisigProxy` has no `receive()` and would reject a refund).

#### Stuck funds

When `Bridge.fundsIn` reverts inside `lzCompose`, the parked payload is recorded under `_stuckFunds[guid]`:

| Field | Description |
|---|---|
| `amountLD` | USDT0 minted onto the adapter by the OFT |
| `nativeValue` | Native (wei) the LayerZero Executor forwarded into `lzCompose` (non-zero for NATIVE-currency commission routes, 0 for TOKEN routes) |
| `sourceChainId` | EVM `block.chainid` of the source chain, captured by `UtexoSourceEntrypoint` at deposit time |
| `operationId`, `destinationChain`, `destinationAddress` | Business fields copied from the decoded `composeMsg` for off-chain diagnostics |

Read a record via `getStuckFunds(guid) returns (StuckFunds memory)`. `amountLD == 0` means "no record".

Release path — `refundStuckFunds(bytes32 guid, address recipient)`:

- Callable only by `multisigProxy` (federation governance gates this on its M-of-N timelock flow).
- Transfers `amountLD` USDT0 and any `nativeValue` to `recipient`, deletes the stored record, emits `StuckFundsRefunded`.
- Atomic: a failing native transfer reverts the entire call, so the record stays recoverable.

There is no on-chain retry — by the time `Bridge.fundsIn` reverts the inbound parameters are user-supplied and re-issuing the same call would deterministically fail again. The federation refunds out to a custodian address; the Utexo backend reimburses the original user off-chain from that custodian.

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
