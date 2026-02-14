// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {FeeManager} from "../src/core/FeeManager.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";

/// @title UpgradeFactory
/// @notice Deploy new FeeManager + VaultFactory with fixed seed deposit logic.
///         - FeeManager: authorized callers (deployer stays owner, factory is authorized)
///         - VaultFactory: proper seed deposit via vault.deposit() + dead shares
///         - UserVault: initial weights set in constructor
contract UpgradeFactory is Script {
    // Existing deployed addresses (DO NOT redeploy these)
    address constant BOW_USDC = 0xF41c1d33C0c89456c68E5Af491A0eC65f1BEf6bA;
    address constant VAULT_REGISTRY = 0x7047fe5a8708225317154d91DDE4e2Ef2A6b362a;
    address constant PORTFOLIO_ORACLE = 0x09a74f358817bD419e5c112b21f881e3e486D073;
    address constant REBALANCE_ENGINE = 0x660cb5D24f9ECc42ED86Cfc5621d524B4Ad899fe;
    address constant TOKEN_ROUTER = 0x960773685f319b4E7BCaEf3306F5aE954efc57b7;
    address constant STOCK_TOKEN_FACTORY = 0x29Fd20648f0cafC3E1dd8c46f2cE965fe5587e56;

    // Stock tokens (from prior deployment)
    address constant bowAAPL = 0xc6e2378240Fc4e62D3BE105D7D506d02C6bf632a;
    address constant bowMSFT = 0x4b4548d9C35f4549d217D598B8a1f726f34f5A64;
    address constant bowNVDA = 0x5E6CB5e35A0B89100DE9b5A90C0C5a9A13F14249;
    address constant bowGOOGL = 0xF29B8A1AcC884c46c58fD3bB6b7f0b42f1eD2b91;
    address constant bowAMZN = 0xF73F5ff6548a9270723e4EaF7D26B1a41C4e00C5;
    address constant bowTSLA = 0x00Ef5E5C3C8C4c27E8FE8AB93ed0E7e5ef2f5836;
    address constant bowMETA = 0x3f2D2EE00a95E905a20662646F39a9f1F2C8D4f0;
    address constant bowJPM = 0xb3A7C5E08DA0bba98E78A0A7E7DB0d57E0990F0a;
    address constant bowV = 0x116BeE4687C78d06c107e71B09A7C09EADA68d1d;
    address constant bowJNJ = 0x34aDBcB6c68Ec10b16FcafBb0261a77BB4B89cE7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // ========== 1. Deploy new FeeManager ==========
        FeeManager newFeeManager = new FeeManager(deployer); // deployer is treasury
        address feeManagerAddr = address(newFeeManager);
        console.log("New FeeManager:", feeManagerAddr);

        // Set all fees to 0 for testnet simplicity
        newFeeManager.setDefaultFees(0, 0, 0, 0);

        // ========== 2. Deploy new VaultFactory ==========
        VaultFactory newFactory = new VaultFactory(
            BOW_USDC,
            feeManagerAddr,
            VAULT_REGISTRY,
            REBALANCE_ENGINE,
            TOKEN_ROUTER,
            PORTFOLIO_ORACLE
        );
        address factoryAddr = address(newFactory);
        console.log("New VaultFactory:", factoryAddr);

        // ========== 3. Wire permissions ==========

        // FeeManager: authorize factory as caller (deployer remains owner)
        newFeeManager.setAuthorizedCaller(factoryAddr, true);
        console.log("FeeManager: authorized factory");

        // Registry: authorize new factory as registrar
        VaultRegistry(VAULT_REGISTRY).setRegistrar(factoryAddr, true);
        console.log("Registry: authorized new factory");

        // ========== 4. Approve tokens in new factory ==========
        address[10] memory stockTokens = [
            bowAAPL, bowMSFT, bowNVDA, bowGOOGL, bowAMZN,
            bowTSLA, bowMETA, bowJPM, bowV, bowJNJ
        ];

        for (uint256 i = 0; i < stockTokens.length; i++) {
            newFactory.setApprovedToken(stockTokens[i], true);
        }
        console.log("Factory: approved 10 stock tokens");

        vm.stopBroadcast();

        console.log("\n========== UPGRADE COMPLETE ==========");
        console.log("New FeeManager:    ", feeManagerAddr);
        console.log("New VaultFactory:  ", factoryAddr);
        console.log("=======================================");
    }
}
