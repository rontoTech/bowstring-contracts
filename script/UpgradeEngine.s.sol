// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {PoliticianVault} from "../src/core/PoliticianVault.sol";

/// @title UpgradeRebalanceEngine
/// @notice Deploys a fixed RebalanceEngine, authorizes vaults, and updates vault references.
///         This script is for upgrading existing deployments.
contract UpgradeRebalanceEngine is Script {
    // Existing deployed addresses (update these for your deployment)
    address constant ROUTER = address(0); // UPDATE
    address constant TILT_USDC = address(0); // UPDATE
    address constant VAULT_FACTORY = address(0); // UPDATE

    // Vault addresses (update these for your deployment)
    address constant PELOSI_VAULT = address(0); // UPDATE
    address constant TUBE_VAULT = address(0); // UPDATE
    address constant CREN_VAULT = address(0); // UPDATE

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new RebalanceEngine
        RebalanceEngine newEngine = new RebalanceEngine(ROUTER, TILT_USDC);
        address engineAddr = address(newEngine);
        console.log("New RebalanceEngine:", engineAddr);

        // 2. Authorize the new engine as caller on the router
        MockTokenRouter(ROUTER).setAuthorizedCaller(engineAddr, true);

        // 3. Authorize factory to register future vaults
        newEngine.setAuthorizedCaller(VAULT_FACTORY, true);

        // 4. Authorize each existing vault on the new engine
        newEngine.setVaultAuthorized(PELOSI_VAULT, true);
        newEngine.setVaultAuthorized(TUBE_VAULT, true);
        newEngine.setVaultAuthorized(CREN_VAULT, true);

        // 5. Update each vault to point to the new engine
        PoliticianVault(PELOSI_VAULT).setRebalanceEngine(engineAddr);
        PoliticianVault(TUBE_VAULT).setRebalanceEngine(engineAddr);
        PoliticianVault(CREN_VAULT).setRebalanceEngine(engineAddr);

        vm.stopBroadcast();

        console.log("\n=== UPGRADE COMPLETE ===");
        console.log("New RebalanceEngine:", engineAddr);
        console.log("========================");
    }
}
