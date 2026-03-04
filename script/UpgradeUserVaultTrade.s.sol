// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";

contract UpgradeUserVaultTrade is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address[3] memory factories = [
            0x9EBC3a7E417105152d83794D9e2DB5C49ff61B26,
            0xbf3456624279ec469931aAe373238a44447D3c08,
            0x67f0CdD4bb561BaAa3A5f1d4FE7Ede1F68E00712
        ];

        vm.startBroadcast(pk);

        UserVault newImpl = new UserVault();
        console.log("New UserVault impl:", address(newImpl));

        for (uint256 i = 0; i < factories.length; i++) {
            UserVaultFactory(payable(factories[i])).upgradeImplementation(address(newImpl));
            console.log("Upgraded factory beacon:", factories[i]);
        }

        vm.stopBroadcast();
    }
}
