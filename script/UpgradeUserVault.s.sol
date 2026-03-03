// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";

/// @notice Deploy a new UserVault implementation and upgrade the beacon via the factory.
contract UpgradeUserVault is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address payable factory = payable(0x9EBC3a7E417105152d83794D9e2DB5C49ff61B26);

        vm.startBroadcast(deployerPrivateKey);

        UserVault newImpl = new UserVault();
        console.log("New UserVault implementation:", address(newImpl));

        UserVaultFactory(factory).upgradeImplementation(address(newImpl));
        console.log("Beacon upgraded successfully");

        vm.stopBroadcast();
    }
}
