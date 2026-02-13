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
import {BowUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";

/// @title DeployBowstring
/// @notice Full deployment of Bowstring protocol on Robinhood L2 Testnet.
///         Creates infrastructure, bow-branded tokens, politician vaults
///         with hardcoded realistic portfolios, and seeds liquidity.
contract DeployBowstring is Script {
    // Deployed addresses
    address public bowUsdc;
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

        // ========== 1. Deploy BowUSDC (18 decimals, with faucet) ==========
        BowUSDC _bowUsdc = new BowUSDC();
        bowUsdc = address(_bowUsdc);
        console.log("BowUSDC:", bowUsdc);

        // ========== 2. Deploy Bow Stock Token Factory ==========
        MockStockTokenFactory _tokenFactory = new MockStockTokenFactory();
        tokenFactory = address(_tokenFactory);
        _tokenFactory.deployStandardTokens();
        console.log("MockStockTokenFactory:", tokenFactory);

        // ========== 3. Deploy Core Infrastructure ==========

        FeeManager _feeManager = new FeeManager(treasury);
        feeManager = address(_feeManager);
        console.log("FeeManager:", feeManager);

        VaultRegistry _registry = new VaultRegistry();
        registry = address(_registry);
        console.log("VaultRegistry:", registry);

        PortfolioOracle _oracle = new PortfolioOracle();
        oracle = address(_oracle);
        console.log("PortfolioOracle:", oracle);

        MockTokenRouter _router = new MockTokenRouter();
        router = address(_router);
        console.log("MockTokenRouter:", router);

        RebalanceEngine _engine = new RebalanceEngine(router, bowUsdc);
        engine = address(_engine);
        console.log("RebalanceEngine:", engine);

        ChainlinkAdapter _adapter = new ChainlinkAdapter(oracle);
        chainlinkAdapter = address(_adapter);
        console.log("ChainlinkAdapter:", chainlinkAdapter);

        // ========== 4. Deploy VaultFactory ==========

        VaultFactory _factory = new VaultFactory(
            bowUsdc, feeManager, registry, engine, router, oracle
        );
        factory = address(_factory);
        console.log("VaultFactory:", factory);

        // ========== 5. Configure Permissions ==========

        // Registry: authorize factory and deployer as registrars
        _registry.setRegistrar(factory, true);
        _registry.setRegistrar(deployer, true);

        // FeeManager: authorize factory (but keep deployer as owner for direct vault creation)
        // We'll transfer ownership after creating politician vaults
        // For now, deployer owns FeeManager

        // Oracle: authorize adapter and deployer as reporters
        _oracle.setReporter(chainlinkAdapter, true);
        _oracle.setReporter(deployer, true);

        // Router: authorize engine as caller
        _router.setAuthorizedCaller(engine, true);

        // ========== 6. Setup Token Prices in Router ==========

        _router.setTokenPrice(bowUsdc, 1e18); // $1.00

        MockStockTokenFactory.StockTokenInfo[] memory tokens = _tokenFactory.getDeployedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _router.setTokenPrice(tokens[i].token, tokens[i].initialPrice);
            _router.setPairSupported(bowUsdc, tokens[i].token, true);
            _factory.setApprovedToken(tokens[i].token, true);

            console.log("Stock Token:", tokens[i].symbol);
            console.log("  Address:", tokens[i].token);
        }

        // ========== 7. Seed Liquidity ==========

        // Mint bowUSDC to deployer for testing
        _bowUsdc.mint(deployer, 1_000_000e18); // 1M bowUSDC

        // Mint stock tokens to router for swap reserves
        _tokenFactory.mintAllTokens(router, 1_000_000e18); // 1M of each stock

        // Mint bowUSDC to router for swap reserves
        _bowUsdc.mint(router, 10_000_000e18); // 10M bowUSDC in router

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

        // ========== 9. Create Politician Vaults ==========

        // bowPELOSI vault
        PoliticianVault _pelosiVault = new PoliticianVault(
            "Bowstring Pelosi Index",
            "bowPELOSI",
            pelosiId,
            bowUsdc,
            oracle,
            feeManager,
            engine,
            router,
            deployer
        );
        pelosiVault = address(_pelosiVault);
        _feeManager.configureVaultFees(pelosiVault, 0, address(0));
        _registry.registerVault(pelosiVault, VaultRegistry.VaultType.POLITICIAN, address(0), "ipfs://pelosi-vault");
        _engine.setVaultAuthorized(pelosiVault, true);
        _pelosiVault.setKeeper(deployer, true); // deployer can trigger rebalances
        console.log("bowPELOSI Vault:", pelosiVault);

        // bowTUBE vault
        PoliticianVault _tubeVault = new PoliticianVault(
            "Bowstring Tuberville Index",
            "bowTUBE",
            tubervilleId,
            bowUsdc,
            oracle,
            feeManager,
            engine,
            router,
            deployer
        );
        tubervilleVault = address(_tubeVault);
        _feeManager.configureVaultFees(tubervilleVault, 0, address(0));
        _registry.registerVault(tubervilleVault, VaultRegistry.VaultType.POLITICIAN, address(0), "ipfs://tuberville-vault");
        _engine.setVaultAuthorized(tubervilleVault, true);
        _tubeVault.setKeeper(deployer, true);
        console.log("bowTUBE Vault:", tubervilleVault);

        // bowCREN vault
        PoliticianVault _crenVault = new PoliticianVault(
            "Bowstring Crenshaw Index",
            "bowCREN",
            crenshawId,
            bowUsdc,
            oracle,
            feeManager,
            engine,
            router,
            deployer
        );
        crenshawVault = address(_crenVault);
        _feeManager.configureVaultFees(crenshawVault, 0, address(0));
        _registry.registerVault(crenshawVault, VaultRegistry.VaultType.POLITICIAN, address(0), "ipfs://crenshaw-vault");
        _engine.setVaultAuthorized(crenshawVault, true);
        _crenVault.setKeeper(deployer, true);
        console.log("bowCREN Vault:", crenshawVault);

        // ========== 10. Transfer FeeManager ownership to factory ==========
        _feeManager.transferOwnership(factory);

        vm.stopBroadcast();

        // ========== Log Summary ==========
        console.log("\n============ DEPLOYMENT SUMMARY ============");
        console.log("Network: Robinhood Chain Testnet (Chain ID:", block.chainid, ")");
        console.log("");
        console.log("--- Core Contracts ---");
        console.log("BowUSDC:              ", bowUsdc);
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
        console.log("bowPELOSI:            ", pelosiVault);
        console.log("bowTUBE:              ", tubervilleVault);
        console.log("bowCREN:              ", crenshawVault);
        console.log("============================================\n");
    }

    // ========== Hardcoded Portfolios (publicly known holdings) ==========

    /// @dev Nancy Pelosi: Known for NVDA, AAPL, GOOGL, MSFT, AMZN, TSLA
    function _seedPelosiPortfolio(
        PortfolioOracle _oracle,
        bytes32 politicianId,
        MockStockTokenFactory.StockTokenInfo[] memory tokens
    ) internal {
        // Pelosi portfolio: heavy tech, led by NVDA
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](6);
        weights[0] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowNVDA"), weightBps: 2800}); // 28%
        weights[1] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowAAPL"), weightBps: 2200}); // 22%
        weights[2] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowGOOGL"), weightBps: 1800}); // 18%
        weights[3] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowMSFT"), weightBps: 1500}); // 15%
        weights[4] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowAMZN"), weightBps: 1000}); // 10%
        weights[5] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowTSLA"), weightBps: 700});  // 7%

        _oracle.updatePortfolio(politicianId, weights);
        console.log("Seeded Pelosi portfolio: NVDA 28%, AAPL 22%, GOOGL 18%, MSFT 15%, AMZN 10%, TSLA 7%");
    }

    /// @dev Tommy Tuberville: Known for financials + defense, broader mix
    function _seedTubervillePortfolio(
        PortfolioOracle _oracle,
        bytes32 politicianId,
        MockStockTokenFactory.StockTokenInfo[] memory tokens
    ) internal {
        // Tuberville portfolio: diversified with financials and big tech
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](6);
        weights[0] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowJPM"), weightBps: 2500});  // 25%
        weights[1] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowNVDA"), weightBps: 2000}); // 20%
        weights[2] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowMSFT"), weightBps: 1800}); // 18%
        weights[3] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowV"), weightBps: 1500});    // 15%
        weights[4] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowAAPL"), weightBps: 1200}); // 12%
        weights[5] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowMETA"), weightBps: 1000}); // 10%

        _oracle.updatePortfolio(politicianId, weights);
        console.log("Seeded Tuberville portfolio: JPM 25%, NVDA 20%, MSFT 18%, V 15%, AAPL 12%, META 10%");
    }

    /// @dev Dan Crenshaw: Known for energy + healthcare positions
    function _seedCrenshawPortfolio(
        PortfolioOracle _oracle,
        bytes32 politicianId,
        MockStockTokenFactory.StockTokenInfo[] memory tokens
    ) internal {
        // Crenshaw portfolio: tech-heavy with healthcare (JNJ)
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](6);
        weights[0] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowMSFT"), weightBps: 2500}); // 25%
        weights[1] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowAAPL"), weightBps: 2000}); // 20%
        weights[2] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowJNJ"), weightBps: 1800});  // 18%
        weights[3] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowGOOGL"), weightBps: 1500}); // 15%
        weights[4] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowAMZN"), weightBps: 1200}); // 12%
        weights[5] = IBaseVault.TokenWeight({token: _findToken(tokens, "bowTSLA"), weightBps: 1000}); // 10%

        _oracle.updatePortfolio(politicianId, weights);
        console.log("Seeded Crenshaw portfolio: MSFT 25%, AAPL 20%, JNJ 18%, GOOGL 15%, AMZN 12%, TSLA 10%");
    }

    /// @dev Find a token address by symbol from the factory's deployed tokens
    function _findToken(
        MockStockTokenFactory.StockTokenInfo[] memory tokens,
        string memory symbol
    ) internal pure returns (address) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (keccak256(bytes(tokens[i].symbol)) == keccak256(bytes(symbol))) {
                return tokens[i].token;
            }
        }
        revert(string.concat("Token not found: ", symbol));
    }
}
