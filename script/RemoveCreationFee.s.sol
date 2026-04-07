// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract RemoveCreationFeeAndAddSymbolExists is Script {
    address constant FACTORY_PROXY = 0xD5210C45C7B65E4D9Eed53391D2199a2aB9DcF57;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. Deploy new UserVaultFactoryV2 impl
        UserVaultFactoryV2 newFactoryImpl = new UserVaultFactoryV2();
        console.log("New UserVaultFactoryV2 impl:", address(newFactoryImpl));

        // 2. Upgrade UUPS proxy
        UUPSUpgradeable(FACTORY_PROXY).upgradeToAndCall(address(newFactoryImpl), "");
        console.log("Factory UUPS proxy upgraded");

        // 3. Call setCreationFee(0) on the proxy to update existing state
        UserVaultFactoryV2(payable(FACTORY_PROXY)).setCreationFee(0);
        console.log("Creation fee set to 0");

        vm.stopBroadcast();
    }
}
