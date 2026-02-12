// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {FeeManager} from "../src/core/FeeManager.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {PortfolioOracle} from "../src/oracle/PortfolioOracle.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {MockUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";

/// @title DeployInsider
/// @notice Full deployment script for the Insider protocol on Robinhood L2 Testnet
///
/// Usage:
///   source .env
///   forge script script/Deploy.s.sol:DeployInsider \
///     --rpc-url https://rpc.testnet.chain.robinhood.com \
///     --broadcast \
///     --verify
contract DeployInsider is Script {
    // Deployed addresses (logged for frontend integration)
    address public usdc;
    address public feeManager;
    address public registry;
    address public oracle;
    address public chainlinkAdapter;
    address public router;
    address public engine;
    address public factory;
    address public tokenFactory;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ========== 1. Deploy Mock USDC ==========
        MockUSDC _usdc = new MockUSDC();
        usdc = address(_usdc);
        console.log("MockUSDC:", usdc);

        // ========== 2. Deploy Mock Stock Token Factory ==========
        MockStockTokenFactory _tokenFactory = new MockStockTokenFactory();
        tokenFactory = address(_tokenFactory);
        _tokenFactory.deployStandardTokens();
        console.log("MockStockTokenFactory:", tokenFactory);

        // ========== 3. Deploy Core Infrastructure ==========

        // FeeManager
        FeeManager _feeManager = new FeeManager(treasury);
        feeManager = address(_feeManager);
        console.log("FeeManager:", feeManager);

        // VaultRegistry
        VaultRegistry _registry = new VaultRegistry();
        registry = address(_registry);
        console.log("VaultRegistry:", registry);

        // PortfolioOracle
        PortfolioOracle _oracle = new PortfolioOracle();
        oracle = address(_oracle);
        console.log("PortfolioOracle:", oracle);

        // MockTokenRouter
        MockTokenRouter _router = new MockTokenRouter();
        router = address(_router);
        console.log("MockTokenRouter:", router);

        // RebalanceEngine
        RebalanceEngine _engine = new RebalanceEngine(router, usdc);
        engine = address(_engine);
        console.log("RebalanceEngine:", engine);

        // ChainlinkAdapter
        ChainlinkAdapter _adapter = new ChainlinkAdapter(oracle);
        chainlinkAdapter = address(_adapter);
        console.log("ChainlinkAdapter:", chainlinkAdapter);

        // ========== 4. Deploy VaultFactory ==========

        VaultFactory _factory = new VaultFactory(usdc, feeManager, registry, engine, oracle);
        factory = address(_factory);
        console.log("VaultFactory:", factory);

        // ========== 5. Configure Permissions ==========

        // Registry: authorize factory as registrar
        _registry.setRegistrar(factory, true);

        // FeeManager: transfer ownership to factory
        _feeManager.transferOwnership(factory);

        // Oracle: authorize adapter and deployer as reporters
        _oracle.setReporter(chainlinkAdapter, true);
        _oracle.setReporter(deployer, true);

        // Router: authorize engine as caller
        _router.setAuthorizedCaller(engine, true);

        // ========== 6. Setup Token Prices in Router ==========

        _router.setTokenPrice(usdc, 1e18); // $1

        // Set stock token prices from factory
        MockStockTokenFactory.StockTokenInfo[] memory tokens = _tokenFactory.getDeployedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _router.setTokenPrice(tokens[i].token, tokens[i].initialPrice);
            _router.setPairSupported(usdc, tokens[i].token, true);

            // Approve tokens in factory
            _factory.setApprovedToken(tokens[i].token, true);

            console.log("Stock Token:", tokens[i].symbol);
            console.log("  Address:", tokens[i].token);
        }

        // ========== 7. Seed Liquidity ==========

        // Mint USDC to deployer for testing
        _usdc.mint(deployer, 1_000_000e6); // 1M USDC

        // Mint stock tokens to router for swaps
        _tokenFactory.mintAllTokens(router, 100_000e18);

        // Mint USDC to router
        _usdc.mint(router, 1_000_000e6);

        // ========== 8. Register Test Politicians ==========

        bytes32 pelosiId = keccak256("nancy-pelosi");
        bytes32 tubervilleId = keccak256("tommy-tuberville");
        bytes32 crenshawId = keccak256("dan-crenshaw");

        _oracle.registerPolitician(pelosiId, "ipfs://pelosi-metadata");
        _oracle.registerPolitician(tubervilleId, "ipfs://tuberville-metadata");
        _oracle.registerPolitician(crenshawId, "ipfs://crenshaw-metadata");

        vm.stopBroadcast();

        // ========== Log Summary ==========
        console.log("\n========== DEPLOYMENT SUMMARY ==========");
        console.log("Network: Robinhood Chain Testnet (Chain ID:", block.chainid, ")");
        console.log("MockUSDC:", usdc);
        console.log("FeeManager:", feeManager);
        console.log("VaultRegistry:", registry);
        console.log("PortfolioOracle:", oracle);
        console.log("ChainlinkAdapter:", chainlinkAdapter);
        console.log("MockTokenRouter:", router);
        console.log("RebalanceEngine:", engine);
        console.log("VaultFactory:", factory);
        console.log("MockStockTokenFactory:", tokenFactory);
        console.log("=========================================\n");
    }
}
