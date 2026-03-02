// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {FeeManager} from "../src/core/FeeManager.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Redeploy FeeManager + UserVaultFactory with per-vault fee support,
///         upgrade vault beacon, migrate existing vaults to new FeeManager.
contract RedeployFees is Script {
    // Existing infrastructure (DO NOT redeploy)
    address constant TILT_USDC   = 0x941A382852E989078e15b381f921C488a7Ca5299;
    address constant TREASURY    = 0xd3f9Dcd6011E1aA13eEB277d9CE5F2f7c9BB6070;
    address constant REGISTRY    = 0xf61b0b073105c8dDAb1adeE13b17E86122D9a60d;
    address constant ENGINE      = 0xd64c437E9A35481b7c4B74D404bb36c20379Ffd0;
    address constant ROUTER      = 0x969FeCdfa7b0036837AD964662d387a2dCd38d6B;
    address constant OLD_FACTORY = 0x67f0CdD4bb561BaAa3A5f1d4FE7Ede1F68E00712;

    // Fees: entry 0.1%, exit 0.5%, mgmt 2%/yr, perf 20%
    uint16 constant ENTRY_BPS = 10;
    uint16 constant EXIT_BPS  = 50;
    uint16 constant MGMT_BPS  = 200;
    uint16 constant PERF_BPS  = 2000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("Deployer:", deployer);

        // Fetch all existing vaults from the old factory
        UserVaultFactory oldFactory = UserVaultFactory(payable(OLD_FACTORY));
        address[] memory vaults = oldFactory.getAllVaults();
        console.log("Existing vaults:", vaults.length);

        vm.startBroadcast(pk);

        // ===== 1. Deploy new FeeManager =====
        FeeManager newFM = new FeeManager(TREASURY, TILT_USDC);
        console.log("New FeeManager:", address(newFM));

        newFM.setDefaultFees(ENTRY_BPS, EXIT_BPS, MGMT_BPS, PERF_BPS);

        // ===== 2. Deploy new UserVaultFactory =====
        UserVaultFactory newFactory = new UserVaultFactory(
            TILT_USDC, address(newFM), REGISTRY, ENGINE, ROUTER
        );
        console.log("New UserVaultFactory:", address(newFactory));

        // ===== 3. Permissions =====
        // FeeManager: authorize new factory
        newFM.setAuthorizedCaller(address(newFactory), true);
        // FeeManager: authorize deployer for manual configureVaultFees calls
        newFM.setAuthorizedCaller(deployer, true);

        // Registry: authorize new factory as registrar
        VaultRegistry(REGISTRY).setRegistrar(address(newFactory), true);

        // RebalanceEngine: authorize new factory
        RebalanceEngine(ENGINE).setAuthorizedCaller(address(newFactory), true);

        // ===== 4. Copy approved tokens from old factory =====
        address[] memory approved = oldFactory.getApprovedTokens();
        if (approved.length > 0) {
            newFactory.setApprovedTokensBatch(approved, true);
        }
        console.log("Approved tokens copied:", approved.length);

        // ===== 5. Set creation fee to 0 on new factory =====
        newFactory.setCreationFee(0);

        // ===== 6. Upgrade vault beacon via old factory (beacon is owned by old factory) =====
        UserVault newImpl = new UserVault();
        oldFactory.upgradeImplementation(address(newImpl));
        console.log("Beacon upgraded to new UserVault impl:", address(newImpl));

        // ===== 7. Migrate each existing vault =====
        for (uint256 i = 0; i < vaults.length; i++) {
            address v = vaults[i];
            // Point vault to new FeeManager
            UserVault(v).setFeeManager(address(newFM));

            // Read curator from old FeeManager
            FeeManager oldFM = FeeManager(payable(0x68414Dc05AFf86c23827dde7e641004f92B0A9b1));
            (, , , , , address curator, ) = oldFM.vaultFees(v);

            // Configure fees on new FeeManager with correct rates
            newFM.configureVaultFeesWithRates(v, MGMT_BPS, PERF_BPS, 8000, curator);
            console.log("Migrated vault:", v);
        }

        vm.stopBroadcast();

        console.log("\n========= MIGRATION COMPLETE =========");
        console.log("New FeeManager:       ", address(newFM));
        console.log("New UserVaultFactory: ", address(newFactory));
        console.log("Vaults migrated:     ", vaults.length);
        console.log("=======================================");
    }
}
