# Bowstring Contracts

Solidity smart contracts for [bowstring.finance](https://bowstring.finance) — **Trade with unfair advantage.**

ERC-4626 vault system that mirrors politician portfolios on-chain with automated rebalancing via Chainlink oracles.

## Architecture

```
src/
├── core/
│   ├── BaseVault.sol          # Abstract ERC-4626 vault
│   ├── PoliticianVault.sol    # Oracle-driven politician tracker
│   ├── UserVault.sol          # Curator-managed permissionless vault
│   ├── VaultFactory.sol       # CREATE2 + EIP-1167 proxy deployer
│   ├── VaultRegistry.sol      # On-chain vault discovery
│   └── FeeManager.sol         # Fee splits (protocol + curator)
├── interfaces/
│   ├── IBaseVault.sol
│   ├── IPortfolioOracle.sol
│   ├── IRebalanceEngine.sol
│   └── ITokenRouter.sol
├── oracle/
│   ├── PortfolioOracle.sol    # Stores politician portfolio weights
│   └── ChainlinkAdapter.sol   # Chainlink Functions + Automation
├── rebalance/
│   ├── RebalanceEngine.sol    # Trade calculation & execution
│   └── TokenRouter.sol        # Mock DEX router (testnet)
└── tokens/
    └── MockStockToken.sol     # Mock ERC-20 stock tokens
```

## Stack

- **Framework**: Foundry (forge, cast, anvil)
- **Solidity**: ^0.8.24
- **Dependencies**: OpenZeppelin Contracts, Chainlink
- **Target Chain**: Robinhood L2 (Arbitrum Orbit, Chain ID 46630)

## Getting Started

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
forge install smartcontractkit/chainlink

# Compile
forge build

# Run tests
forge test -vvv

# Deploy to Robinhood L2 Testnet
cp .env.example .env
# Fill in your private key and RPC URL
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

## Key Concepts

- **PoliticianVault**: Reads target weights from `PortfolioOracle`, rebalanced by Chainlink Keepers
- **UserVault**: Curator sets weights manually, time-lock on changes, earns fee split
- **VaultFactory**: Permissioned (politician vaults, owner-only) + permissionless (user vaults, anyone with seed deposit)
- **FeeManager**: Entry 0.3%, exit 0.5%, management 0.5%/yr, performance 15%. Curator share configurable up to 80%

## Related Repositories

- **[bowstring-ui](https://github.com/bowstring-finance/bowstring-ui)** — Next.js frontend
- **[bowstring-backend](https://github.com/bowstring-finance/bowstring-backend)** — Oracle service & API

## License

MIT
