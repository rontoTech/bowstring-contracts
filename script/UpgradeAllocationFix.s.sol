// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Two-phase upgrade:
///   1. Deploy new UserVaultFactoryV2 impl (adds upgradeImplementation) and UUPS-upgrade the factory proxy.
///   2. Deploy new UserVault impl (allocation fix) and upgrade the beacon via the factory.
contract UpgradeAllocationFix is Script {
    address constant FACTORY_PROXY = 0x8a7A5EC2830c0EDD620f41153a881F71Ffb981B9;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // Phase 1: upgrade factory UUPS proxy so it gains upgradeImplementation()
        UserVaultFactoryV2 newFactoryImpl = new UserVaultFactoryV2();
        console.log("New UserVaultFactoryV2 impl:", address(newFactoryImpl));

        UUPSUpgradeable(FACTORY_PROXY).upgradeToAndCall(address(newFactoryImpl), "");
        console.log("Factory UUPS proxy upgraded");

        // Phase 2: deploy new UserVault impl and upgrade beacon
        UserVault newVaultImpl = new UserVault();
        console.log("New UserVault impl:", address(newVaultImpl));

        UserVaultFactoryV2(payable(FACTORY_PROXY)).upgradeImplementation(address(newVaultImpl));
        console.log("Beacon upgraded to new UserVault impl");

        // Verify
        address liveImpl = UserVaultFactoryV2(payable(FACTORY_PROXY)).implementation();
        console.log("Verified beacon implementation:", liveImpl);
        require(liveImpl == address(newVaultImpl), "impl mismatch");

        vm.stopBroadcast();
    }
}
