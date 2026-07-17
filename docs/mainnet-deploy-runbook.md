# Tilt Protocol — Mainnet Deploy Runbook (Robinhood Chain 4663)

Companion to `docs/mainnet-execution-abi.md` and the deploy scripts
`script/DeployMainnet.s.sol` / `TransferMainnetToSafe.s.sol` / `AssertMainnetOwnership.s.sol`.
Private keys for the roles below live in `bowstring-backend/.env.mainnet` (gitignored, chmod 600) — **never commit or print them**. Addresses are public and recorded here.

## Role wallets (generated fresh 2026-07-09; leaked EOA 0xd3f9Dcd6… used nowhere)

| Role | Address | Used by | Fund with ETH |
|---|---|---|---|
| DEPLOYER | `0xb0FC58cfFECA0527495c2C3e53feAE20f88a3930` | forge `DeployMainnet` (as `PRIVATE_KEY`): deploys ~10 contracts + all wiring + handover | **~0.15 ETH** (many large deploys + wiring txs; leftover recoverable) |
| OWNER (temp) | `0x5387284206D648afE82240d2E303c20dc402D022` | `SAFE_ADDRESS` placeholder / post-handover admin | **~0.03 ETH** — ⚠️ replace with a Gnosis Safe before real capital (see below) |
| RELAYER | `0x827f52D56c9D296C67C37De5Dd3a44b67a9a0459` | backend `REPORTER_PRIVATE_KEY` + `RELAYER_ADDRESS`; authorizedSigner on TradeDelegateProxyV2 | **~0.05 ETH** (ongoing per-trade gas) |
| KEEPER | `0xb01b276be5Ff2e28fFFdF619EE25C48A0B5ef7eE` | backend `KEEPER_PRIVATE_KEY`; allocateIdleAssets + limit fills + `marketOpen` calendar | **~0.05 ETH** (ongoing) |

**Pilot decision:** `SAFE_ADDRESS = OWNER` temp EOA `0x5387284206D648afE82240d2E303c20dc402D022` (single-sig, upgrade to Gnosis Safe before real capital).

L2 gas is cheap, so these are generous; any unspent ETH stays in the wallets and is recoverable. Fund via the canonical Arbitrum bridge or Across → Robinhood Chain 4663.

### ⚠️ OWNER must become a Gnosis Safe
The plan and every security review require a Gnosis Safe (≥2/3) to own all contracts and hold UUPS-upgrade authority. The generated OWNER EOA is a **temporary single-sig placeholder** so a pilot deploy can proceed. Before any real depositor capital: create a Safe on 4663, set `SAFE_ADDRESS` to it, and either deploy with it as owner or run `TransferMainnetToSafe` to it. `AssertMainnetOwnership` is the go/no-go gate that proves every contract is Safe-owned and the leaked EOA holds nothing.

## Resolved config (verified on-chain 2026-07-09 against chain 4663)

All values below live in `bowstring-backend/.env.mainnet` (keys gitignored; these addresses are public).

**Chainlink feeds** — all 8-dec, 86400 (24h) heartbeat, verified live with sane prices (AAPL $315.45, MSFT $383.32, TSLA $405.76, GOOGL $357.26, NVDA $202.65, USDG $0.9998):

| Ticker | Token (18-dec) | Feed (AggregatorV3) |
|---|---|---|
| AAPL | 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 | 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0 |
| MSFT | 0xe93237C50D904957Cf27E7B1133b510C669c2e74 | 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E |
| TSLA | 0x322F0929c4625eD5bAd873c95208D54E1c003b2d | 0x4A1166a659A55625345e9515b32adECea5547C38 |
| GOOGL | 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3 | 0xF6f373a037c30F0e5010d854385cA89185AE638b |
| NVDA | 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC | 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 |
| USDG (base) | 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (6-dec) | 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2 |

