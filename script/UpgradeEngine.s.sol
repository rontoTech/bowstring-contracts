// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {PoliticianVault} from "../src/core/PoliticianVault.sol";

/// @title UpgradeRebalanceEngine
/// @notice Deploys a fixed RebalanceEngine, authorizes vaults, and updates vault references.
contract UpgradeRebalanceEngine is Script {
    // Existing deployed addresses
    address constant ROUTER = 0x960773685f319b4E7BCaEf3306F5aE954efc57b7;
    address constant BOW_USDC = 0xF41c1d33C0c89456c68E5Af491A0eC65f1BEf6bA;

    address constant PELOSI_VAULT = 0x44e9c800ea726e157C4Fde241f0acA1a04c66f02;
    address constant TUBE_VAULT = 0xdC1Cd37a69246Bdf7454fFdA911331b184E62fFc;
    address constant CREN_VAULT = 0xBB98d64CA8DC72B618E0A2F5852bDf020d922477;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new RebalanceEngine with fixed buy-side minAmountOut
        RebalanceEngine newEngine = new RebalanceEngine(ROUTER, BOW_USDC);
        address engineAddr = address(newEngine);
        console.log("New RebalanceEngine:", engineAddr);

        // 2. Authorize the new engine as caller on the router
        MockTokenRouter(ROUTER).setAuthorizedCaller(engineAddr, true);
        console.log("Router: authorized new engine");

        // 3. Authorize each vault on the new engine
        newEngine.setVaultAuthorized(PELOSI_VAULT, true);
        newEngine.setVaultAuthorized(TUBE_VAULT, true);
        newEngine.setVaultAuthorized(CREN_VAULT, true);
        console.log("Engine: authorized all 3 vaults");

        // 4. Update each vault to point to the new engine
        PoliticianVault(PELOSI_VAULT).setRebalanceEngine(engineAddr);
        PoliticianVault(TUBE_VAULT).setRebalanceEngine(engineAddr);
        PoliticianVault(CREN_VAULT).setRebalanceEngine(engineAddr);
        console.log("Vaults: updated rebalance engine references");

        vm.stopBroadcast();

        console.log("\n=== UPGRADE COMPLETE ===");
        console.log("New RebalanceEngine:", engineAddr);
        console.log("========================");
    }
}
