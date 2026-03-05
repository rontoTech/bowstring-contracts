// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StockTokenUpgradeable} from "../src/tokens/StockTokenUpgradeable.sol";
import {StockTokenFactoryUpgradeable} from "../src/tokens/StockTokenFactoryUpgradeable.sol";
import {TokenRouterUpgradeable} from "../src/rebalance/TokenRouterUpgradeable.sol";
import {RebalanceEngineUpgradeable} from "../src/rebalance/RebalanceEngineUpgradeable.sol";
import {FeeManagerUpgradeable} from "../src/core/FeeManagerUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../src/core/VaultRegistryUpgradeable.sol";
import {PriceOracleUpgradeable} from "../src/oracle/PriceOracleUpgradeable.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";
import {TiltUSDC} from "../src/tokens/MockStockToken.sol";

/// @title DeployUpgradeable
/// @notice Deploys the full upgradeable infrastructure behind proxies.
///         Stock tokens use UpgradeableBeacon (via factory). Singletons use UUPS + ERC1967Proxy.
///         Existing TiltUSDC is kept as-is — router uses transfer for USDC, mint/burn for stocks.
contract DeployUpgradeable is Script {
    address constant TILT_USDC = 0x941A382852E989078e15b381f921C488a7Ca5299;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("TiltUSDC (existing):", TILT_USDC);

        vm.startBroadcast(deployerPrivateKey);

        // ===== 1. Token Router (UUPS) =====
        TokenRouterUpgradeable routerImpl = new TokenRouterUpgradeable();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(TokenRouterUpgradeable.initialize, (deployer, TILT_USDC))
        );
        TokenRouterUpgradeable router = TokenRouterUpgradeable(address(routerProxy));
        console.log("TokenRouter (proxy):", address(router));

        // ===== 2. Rebalance Engine (UUPS) =====
        RebalanceEngineUpgradeable engineImpl = new RebalanceEngineUpgradeable();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl),
            abi.encodeCall(RebalanceEngineUpgradeable.initialize, (address(router), TILT_USDC, deployer))
        );
        RebalanceEngineUpgradeable engine = RebalanceEngineUpgradeable(address(engineProxy));
        console.log("RebalanceEngine (proxy):", address(engine));

        // ===== 3. Fee Manager (UUPS) =====
        FeeManagerUpgradeable feeImpl = new FeeManagerUpgradeable();
        ERC1967Proxy feeProxy = new ERC1967Proxy(
            address(feeImpl),
            abi.encodeCall(FeeManagerUpgradeable.initialize, (deployer, TILT_USDC, deployer))
        );
        FeeManagerUpgradeable feeManager = FeeManagerUpgradeable(payable(address(feeProxy)));
        feeManager.setDefaultFees(10, 50, 200, 2000);
        console.log("FeeManager (proxy):", address(feeManager));

        // ===== 4. Vault Registry (UUPS) =====
        VaultRegistryUpgradeable registryImpl = new VaultRegistryUpgradeable();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(VaultRegistryUpgradeable.initialize, (deployer))
        );
        VaultRegistryUpgradeable registry = VaultRegistryUpgradeable(address(registryProxy));
        console.log("VaultRegistry (proxy):", address(registry));

        // ===== 5. Stock Token Factory (UUPS + owns beacon) =====
        StockTokenUpgradeable stockTokenImpl = new StockTokenUpgradeable();
        StockTokenFactoryUpgradeable factoryImpl = new StockTokenFactoryUpgradeable();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(StockTokenFactoryUpgradeable.initialize, (deployer, address(stockTokenImpl)))
        );
        StockTokenFactoryUpgradeable factory = StockTokenFactoryUpgradeable(address(factoryProxy));
        factory.setTokenRouter(address(router));
        console.log("StockTokenFactory (proxy):", address(factory));

        // ===== 6. Price Oracle (UUPS) =====
        PriceOracleUpgradeable oracleImpl = new PriceOracleUpgradeable();
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeCall(PriceOracleUpgradeable.initialize, (address(router), address(factory), deployer))
        );
        PriceOracleUpgradeable oracle = PriceOracleUpgradeable(address(oracleProxy));
        console.log("PriceOracle (proxy):", address(oracle));

        // ===== 7. User Vault Factory (uses existing pattern) =====
        UserVaultFactory uvFactory = new UserVaultFactory(
            TILT_USDC, address(feeManager), address(registry), address(engine), address(router)
        );
        console.log("UserVaultFactory:", address(uvFactory));

        // ===== 8. Wire permissions =====
        router.setAuthorizedCaller(address(engine), true);
        engine.setAuthorizedCaller(address(uvFactory), true);
        registry.setRegistrar(address(uvFactory), true);
        registry.setRegistrar(deployer, true);
        feeManager.setAuthorizedCaller(address(uvFactory), true);

        // ===== 9. Set tiltUSDC price =====
        router.setTokenPrice(TILT_USDC, 1e18);

        // ===== 10. Deploy 10 standard stock tokens =====
        _deployStockToken(factory, router, uvFactory, "Tilt Apple", "AAPL", 195e18);
        _deployStockToken(factory, router, uvFactory, "Tilt Microsoft", "MSFT", 420e18);
        _deployStockToken(factory, router, uvFactory, "Tilt NVIDIA", "NVDA", 875e18);
        _deployStockToken(factory, router, uvFactory, "Tilt Tesla", "TSLA", 250e18);
        _deployStockToken(factory, router, uvFactory, "Tilt Amazon", "AMZN", 185e18);
        _deployStockToken(factory, router, uvFactory, "Tilt Alphabet", "GOOGL", 165e18);
        _deployStockToken(factory, router, uvFactory, "Tilt Meta", "META", 500e18);
        _deployStockToken(factory, router, uvFactory, "Tilt JPMorgan", "JPM", 205e18);
        _deployStockToken(factory, router, uvFactory, "Tilt Visa", "V", 290e18);
        _deployStockToken(factory, router, uvFactory, "Tilt J&J", "JNJ", 160e18);

        // ===== 11. Fund router with tiltUSDC =====
        TiltUSDC tiltUsdc = TiltUSDC(TILT_USDC);
        tiltUsdc.mint(address(router), 1_000_000_000_000e6);

        // ===== 12. Seed deployer =====
        tiltUsdc.mint(deployer, 1_000_000e6);

        vm.stopBroadcast();

        console.log("\n========= UPGRADEABLE DEPLOYMENT COMPLETE =========");
        console.log("TiltUSDC (existing):   ", TILT_USDC);
        console.log("TokenRouter (proxy):   ", address(router));
        console.log("RebalanceEngine (proxy):", address(engine));
        console.log("FeeManager (proxy):    ", address(feeManager));
        console.log("VaultRegistry (proxy): ", address(registry));
        console.log("StockTokenFactory (proxy):", address(factory));
        console.log("PriceOracle (proxy):   ", address(oracle));
        console.log("UserVaultFactory:      ", address(uvFactory));
        console.log("====================================================\n");
    }

    function _deployStockToken(
        StockTokenFactoryUpgradeable factory,
        TokenRouterUpgradeable router,
        UserVaultFactory uvFactory,
        string memory name,
        string memory symbol,
        uint256 price
    ) internal {
        address token = factory.createStockToken(name, symbol, price);
        router.setTokenPrice(token, price);
        router.setPairSupported(0x941A382852E989078e15b381f921C488a7Ca5299, token, true);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uvFactory.setApprovedTokensBatch(tokens, true);

        console.log("  Token:", symbol, token);
    }
}