**0x settlement target** (`allowedSettlementTargets`): AllowanceHolder `0x0000000000001fF3684f28c67538d4D072C22734` — **verified deployed + verified on 4663** (Cancun canonical). Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`.

**0x API key status (verified live 2026-07-17):** key in `.env.mainnet` (`ZEROX_API_KEY`) is valid and chain 4663 is enabled for it — USDG→WETH `/price` + `/quote` return 200 with routes (Uniswap V3/V4). **BLOCKER: the Robinhood stock tokens are NOT yet authorized for this key** — AAPL/MSFT, both directions, return 422 `BUY/SELL_TOKEN_NOT_AUTHORIZED_FOR_TRADE` ("legal restrictions"), i.e. 0x's tokenized-equities entitlement has not been granted to our account. Request it from 0x (and/or Tokka Labs, the RFQ MM) citing trace zids `0x288b203bdfc57521cdfcddf2` (AAPL buy), `0x9cd605a235bd35fa7f32cd6f` (AAPL sell), `0xe631aeaf3d98047e59342b3c` (MSFT buy). Until granted, no stock-token quotes → no pilot trading. The settlement path itself is proven: `test/mainnet-fork/Fork0xReplay.t.sol` (run `script/fork-0x-replay.sh`) replays a live firm quote through TradeDelegateProxyV2 → engine → AllowanceHolder on a 4663 fork — green 2026-07-17 (taker=vault semantics, balance-delta verification, oracle floor, residual sweep). Re-run it with `REPLAY_BUY_TOKEN=<AAPL>` the day the entitlement lands.

**Contract size (verified 2026-07-17):** chain 4663 accepts contracts above the 24,576-byte EIP-170 limit (eth_call CREATE of the 26,682-byte UserVault runtime succeeds against the live node, same as testnet) — forge's `UserVault is above the contract size limit` warning during the deploy simulation is expected and harmless. The full `DeployMainnet` fork simulation is green (~0.005 ETH estimated).

**Launch token set (pilot):** AAPL, MSFT, TSLA, GOOGL, NVDA (each has a verified feed). Seed `data/mainnet-tokens.json` + `approvedTokens` + engine `allowedTokens`.

`marketOpen` starts **false** — flip on (owner/keeper) only during the trading calendar after feeds verify fresh.

## Still unresolved — could not find (non-blocking for pilot)

- **Uniswap router / AMM routes** (`AMM_ROUTER`, `<SYMBOL>_AMM_ROUTE`) — Uniswap is confirmed live on 4663 (WETH pools exist) but the UniversalRouter/SwapRouter address is **not published** in Uniswap docs, the blog, or the deployments GitHub yet. Impact: user `withdraw()/redeem()` that must sell tokens revert `NoRoute` — exits are **buffer + in-kind `emergencyWithdraw`** only. Acceptable for a pilot where managers keep a USDG buffer. Add later via `engine.setAmmRouter`/`setAmmRoute` once the address is known (from the Uniswap dashboard / your Uniswap contact / a verified pool's on-chain lookup). `AssertMainnetOwnership` reports AMM-route as a warning, not a gate.
- **Sequencer uptime feed** (`SEQUENCER_UPTIME_FEED`) — **not in Chainlink's Robinhood feed directory**; no L2 sequencer feed published for 4663 yet. Left unset → engine skips the check, backend logs a boot warning. Set before scaling past the pilot.

## Deploy sequence (once funded + config resolved)

1. Fund the 4 wallets (above).
2. Resolve every checklist item; export into the forge deploy env (deployer = `PRIVATE_KEY`, `SAFE_ADDRESS`, `RELAYER_ADDRESS`, feeds, settler, AMM, sequencer).
3. `forge script DeployMainnet --rpc-url robinhood_mainnet --broadcast` — deploys + wires + post-checks (hard requires: RouterDrift, beacon-owned-by-factory, proxy-is-engine-relayer).
4. Populate `deployments/robinhood-mainnet.json` from the script's printed block + the backend env (`EXECUTION_ENGINE`, `VAULT_REGISTRY`, `VAULT_FACTORY`, `TRADE_DELEGATE_PROXY`, `CHAINLINK_ORACLE`, USDG).
5. `TransferMainnetToSafe` (once the Safe exists) → `AssertMainnetOwnership` must exit 0 (owner==Safe everywhere, leaked EOA nowhere, proxy-relayer set, per-token AMM-route liveness reported).
6. Smoke test: small USDG deposit + a $10 AAPL market buy end-to-end; reconcile the fill vs Blockscout + Chainlink before opening to any manager.

## Backend runtime env (mainnet Railway service)
From `.env.mainnet`: `CHAIN_ENV=mainnet`, `REPORTER_PRIVATE_KEY`, `KEEPER_PRIVATE_KEY`, plus (post-deploy) `EXECUTION_ENGINE`, `TRADE_DELEGATE_PROXY`, `VAULT_REGISTRY`, `VAULT_FACTORY`, `CHAINLINK_ORACLE`, `USDG_ADDRESS`, `SEQUENCER_UPTIME_FEED`, `ZEROX_API_KEY`, `RPC_URL` (Alchemy 4663), a **separate mainnet Upstash Redis**, `MAX_PRICE_DEVIATION_BPS=100`, `DEFAULT_SLIPPAGE_BPS=50`. Absent by design: any ORACLE / FAUCET / DEPLOYER / price-source key.
