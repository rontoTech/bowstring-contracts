// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {FeeManager} from "../src/core/FeeManager.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploy UserVaultFactoryV2, initialize it, and authorize it.
///
///   ENV vars:
///     PRIVATE_KEY          — deployer/owner key
///     TRADE_DELEGATE_PROXY — address of the deployed TradeDelegateProxy
///     OLD_FACTORY          — address of the existing UserVaultFactory
///     VAULT_REGISTRY       — address of VaultRegistry
///     FEE_MANAGER          — address of FeeManager
///     REBALANCE_ENGINE     — address of RebalanceEngine
///
///   forge script script/UpgradeToV2.s.sol \
///       --rpc-url robinhood_testnet --broadcast
contract UpgradeToV2 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        
        address tradeDelegateProxy = vm.envAddress("TRADE_DELEGATE_PROXY");
        address oldFactoryAddr = vm.envAddress("OLD_FACTORY");
        address registryAddr = vm.envAddress("VAULT_REGISTRY");
        address feeManagerAddr = vm.envAddress("FEE_MANAGER");
        address rebalanceEngineAddr = vm.envAddress("REBALANCE_ENGINE");

        UserVaultFactory oldFactory = UserVaultFactory(payable(oldFactoryAddr));
        address beacon = address(oldFactory.beacon());
        address baseAsset = oldFactory.baseAsset();
        address tokenRouter = oldFactory.tokenRouter();

        vm.startBroadcast(pk);

        // 1. Deploy V2 implementation
        UserVaultFactoryV2 impl = new UserVaultFactoryV2();
        console.log("UserVaultFactoryV2 implementation deployed at:", address(impl));

        // 2. Deploy Proxy and initialize
        bytes memory initData = abi.encodeCall(
            UserVaultFactoryV2.initialize,
            (
                beacon,
                baseAsset,
                feeManagerAddr,
                registryAddr,
                rebalanceEngineAddr,
                tokenRouter,
                tradeDelegateProxy
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        UserVaultFactoryV2 newFactory = UserVaultFactoryV2(payable(address(proxy)));
        console.log("UserVaultFactoryV2 proxy deployed at:", address(newFactory));

        // 3. Migrate approved tokens
        address[] memory approvedTokens = oldFactory.getApprovedTokens();
        if (approvedTokens.length > 0) {
            newFactory.setApprovedTokensBatch(approvedTokens, true);
            console.log("Migrated", approvedTokens.length, "approved tokens");
        }

        // 4. Authorize new factory
        VaultRegistry(registryAddr).setRegistrar(address(newFactory), true);
        console.log("Authorized new factory on VaultRegistry");

        FeeManager(payable(feeManagerAddr)).setAuthorizedCaller(address(newFactory), true);
        console.log("Authorized new factory on FeeManager");

        RebalanceEngine(rebalanceEngineAddr).setAuthorizedCaller(address(newFactory), true);
        console.log("Authorized new factory on RebalanceEngine");

        vm.stopBroadcast();
    }
}