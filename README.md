# Tilt Protocol — Smart Contracts

On-chain vault infrastructure for [tiltprotocol.com](https://www.tiltprotocol.com/). ERC-4626 vaults that enable anyone to create and manage decentralized hedge funds with automated rebalancing, fee management, and permissionless vault creation.

> **Status**: Testnet — deployed on Robinhood L2 (Arbitrum Orbit, Chain ID 46630).

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Contract Reference](#contract-reference)
  - [Core](#core)
  - [Interfaces](#interfaces)
  - [Oracle](#oracle)
  - [Rebalance](#rebalance)
  - [Tokens](#tokens)
- [Fee Structure](#fee-structure)
- [Deployment](#deployment)
- [Development](#development)
- [Security](#security)
- [License](#license)

---

## Overview

Tilt Protocol is an Operating System for Decentralized Hedge Funds. Anyone can create a fund, define a portfolio strategy, and accept deposits — all on-chain. The protocol is designed so that AI developers can set up trading strategies in seconds, while retail investors gain direct exposure to these strategies.

All vaults use a unified **UserVault** architecture: an ERC-4626 vault that holds a basket of ERC-20 stock tokens denominated in a single base asset (tiltUSDC). A curator (the fund manager) controls target portfolio weights with a time-lock governance mechanism. Deposits mint shares proportional to NAV; withdrawals burn shares and auto-liquidate held tokens to return the base asset.

Flagship vaults — such as politician stock-tracking indices — are simply UserVaults managed by the Tilt Protocol address, with rich metadata stored on-chain via `metadataURI`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       Frontend (UI)                         │
└──────────┬──────────────────────────────────┬───────────────┘
           │ deposit / withdraw / create      │ read state
           ▼                                  ▼
┌─────────────────────┐          ┌──────────────────────────┐
│  UserVaultFactory   │          │     VaultRegistry        │
│ (permissionless)    │          │   on-chain discovery     │
└────────┬────────────┘          └──────────────────────────┘
         │ deploys (BeaconProxy)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                     BaseVault (ERC-4626)                     │
│  ┌─────────────────────────────────────────┐                │
│  │            UserVault                     │                │
│  │   curator-managed, time-locked weights   │                │
│  └────────────────────┬────────────────────┘                │
│                       │ getTargetWeights()                  │
│                       ▼                                     │
│               Internal weights                              │
│               (curator-set, time-locked)                    │
└───────────────────────────┬─────────────────────────────────┘
                            │ rebalance / allocate
                            ▼
                 ┌─────────────────────┐
                 │   RebalanceEngine   │
                 │  trade calculation  │
                 └──────────┬──────────┘
                            │ swap
                            ▼
                 ┌─────────────────────┐
                 │    TokenRouter      │     ┌──────────────┐
                 │  price oracle +     │     │ PriceOracle  │
                 │  swap execution     │────▶│ ticker-based │
                 └─────────────────────┘     │ price lookup │
                                             └──────────────┘
                 ┌──────────────┐
                 │  FeeManager  │
                 │  fee splits  │
                 └──────────────┘
```

### Directory Layout

```
src/
├── core/
│   ├── BaseVault.sol              Abstract ERC-4626 vault base
│   ├── UserVault.sol              Curator-managed permissionless vault
│   ├── UserVaultFactory.sol       BeaconProxy factory (permissionless)
│   ├── VaultRegistry.sol          On-chain vault discovery + metadata
│   └── FeeManager.sol             Protocol + curator fee splits
├── interfaces/
│   ├── IBaseVault.sol
│   ├── IRebalanceEngine.sol
│   └── ITokenRouter.sol
├── oracle/
│   └── PriceOracle.sol            Ticker-based price lookups via TokenRouter
├── rebalance/
│   ├── RebalanceEngine.sol        Trade calculation and execution
│   └── TokenRouter.sol            Mock DEX router (testnet swap + oracle)
├── tokens/
│   └── MockStockToken.sol         Mock ERC-20 stock tokens (testnet)
└── deprecated/                    Legacy contracts (PoliticianVault, etc.)

script/
├── Deploy.s.sol                   Full protocol deployment
└── deprecated/                    Legacy deployment scripts

test/
└── TiltProtocolTest.t.sol         Protocol integration tests
```

---

## Contract Reference

### Core

#### `BaseVault`

Abstract base for all vaults. Implements ERC-4626 deposit/withdraw semantics with a multi-token portfolio under the hood.

- **Deposits**: User sends base asset → shares minted proportional to current NAV. Entry fee deducted. Funds held as `unallocatedDeposits` until allocated.
- **Withdrawals**: User burns shares → vault auto-liquidates held tokens via `_ensureBaseLiquidity()` → base asset returned. Exit fee deducted. Withdrawals are never paused.
- **NAV Calculation**: `totalAssets()` sums the base asset balance plus the USD-equivalent value of every held token (priced via `TokenRouter`).
- **Share Price**: `sharePrice()` returns the per-share NAV in 18-decimal precision.
- **Fee Accrual**: Management fees accrue continuously via share dilution. Performance fees accrue above a high-water mark. Entry/exit fees are deducted from asset flow.
- **Allocation**: `allocateIdleAssets()` buys target portfolio tokens using unallocated base asset. Permissionless — anyone can call it.
- **Rebalancing**: `rebalance()` sells over-weight tokens and buys under-weight tokens to match target allocations.
- **Dead Shares**: First 1,000 shares are minted to `address(1)` to prevent inflation attacks.
- **Emergency Withdraw**: `emergencyWithdraw()` returns pro-rata share of all held tokens directly — works even when oracle is down or vault is paused.

#### `UserVault`

Extends `BaseVault`. A curator (the vault creator) manages target weights directly with a time-lock governance mechanism.

- **Weight Changes**: Curator proposes new weights → time-lock delay → weights become effective. Prevents rug-pulls.
- **Approved Tokens**: Only tokens from a factory-managed allowlist can be held.
- **Curator Fees**: Curator earns a configurable share of management and performance fees.
- **Config Time-locks**: Critical changes (rebalance engine, token router, base asset) are time-locked to protect depositors.
- **Emergency Unpause**: Both curator and protocol admin can unpause, preventing permanent fund lock if the curator disappears.

#### `UserVaultFactory`

Deploys `UserVault` instances as `BeaconProxy` clones. Permissionless — anyone can create a vault by paying a creation fee and providing a seed deposit.

- Enforces minimum seed deposit and token allowlist.
- Curator fee capped so protocol retains minimum share.
- Registers vaults in `VaultRegistry` and authorizes on `RebalanceEngine`.
- Seeds dead shares to `address(1)` for donation attack protection.

#### `VaultRegistry`

On-chain directory of all deployed vaults. Stores vault type, curator address, metadata URI, and active status. Supports enumeration for frontend discovery and curator-indexed lookups.

- `updateVaultMetadata()` allows curators or the protocol owner to update vault metadata post-deployment.
- `updateCuratorProfile()` allows curators to set their own profile metadata.

#### `FeeManager`

Centralized fee configuration with protocol/curator revenue splits.

| Fee | Default | Max |
|---|---|---|
| Entry | 0.30% | 1.00% |
| Exit | 0.50% | 2.00% |
| Management (annualized) | 0.50% | 2.00% |
| Performance (above HWM) | 15.00% | 30.00% |
| Min Protocol Share | 20% | — |

Entry/exit fees are collected in the base asset. Management/performance fees are collected via share dilution minted to the protocol treasury and curator.

### Interfaces

| Interface | Purpose |
|---|---|
| `IBaseVault` | Vault lifecycle: `TokenWeight` struct, config getters |
| `IRebalanceEngine` | `calculateRebalance()`, `executeRebalance()`, `TradeOrder` struct |
| `ITokenRouter` | `swap()`, `getQuote()`, `getTokenPrice()`, pair support |

### Oracle

#### `PriceOracle`

Provides a ticker-symbol-based interface for reading token prices from the `TokenRouter`. Maps human-readable ticker symbols (e.g., "AAPL") to token addresses for convenient off-chain integration.

### Rebalance

#### `RebalanceEngine`

Stateless trade executor. Calculates the set of buy/sell trades needed to move a vault from current weights to target weights, then executes them through the `TokenRouter`.

- Vault-authorized: only registered vaults can call `executeRebalance()`.
- Trade orders specify `tokenIn`, `tokenOut`, `amountIn`, and `minAmountOut` for slippage protection.

#### `TokenRouter` (Mock)

Testnet swap router that executes trades at oracle prices. Stores USD prices per token (18-decimal), supports pair allowlisting, and handles decimal normalization between tokens.

In production, this will be replaced by an RFQ system or DEX aggregator.

### Tokens

#### `MockStockToken`

Simple ERC-20 with configurable name, symbol, and decimals. Minted by the deployer to represent tokenized stocks on testnet (e.g., tiltAAPL, tiltNVDA, tiltMETA).

---

## Fee Structure

```
User deposits 1,000 tiltUSDC
  └─ Entry fee: 0.30% → 3.00 tiltUSDC to FeeManager
  └─ Net deposit: 997.00 tiltUSDC → vault mints shares

Vault holds portfolio for 1 year, grows 20%
  └─ Management fee: 0.50% of AUM accrued continuously via share dilution
  └─ Performance fee: 15% of gains above high-water mark via share dilution
  └─ Fee shares split: protocol treasury (≥20%) + curator (≤80%)

User withdraws
  └─ Exit fee: 0.50% deducted from gross withdrawal
  └─ Vault auto-liquidates tokens → returns base asset
```

---

## Deployment

### Testnet (Robinhood L2)

Canonical testnet addresses for the live app are in [`bowstring-ui/src/lib/contracts.ts`](../bowstring-ui/src/lib/contracts.ts) (`ADDRESSES`). This repo’s [`deployments/robinhood-testnet.json`](./deployments/robinhood-testnet.json) holds an additional snapshot (including historical stock token address maps).

Production stock tokens use **StockTokenFactoryUpgradeable** (`ADDRESSES.STOCK_TOKEN_FACTORY`) and **TokenRouter** (`ADDRESSES.TOKEN_ROUTER`). The `MockStockTokenFactory` Solidity contract remains in-tree for **local Forge scripts and tests** only (`Deploy.s.sol`, `DeployMintBurn.s.sol`); it is not a deployed dependency for the current UI or backend.

### Deploy from scratch

```bash
cp .env.example .env
# Set PRIVATE_KEY and RPC_URL

forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Solidity 0.8.24

### Setup

```bash
git clone <repo-url>
cd tilt-contracts
forge install

# Compile
forge build

# Run tests
forge test -vvv

# Gas report
forge test --gas-report
```

### Stack

| | |
|---|---|
| Framework | Foundry |
| Solidity | 0.8.24 (optimizer: 200 runs, via-ir) |
| Dependencies | OpenZeppelin Contracts v5 |
| Target Chain | Robinhood L2 (Arbitrum Orbit, Chain ID 46630) |
| Proxy Pattern | UpgradeableBeacon + BeaconProxy |

---

## Security

### Access Control

| Role | Capabilities |
|---|---|
| Protocol Owner | Deploy factories, configure fees, pause vaults, upgrade beacons |
| Curator (UserVault) | Propose weight changes, trigger rebalance, pause/unpause |
| Vault Factory | Deploy vaults, authorize on engine, configure fees |
| RebalanceEngine | Execute trades on behalf of vaults |
| Anyone | Deposit, withdraw (never paused), call `allocateIdleAssets()`, `emergencyWithdraw()` |

### Safety Mechanisms

- **Reentrancy guards** on all state-changing vault operations.
- **Dead shares** (1,000 shares to `address(1)`) prevent first-depositor inflation attacks.
- **Withdrawal never paused** — users can always exit regardless of vault state.
- **Emergency withdraw** — returns pro-rata tokens directly, works even with broken oracle.
- **Time-lock on weight changes** prevents curator rug-pulls.
- **Time-lock on critical config** (engine, router, base asset) protects depositors.
- **Emergency unpause** — protocol admin can unpause if curator disappears.
- **Slippage protection** on all swaps with configurable tolerance.
- **Token count cap** (30 max held tokens) prevents gas DoS on enumeration.
- **High-water mark** prevents performance fee double-charging after drawdowns.
- **Ceiling-division rounding** on withdrawals protects the vault from rounding exploits.
- **One-time fee configuration** — vault fees cannot be reconfigured after initial setup.

---

## License

This project is licensed under the [Business Source License 1.1](./LICENSE). Production use requires a commercial license from Tilt Protocol. The code transitions to GPLv2+ on the change date specified in the license.
