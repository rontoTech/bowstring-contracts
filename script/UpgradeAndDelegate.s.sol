// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";

/// @notice Deploy a new UserVault implementation with delegate support and
///         upgrade the beacon via the factory (the beacon is owned by the factory).
///
/// Usage (beacon upgrade — run as factory owner):
///   FACTORY=0x... forge script script/UpgradeAndDelegate.s.sol \
///     --rpc-url $RPC_URL --broadcast --private-key $DEPLOYER_KEY
contract UpgradeAndDelegate is Script {
    function run() external {
        address payable factory = payable(vm.envAddress("FACTORY"));

        vm.startBroadcast();

        UserVault newImpl = new UserVault();
        console.log("New UserVault implementation:", address(newImpl));

        UserVaultFactory(factory).upgradeImplementation(address(newImpl));
        console.log("Beacon upgraded via factory:", factory);

        vm.stopBroadcast();
    }
}
