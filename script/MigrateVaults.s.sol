// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {StockTokenFactoryUpgradeable} from "../src/tokens/StockTokenFactoryUpgradeable.sol";
import {StockTokenUpgradeable} from "../src/tokens/StockTokenUpgradeable.sol";
import {TokenRouterUpgradeable} from "../src/rebalance/TokenRouterUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../src/core/VaultRegistryUpgradeable.sol";
import {FeeManagerUpgradeable} from "../src/core/FeeManagerUpgradeable.sol";

interface IVaultRegistry {
    struct VaultInfo {
        address vault;
        uint8 vaultType;
        address curator;
        string metadataURI;
        uint256 createdAt;
        bool active;
    }
    function getAllVaults() external view returns (VaultInfo[] memory);
}

interface IUserVault {
    function getHeldTokens() external view returns (address[] memory);
    function curator() external view returns (address);
    function name() external view returns (string memory);
    function setRebalanceEngine(address) external;
    function setTokenRouter(address) external;
    function setFeeManager(address) external;
    function migrateToken(address oldToken, address newToken) external;
}

/// @title MigrateVaults
/// @notice Upgrades existing vault beacons, migrates stock token addresses,
///         and points vaults at new infrastructure.
///
///         Prerequisites:
///           - DeployUpgradeable.s.sol has been run (new infra deployed)
///           - Env vars set: PRIVATE_KEY, plus the addresses below
///
///         This script:
///           1. Deploys new UserVault implementation with migrateToken()
///           2. Upgrades all 3 old factory beacons
///           3. For each vault: deploys matching new tokens, mints balances, migrates
///           4. Updates engine/router/feeManager on each vault
///           5. Bulk-registers vaults on new VaultRegistry
contract MigrateVaults is Script {
    // --- Old infrastructure (hardcode or read from env) ---
    address constant OLD_REGISTRY = 0xf61b0b073105c8dDAb1adeE13b17E86122D9a60d;
    address constant TILT_USDC = 0x941A382852E989078e15b381f921C488a7Ca5299;

    // Old factory beacons to upgrade
    address constant FACTORY_1 = 0x9EBC3a7E417105152d83794D9e2DB5C49ff61B26;
    address constant FACTORY_2 = 0xbf3456624279ec469931aAe373238a44447D3c08;
    address constant FACTORY_3 = 0x67f0CdD4bb561BaAa3A5f1d4FE7Ede1F68E00712;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // New infrastructure addresses (set via env or hardcode after deploy)
        address newRouter = vm.envAddress("NEW_ROUTER");
        address newEngine = vm.envAddress("NEW_ENGINE");
        address newFeeManager = vm.envAddress("NEW_FEE_MANAGER");
        address newRegistry = vm.envAddress("NEW_REGISTRY");
        address newStockFactory = vm.envAddress("NEW_STOCK_FACTORY");

        console.log("Deployer:", deployer);
        console.log("New Router:", newRouter);
        console.log("New Engine:", newEngine);

        vm.startBroadcast(deployerPrivateKey);

        // ===== 1. Deploy new UserVault implementation =====
        UserVault newVaultImpl = new UserVault();
        console.log("New UserVault implementation:", address(newVaultImpl));

        // ===== 2. Upgrade all old factory beacons =====
        _upgradeFactory(FACTORY_1, address(newVaultImpl));
        _upgradeFactory(FACTORY_2, address(newVaultImpl));
        _upgradeFactory(FACTORY_3, address(newVaultImpl));

        // ===== 3. Read all vaults from old registry =====
        IVaultRegistry.VaultInfo[] memory vaults = IVaultRegistry(OLD_REGISTRY).getAllVaults();
        console.log("Total vaults to migrate:", vaults.length);

        StockTokenFactoryUpgradeable factory = StockTokenFactoryUpgradeable(newStockFactory);
        TokenRouterUpgradeable router = TokenRouterUpgradeable(newRouter);

        // ===== 4. Migrate each vault =====
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!vaults[i].active) continue;
            address vaultAddr = vaults[i].vault;

            _migrateVault(
                vaultAddr, factory, router, newEngine, newRouter, newFeeManager
            );
        }

        // ===== 5. Bulk-register vaults on new registry =====
        VaultRegistryUpgradeable newReg = VaultRegistryUpgradeable(newRegistry);
        VaultRegistryUpgradeable.VaultInfo[] memory regInfos =
            new VaultRegistryUpgradeable.VaultInfo[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            regInfos[i] = VaultRegistryUpgradeable.VaultInfo({
                vault: vaults[i].vault,
                vaultType: VaultRegistryUpgradeable.VaultType(vaults[i].vaultType),
                curator: vaults[i].curator,
                metadataURI: vaults[i].metadataURI,
                createdAt: vaults[i].createdAt,
                active: vaults[i].active
            });
        }
        newReg.bulkRegister(regInfos);
        console.log("Bulk-registered vaults on new registry");

        vm.stopBroadcast();
        console.log("\n========= MIGRATION COMPLETE =========");
    }

    function _upgradeFactory(address factoryAddr, address newImpl) internal {
        try UserVaultFactory(payable(factoryAddr)).upgradeImplementation(newImpl) {
            console.log("  Upgraded factory beacon:", factoryAddr);
        } catch {
            console.log("  SKIP factory (not owner?):", factoryAddr);
        }
    }

    function _migrateVault(
        address vaultAddr,
        StockTokenFactoryUpgradeable factory,
        TokenRouterUpgradeable router,
        address newEngine,
        address newRouter,
        address newFeeManager
    ) internal {
        string memory vaultName = IUserVault(vaultAddr).name();
        console.log("\nMigrating vault:", vaultName, vaultAddr);

        address[] memory held = IUserVault(vaultAddr).getHeldTokens();

        for (uint256 j = 0; j < held.length; j++) {
            address oldToken = held[j];
            uint256 balance = IERC20(oldToken).balanceOf(vaultAddr);
            if (balance == 0) continue;

            string memory symbol;
            try StockTokenUpgradeable(oldToken).symbol() returns (string memory s) {
                symbol = s;
            } catch {
                console.log("  SKIP: cannot read symbol for", oldToken);
                continue;
            }

            address newToken = factory.tokenBySymbol(symbol);
            if (newToken == address(0)) {
                uint256 price = router.tokenPrices(oldToken);
                if (price == 0) price = 1e18;
                newToken = factory.createStockToken(
                    string.concat("Tilt ", symbol), symbol, price
                );
                router.setTokenPrice(newToken, price);
                router.setPairSupported(TILT_USDC, newToken, true);
                console.log("  Deployed new token:", symbol, newToken);
            }

            StockTokenUpgradeable(newToken).mint(vaultAddr, balance);
            console.log("  Minted", balance, symbol, "to vault");

            IUserVault(vaultAddr).migrateToken(oldToken, newToken);
            console.log("  Migrated token accounting:", symbol);
        }

        IUserVault(vaultAddr).setRebalanceEngine(newEngine);
        IUserVault(vaultAddr).setTokenRouter(newRouter);
        IUserVault(vaultAddr).setFeeManager(newFeeManager);
        console.log("  Updated engine/router/feeManager");
    }
}
