// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Deploy a new UserVault implementation with delegate support and
///         upgrade the beacon. Then authorize the backend wallet as delegate
///         on specified vaults.
///
/// Usage:
///   BACKEND_WALLET=0x... BEACON=0x... VAULTS=0xA,0xB forge script \
///     script/UpgradeAndDelegate.s.sol --rpc-url $RPC_URL --broadcast
contract UpgradeAndDelegate is Script {
    function run() external {
        address backendWallet = vm.envAddress("BACKEND_WALLET");
        address beaconAddr = vm.envAddress("BEACON");
        address[] memory vaults = _parseAddressList(vm.envString("VAULTS"));

        vm.startBroadcast();

        UserVault newImpl = new UserVault();
        UpgradeableBeacon(beaconAddr).upgradeTo(address(newImpl));
        console.log("Beacon upgraded to:", address(newImpl));

        for (uint256 i = 0; i < vaults.length; i++) {
            UserVault(vaults[i]).setDelegate(backendWallet, true);
            console.log("Delegate set on vault:", vaults[i]);
        }

        vm.stopBroadcast();
    }

    function _parseAddressList(string memory csv) internal pure returns (address[] memory) {
        bytes memory b = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }
        address[] memory addrs = new address[](count);
        uint256 start = 0;
        uint256 idx = 0;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = b[j];
                }
                addrs[idx] = vm.parseAddress(string(slice));
                idx++;
                start = i + 1;
            }
        }
        return addrs;
    }
}
