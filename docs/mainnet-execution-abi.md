# Mainnet Execution ABI Spec (Robinhood Chain 4663)

**Status: DRAFT v0.1 — freeze before Phase 1 implementation begins.** Once frozen, changes require sign-off from both the contracts and backend owners, because three backend consumers parse these ABIs byte-for-byte.

Source plan: `docs/superpowers/plans/2026-07-08-mainnet-migration.md` (workspace root).

## Why this file exists

The mainnet migration replaces `TokenRouterUpgradeable` + `RebalanceEngineUpgradeable` with `ChainlinkPriceRouter` + `MainnetExecutionEngine`. The backend's fill recording (`bowstring-backend/src/swap-fill.ts`), activity indexer (`src/vault-activity-indexer.ts`), and position backfill (`agent-api.ts` backfill-positions) all parse the router's `Swap` event today. The new engine MUST emit the identical event so those consumers need only an address change. This file is the single source of truth for that contract.

## 1. `Swap` event (FROZEN — identical to `src/interfaces/ITokenRouter.sol:7`)

```solidity
event Swap(
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    address indexed recipient   // always the vault
);
```

Topic layout the indexer depends on (`vault-activity-indexer.ts:141-146`):
`topics = [sig, tokenIn, tokenOut, recipient]`, `data = (amountIn, amountOut)`.

Emitted by `MainnetExecutionEngine` exactly once per executed `TradeOrder`, after settlement verification, with `recipient = vault`. `amountOut` is the **verified vault balance delta**, not the 0x-quoted amount.

## 2. `MainnetExecutionEngine` — vault-facing surface (must match `IRebalanceEngine`)

```solidity
struct TradeOrder {            // unchanged from src/interfaces/IRebalanceEngine.sol:9
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
}

function executeRebalance(address vault, TradeOrder[] calldata trades) external;
// invariant preserved: require(msg.sender == vault && authorizedVaults[vault])
function tokenRouter() external view returns (address);
// required by UserVaultFactoryV2._createVault RouterDrift check (UserVaultFactoryV2.sol:223);
// returns the ChainlinkPriceRouter address

event RebalanceExecuted(address indexed vault, TradeOrder[] trades); // unchanged
```

Relayer-facing (new):

```solidity
function stageSettlement(
    address vault,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address target,            // must be in allowedSettlementTargets (0x Settler/AllowanceHolder)
    bytes calldata data        // 0x Swap API v2 transaction.data
) external;                    // onlyRelayer; consumable only in the same tx
```

Enforcement inside `executeRebalance` (see plan §A.2): `allowedTokens` on tokenOut for buys (sells always allowed), oracle-anchored minOut floor `max(order.minAmountOut, chainlinkQuote × (1 − maxSlippageBps))`, vault balance-delta verification, per-vault daily notional cap.

## 3. `TradeDelegateProxyV2` — relayer entrypoint

Existing method kept byte-identical to `src/core/TradeDelegateProxy.sol:40` (used for AMM-fallback trades with no staged calldata):

```solidity
function executeTrade(address vault, address tokenIn, address tokenOut,
                      uint256 amountIn, uint256 minAmountOut) external; // onlySigner
```

New method (stages + executes atomically in one tx, so 0x quote expiry cannot bite between steps):

```solidity
function executeTradeWithSettlement(
    address vault,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,      // from 0x quote.minBuyAmount; engine may raise via oracle floor
    address target,
    bytes calldata swapData
) external;                    // onlySigner: stageSettlement(...) then IUserVaultTrade(vault).executeTrade(...)
```

`UserVault.executeTrade(tokenIn, tokenOut, amountIn, minAmountOut)` (UserVault.sol:319) is unchanged.

## 4. `ChainlinkPriceRouter` — view surface consumed by vaults + backend

Implements the `ITokenRouter` views so `BaseVault` needs no interface change:

```solidity
function getTokenPrice(address token) external view returns (uint256); // 18-dec USD; 0 only past hard cap
function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
function isPairSupported(address tokenA, address tokenB) external view returns (bool);
function swap(address, address, uint256, uint256, address) external returns (uint256); // always reverts SwapDisabled()

// new gating surface, capability-probed by BaseVault._deposit (try/catch)
function depositsOpen() external view returns (bool);

// backend-compat shims (PriceOracleUpgradeable redeploys unmodified)
function tokenPrices(address token) external view returns (uint256);
function tokenBySymbol(string calldata symbol) external view returns (address);
```

## 5. Backend consumers bound to this spec

| Consumer | What it parses | Change needed on mainnet |
|---|---|---|
| `bowstring-backend/src/swap-fill.ts:4` | `Swap` event ABI string | none (address via chain-config) |
| `bowstring-backend/src/vault-activity-indexer.ts:141-176` | `Swap` topics + Deposit/Withdraw | engine address via chain-config |
| `bowstring-backend/src/agent-api.ts` backfill-positions | `Swap` via explorer API | explorer base + address via chain-config |
| `bowstring-backend/src/trading-api.ts` (mainnet branch) | calls `executeTradeWithSettlement` | new code path per plan §B |

## Open items before freeze

- [ ] Confirm 0x Settler vs AllowanceHolder as the `target` on chain 4663 (pull one live `/quote` and inspect `transaction.to` + `issues.allowance`).
- [ ] Decide whether `executeTradesBatch` gets a settlement-aware variant (v1: not needed; one order = one tx).
- [ ] Confirm the Chainlink L2 Sequencer Uptime Feed address on 4663 (or omit the check if the feed doesn't exist there).
- [ ] Sign-off: contracts owner ☐ · backend owner ☐
