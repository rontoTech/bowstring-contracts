// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {FeeManager} from "../src/core/FeeManager.sol";
import {FeeManagerUpgradeable} from "../src/core/FeeManagerUpgradeable.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MigrateFeeManager
/// @notice One-shot migration from the legacy, non-upgradeable FeeManager
///         (stale bytecode missing `configureVaultFeesWithRates`) to a new
///         UUPS-upgradeable FeeManagerUpgradeable instance.
///
/// Steps:
///   1. Deploy FeeManagerUpgradeable implementation
///   2. Deploy ERC1967Proxy in front of it, call initialize(...)
///   3. Copy `defaultEntryFeeBps / defaultExitFeeBps / defaultMgmtFeeBps / defaultPerfFeeBps`
///      from the old FeeManager so we keep fee defaults stable
///   4. Authorize the deployer + UserVaultFactoryV2 as callers on the new FM
///   5. Deploy a new UserVaultFactoryV2 implementation that contains
///      `setFeeManager / setRegistry / setTokenRouter` (storage-compatible
///      upgrade of the existing proxy)
///   6. `upgradeToAndCall` the factory proxy to the new impl
///   7. Call `factory.setFeeManager(newFM)` so subsequent createUserVault*
///      flows use the working FM
///   8. Per-vault migration: for every vault currently registered on the
///      factory, call `UserVault.setFeeManager(newFM)` and re-configure
///      that vault on the new FM (copying curator + curator share from the
///      old FM). This keeps historic vaults fully functional.
///
/// Required env:
///   - PRIVATE_KEY: deployer key (must own the factory proxy AND the old FM)
///
/// Optional env:
///   - OLD_FEE_MANAGER (default: deployments/robinhood-testnet.json -> FeeManager)
///   - USER_VAULT_FACTORY (default: deployments/robinhood-testnet.json -> UserVaultFactory)
///   - BASE_ASSET         (default: deployments/robinhood-testnet.json -> TiltUSDC)
///   - TREASURY           (default: deployer)
contract MigrateFeeManager is Script {
    // Robinhood testnet addresses (from deployments/robinhood-testnet.json).
    address constant DEFAULT_OLD_FM = 0x63D367C9A34d94aBD4D2cD0921Dd0F4252E8548A;
    address constant DEFAULT_FACTORY = 0xD5210C45C7B65E4D9Eed53391D2199a2aB9DcF57;
    address constant DEFAULT_BASE_ASSET = 0x941A382852E989078e15b381f921C488a7Ca5299;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address oldFMAddr = _envOr("OLD_FEE_MANAGER", DEFAULT_OLD_FM);
        address factoryAddr = _envOr("USER_VAULT_FACTORY", DEFAULT_FACTORY);
        address baseAsset = _envOr("BASE_ASSET", DEFAULT_BASE_ASSET);
        address treasury = _envOr("TREASURY", deployer);

        FeeManager oldFM = FeeManager(payable(oldFMAddr));
        UserVaultFactoryV2 factory = UserVaultFactoryV2(payable(factoryAddr));

        console.log("===== MigrateFeeManager =====");
        console.log("deployer:   ", deployer);
        console.log("oldFM:      ", oldFMAddr);
        console.log("factory:    ", factoryAddr);
        console.log("baseAsset:  ", baseAsset);
        console.log("treasury:   ", treasury);

        // Preflight: ownership + sanity
        require(oldFM.owner() == deployer, "deployer must own old FeeManager");
        require(factory.owner() == deployer, "deployer must own UserVaultFactoryV2");

        // Capture defaults + prior factory authorisation so we can replicate them.
        uint16 entryBps = oldFM.defaultEntryFeeBps();
        uint16 exitBps = oldFM.defaultExitFeeBps();
        uint16 mgmtBps = oldFM.defaultManagementFeeBps();
        uint16 perfBps = oldFM.defaultPerformanceFeeBps();
        console.log("defaults: entry/exit/mgmt/perf", entryBps, exitBps);
        console.log("         ", mgmtBps, perfBps);

        address[] memory vaults = factory.getAllVaults();
        console.log("existing vaults on factory:", vaults.length);

        vm.startBroadcast(pk);

        // ---------- 1. Deploy FeeManagerUpgradeable behind ERC1967Proxy ----------
        FeeManagerUpgradeable fmImpl = new FeeManagerUpgradeable();
        bytes memory initData = abi.encodeCall(
            FeeManagerUpgradeable.initialize,
            (treasury, baseAsset, deployer)
        );
        ERC1967Proxy fmProxy = new ERC1967Proxy(address(fmImpl), initData);
        FeeManagerUpgradeable newFM = FeeManagerUpgradeable(payable(address(fmProxy)));
        console.log("FeeManagerUpgradeable impl: ", address(fmImpl));
        console.log("FeeManagerUpgradeable proxy:", address(newFM));

        // ---------- 2. Copy default fee schedule ----------
        if (entryBps != 30 || exitBps != 50 || mgmtBps != 50 || perfBps != 1500) {
            newFM.setDefaultFees(entryBps, exitBps, mgmtBps, perfBps);
            console.log("default fees replicated from old FM");
        }

        // ---------- 3. Authorize callers on new FM ----------
        newFM.setAuthorizedCaller(factoryAddr, true);
        newFM.setAuthorizedCaller(deployer, true);
        console.log("authorized factory + deployer on new FM");

        // ---------- 4. Deploy new UserVaultFactoryV2 implementation ----------
        //     (adds setFeeManager / setRegistry / setTokenRouter)
        UserVaultFactoryV2 factoryImpl = new UserVaultFactoryV2();
        console.log("UserVaultFactoryV2 new impl:", address(factoryImpl));

        // ---------- 5. Upgrade factory proxy (UUPS: owner-gated) ----------
        factory.upgradeToAndCall(address(factoryImpl), "");
        console.log("factory proxy upgraded to new impl");

        // ---------- 6. Repoint factory at the new FM ----------
        factory.setFeeManager(address(newFM));
        console.log("factory.feeManager -> new FM");

        // ---------- 7. Migrate each existing vault ----------
        for (uint256 i = 0; i < vaults.length; i++) {
            address v = vaults[i];
            // Pull existing config from the old FM so we preserve curator + share.
            (
                ,
                ,
                uint16 mgmt,
                uint16 perf,
                uint16 curatorShare,
                address curator,
                bool isConfigured
            ) = oldFM.vaultFees(v);

            // Repoint the vault at the new FM (must be called before any new
            // configure/record; caller must equal the current feeManager.owner(),
            // which is still the deployer because old + new FMs share owner).
            UserVault(v).setFeeManager(address(newFM));

            if (isConfigured) {
                if (mgmt > 0 || perf > 0) {
                    newFM.configureVaultFeesWithRates(v, mgmt, perf, curatorShare, curator);
                } else {
                    newFM.configureVaultFees(v, curatorShare, curator);
                }
            }
            console.log("migrated vault:", v);
        }

        vm.stopBroadcast();

        console.log("===== Migration complete =====");
        console.log("NEW FeeManager proxy:", address(newFM));
        console.log("Update deployments/robinhood-testnet.json FeeManager to:");
        console.log(address(newFM));
    }

    function _envOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v == address(0) ? fallback_ : v;
        } catch {
            return fallback_;
        }
    }
}
