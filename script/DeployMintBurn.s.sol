// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {FeeManager} from "../src/core/FeeManager.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {TiltUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";

/// @title DeployMintBurn
/// @notice Full redeployment with mint-burn router (infinite liquidity).
///         All tokens, router, and infrastructure are fresh.
contract DeployMintBurn is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. TiltUSDC
        TiltUSDC tiltUsdc = new TiltUSDC();
        console.log("TiltUSDC:", address(tiltUsdc));

        // 2. Router (mint-burn, no pre-funded liquidity needed)
        MockTokenRouter router = new MockTokenRouter();
        console.log("MockTokenRouter:", address(router));

        // 3. Authorize router as minter on TiltUSDC
        tiltUsdc.addMinter(address(router));

        // 4. Stock Token Factory (auto-authorizes router on new tokens)
        MockStockTokenFactory tokenFactory = new MockStockTokenFactory();
        tokenFactory.setTokenRouter(address(router));
        tokenFactory.deployStandardTokens();
        console.log("MockStockTokenFactory:", address(tokenFactory));

        // 5. FeeManager
        FeeManager feeManager = new FeeManager(deployer, address(tiltUsdc));
        feeManager.setDefaultFees(10, 50, 200, 2000); // 0.1% entry, 0.5% exit, 2% mgmt, 20% perf
        console.log("FeeManager:", address(feeManager));

        // 6. VaultRegistry
        VaultRegistry registry = new VaultRegistry();
        console.log("VaultRegistry:", address(registry));

        // 7. RebalanceEngine
        RebalanceEngine engine = new RebalanceEngine(address(router), address(tiltUsdc));
        console.log("RebalanceEngine:", address(engine));

        // 8. PriceOracle
        PriceOracle priceOracle = new PriceOracle(address(router), address(tokenFactory));
        console.log("PriceOracle:", address(priceOracle));

        // 9. UserVaultFactory
        UserVaultFactory uvFactory = new UserVaultFactory(
            address(tiltUsdc), address(feeManager), address(registry), address(engine), address(router)
        );
        console.log("UserVaultFactory:", address(uvFactory));

        // 10. Permissions
        registry.setRegistrar(address(uvFactory), true);
        registry.setRegistrar(deployer, true);
        feeManager.setAuthorizedCaller(address(uvFactory), true);
        router.setAuthorizedCaller(address(engine), true);
        engine.setAuthorizedCaller(address(uvFactory), true);

        // 11. Token prices and pairs
        router.setTokenPrice(address(tiltUsdc), 1e18);

        MockStockTokenFactory.StockTokenInfo[] memory tokens = tokenFactory.getDeployedTokens();
        address[] memory tokenAddrs = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            router.setTokenPrice(tokens[i].token, tokens[i].initialPrice);
            router.setPairSupported(address(tiltUsdc), tokens[i].token, true);
            tokenAddrs[i] = tokens[i].token;
            console.log("  Token:", tokens[i].symbol, tokens[i].token);
        }
        uvFactory.setApprovedTokensBatch(tokenAddrs, true);

        // 12. Seed deployer with tiltUSDC
        tiltUsdc.mint(deployer, 1_000_000e6);

        vm.stopBroadcast();

        console.log("\n========= MINT-BURN DEPLOYMENT COMPLETE =========");
        console.log("TiltUSDC:          ", address(tiltUsdc));
        console.log("MockTokenRouter:   ", address(router));
        console.log("StockTokenFactory: ", address(tokenFactory));
        console.log("FeeManager:        ", address(feeManager));
        console.log("VaultRegistry:     ", address(registry));
        console.log("RebalanceEngine:   ", address(engine));
        console.log("PriceOracle:       ", address(priceOracle));
        console.log("UserVaultFactory:  ", address(uvFactory));
        console.log("=================================================\n");
    }
}
