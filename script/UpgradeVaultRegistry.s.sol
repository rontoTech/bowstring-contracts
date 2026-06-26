// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultRegistryUpgradeable} from "../src/core/VaultRegistryUpgradeable.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";

interface ILegacyVaultRegistry {
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

/// @notice Replace the non-upgradeable current registry with a UUPS registry.
///
/// The current registry at 0x3848...0795 cannot be upgraded in place and does
/// not expose updateVaultMetadata(address,string). This script deploys a new
/// upgradeable registry, copies all known vault records from the current and
/// old registries, authorizes the active factory, and repoints the factory to
/// the new registry for future strategy creation.
contract UpgradeVaultRegistry is Script {
    address internal constant CURRENT_REGISTRY = 0x38485146d0D1E0c700ddBf61206188CFaC170795;
    address internal constant OLD_REGISTRY = 0xBe4447B2381928614a91cEf4Bac2c34CeF539a22;
    address payable internal constant USER_VAULT_FACTORY =
        payable(0xD5210C45C7B65E4D9Eed53391D2199a2aB9DcF57);

    uint256 internal constant CHUNK_SIZE = 20;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        ILegacyVaultRegistry.VaultInfo[] memory currentVaults =
            ILegacyVaultRegistry(CURRENT_REGISTRY).getAllVaults();
        ILegacyVaultRegistry.VaultInfo[] memory oldVaults =
            ILegacyVaultRegistry(OLD_REGISTRY).getAllVaults();

        console.log("Deployer:", deployer);
        console.log("Current registry:", CURRENT_REGISTRY);
        console.log("Old registry:", OLD_REGISTRY);
        console.log("Factory:", USER_VAULT_FACTORY);
        console.log("Current registry vaults:", currentVaults.length);
        console.log("Old registry vaults:", oldVaults.length);

        vm.startBroadcast(pk);

        VaultRegistryUpgradeable implementation = new VaultRegistryUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(VaultRegistryUpgradeable.initialize, (deployer))
        );
        VaultRegistryUpgradeable newRegistry =
            VaultRegistryUpgradeable(address(proxy));

        console.log("New registry implementation:", address(implementation));
        console.log("New registry proxy:", address(newRegistry));

        _bulkRegister(newRegistry, currentVaults, "current");
        _bulkRegister(newRegistry, oldVaults, "old");

        newRegistry.setRegistrar(USER_VAULT_FACTORY, true);
        newRegistry.setRegistrar(deployer, true);
        UserVaultFactoryV2(USER_VAULT_FACTORY).setRegistry(address(newRegistry));

        vm.stopBroadcast();

        console.log("Registry upgrade complete.");
        console.log("New VAULT_REGISTRY:", address(newRegistry));
    }

    function _bulkRegister(
        VaultRegistryUpgradeable newRegistry,
        ILegacyVaultRegistry.VaultInfo[] memory vaults,
        string memory label
    ) internal {
        for (uint256 start = 0; start < vaults.length; start += CHUNK_SIZE) {
            uint256 end = start + CHUNK_SIZE;
            if (end > vaults.length) end = vaults.length;

            VaultRegistryUpgradeable.VaultInfo[] memory chunk =
                new VaultRegistryUpgradeable.VaultInfo[](end - start);
            for (uint256 i = start; i < end; i++) {
                ILegacyVaultRegistry.VaultInfo memory v = vaults[i];
                chunk[i - start] = VaultRegistryUpgradeable.VaultInfo({
                    vault: v.vault,
                    vaultType: VaultRegistryUpgradeable.VaultType(v.vaultType),
                    curator: v.curator,
                    metadataURI: v.metadataURI,
                    createdAt: v.createdAt,
                    active: v.active
                });
            }

            newRegistry.bulkRegister(chunk);
            console.log("Registered registry chunk");
            console.log(label);
            console.log(start);
            console.log(end);
        }
    }
}
