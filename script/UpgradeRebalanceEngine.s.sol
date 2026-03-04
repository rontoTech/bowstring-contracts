// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";

interface IVaultMinimal {
    function rebalanceEngine() external view returns (address);
    function setRebalanceEngine(address) external;
    function curator() external view returns (address);
}

/// @notice Deploy a new RebalanceEngine with the balance-cap fix,
///         authorize vaults, and update each vault to use it.
contract UpgradeRebalanceEngine is Script {
    address constant ROUTER = 0x969FeCdfa7b0036837AD964662d387a2dCd38d6B;
    address constant BASE_ASSET = 0x941A382852E989078e15b381f921C488a7Ca5299;
    address constant CURRENT_FACTORY = 0x9EBC3a7E417105152d83794D9e2DB5C49ff61B26;
    address constant OLD_FACTORY_1 = 0xbf3456624279ec469931aAe373238a44447D3c08;
    address constant OLD_FACTORY_2 = 0x67f0CdD4bb561BaAa3A5f1d4FE7Ede1F68E00712;

    address[] vaults;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vaults.push(0xdc77cB824A5F404E6e98D24beC0F78354449919E);
        vaults.push(0x614ABED7f34F3882379b81128baC678bD320B41A);

        vm.startBroadcast(pk);

        // 1. Deploy new engine
        RebalanceEngine newEngine = new RebalanceEngine(ROUTER, BASE_ASSET);
        console.log("New RebalanceEngine:", address(newEngine));

        // 2. Copy config from old engine
        newEngine.setMaxSlippage(100); // 1%

        // 3. Authorize callers (factories + deployer for manual ops)
        newEngine.setAuthorizedCaller(CURRENT_FACTORY, true);
        newEngine.setAuthorizedCaller(OLD_FACTORY_1, true);
        newEngine.setAuthorizedCaller(OLD_FACTORY_2, true);
        newEngine.setAuthorizedCaller(deployer, true);

        // 4. Authorize each vault and point vault → new engine
        for (uint256 i = 0; i < vaults.length; i++) {
            newEngine.setVaultAuthorized(vaults[i], true);

            // UserVault.setRebalanceEngine is time-locked by default,
            // but if timeLock == 0 it applies immediately.
            // We'll attempt it; if time-locked it will go pending.
            try IVaultMinimal(vaults[i]).setRebalanceEngine(address(newEngine)) {
                console.log("Vault updated immediately:", vaults[i]);
            } catch {
                console.log("Vault time-locked (pending):", vaults[i]);
            }
        }

        // 5. Update current factory's default engine
        UserVaultFactory(payable(CURRENT_FACTORY)).setRebalanceEngine(address(newEngine));
        console.log("Factory default engine updated");

        vm.stopBroadcast();
    }
}
