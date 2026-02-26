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

/// @title DeployTiltProtocol
/// @notice Full deployment of Tilt Protocol on Robinhood L2 Testnet.
///         Deploys core infrastructure, mock stock tokens, and UserVaultFactory.
///         All vaults are now created via UserVaultFactory (unified architecture).
contract DeployTiltProtocol is Script {
    address public tiltUsdc;
    address public feeManager;
    address public registry;
    address public router;
    address public engine;
    address public uvFactory;
    address public tokenFactory;
    address public priceOracle;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ========== 1. Deploy TiltUSDC (6 decimals, with faucet) ==========
        TiltUSDC _tiltUsdc = new TiltUSDC();
        tiltUsdc = address(_tiltUsdc);
        console.log("TiltUSDC:", tiltUsdc);

        // ========== 2. Deploy Tilt Stock Token Factory ==========
        MockStockTokenFactory _tokenFactory = new MockStockTokenFactory();
        tokenFactory = address(_tokenFactory);
        _tokenFactory.deployStandardTokens();
        console.log("MockStockTokenFactory:", tokenFactory);

        // ========== 3. Deploy Core Infrastructure ==========

        FeeManager _feeManager = new FeeManager(treasury, tiltUsdc);
        feeManager = address(_feeManager);
        console.log("FeeManager:", feeManager);

        _feeManager.setDefaultFees(0, 0, 0, 0);

        VaultRegistry _registry = new VaultRegistry();
        registry = address(_registry);
        console.log("VaultRegistry:", registry);

        MockTokenRouter _router = new MockTokenRouter();
        router = address(_router);
        console.log("MockTokenRouter:", router);

        RebalanceEngine _engine = new RebalanceEngine(router, tiltUsdc);
        engine = address(_engine);
        console.log("RebalanceEngine:", engine);

        // ========== 4. Deploy PriceOracle ==========

        PriceOracle _priceOracle = new PriceOracle(router, tokenFactory);
        priceOracle = address(_priceOracle);
        console.log("PriceOracle:", priceOracle);

        // ========== 5. Deploy UserVaultFactory ==========

        UserVaultFactory _uvFactory =
            new UserVaultFactory(tiltUsdc, feeManager, registry, engine, router);
        uvFactory = address(_uvFactory);
        console.log("UserVaultFactory:", uvFactory);

        // ========== 6. Configure Permissions ==========

        _registry.setRegistrar(uvFactory, true);
        _registry.setRegistrar(deployer, true);

        _feeManager.setAuthorizedCaller(uvFactory, true);

        _router.setAuthorizedCaller(engine, true);

        _engine.setAuthorizedCaller(uvFactory, true);

        // ========== 7. Setup Token Prices in Router ==========

        _router.setTokenPrice(tiltUsdc, 1e18); // $1.00

        MockStockTokenFactory.StockTokenInfo[] memory tokens = _tokenFactory.getDeployedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _router.setTokenPrice(tokens[i].token, tokens[i].initialPrice);
            _router.setPairSupported(tiltUsdc, tokens[i].token, true);
            console.log("Stock Token:", tokens[i].symbol);
            console.log("  Address:", tokens[i].token);
        }

        // Approve all stock tokens in the UserVaultFactory
        address[] memory tokenAddresses = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenAddresses[i] = tokens[i].token;
        }
        _uvFactory.setApprovedTokensBatch(tokenAddresses, true);

        // ========== 8. Seed Liquidity ==========

        _tiltUsdc.mint(deployer, 1_000_000e6);
        _tokenFactory.mintAllTokens(router, 1_000_000e18);
        _tiltUsdc.mint(router, 10_000_000e6);

        vm.stopBroadcast();

        // ========== Log Summary ==========
        console.log("\n============ DEPLOYMENT SUMMARY ============");
        console.log("Network: Robinhood Chain Testnet (Chain ID:", block.chainid, ")");
        console.log("");
        console.log("--- Core Contracts ---");
        console.log("TiltUSDC:             ", tiltUsdc);
        console.log("FeeManager:           ", feeManager);
        console.log("VaultRegistry:        ", registry);
        console.log("MockTokenRouter:      ", router);
        console.log("RebalanceEngine:      ", engine);
        console.log("PriceOracle:          ", priceOracle);
        console.log("UserVaultFactory:     ", uvFactory);
        console.log("StockTokenFactory:    ", tokenFactory);
        console.log("============================================\n");
    }
}
