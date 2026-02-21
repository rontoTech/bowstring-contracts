// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {PoliticianVaultFactory} from "../src/core/PoliticianVaultFactory.sol";
import {PoliticianVault} from "../src/core/PoliticianVault.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {FeeManager} from "../src/core/FeeManager.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployNewVaults
/// @notice Deploys a new PoliticianVaultFactory with Beacon Proxy architecture.
///         Creates UpgradeableBeacon + implementation, then spawns all 6
///         politician vaults as BeaconProxy instances. Reuses existing infrastructure.
contract DeployNewVaults is Script {
    // Existing infrastructure on Robinhood L2 Testnet
    address constant TILT_USDC       = 0x941A382852E989078e15b381f921C488a7Ca5299;
    address constant FEE_MANAGER     = 0x68414Dc05AFf86c23827dde7e641004f92B0A9b1;
    address constant VAULT_REGISTRY  = 0xf61b0b073105c8dDAb1adeE13b17E86122D9a60d;
    address constant ORACLE          = 0xF59e20843905b52dd40029b470ccc86c2D33D478;
    address constant ENGINE          = 0x1Dd95799fB7fC020e3e1d4a6a09Dd9bBE91Efa2c;
    address constant ROUTER          = 0x7Ee4a6b088797762ab6D99fD5C59dBa0582D8E77;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ========== 0. Ensure base asset price is set in router ==========
        MockTokenRouter routerContract = MockTokenRouter(ROUTER);
        if (routerContract.getTokenPrice(TILT_USDC) == 0) {
            routerContract.setTokenPrice(TILT_USDC, 1e18); // $1.00
            console.log("Set tiltUSDC price to $1.00 on router");
        }

        // ========== 1. Deploy new PoliticianVaultFactory ==========
        PoliticianVaultFactory factory = new PoliticianVaultFactory(
            TILT_USDC, FEE_MANAGER, VAULT_REGISTRY, ENGINE, ROUTER, ORACLE
        );
        console.log("New PoliticianVaultFactory:", address(factory));
        console.log("  Beacon:", address(factory.beacon()));
        console.log("  Implementation:", factory.implementation());

        // ========== 2. Configure permissions for new factory ==========
        VaultRegistry(VAULT_REGISTRY).setRegistrar(address(factory), true);
        FeeManager(payable(FEE_MANAGER)).setAuthorizedCaller(address(factory), true);
        RebalanceEngine(ENGINE).setAuthorizedCaller(address(factory), true);

        // ========== 3. Create all 6 politician vaults ==========
        uint256 seedPerVault = 1000e6; // 1,000 tiltUSDC each
        uint256 totalSeed = seedPerVault * 6;

        IERC20(TILT_USDC).approve(address(factory), totalSeed);

        // Pelosi
        bytes32 pelosiId = keccak256("nancy-pelosi");
        address pelosiVault = factory.createPoliticianVault(
            pelosiId, "Tilt Pelosi Index", "tiltPELOSI", address(0), "ipfs://pelosi-vault", seedPerVault
        );
        PoliticianVault(pelosiVault).setKeeper(deployer, true);
        console.log("tiltPELOSI:", pelosiVault);

        // Tuberville
        bytes32 tubeId = keccak256("tommy-tuberville");
        address tubeVault = factory.createPoliticianVault(
            tubeId, "Tilt Tuberville Index", "tiltTUBE", address(0), "ipfs://tuberville-vault", seedPerVault
        );
        PoliticianVault(tubeVault).setKeeper(deployer, true);
        console.log("tiltTUBE:", tubeVault);

        // Crenshaw
        bytes32 crenId = keccak256("dan-crenshaw");
        address crenVault = factory.createPoliticianVault(
            crenId, "Tilt Crenshaw Index", "tiltCREN", address(0), "ipfs://crenshaw-vault", seedPerVault
        );
        PoliticianVault(crenVault).setKeeper(deployer, true);
        console.log("tiltCREN:", crenVault);

        // McCaul
        bytes32 mccaulId = keccak256("michael-mccaul");
        address mccaulVault = factory.createPoliticianVault(
            mccaulId, "Tilt McCaul Index", "tiltMCCAUL", address(0), "ipfs://mccaul-vault", seedPerVault
        );
        PoliticianVault(mccaulVault).setKeeper(deployer, true);
        console.log("tiltMCCAUL:", mccaulVault);

        // Wyden
        bytes32 wydenId = keccak256("ron-wyden");
        address wydenVault = factory.createPoliticianVault(
            wydenId, "Tilt Wyden Index", "tiltWYDEN", address(0), "ipfs://wyden-vault", seedPerVault
        );
        PoliticianVault(wydenVault).setKeeper(deployer, true);
        console.log("tiltWYDEN:", wydenVault);

        // Sessions
        bytes32 sessId = keccak256("pete-sessions");
        address sessVault = factory.createPoliticianVault(
            sessId, "Tilt Sessions Index", "tiltSESS", address(0), "ipfs://sessions-vault", seedPerVault
        );
        PoliticianVault(sessVault).setKeeper(deployer, true);
        console.log("tiltSESS:", sessVault);

        vm.stopBroadcast();

        // ========== Summary ==========
        console.log("\n============ BEACON PROXY DEPLOYMENT ============");
        console.log("PoliticianVaultFactory:", address(factory));
        console.log("UpgradeableBeacon:     ", address(factory.beacon()));
        console.log("Implementation:        ", factory.implementation());
        console.log("");
        console.log("tiltPELOSI:  ", pelosiVault);
        console.log("tiltTUBE:    ", tubeVault);
        console.log("tiltCREN:    ", crenVault);
        console.log("tiltMCCAUL:  ", mccaulVault);
        console.log("tiltWYDEN:   ", wydenVault);
        console.log("tiltSESS:    ", sessVault);
        console.log("================================================\n");
    }
}
