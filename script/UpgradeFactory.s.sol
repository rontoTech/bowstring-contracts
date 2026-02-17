// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {FeeManager} from "../src/core/FeeManager.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";

/// @title UpgradeFactory
/// @notice Deploy new FeeManager + VaultFactory with all audit fixes.
///         This script is for upgrading existing deployments.
contract UpgradeFactory is Script {
    // Existing deployed addresses (update these for your deployment)
    address constant TILT_USDC = address(0); // UPDATE
    address constant VAULT_REGISTRY = address(0); // UPDATE
    address constant PORTFOLIO_ORACLE = address(0); // UPDATE
    address constant REBALANCE_ENGINE = address(0); // UPDATE
    address constant TOKEN_ROUTER = address(0); // UPDATE

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new FeeManager (with base asset)
        FeeManager newFeeManager = new FeeManager(deployer, TILT_USDC);
        address feeManagerAddr = address(newFeeManager);
        console.log("New FeeManager:", feeManagerAddr);

        // Set all fees to 0 for testnet
        newFeeManager.setDefaultFees(0, 0, 0, 0);

        // 2. Deploy new VaultFactory
        VaultFactory newFactory = new VaultFactory(
            TILT_USDC, feeManagerAddr, VAULT_REGISTRY, REBALANCE_ENGINE, TOKEN_ROUTER, PORTFOLIO_ORACLE
        );
        address factoryAddr = address(newFactory);
        console.log("New VaultFactory:", factoryAddr);

        // 3. Wire permissions
        newFeeManager.setAuthorizedCaller(factoryAddr, true);
        VaultRegistry(VAULT_REGISTRY).setRegistrar(factoryAddr, true);
        RebalanceEngine(REBALANCE_ENGINE).setAuthorizedCaller(factoryAddr, true);

        vm.stopBroadcast();

        console.log("\n========== UPGRADE COMPLETE ==========");
        console.log("New FeeManager:    ", feeManagerAddr);
        console.log("New VaultFactory:  ", factoryAddr);
        console.log("=======================================");
    }
}
