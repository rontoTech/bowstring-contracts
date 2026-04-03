// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Transfer ownership of all protocol singletons to a Gnosis Safe multisig.
///         The multisig becomes the cold admin — contract upgrades, deactivation,
///         fee changes all require multi-party approval.
///
///   ENV vars:
///     PRIVATE_KEY                — current owner
///     MULTISIG                   — Gnosis Safe address
///     TOKEN_ROUTER_PROXY         — TokenRouter proxy
///     STOCK_FACTORY_PROXY        — StockTokenFactory proxy
///     VAULT_REGISTRY_PROXY       — VaultRegistry proxy
///     FEE_MANAGER_PROXY          — FeeManager proxy
///     REBALANCE_ENGINE_PROXY     — RebalanceEngine proxy
///     USER_VAULT_FACTORY         — UserVaultFactory
///
///   forge script script/TransferToMultisig.s.sol \
///       --rpc-url robinhood_testnet --broadcast
///
///   WARNING: This is irreversible. The deployer key will lose owner access.
///   Test on a fork first: --fork-url robinhood_testnet
contract TransferToMultisig is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address multisig = vm.envAddress("MULTISIG");

        address[] memory contracts = new address[](6);
        string[] memory labels = new string[](6);

        contracts[0] = vm.envAddress("TOKEN_ROUTER_PROXY");
        labels[0] = "TokenRouter";
        contracts[1] = vm.envAddress("STOCK_FACTORY_PROXY");
        labels[1] = "StockTokenFactory";
        contracts[2] = vm.envAddress("VAULT_REGISTRY_PROXY");
        labels[2] = "VaultRegistry";
        contracts[3] = vm.envAddress("FEE_MANAGER_PROXY");
        labels[3] = "FeeManager";
        contracts[4] = vm.envAddress("REBALANCE_ENGINE_PROXY");
        labels[4] = "RebalanceEngine";
        contracts[5] = vm.envAddress("USER_VAULT_FACTORY");
        labels[5] = "UserVaultFactory";

        console.log("Transferring to multisig:", multisig);

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < contracts.length; i++) {
            address current = IOwnable(contracts[i]).owner();
            console.log(labels[i], contracts[i], "current owner:", current);

            IOwnable(contracts[i]).transferOwnership(multisig);
            console.log("  -> transferred to", multisig);
        }

        vm.stopBroadcast();

        console.log("\nAll contracts transferred. Deployer key is no longer owner.");
        console.log("The multisig must accept ownership if using OZ Ownable2Step.");
    }
}
