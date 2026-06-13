// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";

/// @notice Deploy the security-hardened UserVault implementation and upgrade the
///         LIVE V2 beacon (used by all UserVaultFactoryV2 vaults) via its owner
///         factory. The V2 factory reuses an earlier factory's UpgradeableBeacon
///         (TechnicalDebt 1.1), so the upgrade must be routed through that
///         beacon-owning factory's upgradeImplementation(), not the V2 factory.
///
///         Beacon-owning factory: 0x8a7A5EC2830c0EDD620f41153a881F71Ffb981B9
///         Live beacon:           0x104798F68Dd7319399bF717aa5bB65733E8a6874
///
///         Storage layout verified identical to the prior implementation
///         (only a constant + two pure/view helpers were added), so this is a
///         logic-only upgrade — no per-vault state migration.
interface IUpgradeableFactory {
    function upgradeImplementation(address newImplementation) external;
    function beacon() external view returns (address);
    function implementation() external view returns (address);
}

interface IBeacon {
    function implementation() external view returns (address);
}

contract UpgradeUserVaultSecurity is Script {
    address constant BEACON_OWNER_FACTORY = 0x8a7A5EC2830c0EDD620f41153a881F71Ffb981B9;
    address constant LIVE_BEACON = 0x104798F68Dd7319399bF717aa5bB65733E8a6874;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address before = IBeacon(LIVE_BEACON).implementation();
        console.log("Beacon (live):           ", LIVE_BEACON);
        console.log("Implementation (before): ", before);

        vm.startBroadcast(pk);

        UserVault newImpl = new UserVault();
        console.log("New UserVault impl:      ", address(newImpl));

        IUpgradeableFactory(BEACON_OWNER_FACTORY).upgradeImplementation(address(newImpl));

        vm.stopBroadcast();

        address afterImpl = IBeacon(LIVE_BEACON).implementation();
        console.log("Implementation (after):  ", afterImpl);
        require(afterImpl == address(newImpl), "Beacon upgrade did not take effect");
        console.log("OK: live beacon now points at the new implementation");
    }
}
