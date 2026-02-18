// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {FeeManager} from "../src/core/FeeManager.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {PoliticianVault} from "../src/core/PoliticianVault.sol";
import {PortfolioOracle} from "../src/oracle/PortfolioOracle.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {TiltUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployTiltProtocol
/// @notice Full deployment of Tilt Protocol on Robinhood L2 Testnet.
///         Creates infrastructure, tilt-branded tokens, politician vaults
///         with hardcoded realistic portfolios, and seeds liquidity.
contract DeployTiltProtocol is Script {
    // Deployed addresses
    address public tiltUsdc;
    address public feeManager;
    address public registry;
    address public oracle;
    address public chainlinkAdapter;
    address public router;
    address public engine;
    address public factory;
    address public tokenFactory;

    // Politician vault addresses
    address public pelosiVault;
    address public tubervilleVault;
    address public crenshawVault;

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

        // Set all fees to 0 for testnet simplicity
        _feeManager.setDefaultFees(0, 0, 0, 0);

        VaultRegistry _registry = new VaultRegistry();
        registry = address(_registry);
        console.log("VaultRegistry:", registry);

        PortfolioOracle _oracle = new PortfolioOracle();
        oracle = address(_oracle);
        console.log("PortfolioOracle:", oracle);

        MockTokenRouter _router = new MockTokenRouter();
        router = address(_router);
        console.log("MockTokenRouter:", router);

        RebalanceEngine _engine = new RebalanceEngine(router, tiltUsdc);
        engine = address(_engine);
        console.log("RebalanceEngine:", engine);

        ChainlinkAdapter _adapter = new ChainlinkAdapter(oracle);
        chainlinkAdapter = address(_adapter);
        console.log("ChainlinkAdapter:", chainlinkAdapter);

        // ========== 4. Deploy VaultFactory ==========

        VaultFactory _factory = new VaultFactory(tiltUsdc, feeManager, registry, engine, router, oracle);
        factory = address(_factory);
        console.log("VaultFactory:", factory);

        // ========== 5. Configure Permissions ==========

        // Registry: authorize factory and deployer as registrars
        _registry.setRegistrar(factory, true);
        _registry.setRegistrar(deployer, true);

        // FeeManager: authorize factory as caller (deployer stays owner)
        _feeManager.setAuthorizedCaller(factory, true);

        // Oracle: authorize adapter and deployer as reporters
        _oracle.setReporter(chainlinkAdapter, true);
        _oracle.setReporter(deployer, true);

        // Router: authorize engine as caller
        _router.setAuthorizedCaller(engine, true);

        // Engine: authorize factory to register vaults
        _engine.setAuthorizedCaller(factory, true);

        // ========== 6. Setup Token Prices in Router ==========

        _router.setTokenPrice(tiltUsdc, 1e18); // $1.00

        MockStockTokenFactory.StockTokenInfo[] memory tokens = _tokenFactory.getDeployedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _router.setTokenPrice(tokens[i].token, tokens[i].initialPrice);
            _router.setPairSupported(tiltUsdc, tokens[i].token, true);
            _factory.setApprovedToken(tokens[i].token, true);

            console.log("Stock Token:", tokens[i].symbol);
            console.log("  Address:", tokens[i].token);
        }

        // ========== 7. Seed Liquidity ==========

        // Mint tiltUSDC to deployer for vault seeding
        _tiltUsdc.mint(deployer, 1_000_000e6); // 1M tiltUSDC

        // Mint stock tokens to router for swap reserves
        _tokenFactory.mintAllTokens(router, 1_000_000e18); // 1M of each stock (18 dec)

        // Mint tiltUSDC to router for swap reserves
        _tiltUsdc.mint(router, 10_000_000e6); // 10M tiltUSDC in router

        // ========== 8. Register Politicians & Seed Portfolios ==========

        bytes32 pelosiId = keccak256("nancy-pelosi");
        bytes32 tubervilleId = keccak256("tommy-tuberville");
        bytes32 crenshawId = keccak256("dan-crenshaw");

        _oracle.registerPolitician(pelosiId, "ipfs://pelosi-metadata");
        _oracle.registerPolitician(tubervilleId, "ipfs://tuberville-metadata");
        _oracle.registerPolitician(crenshawId, "ipfs://crenshaw-metadata");

        // Seed realistic portfolios from publicly known holdings
        _seedPelosiPortfolio(_oracle, pelosiId, tokens);
        _seedTubervillePortfolio(_oracle, tubervilleId, tokens);
        _seedCrenshawPortfolio(_oracle, crenshawId, tokens);

        // ========== 9. Create Politician Vaults (via factory, with dead shares) ==========

        uint256 seedAmount = 1000e6; // 1,000 tiltUSDC seed per vault

        // Approve factory to pull tiltUSDC for seeding
        _tiltUsdc.approve(factory, seedAmount * 3);

        // tiltPELOSI vault
        pelosiVault = _factory.createPoliticianVault(
            pelosiId, "Tilt Pelosi Index", "tiltPELOSI", address(0), "ipfs://pelosi-vault", seedAmount
        );
        PoliticianVault(pelosiVault).setKeeper(deployer, true);
        console.log("tiltPELOSI Vault:", pelosiVault);

        // tiltTUBE vault
        tubervilleVault = _factory.createPoliticianVault(
            tubervilleId,
            "Tilt Tuberville Index",
            "tiltTUBE",
            address(0),
            "ipfs://tuberville-vault",
            seedAmount
        );
        PoliticianVault(tubervilleVault).setKeeper(deployer, true);
        console.log("tiltTUBE Vault:", tubervilleVault);

        // tiltCREN vault
        crenshawVault = _factory.createPoliticianVault(
            crenshawId, "Tilt Crenshaw Index", "tiltCREN", address(0), "ipfs://crenshaw-vault", seedAmount
        );
        PoliticianVault(crenshawVault).setKeeper(deployer, true);
        console.log("tiltCREN Vault:", crenshawVault);

        vm.stopBroadcast();

        // ========== Log Summary ==========
        console.log("\n============ DEPLOYMENT SUMMARY ============");
        console.log("Network: Robinhood Chain Testnet (Chain ID:", block.chainid, ")");
        console.log("");
        console.log("--- Core Contracts ---");
        console.log("TiltUSDC:             ", tiltUsdc);
        console.log("FeeManager:           ", feeManager);
        console.log("VaultRegistry:        ", registry);
        console.log("PortfolioOracle:      ", oracle);
        console.log("ChainlinkAdapter:     ", chainlinkAdapter);
        console.log("MockTokenRouter:      ", router);
        console.log("RebalanceEngine:      ", engine);
        console.log("VaultFactory:         ", factory);
        console.log("StockTokenFactory:    ", tokenFactory);
        console.log("");
        console.log("--- Politician Vaults ---");
        console.log("tiltPELOSI:           ", pelosiVault);
        console.log("tiltTUBE:             ", tubervilleVault);
        console.log("tiltCREN:             ", crenshawVault);
        console.log("============================================\n");
    }

    // ========== Hardcoded Portfolios (publicly known holdings) ==========

    function _seedPelosiPortfolio(
        PortfolioOracle _oracle,
        bytes32 politicianId,
        MockStockTokenFactory.StockTokenInfo[] memory tokens
    ) internal {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](6);
        weights[0] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltNVDA"), weightBps: 2800}); // 28%
        weights[1] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltAAPL"), weightBps: 2200}); // 22%
        weights[2] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltGOOGL"), weightBps: 1800}); // 18%
        weights[3] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltMSFT"), weightBps: 1500}); // 15%
        weights[4] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltAMZN"), weightBps: 1000}); // 10%
        weights[5] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltTSLA"), weightBps: 700}); // 7%

        _oracle.updatePortfolio(politicianId, weights);
        console.log("Seeded Pelosi portfolio: NVDA 28%, AAPL 22%, GOOGL 18%, MSFT 15%, AMZN 10%, TSLA 7%");
    }

    function _seedTubervillePortfolio(
        PortfolioOracle _oracle,
        bytes32 politicianId,
        MockStockTokenFactory.StockTokenInfo[] memory tokens
    ) internal {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](6);
        weights[0] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltJPM"), weightBps: 2500}); // 25%
        weights[1] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltNVDA"), weightBps: 2000}); // 20%
        weights[2] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltMSFT"), weightBps: 1800}); // 18%
        weights[3] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltV"), weightBps: 1500}); // 15%
        weights[4] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltAAPL"), weightBps: 1200}); // 12%
        weights[5] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltMETA"), weightBps: 1000}); // 10%

        _oracle.updatePortfolio(politicianId, weights);
        console.log("Seeded Tuberville portfolio: JPM 25%, NVDA 20%, MSFT 18%, V 15%, AAPL 12%, META 10%");
    }

    function _seedCrenshawPortfolio(
        PortfolioOracle _oracle,
        bytes32 politicianId,
        MockStockTokenFactory.StockTokenInfo[] memory tokens
    ) internal {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](6);
        weights[0] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltMSFT"), weightBps: 2500}); // 25%
        weights[1] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltAAPL"), weightBps: 2000}); // 20%
        weights[2] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltJNJ"), weightBps: 1800}); // 18%
        weights[3] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltGOOGL"), weightBps: 1500}); // 15%
        weights[4] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltAMZN"), weightBps: 1200}); // 12%
        weights[5] = IBaseVault.TokenWeight({token: _findToken(tokens, "tiltTSLA"), weightBps: 1000}); // 10%

        _oracle.updatePortfolio(politicianId, weights);
        console.log("Seeded Crenshaw portfolio: MSFT 25%, AAPL 20%, JNJ 18%, GOOGL 15%, AMZN 12%, TSLA 10%");
    }

    function _findToken(MockStockTokenFactory.StockTokenInfo[] memory tokens, string memory symbol)
        internal
        pure
        returns (address)
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (keccak256(bytes(tokens[i].symbol)) == keccak256(bytes(symbol))) {
                return tokens[i].token;
            }
        }
        revert(string.concat("Token not found: ", symbol));
    }
}
