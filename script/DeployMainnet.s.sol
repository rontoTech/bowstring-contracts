// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {FeeManagerUpgradeable} from "../src/core/FeeManagerUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../src/core/VaultRegistryUpgradeable.sol";
import {ChainlinkPriceRouter} from "../src/mainnet/ChainlinkPriceRouter.sol";
import {MainnetExecutionEngine} from "../src/mainnet/MainnetExecutionEngine.sol";
import {TradeDelegateProxyV2} from "../src/mainnet/TradeDelegateProxyV2.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {PriceOracleUpgradeable} from "../src/oracle/PriceOracleUpgradeable.sol";
import {AgentRegistry} from "../src/agents/AgentRegistry.sol";

/// @title DeployMainnet
/// @notice Fresh full-stack deploy for Robinhood Chain mainnet (chain 4663).
///         Mirrors DeployUpgradeable's proxy idiom (impl + ERC1967Proxy +
///         initialize, console.log + require post-checks) but wires the mainnet
///         pricing/execution contracts (ChainlinkPriceRouter + MainnetExecutionEngine
///         + TradeDelegateProxyV2) against real USDG rather than the mint/burn
///         testnet router.
///
///   The deployer holds ownership through this script ONLY. Ownership is handed
///   to the Gnosis Safe by `TransferMainnetToSafe.s.sol` afterwards, verified by
///   `AssertMainnetOwnership.s.sol`. Nothing here is broadcast automatically —
///   run with `--rpc-url robinhood_mainnet` and add `--broadcast` deliberately.
///
///   Required env:
///     PRIVATE_KEY   — deployer key (loses ownership after handover)
///     SAFE_ADDRESS  — Gnosis Safe (FeeManager treasury from genesis + handover target)
///
///   Optional env (skipped-with-warning when unset — never a guessed address):
///     RELAYER_ADDRESS          — engine relayer + delegate-proxy signer
///     KEEPER_ADDRESS           — ChainlinkPriceRouter market-hours keeper
///     ZEROX_SETTLER            — 0x Settler settlement target (engine allowlist)
///     ZEROX_ALLOWANCE_HOLDER   — 0x AllowanceHolder settlement target
///     AMM_ROUTER               — Uniswap-style fallback router (engine)
///     USDG_FEED                — Chainlink feed for USDG (else constant 1e18)
///     SEQUENCER_FEED           — Chainlink L2 sequencer uptime feed
///     SEQUENCER_GRACE          — sequencer grace period seconds (default 3600)
///     FEED_MAX_STALENESS       — per-feed max staleness seconds (default 3600)
///     <SYMBOL>_FEED            — Chainlink feed per seed token: AAPL_FEED, MSFT_FEED,
///                                TSLA_FEED, GOOGL_FEED, NVDA_FEED
contract DeployMainnet is Script {
    // ----- Mainnet ground-truth constants (global-constraints.md §6) -----
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6-dec base asset
    address constant LEAKED_EOA = 0xd3f9Dcd6011E1aA13eEB277d9CE5F2f7c9BB6070; // must own NOTHING

    // Seed token set (real 18-dec ERC-20 + ERC-8056 stock tokens on 4663).
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    struct Deployed {
        address feeManager;
        address registry;
        address priceRouter;
        address engine;
        address delegateProxyV2;
        address userVaultImpl;
        address beacon;
        address factory;
        address priceOracle;
        address agentRegistry;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address safe = vm.envAddress("SAFE_ADDRESS");
        // The leaked EOA is the repo's current deployer key (rotation still
        // outstanding, 2026-06 audit). Refuse to deploy from it: otherwise every
        // fresh singleton would be owned by a compromised key until handover.
        require(deployer != LEAKED_EOA, "DeployMainnet: deployer is the leaked EOA");
        require(safe != address(0), "DeployMainnet: SAFE_ADDRESS zero");
        require(safe != LEAKED_EOA, "DeployMainnet: SAFE_ADDRESS is the leaked EOA");

        // Seed tokens + their feed env keys (parallel arrays).
        address[] memory seedTokens = new address[](5);
        string[] memory seedSymbols = new string[](5);
        string[] memory feedKeys = new string[](5);
        (seedTokens[0], seedSymbols[0], feedKeys[0]) = (AAPL, "AAPL", "AAPL_FEED");
        (seedTokens[1], seedSymbols[1], feedKeys[1]) = (MSFT, "MSFT", "MSFT_FEED");
        (seedTokens[2], seedSymbols[2], feedKeys[2]) = (TSLA, "TSLA", "TSLA_FEED");
        (seedTokens[3], seedSymbols[3], feedKeys[3]) = (GOOGL, "GOOGL", "GOOGL_FEED");
        (seedTokens[4], seedSymbols[4], feedKeys[4]) = (NVDA, "NVDA", "NVDA_FEED");

        uint48 feedMaxStaleness = uint48(vm.envOr("FEED_MAX_STALENESS", uint256(3600)));

        console.log("=== DeployMainnet (chain 4663) ===");
        console.log("Deployer:  ", deployer);
        console.log("Safe:      ", safe);
        console.log("USDG:      ", USDG);

        Deployed memory d;

        vm.startBroadcast(pk);

        // ===== 1. FeeManager (UUPS) — treasury = Safe from genesis =====
        {
            FeeManagerUpgradeable feeImpl = new FeeManagerUpgradeable();
            ERC1967Proxy feeProxy = new ERC1967Proxy(
                address(feeImpl),
                // initialize(treasury_, baseAsset_, owner_)
                abi.encodeCall(FeeManagerUpgradeable.initialize, (safe, USDG, deployer))
            );
            FeeManagerUpgradeable feeManager = FeeManagerUpgradeable(payable(address(feeProxy)));
            feeManager.setDefaultFees(10, 50, 200, 2000); // entry/exit/mgmt/perf bps (parity with testnet)
            d.feeManager = address(feeManager);
            console.log("FeeManager (proxy):     ", d.feeManager);
        }

        // ===== 2. VaultRegistry (UUPS) =====
        {
            VaultRegistryUpgradeable registryImpl = new VaultRegistryUpgradeable();
            ERC1967Proxy registryProxy = new ERC1967Proxy(
                address(registryImpl), abi.encodeCall(VaultRegistryUpgradeable.initialize, (deployer))
            );
            d.registry = address(registryProxy);
            console.log("VaultRegistry (proxy):  ", d.registry);
        }

        // ===== 3. ChainlinkPriceRouter (UUPS) + feed registration =====
        ChainlinkPriceRouter priceRouter;
        {
            ChainlinkPriceRouter prImpl = new ChainlinkPriceRouter();
            ERC1967Proxy prProxy = new ERC1967Proxy(
                address(prImpl),
                // initialize(owner_, baseAsset_)
                abi.encodeCall(ChainlinkPriceRouter.initialize, (deployer, USDG))
            );
            priceRouter = ChainlinkPriceRouter(address(prProxy));
            d.priceRouter = address(priceRouter);
            console.log("ChainlinkPriceRouter (proxy):", d.priceRouter);

            // USDG base feed: constant 1e18 unless a real feed is supplied.
            address usdgFeed = vm.envOr("USDG_FEED", address(0));
            if (usdgFeed != address(0)) {
                priceRouter.setFeed(USDG, usdgFeed, feedMaxStaleness, "USDG", false);
                console.log("  USDG feed registered:", usdgFeed);
            } else {
                console.log("  USDG feed unset -> constant 1e18 base price (expected).");
            }

            // Optional L2 sequencer uptime feed.
            address seqFeed = vm.envOr("SEQUENCER_FEED", address(0));
            if (seqFeed != address(0)) {
                uint256 grace = vm.envOr("SEQUENCER_GRACE", uint256(3600));
                priceRouter.setSequencerFeed(seqFeed, grace);
                console.log("  Sequencer feed registered:", seqFeed);
            } else {
                console.log("  WARNING: SEQUENCER_FEED unset -> L2 sequencer check DISABLED.");
            }

            // Optional keeper for setMarketOpen().
            address keeper = vm.envOr("KEEPER_ADDRESS", address(0));
            if (keeper != address(0)) {
                priceRouter.setKeeper(keeper, true);
                console.log("  Keeper authorized:", keeper);
            } else {
                console.log("  WARNING: KEEPER_ADDRESS unset -> only the owner can flip marketOpen.");
            }

            // Per-seed-token Chainlink feeds — only when explicitly provided.
            for (uint256 i = 0; i < seedTokens.length; i++) {
                address feed = vm.envOr(feedKeys[i], address(0));
                if (feed != address(0)) {
                    priceRouter.setFeed(seedTokens[i], feed, feedMaxStaleness, seedSymbols[i], true);
                    console.log("  Feed registered:", seedSymbols[i], feed);
                } else {
                    console.log("  WARNING: feed unset, skipping (no zero feed):", feedKeys[i]);
                }
            }
            // marketOpen intentionally left false; the runbook flips it post-verify.
            console.log("  REMINDER: marketOpen=false. Flip it via setMarketOpen(true) after go/no-go.");
        }

        // ===== 4. MainnetExecutionEngine (UUPS) =====
        MainnetExecutionEngine engine;
        {
            MainnetExecutionEngine engineImpl = new MainnetExecutionEngine();
            ERC1967Proxy engineProxy = new ERC1967Proxy(
                address(engineImpl),
                // initialize(tokenRouter_, baseAsset_, owner_)
                abi.encodeCall(MainnetExecutionEngine.initialize, (d.priceRouter, USDG, deployer))
            );
            engine = MainnetExecutionEngine(address(engineProxy));
            d.engine = address(engine);
            console.log("MainnetExecutionEngine (proxy):", d.engine);

            // Settlement targets (0x). Skip+warn when unset — never a guess.
            address settler = vm.envOr("ZEROX_SETTLER", address(0));
            if (settler != address(0)) {
                engine.setAllowedSettlementTarget(settler, true);
                console.log("  0x Settler allowed:", settler);
            } else {
                console.log("  WARNING: ZEROX_SETTLER unset -> staged settlement disabled until set.");
            }
            address allowanceHolder = vm.envOr("ZEROX_ALLOWANCE_HOLDER", address(0));
            if (allowanceHolder != address(0)) {
                engine.setAllowedSettlementTarget(allowanceHolder, true);
                console.log("  0x AllowanceHolder allowed:", allowanceHolder);
            } else {
                console.log("  WARNING: ZEROX_ALLOWANCE_HOLDER unset -> not allowlisted.");
            }

            // Relayer.
            address relayer = vm.envOr("RELAYER_ADDRESS", address(0));
            if (relayer != address(0)) {
                engine.setRelayer(relayer, true);
                console.log("  Relayer authorized:", relayer);
            } else {
                console.log("  WARNING: RELAYER_ADDRESS unset -> no relayer can stage settlement.");
            }

            // Buy-side allowlist for seed tokens (sells are always allowed).
            for (uint256 i = 0; i < seedTokens.length; i++) {
                engine.setAllowedToken(seedTokens[i], true);
                console.log("  allowedToken:", seedSymbols[i], seedTokens[i]);
            }

            // Optional AMM fallback venue + per-token routes. User withdraw()/
            // redeem() liquidate via engine.executeRebalance with NO stage (only
            // the relayer can stage, same-block), so they can settle only through
            // _settleViaAmm — which reverts NoRoute unless BOTH ammRouter != 0 AND
            // ammRoute[token].length > 0. Without these, withdraw-to-base reverts
            // for any fully-invested vault and only in-kind emergencyWithdraw
            // exits. Routes are per-token hex paths from <SYMBOL>_AMM_ROUTE; each
            // is warn+skipped when unset (never a guessed route).
            address amm = vm.envOr("AMM_ROUTER", address(0));
            if (amm != address(0)) {
                engine.setAmmRouter(amm);
                console.log("  AMM router set:", amm);
                for (uint256 i = 0; i < seedTokens.length; i++) {
                    bytes memory route = vm.envOr(string.concat(seedSymbols[i], "_AMM_ROUTE"), bytes(""));
                    if (route.length > 0) {
                        engine.setAmmRoute(seedTokens[i], route);
                        console.log("  AMM route set (withdraw-to-base ENABLED):", seedSymbols[i]);
                    } else {
                        console.log("  WARNING: WITHDRAW-TO-BASE DISABLED until ammRoute set for:", seedSymbols[i]);
                    }
                }
            } else {
                console.log("  WARNING: AMM_ROUTER unset -> AMM fallback unavailable (0x-only).");
                console.log("  WARNING: WITHDRAW-TO-BASE DISABLED for ALL seed tokens until AMM_ROUTER + routes set.");
            }
        }

        // ===== 5. TradeDelegateProxyV2 (plain Ownable) =====
        {
            TradeDelegateProxyV2 delegate = new TradeDelegateProxyV2(deployer, d.engine);
            d.delegateProxyV2 = address(delegate);
            console.log("TradeDelegateProxyV2:   ", d.delegateProxyV2);
            address relayer = vm.envOr("RELAYER_ADDRESS", address(0));
            if (relayer != address(0)) {
                delegate.setAuthorizedSigner(relayer, true);
                console.log("  Signer authorized:", relayer);
            } else {
                console.log("  WARNING: RELAYER_ADDRESS unset -> no signer authorized on the delegate proxy.");
            }

            // Authorize the delegate proxy itself as an engine RELAYER. This is
            // the critical relayer: the primary 0x-staged path runs
            // proxy.executeTradeWithSettlement -> engine.stageSettlement with
            // msg.sender == this proxy, gated by authorizedRelayers[msg.sender]
            // (MainnetExecutionEngine.stageSettlement). Without it every staged
            // trade reverts UnauthorizedRelayer and no staged trade can execute.
            // The backend RELAYER_ADDRESS is also an engine relayer (section 4)
            // for any direct-relayer flow, but the PROXY is the one that stages.
            engine.setRelayer(address(delegate), true);
            console.log("  Engine relayer authorized (delegate proxy):", d.delegateProxyV2);
        }

        // ===== 6. UserVault impl + UpgradeableBeacon =====
        // Beacon is deployed with the deployer as a TEMPORARY owner, then
        // transferred to the factory proxy below so the beacon is owned by the
        // factory from the moment the factory exists (kills the beacon-ownership
        // trap, AGENTS.md TechnicalDebt 1.1). An explicit require() enforces it.
        {
            UserVault userVaultImpl = new UserVault();
            d.userVaultImpl = address(userVaultImpl);
            UpgradeableBeacon beacon = new UpgradeableBeacon(address(userVaultImpl), deployer);
            d.beacon = address(beacon);
            console.log("UserVault impl:         ", d.userVaultImpl);
            console.log("UpgradeableBeacon:      ", d.beacon);
        }

        // ===== 7. UserVaultFactoryV2 (UUPS) + wiring + beacon handover =====
        {
            UserVaultFactoryV2 factoryImpl = new UserVaultFactoryV2();
            ERC1967Proxy factoryProxy = new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(
                    UserVaultFactoryV2.initialize,
                    (
                        d.beacon,
                        USDG,
                        d.feeManager,
                        d.registry,
                        d.engine, // rebalanceEngine = MainnetExecutionEngine
                        d.priceRouter, // tokenRouter = ChainlinkPriceRouter
                        d.delegateProxyV2
                    )
                )
            );
            UserVaultFactoryV2 factory = UserVaultFactoryV2(payable(address(factoryProxy)));
            d.factory = address(factory);
            console.log("UserVaultFactoryV2 (proxy):", d.factory);

            // Seed approved tokens.
            factory.setApprovedTokensBatch(seedTokens, true);

            // Wire the factory's authority across the stack (mirror DeployUpgradeable).
            VaultRegistryUpgradeable(d.registry).setRegistrar(d.factory, true);
            FeeManagerUpgradeable(payable(d.feeManager)).setAuthorizedCaller(d.factory, true);
            engine.setAuthorizedCaller(d.factory, true); // factory can setVaultAuthorized

            // Hand the beacon to the factory proxy (from-genesis ownership).
            UpgradeableBeacon(d.beacon).transferOwnership(d.factory);
        }

        // ===== 8. PriceOracle (UUPS) — both shims point at ChainlinkPriceRouter =====
        {
            PriceOracleUpgradeable oracleImpl = new PriceOracleUpgradeable();
            ERC1967Proxy oracleProxy = new ERC1967Proxy(
                address(oracleImpl),
                // initialize(tokenRouter_, stockTokenFactory_, owner_)
                abi.encodeCall(PriceOracleUpgradeable.initialize, (d.priceRouter, d.priceRouter, deployer))
            );
            d.priceOracle = address(oracleProxy);
            console.log("PriceOracle (proxy):    ", d.priceOracle);
        }

        // ===== 9. AgentRegistry (chain-agnostic, plain Ownable ERC721) =====
        {
            AgentRegistry agentRegistry = new AgentRegistry();
            d.agentRegistry = address(agentRegistry);
            console.log("AgentRegistry:          ", d.agentRegistry);
        }

        vm.stopBroadcast();

        // ===================== Post-checks (fail the script) =====================
        _postChecks(d, deployer);

        // Informational liveness report (does NOT revert): withdraw-to-base
        // readiness per token. The proxy-relayer requirement is enforced hard in
        // _postChecks; AMM routes may legitimately be deferred at genesis.
        _reportLiveness(d, seedTokens, seedSymbols);

        _printJson(d, deployer, safe, seedTokens, seedSymbols, feedKeys);
    }

    function _postChecks(Deployed memory d, address deployer) internal view {
        // RouterDrift precondition: the engine the factory points at must expose
        // the SAME token router the factory hands new vaults, else every vault is
        // born broken. MainnetExecutionEngine.tokenRouter() must equal priceRouter.
        require(address(MainnetExecutionEngine(d.engine).tokenRouter()) == d.priceRouter, "post: engine router drift");

        // Factory reads back its wiring.
        UserVaultFactoryV2 f = UserVaultFactoryV2(payable(d.factory));
        require(f.rebalanceEngine() == d.engine, "post: factory engine mismatch");
        require(f.tokenRouter() == d.priceRouter, "post: factory router mismatch");
        require(address(f.beacon()) == d.beacon, "post: factory beacon mismatch");
        require(f.isRouterAligned(), "post: factory not router-aligned");

        // THE mandatory one: beacon owned by the factory proxy (not the deployer).
        require(UpgradeableBeacon(d.beacon).owner() == d.factory, "post: beacon NOT owned by factory");

        // Delegate proxy points at the engine.
        require(TradeDelegateProxyV2(d.delegateProxyV2).engine() == d.engine, "post: delegate engine mismatch");

        // Fix A (mandatory): the delegate proxy MUST be an authorized engine
        // relayer. The primary 0x-staged path stages settlement with
        // msg.sender == delegateProxyV2, gated on authorizedRelayers[msg.sender];
        // without this every staged trade reverts UnauthorizedRelayer.
        require(
            MainnetExecutionEngine(d.engine).authorizedRelayers(d.delegateProxyV2), "post: proxy not engine relayer"
        );

        // Price router still owner=deployer pre-handover (Safe transfer is a separate script).
        require(ChainlinkPriceRouter(d.priceRouter).owner() == deployer, "post: price router owner != deployer");

        console.log("\nAll post-checks PASSED (beacon owned by factory; router aligned; proxy is engine relayer).");
    }

    /// @notice Informational (non-reverting) liveness report — is the stack
    ///         actually wired for trading AND withdrawals, not merely owned. The
    ///         proxy-relayer is enforced hard in _postChecks; withdraw-to-base
    ///         readiness (ammRouter + per-token ammRoute) may be intentionally
    ///         deferred at genesis, so it is surfaced as a loud warning here.
    function _reportLiveness(Deployed memory d, address[] memory seedTokens, string[] memory seedSymbols)
        internal
        view
    {
        MainnetExecutionEngine engine = MainnetExecutionEngine(d.engine);
        console.log("\n===== Liveness (trade + withdraw wiring) =====");
        console.log("Proxy authorized as engine relayer (staged trades live):");
        console.log("  ", engine.authorizedRelayers(d.delegateProxyV2));
        address amm = engine.ammRouter();
        console.log("engine.ammRouter():", amm);
        for (uint256 i = 0; i < seedTokens.length; i++) {
            bool routed = amm != address(0) && engine.ammRoute(seedTokens[i]).length > 0;
            if (routed) {
                console.log("  withdraw-to-base ENABLED:", seedSymbols[i]);
            } else {
                console.log("  WITHDRAW-TO-BASE DISABLED (in-kind emergencyWithdraw only) for:", seedSymbols[i]);
            }
        }
    }

    function _printJson(
        Deployed memory d,
        address deployer,
        address safe,
        address[] memory seedTokens,
        string[] memory seedSymbols,
        string[] memory feedKeys
    ) internal view {
        console.log("\n===== PASTE INTO deployments/robinhood-mainnet.json =====");
        console.log('{');
        console.log('  "network": "Robinhood Chain Mainnet",');
        console.log('  "chainId": 4663,');
        console.log('  "deployer": "%s",', deployer);
        console.log('  "safe": "%s",', safe);
        console.log('  "contracts": {');
        console.log('    "USDG": "%s",', USDG);
        console.log('    "FeeManager": "%s",', d.feeManager);
        console.log('    "VaultRegistry": "%s",', d.registry);
        console.log('    "ChainlinkPriceRouter": "%s",', d.priceRouter);
        console.log('    "MainnetExecutionEngine": "%s",', d.engine);
        console.log('    "TradeDelegateProxyV2": "%s",', d.delegateProxyV2);
        console.log('    "UserVaultImpl": "%s",', d.userVaultImpl);
        console.log('    "UserVaultBeacon": "%s",', d.beacon);
        console.log('    "UserVaultFactoryV2": "%s",', d.factory);
        console.log('    "PriceOracle": "%s",', d.priceOracle);
        console.log('    "AgentRegistry": "%s"', d.agentRegistry);
        console.log('  },');
        console.log('  "seedTokens": {');
        for (uint256 i = 0; i < seedTokens.length; i++) {
            string memory tail = i + 1 < seedTokens.length ? "," : "";
            console.log(string.concat('    "', seedSymbols[i], '": "%s"', tail), seedTokens[i]);
        }
        console.log('  },');
        console.log('  "feeds": {');
        for (uint256 i = 0; i < seedTokens.length; i++) {
            address feed = vm.envOr(feedKeys[i], address(0));
            string memory tail = i + 1 < seedTokens.length ? "," : "";
            console.log(string.concat('    "', seedSymbols[i], '": "%s"', tail), feed);
        }
        console.log('  }');
        console.log('}');
        console.log("=========================================================");
    }
}
