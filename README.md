# Tilt Protocol — Smart Contracts

On-chain vault infrastructure for [tiltprotocol.com](https://www.tiltprotocol.com/). ERC-4626 vaults that mirror politician stock portfolios with automated rebalancing, fee management, and permissionless vault creation.

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

Tilt is a vault protocol that lets anyone invest in portfolios that track the stock trades of U.S. politicians. Public disclosure filings are ingested off-chain, written to an on-chain oracle, and vaults automatically rebalance to match the latest positions.

The protocol supports two vault types:

| | Politician Vault | User Vault |
|---|---|---|
| **Weight source** | `PortfolioOracle` (Chainlink-fed) | Curator-managed |
| **Creation** | Permissioned (protocol owner) | Permissionless (anyone with seed deposit) |
| **Rebalancing** | Automatic via Chainlink Keepers | Curator-triggered with time-lock |
| **Fee split** | 100% protocol | Configurable curator share (up to 80%) |

All vaults share the same base: an abstract ERC-4626 vault that holds a basket of ERC-20 stock tokens denominated in a single base asset (tiltUSDC). Deposits mint shares proportional to NAV; withdrawals burn shares and auto-liquidate held tokens to return the base asset.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       Frontend (UI)                         │
└──────────┬──────────────────────────────────┬───────────────┘
           │ deposit / withdraw / create      │ read state
           ▼                                  ▼
┌─────────────────────┐          ┌──────────────────────────┐
│   VaultFactory(s)   │          │     VaultRegistry        │
│  Politician / User  │          │   on-chain discovery     │
└────────┬────────────┘          └──────────────────────────┘
         │ deploys (BeaconProxy)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                     BaseVault (ERC-4626)                     │
│  ┌─────────────────┐  ┌──────────────────┐                  │
│  │ PoliticianVault │  │    UserVault      │                  │
│  │ (oracle-driven) │  │ (curator-managed) │                  │
│  └────────┬────────┘  └────────┬─────────┘                  │
│           │ getTargetWeights() │                             │
│           ▼                    ▼                             │
│  ┌─────────────────┐  ┌──────────────────┐                  │
│  │ PortfolioOracle │  │ Internal weights │                  │
│  └─────────────────┘  └──────────────────┘                  │
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
                 │    TokenRouter      │
                 │  price oracle +     │
                 │  swap execution     │
                 └─────────────────────┘

        ┌──────────────┐    ┌───────────────────┐
        │  FeeManager  │    │ ChainlinkAdapter  │
        │  fee splits  │    │ oracle automation │
        └──────────────┘    └───────────────────┘
```

### Directory Layout

```
src/
├── core/
│   ├── BaseVault.sol              Abstract ERC-4626 vault base
│   ├── PoliticianVault.sol        Oracle-driven politician tracker
│   ├── UserVault.sol              Curator-managed permissionless vault
│   ├── PoliticianVaultFactory.sol BeaconProxy factory (permissioned)
│   ├── UserVaultFactory.sol       BeaconProxy factory (permissionless)
│   ├── VaultFactory.sol           Legacy CREATE2 + EIP-1167 factory
│   ├── VaultRegistry.sol          On-chain vault discovery
│   └── FeeManager.sol             Protocol + curator fee splits
├── interfaces/
│   ├── IBaseVault.sol
│   ├── IPortfolioOracle.sol
│   ├── IRebalanceEngine.sol
│   └── ITokenRouter.sol
├── oracle/
│   ├── PortfolioOracle.sol        Stores politician portfolio weights
│   └── ChainlinkAdapter.sol       Chainlink Functions + Automation bridge
├── rebalance/
│   ├── RebalanceEngine.sol        Trade calculation and execution
│   └── TokenRouter.sol            Mock DEX router (testnet swap + oracle)
└── tokens/
    └── MockStockToken.sol         Mock ERC-20 stock tokens (testnet)

script/
├── Deploy.s.sol                   Full protocol deployment
├── DeployNewVaults.s.sol          Deploy new vaults with BeaconProxy
├── UpgradeEngine.s.sol            Upgrade RebalanceEngine
└── UpgradeFactory.s.sol           Upgrade VaultFactory

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

#### `PoliticianVault`

Extends `BaseVault`. Target weights are sourced from `PortfolioOracle`. When the oracle publishes updated politician filings, the vault's target weights update automatically and rebalancing brings holdings in line.

- Rebalancing is restricted to the `rebalanceEngine` or vault owner.
- Configurable `minRebalanceInterval` prevents excessive rebalancing.

#### `UserVault`

Extends `BaseVault`. A curator (the vault creator) manages target weights directly with a time-lock governance mechanism.

- **Weight Changes**: Curator proposes new weights → time-lock delay → weights become effective. Prevents rug-pulls.
- **Approved Tokens**: Only tokens from a factory-managed allowlist can be held.
- **Curator Fees**: Curator earns a configurable share of management and performance fees.

#### `PoliticianVaultFactory`

Deploys `PoliticianVault` instances as `BeaconProxy` clones. Owner-only. Automatically:
- Registers vaults in `VaultRegistry`
- Configures fees via `FeeManager`
- Authorizes vaults on `RebalanceEngine`
- Seeds initial liquidity with dead shares

#### `UserVaultFactory`

Deploys `UserVault` instances as `BeaconProxy` clones. Permissionless — anyone can create a vault by paying a creation fee and providing a seed deposit.

- Enforces minimum seed deposit and token allowlist.
- Curator fee capped so protocol retains minimum share.
- Registers vaults in `VaultRegistry` and authorizes on `RebalanceEngine`.

#### `VaultRegistry`

On-chain directory of all deployed vaults. Stores vault type (politician/user), creator address, metadata URI, and active status. Supports enumeration for frontend discovery.

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
| `IPortfolioOracle` | `getPortfolio(politicianId)` → token/weight arrays |
| `IRebalanceEngine` | `calculateRebalance()`, `executeRebalance()`, `TradeOrder` struct |
| `ITokenRouter` | `swap()`, `getQuote()`, `getTokenPrice()`, pair support |

### Oracle

#### `PortfolioOracle`

Stores politician portfolio allocations as `(token, weightBps)` arrays. Updated by authorized reporters (backend service via Chainlink or direct write). Each update is timestamped for freshness checks.

#### `ChainlinkAdapter`

Bridges Chainlink Functions (off-chain API calls for filing data) and Chainlink Automation (periodic triggers) to the `PortfolioOracle`. Handles request/response lifecycle and error recovery.

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

Current deployment addresses are in [`deployments/robinhood-testnet.json`](./deployments/robinhood-testnet.json).

| Contract | Address |
|---|---|
| TiltUSDC | `0x941A382852E989078e15b381f921C488a7Ca5299` |
| FeeManager | `0x63D367C9A34d94aBD4D2cD0921Dd0F4252E8548A` |
| VaultRegistry | `0x38485146d0D1E0c700ddBf61206188CFaC170795` |
| PortfolioOracle | `0x1a105C43e70Dee39Fa33841d1846C2c2620c9DE4` |
| MockTokenRouter | `0x18e66aA8C28cA21eEA724B75E01F56Cc3e293Ba8` |
| RebalanceEngine | `0xAfe9CA99AB3CFa2523553E25743eA1463ae35eF2` |
| PoliticianVaultFactory | `0x2505fccc8CE6BAb9f3b4DF4671958CE5CB8154a9` |

Plus 6 politician vaults, 1 user vault factory, and 100+ mock stock tokens.

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
# Clone and install dependencies
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
| Dependencies | OpenZeppelin Contracts v5, Chainlink |
| Target Chain | Robinhood L2 (Arbitrum Orbit, Chain ID 46630) |
| Proxy Pattern | UpgradeableBeacon + BeaconProxy |

---

## Security

### Access Control

| Role | Capabilities |
|---|---|
| Protocol Owner | Deploy factories, configure fees, pause vaults, upgrade beacons |
| Curator (UserVault) | Propose weight changes, trigger rebalance |
| Vault Factory | Deploy vaults, authorize on engine, configure fees |
| RebalanceEngine | Execute trades on behalf of vaults |
| Anyone | Deposit, withdraw (never paused), call `allocateIdleAssets()` |

### Safety Mechanisms

- **Reentrancy guards** on all state-changing vault operations.
- **Dead shares** (1,000 shares to `address(1)`) prevent first-depositor inflation attacks.
- **Withdrawal never paused** — users can always exit regardless of vault state.
- **Time-lock on weight changes** in UserVault prevents curator rug-pulls.
- **Slippage protection** on all swaps with configurable tolerance.
- **Token count cap** (30 max held tokens) prevents gas DoS on enumeration.
- **High-water mark** prevents performance fee double-charging after drawdowns.
- **Ceiling-division rounding** on withdrawals protects the vault from rounding exploits.

---

## License

This project is licensed under the [Business Source License 1.1](./LICENSE). Production use requires a commercial license from Tilt Protocol. The code transitions to GPLv2+ on the change date specified in the license.
