// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TradeDelegateProxy} from "../src/core/TradeDelegateProxy.sol";

interface IVaultRegistry {
    function getAllVaults() external view returns (VaultInfo[] memory);
}

interface IUserVault {
    function setDelegate(address delegate, bool authorized) external;
    function curator() external view returns (address);
    function delegates(address) external view returns (bool);
}

struct VaultInfo {
    address vault;
    uint8 vaultType;
    address curator;
    string metadataURI;
    uint256 createdAt;
    bool active;
}

/// @notice Deploy TradeDelegateProxy and register it as delegate on all protocol vaults.
///
///   ENV vars:
///     PRIVATE_KEY          — deployer/owner key
///     TRADE_EXECUTOR_KEY   — private key for the backend trade signer (authorized on proxy)
///     VAULT_REGISTRY       — VaultRegistry address
///
///   forge script script/DeployTradeDelegateProxy.s.sol \
///       --rpc-url robinhood_testnet --broadcast
contract DeployTradeDelegateProxy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address tradeExecutor = vm.envOr("TRADE_EXECUTOR_ADDRESS", deployer);
        address registryAddr = vm.envAddress("VAULT_REGISTRY");

        vm.startBroadcast(pk);

        // 1. Deploy TradeDelegateProxy
        TradeDelegateProxy proxy = new TradeDelegateProxy(deployer);
        console.log("TradeDelegateProxy deployed:", address(proxy));

        // 2. Authorize the backend trade signer
        proxy.setAuthorizedSigner(tradeExecutor, true);
        console.log("Trade executor authorized:", tradeExecutor);

        // Also authorize the deployer as signer for manual operations
        if (tradeExecutor != deployer) {
            proxy.setAuthorizedSigner(deployer, true);
            console.log("Deployer also authorized as signer");
        }

        // 3. Register the proxy as delegate on all vaults we curate
        IVaultRegistry registry = IVaultRegistry(registryAddr);
        VaultInfo[] memory allVaults = registry.getAllVaults();

        uint256 delegated = 0;
        uint256 skipped = 0;
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (!allVaults[i].active) continue;
            if (allVaults[i].curator != deployer) {
                skipped++;
                continue;
            }

            IUserVault vault = IUserVault(allVaults[i].vault);
            if (vault.delegates(address(proxy))) {
                console.log("  Already delegated:", allVaults[i].vault);
                continue;
            }

            vault.setDelegate(address(proxy), true);
            delegated++;
            console.log("  Delegated:", allVaults[i].vault);
        }

        console.log("Delegated on", delegated, "vaults");
        console.log("Skipped", skipped, "non-curator vaults (require UI-based migration)");

        vm.stopBroadcast();
    }
}
