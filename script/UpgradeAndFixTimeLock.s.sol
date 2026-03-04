// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";

interface IVaultTimeLock {
    function setWeightChangeTimeLock(uint256) external;
    function setMinRebalanceInterval(uint256) external;
    function weightChangeTimeLock() external view returns (uint256);
    function hasPendingWeights() external view returns (bool);
}

contract UpgradeAndFixTimeLock is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address[3] memory factories = [
            0x9EBC3a7E417105152d83794D9e2DB5C49ff61B26,
            0xbf3456624279ec469931aAe373238a44447D3c08,
            0x67f0CdD4bb561BaAa3A5f1d4FE7Ede1F68E00712
        ];

        address[2] memory vaults = [
            0xdc77cB824A5F404E6e98D24beC0F78354449919E,
            0x614ABED7f34F3882379b81128baC678bD320B41A
        ];

        vm.startBroadcast(pk);

        // 1. Deploy new UserVault implementation
        UserVault newImpl = new UserVault();
        console.log("New UserVault impl:", address(newImpl));

        // 2. Upgrade all three factory beacons
        for (uint256 i = 0; i < factories.length; i++) {
            UserVaultFactory(payable(factories[i])).upgradeImplementation(address(newImpl));
            console.log("Upgraded factory beacon:", factories[i]);
        }

        // 3. Set weightChangeTimeLock = 0 and minRebalanceInterval = 0 on all vaults
        for (uint256 i = 0; i < vaults.length; i++) {
            IVaultTimeLock(vaults[i]).setWeightChangeTimeLock(0);
            IVaultTimeLock(vaults[i]).setMinRebalanceInterval(0);
            console.log("TimeLock=0, RebalInterval=0:", vaults[i]);
        }

        vm.stopBroadcast();
    }
}
