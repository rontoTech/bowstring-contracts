// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {FeeManagerUpgradeable} from "../src/core/FeeManagerUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../src/core/VaultRegistryUpgradeable.sol";
import {ChainlinkPriceRouter} from "../src/mainnet/ChainlinkPriceRouter.sol";
import {MainnetExecutionEngine} from "../src/mainnet/MainnetExecutionEngine.sol";
import {TradeDelegateProxyV2} from "../src/mainnet/TradeDelegateProxyV2.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/// @title AssertMainnetOwnership
/// @notice Read-only go/no-go gate to run AFTER the Safe handover and BEFORE any
///         funding. Asserts:
///           1. every contract's owner() == SAFE_ADDRESS,
///           2. the beacon is owned by the factory (which is Safe-owned),
///           3. the leaked deployer EOA holds ZERO owner + ZERO role across every
///              role mapping (keeper / relayer / caller / signer / registrar),
///         and logs the marketOpen flag + registered-feed count. Prints a
///         PASS/FAIL line per check and reverts if any check fails (non-zero exit).
///
///   No broadcast — pure view. Run with `--rpc-url robinhood_mainnet`.
///
///   Required env: SAFE_ADDRESS + the deployed addresses (same names as
///   TransferMainnetToSafe, plus USER_VAULT_BEACON).
contract AssertMainnetOwnership is Script {
    address constant LEAKED_EOA = 0xd3f9Dcd6011E1aA13eEB277d9CE5F2f7c9BB6070;

    // Seed token set (mirror of DeployMainnet) — used only for the informational
    // AMM withdraw-to-base liveness report; not part of the ownership assertions.
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    uint256 internal failures;

    function _check(bool cond, string memory label) internal {
        if (cond) {
            console.log("  [PASS]", label);
        } else {
            console.log("  [FAIL]", label);
            failures++;
        }
    }

    function run() external {
        address safe = vm.envAddress("SAFE_ADDRESS");
        require(safe != address(0), "Assert: SAFE_ADDRESS zero");

        address feeManager = vm.envAddress("FEE_MANAGER");
        address registry = vm.envAddress("VAULT_REGISTRY");
        address priceRouter = vm.envAddress("PRICE_ROUTER");
        address engine = vm.envAddress("EXECUTION_ENGINE");
        address factory = vm.envAddress("USER_VAULT_FACTORY");
        address delegate = vm.envAddress("TRADE_DELEGATE_PROXY_V2");
        address priceOracle = vm.envAddress("PRICE_ORACLE");
        address agentRegistry = vm.envAddress("AGENT_REGISTRY");
        address beacon = vm.envAddress("USER_VAULT_BEACON");

        console.log("=== AssertMainnetOwnership (go/no-go) ===");
        console.log("Safe:", safe);
        console.log("Leaked EOA (must own nothing):", LEAKED_EOA);

        // -------- 1. owner() == Safe for every owned contract --------
        console.log("\n[1] Ownership -> Safe:");
        _check(IOwnable(feeManager).owner() == safe, "FeeManager owner == Safe");
        _check(IOwnable(registry).owner() == safe, "VaultRegistry owner == Safe");
        _check(IOwnable(priceRouter).owner() == safe, "ChainlinkPriceRouter owner == Safe");
        _check(IOwnable(engine).owner() == safe, "MainnetExecutionEngine owner == Safe");
        _check(IOwnable(factory).owner() == safe, "UserVaultFactoryV2 owner == Safe");
        _check(IOwnable(delegate).owner() == safe, "TradeDelegateProxyV2 owner == Safe");
        _check(IOwnable(priceOracle).owner() == safe, "PriceOracle owner == Safe");
        _check(IOwnable(agentRegistry).owner() == safe, "AgentRegistry owner == Safe");

        // -------- 2. Beacon owned by the (Safe-owned) factory --------
        console.log("\n[2] Beacon ownership:");
        _check(UpgradeableBeacon(beacon).owner() == factory, "Beacon owned by factory");

        // -------- 3. Leaked EOA holds ZERO owner + ZERO role --------
        console.log("\n[3] Leaked EOA holds nothing:");
        _check(IOwnable(feeManager).owner() != LEAKED_EOA, "FeeManager owner != leaked");
        _check(IOwnable(registry).owner() != LEAKED_EOA, "VaultRegistry owner != leaked");
        _check(IOwnable(priceRouter).owner() != LEAKED_EOA, "PriceRouter owner != leaked");
        _check(IOwnable(engine).owner() != LEAKED_EOA, "Engine owner != leaked");
        _check(IOwnable(factory).owner() != LEAKED_EOA, "Factory owner != leaked");
        _check(IOwnable(delegate).owner() != LEAKED_EOA, "Delegate owner != leaked");
        _check(IOwnable(priceOracle).owner() != LEAKED_EOA, "PriceOracle owner != leaked");
        _check(IOwnable(agentRegistry).owner() != LEAKED_EOA, "AgentRegistry owner != leaked");
        _check(UpgradeableBeacon(beacon).owner() != LEAKED_EOA, "Beacon owner != leaked");

        // Role mappings — leaked EOA must be false everywhere.
        _check(!ChainlinkPriceRouter(priceRouter).authorizedKeepers(LEAKED_EOA), "PriceRouter keeper role != leaked");
        _check(!MainnetExecutionEngine(engine).authorizedCallers(LEAKED_EOA), "Engine caller role != leaked");
        _check(!MainnetExecutionEngine(engine).authorizedRelayers(LEAKED_EOA), "Engine relayer role != leaked");
        _check(!MainnetExecutionEngine(engine).authorizedVaults(LEAKED_EOA), "Engine vault role != leaked");
        _check(!TradeDelegateProxyV2(delegate).authorizedSigners(LEAKED_EOA), "Delegate signer role != leaked");
        _check(
            !FeeManagerUpgradeable(payable(feeManager)).authorizedCallers(LEAKED_EOA),
            "FeeManager caller role != leaked"
        );
        _check(
            !VaultRegistryUpgradeable(registry).authorizedRegistrars(LEAKED_EOA), "Registry registrar role != leaked"
        );

        // -------- Informational state --------
        console.log("\n[i] State:");
        bool marketOpen = ChainlinkPriceRouter(priceRouter).marketOpen();
        console.log("  marketOpen:", marketOpen);
        console.log("  registered feeds:", ChainlinkPriceRouter(priceRouter).registeredTokensLength());
        console.log("  engine.tokenRouter():", address(MainnetExecutionEngine(engine).tokenRouter()));

        // Cross-consistency: engine router must equal the price router (RouterDrift).
        _check(
            address(MainnetExecutionEngine(engine).tokenRouter()) == priceRouter, "Engine router == PriceRouter"
        );
        _check(UserVaultFactoryV2(payable(factory)).isRouterAligned(), "Factory router aligned");

        // -------- 4. Liveness: trades & withdrawals actually wired --------
        // Ownership being clean is necessary but not sufficient: a deploy can be
        // fully Safe-owned yet unable to trade or process withdraw-to-base. Surface
        // both so go/no-go reflects "the stack actually works", not just custody.
        console.log("\n[4] Liveness (trade + withdraw wiring):");
        // MANDATORY (hard fail): the delegate proxy must be an engine relayer, else
        // every 0x-staged trade reverts UnauthorizedRelayer (the staged path calls
        // stageSettlement with msg.sender == TradeDelegateProxyV2).
        _check(
            MainnetExecutionEngine(engine).authorizedRelayers(delegate),
            "Delegate proxy authorized as engine relayer"
        );
        // WARNING only (not a failure): withdraw-to-base for a fully-invested vault
        // needs ammRouter + per-token ammRoute; genesis may intentionally launch
        // 0x-only (in-kind emergencyWithdraw still exits). Print, don't fail.
        address amm = MainnetExecutionEngine(engine).ammRouter();
        console.log("  engine.ammRouter():", amm);
        address[5] memory seeds = [AAPL, MSFT, TSLA, GOOGL, NVDA];
        string[5] memory syms = ["AAPL", "MSFT", "TSLA", "GOOGL", "NVDA"];
        for (uint256 i = 0; i < seeds.length; i++) {
            bool routed = amm != address(0) && MainnetExecutionEngine(engine).ammRoute(seeds[i]).length > 0;
            if (routed) {
                console.log("  [ok]   withdraw-to-base ENABLED:", syms[i]);
            } else {
                console.log("  [warn] WITHDRAW-TO-BASE DISABLED until ammRoute set:", syms[i]);
            }
        }

        // -------- Summary --------
        console.log("\n==================================================");
        if (failures == 0) {
            console.log("RESULT: PASS - ownership graph clean, GO for funding.");
        } else {
            console.log("RESULT: FAIL - %s check(s) failed. NO-GO.", failures);
        }
        console.log("==================================================");

        require(failures == 0, "AssertMainnetOwnership: one or more checks FAILED (NO-GO)");
    }
}
