// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TokenRouterUpgradeable} from "../src/rebalance/TokenRouterUpgradeable.sol";
import {StockTokenFactoryUpgradeable} from "../src/tokens/StockTokenFactoryUpgradeable.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

/// @notice Upgrade TokenRouter and StockTokenFactory to support authorized
///         pricers/deployers, then register the oracle wallet.
///
///   ENV vars:
///     PRIVATE_KEY              — current contract owner
///     TOKEN_ROUTER_PROXY       — deployed proxy address
///     STOCK_FACTORY_PROXY      — deployed proxy address
///     ORACLE_WALLET            — new hot wallet for price/token ops (optional, skipped if unset)
///
///   forge script script/UpgradeRouterAndFactory.s.sol \
///       --rpc-url robinhood_testnet --broadcast
contract UpgradeRouterAndFactory is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address routerProxy = vm.envAddress("TOKEN_ROUTER_PROXY");
        address factoryProxy = vm.envAddress("STOCK_FACTORY_PROXY");
        address oracleWallet = vm.envOr("ORACLE_WALLET", address(0));

        vm.startBroadcast(pk);

        // 1. Deploy new TokenRouter implementation and upgrade proxy
        TokenRouterUpgradeable newRouterImpl = new TokenRouterUpgradeable();
        console.log("New TokenRouter impl:", address(newRouterImpl));
        IUUPS(routerProxy).upgradeToAndCall(address(newRouterImpl), "");
        console.log("TokenRouter proxy upgraded");

        // 2. Deploy new StockTokenFactory implementation and upgrade proxy
        StockTokenFactoryUpgradeable newFactoryImpl = new StockTokenFactoryUpgradeable();
        console.log("New StockTokenFactory impl:", address(newFactoryImpl));
        IUUPS(factoryProxy).upgradeToAndCall(address(newFactoryImpl), "");
        console.log("StockTokenFactory proxy upgraded");

        // 3. Register oracle wallet as authorized pricer + deployer
        if (oracleWallet != address(0)) {
            TokenRouterUpgradeable(routerProxy).setAuthorizedPricer(oracleWallet, true);
            console.log("Oracle wallet authorized as pricer on TokenRouter");

            StockTokenFactoryUpgradeable(factoryProxy).setAuthorizedDeployer(oracleWallet, true);
            console.log("Oracle wallet authorized as deployer on StockTokenFactory");
        } else {
            console.log("ORACLE_WALLET not set, skipping authorization");
        }

        vm.stopBroadcast();
    }
}
