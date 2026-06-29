// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {TokenRouterUpgradeable} from "../src/rebalance/TokenRouterUpgradeable.sol";

interface IUpgradeableFactory {
    function upgradeImplementation(address newImplementation) external;
}

interface IBeacon {
    function implementation() external view returns (address);
}

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @notice Production upgrade for accounting fixes:
///         - UserVault beacon implementation for NAV/fee/share accounting.
///         - TokenRouter UUPS implementation for fresh prices and base-asset sell fills.
///
/// Optional env overrides:
///   USER_VAULT_FACTORY
///   USER_VAULT_BEACON
///   TOKEN_ROUTER_PROXY
///   TOKEN_ROUTER_MAX_PRICE_AGE
contract UpgradeAccountingEngines is Script {
    address constant DEFAULT_USER_VAULT_FACTORY = 0x8a7A5EC2830c0EDD620f41153a881F71Ffb981B9;
    address constant DEFAULT_USER_VAULT_BEACON = 0x104798F68Dd7319399bF717aa5bB65733E8a6874;
    address constant DEFAULT_TOKEN_ROUTER_PROXY = 0x9fA2D96Ef53912162f3F8bcd73620Bf93D39808D;
    bytes32 constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address userVaultFactory = vm.envOr("USER_VAULT_FACTORY", DEFAULT_USER_VAULT_FACTORY);
        address userVaultBeacon = vm.envOr("USER_VAULT_BEACON", DEFAULT_USER_VAULT_BEACON);
        address tokenRouterProxy = vm.envOr("TOKEN_ROUTER_PROXY", DEFAULT_TOKEN_ROUTER_PROXY);
        uint256 maxPriceAge = vm.envOr("TOKEN_ROUTER_MAX_PRICE_AGE", uint256(7 days));

        address vaultImplBefore = IBeacon(userVaultBeacon).implementation();
        address routerImplBefore = _implementationOf(tokenRouterProxy);

        console.log("UserVault factory:        ", userVaultFactory);
        console.log("UserVault beacon:         ", userVaultBeacon);
        console.log("UserVault impl before:    ", vaultImplBefore);
        console.log("TokenRouter proxy:        ", tokenRouterProxy);
        console.log("TokenRouter impl before:  ", routerImplBefore);
        console.log("TokenRouter max price age:", maxPriceAge);

        vm.startBroadcast(pk);

        UserVault newVaultImpl = new UserVault();
        console.log("New UserVault impl:       ", address(newVaultImpl));
        IUpgradeableFactory(userVaultFactory).upgradeImplementation(address(newVaultImpl));

        TokenRouterUpgradeable newRouterImpl = new TokenRouterUpgradeable();
        console.log("New TokenRouter impl:     ", address(newRouterImpl));
        IUUPS(tokenRouterProxy).upgradeToAndCall(
            address(newRouterImpl),
            abi.encodeCall(TokenRouterUpgradeable.initializePriceFreshness, (maxPriceAge))
        );

        vm.stopBroadcast();

        address vaultImplAfter = IBeacon(userVaultBeacon).implementation();
        address routerImplAfter = _implementationOf(tokenRouterProxy);
        uint256 liveMaxPriceAge = TokenRouterUpgradeable(tokenRouterProxy).maxPriceAge();

        console.log("UserVault impl after:     ", vaultImplAfter);
        console.log("TokenRouter impl after:   ", routerImplAfter);
        console.log("Live max price age:       ", liveMaxPriceAge);

        require(vaultImplAfter == address(newVaultImpl), "UserVault beacon upgrade failed");
        require(routerImplAfter == address(newRouterImpl), "TokenRouter upgrade failed");
        require(liveMaxPriceAge == maxPriceAge, "TokenRouter freshness init failed");
    }

    function _implementationOf(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }
}
