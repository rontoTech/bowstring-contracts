// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

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
import {UserVault} from "../src/core/UserVault.sol";
import {BaseVault} from "../src/core/BaseVault.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../src/interfaces/IRebalanceEngine.sol";
import {TiltUSDC} from "../src/tokens/MockStockToken.sol";

/// @title UpgradeableProtocolTest
/// @notice Tests the full upgradeable architecture: proxied singletons,
///         beacon-proxied stock tokens, hybrid mint/burn router, and migration.
contract UpgradeableProtocolTest is Test {
    address public deployer = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public curator = makeAddr("curator");

    TiltUSDC public usdc;

    TokenRouterUpgradeable public router;
    RebalanceEngineUpgradeable public engine;
    FeeManagerUpgradeable public feeManager;
    VaultRegistryUpgradeable public registry;
    StockTokenFactoryUpgradeable public factory;
    PriceOracleUpgradeable public oracle;
    UserVaultFactory public uvFactory;

    address public aapl;
    address public msft;
    address public nvda;

    uint256 public constant INITIAL_USDC = 100_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 10_000e6;
    uint256 public constant SEED_AMOUNT = 1000e6;

    function setUp() public {
        usdc = new TiltUSDC();

        // --- TokenRouter (UUPS) ---
        TokenRouterUpgradeable routerImpl = new TokenRouterUpgradeable();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(TokenRouterUpgradeable.initialize, (deployer, address(usdc)))
        );
        router = TokenRouterUpgradeable(address(routerProxy));

        // --- RebalanceEngine (UUPS) ---
        RebalanceEngineUpgradeable engineImpl = new RebalanceEngineUpgradeable();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl),
            abi.encodeCall(RebalanceEngineUpgradeable.initialize, (address(router), address(usdc), deployer))
        );
        engine = RebalanceEngineUpgradeable(address(engineProxy));

        // --- FeeManager (UUPS) ---
        FeeManagerUpgradeable feeImpl = new FeeManagerUpgradeable();
        ERC1967Proxy feeProxy = new ERC1967Proxy(
            address(feeImpl),
            abi.encodeCall(FeeManagerUpgradeable.initialize, (treasury, address(usdc), deployer))
        );
        feeManager = FeeManagerUpgradeable(payable(address(feeProxy)));
        feeManager.setDefaultFees(0, 0, 0, 0);

        // --- VaultRegistry (UUPS) ---
        VaultRegistryUpgradeable registryImpl = new VaultRegistryUpgradeable();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(VaultRegistryUpgradeable.initialize, (deployer))
        );
        registry = VaultRegistryUpgradeable(address(registryProxy));

        // --- StockTokenFactory (UUPS + beacon) ---
        StockTokenUpgradeable stockTokenImpl = new StockTokenUpgradeable();
        StockTokenFactoryUpgradeable factoryImpl = new StockTokenFactoryUpgradeable();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(StockTokenFactoryUpgradeable.initialize, (deployer, address(stockTokenImpl)))
        );
        factory = StockTokenFactoryUpgradeable(address(factoryProxy));
        factory.setTokenRouter(address(router));

        // --- PriceOracle (UUPS) ---
        PriceOracleUpgradeable oracleImpl = new PriceOracleUpgradeable();
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeCall(PriceOracleUpgradeable.initialize, (address(router), address(factory), deployer))
        );
        oracle = PriceOracleUpgradeable(address(oracleProxy));

        // --- UserVaultFactory ---
        uvFactory = new UserVaultFactory(
            address(usdc), address(feeManager), address(registry), address(engine), address(router)
        );

        // --- Permissions ---
        router.setAuthorizedCaller(address(engine), true);
        engine.setAuthorizedCaller(address(uvFactory), true);
        registry.setRegistrar(address(uvFactory), true);
        registry.setRegistrar(deployer, true);
        feeManager.setAuthorizedCaller(address(uvFactory), true);

        // --- Deploy stock tokens via beacon factory ---
        aapl = factory.createStockToken("Tilt Apple", "AAPL", 195e18);
        msft = factory.createStockToken("Tilt Microsoft", "MSFT", 420e18);
        nvda = factory.createStockToken("Tilt NVIDIA", "NVDA", 875e18);

        // --- Prices and pairs ---
        router.setTokenPrice(address(usdc), 1e18);
        router.setTokenPrice(aapl, 195e18);
        router.setTokenPrice(msft, 420e18);
        router.setTokenPrice(nvda, 875e18);
        router.setPairSupported(address(usdc), aapl, true);
        router.setPairSupported(address(usdc), msft, true);
        router.setPairSupported(address(usdc), nvda, true);
        router.setPairSupported(aapl, nvda, true);
        router.setPairSupported(aapl, msft, true);
        router.setPairSupported(msft, nvda, true);

        // --- Router is minter on all stock tokens (set by factory) ---
        // tiltUSDC: router mints when authorized; funding also covers legacy fallback paths.
        usdc.addMinter(address(router));
        usdc.mint(address(router), 1_000_000_000e6);

        // --- Approve tokens on vault factory ---
        address[] memory tokenBatch = new address[](3);
        tokenBatch[0] = aapl;
        tokenBatch[1] = msft;
        tokenBatch[2] = nvda;
        uvFactory.setApprovedTokensBatch(tokenBatch, true);

        // --- Fund test accounts ---
        usdc.mint(deployer, INITIAL_USDC);
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
        usdc.mint(curator, INITIAL_USDC);
    }

    // ===================== Stock Token Beacon Tests =====================

    function test_stockTokens_areBeaconProxies() public view {
        assertTrue(aapl != address(0));
        assertEq(StockTokenUpgradeable(aapl).decimals(), 18);
        assertEq(StockTokenUpgradeable(aapl).symbol(), "AAPL");
        assertEq(StockTokenUpgradeable(aapl).owner(), address(factory));
    }

    function test_stockToken_routerIsMinter() public view {
        assertTrue(StockTokenUpgradeable(aapl).minters(address(router)));
        assertTrue(StockTokenUpgradeable(msft).minters(address(router)));
    }

    function test_stockToken_mint_burn() public {
        StockTokenUpgradeable token = StockTokenUpgradeable(aapl);
        vm.prank(address(factory));
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);

        vm.prank(address(factory));
        token.burn(alice, 50e18);
        assertEq(token.balanceOf(alice), 50e18);
    }

    // ===================== Hybrid Router Tests =====================

    function test_router_buyStock_mintBurn() public {
        router.setAuthorizedCaller(address(this), true);

        usdc.mint(address(this), 195e6);
        usdc.approve(address(router), 195e6);

        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 out = router.swap(address(usdc), aapl, 195e6, 0, address(this));

        assertEq(out, 1e18);
        assertEq(StockTokenUpgradeable(aapl).balanceOf(address(this)), 1e18);
        assertEq(usdc.balanceOf(address(router)), routerUsdcBefore + 195e6);
    }

    function test_router_sellStock_mintBurn() public {
        router.setAuthorizedCaller(address(this), true);

        vm.prank(address(factory));
        StockTokenUpgradeable(aapl).mint(address(this), 1e18);
        IERC20(aapl).approve(address(router), 1e18);

        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 recipientUsdcBefore = usdc.balanceOf(address(this));
        uint256 out = router.swap(aapl, address(usdc), 1e18, 0, address(this));

        assertEq(out, 195e6);
        assertEq(usdc.balanceOf(address(router)), routerUsdcBefore);
        assertEq(usdc.balanceOf(address(this)) - recipientUsdcBefore, 195e6);
    }

    // ===================== Vault Lifecycle (through proxies) =====================

    function test_vault_fullCycle() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.depositAndAllocate(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0);
        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length > 0);

        uint256 nav = vault.totalAssets();
        assertApproxEqRel(nav, SEED_AMOUNT + DEPOSIT_AMOUNT, 0.02e18);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(aliceShares, alice, alice);
        assertTrue(assets > 0);
    }

    function test_vault_executeTrade() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);
        vault.allocateIdleAssets();

        uint256 aaplBal = IERC20(aapl).balanceOf(vaultAddr);
        assertTrue(aaplBal > 0);

        vm.prank(curator);
        vault.executeTrade(aapl, nvda, aaplBal / 2, 0);

        assertTrue(IERC20(nvda).balanceOf(vaultAddr) > 0);
    }

    // ===================== Migration Tests =====================

    function test_migrateToken() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);
        vault.allocateIdleAssets();

        uint256 oldAaplBal = IERC20(aapl).balanceOf(vaultAddr);
        assertTrue(oldAaplBal > 0);

        address newAapl = factory.createStockToken("Tilt Apple v2", "AAPLv2", 195e18);
        router.setTokenPrice(newAapl, 195e18);
        router.setPairSupported(address(usdc), newAapl, true);

        vm.prank(address(factory));
        StockTokenUpgradeable(newAapl).mint(vaultAddr, oldAaplBal);

        vault.migrateToken(aapl, newAapl);

        address[] memory held = vault.getHeldTokens();
        bool foundNew = false;
        bool foundOld = false;
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i] == newAapl) foundNew = true;
            if (held[i] == aapl) foundOld = true;
        }
        assertTrue(foundNew, "new token should be in heldTokens");
        assertFalse(foundOld, "old token should be removed from heldTokens");

        IBaseVault.TokenWeight[] memory weights = vault.getTargetWeights();
        bool weightUpdated = false;
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i].token == newAapl) weightUpdated = true;
        }
        assertTrue(weightUpdated, "target weights should reference new token");
    }

    function test_migrateToken_onlyProtocolAdmin() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(alice);
        vm.expectRevert("UserVault: only protocol admin");
        vault.migrateToken(aapl, address(0xBEEF));
    }

    // ===================== Upgrade Tests =====================

    function test_upgradeTokenRouter() public {
        TokenRouterUpgradeable routerV2 = new TokenRouterUpgradeable();
        router.upgradeToAndCall(address(routerV2), "");

        assertEq(router.getTokenPrice(aapl), 195e18);
        assertEq(router.baseAsset(), address(usdc));
    }

    function test_upgradeTokenRouter_preservesPreFreshnessStorageLayout() public {
        address oracleWallet = makeAddr("oracleWallet");

        vm.store(address(router), _mappingSlot(aapl, 1), bytes32(uint256(123e18)));
        vm.store(address(router), _nestedMappingSlot(aapl, msft, 2), bytes32(uint256(1)));
        vm.store(address(router), _mappingSlot(address(engine), 3), bytes32(uint256(1)));
        vm.store(address(router), _mappingSlot(aapl, 4), bytes32(uint256(8)));
        vm.store(address(router), _mappingSlot(aapl, 5), bytes32(uint256(1)));
        vm.store(address(router), _mappingSlot(oracleWallet, 6), bytes32(uint256(1)));
        vm.store(address(router), _mappingSlot(aapl, 7), bytes32(0));

        TokenRouterUpgradeable routerV2 = new TokenRouterUpgradeable();
        router.upgradeToAndCall(
            address(routerV2),
            abi.encodeCall(TokenRouterUpgradeable.initializePriceFreshness, (7 days))
        );

        assertEq(router.getTokenPrice(aapl), 123e18);
        assertTrue(router.pairSupported(aapl, msft));
        assertTrue(router.authorizedCallers(address(engine)));
        assertEq(router.decimalOverride(aapl), 8);
        assertTrue(router.hasDecimalOverride(aapl));
        assertTrue(router.authorizedPricers(oracleWallet));
        assertEq(router.getTokenPriceUpdatedAt(aapl), 0);
        assertEq(router.maxPriceAge(), 7 days);
    }

    function test_upgradeRebalanceEngine() public {
        RebalanceEngineUpgradeable engineV2 = new RebalanceEngineUpgradeable();
        engine.upgradeToAndCall(address(engineV2), "");

        assertEq(address(engine.tokenRouter()), address(router));
        assertEq(engine.maxSlippageBps(), 100);
    }

    function test_upgradeStockTokenBeacon() public {
        uint256 balBefore = StockTokenUpgradeable(aapl).balanceOf(alice);
        vm.prank(address(factory));
        StockTokenUpgradeable(aapl).mint(alice, 10e18);

        StockTokenUpgradeable newImpl = new StockTokenUpgradeable();
        factory.upgradeTokenImplementation(address(newImpl));

        assertEq(StockTokenUpgradeable(aapl).balanceOf(alice), balBefore + 10e18);
        assertEq(StockTokenUpgradeable(aapl).symbol(), "AAPL");
    }

    function _mappingSlot(address key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _nestedMappingSlot(address outerKey, address innerKey, uint256 slot) internal pure returns (bytes32) {
        bytes32 outerSlot = keccak256(abi.encode(outerKey, slot));
        return keccak256(abi.encode(innerKey, outerSlot));
    }

    // ===================== Registry Bulk Register =====================

    function test_registry_bulkRegister() public {
        VaultRegistryUpgradeable.VaultInfo[] memory vaults = new VaultRegistryUpgradeable.VaultInfo[](2);
        vaults[0] = VaultRegistryUpgradeable.VaultInfo({
            vault: address(0xA),
            vaultType: VaultRegistryUpgradeable.VaultType.USER,
            curator: curator,
            metadataURI: "ipfs://a",
            createdAt: block.timestamp,
            active: true
        });
        vaults[1] = VaultRegistryUpgradeable.VaultInfo({
            vault: address(0xB),
            vaultType: VaultRegistryUpgradeable.VaultType.USER,
            curator: curator,
            metadataURI: "ipfs://b",
            createdAt: block.timestamp,
            active: true
        });

        registry.bulkRegister(vaults);

        assertTrue(registry.isRegistered(address(0xA)));
        assertTrue(registry.isRegistered(address(0xB)));
        assertEq(registry.totalVaults(), 2);
    }

    // ===================== FeeManager Proxy =====================

    function test_feeManager_proxy_works() public {
        feeManager.setDefaultFees(10, 50, 200, 2000);
        assertEq(feeManager.defaultEntryFeeBps(), 10);
        assertEq(feeManager.defaultManagementFeeBps(), 200);
    }

    // ===================== PriceOracle Proxy =====================

    function test_priceOracle_resolve() public view {
        uint256 price = oracle.getTokenPrice("AAPL");
        assertEq(price, 195e18);
    }

    // ===================== Helpers =====================

    function _createUserVault() internal returns (address vault) {
        address[] memory tokens = new address[](2);
        tokens[0] = aapl;
        tokens[1] = msft;

        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;

        vm.deal(curator, 1 ether);
        vm.startPrank(curator);
        usdc.approve(address(uvFactory), 1000e6);
        vault = uvFactory.createUserVault{value: 0.01 ether}(
            "Tech Growth", "vTECH", tokens, weights, 5000, 1000e6, "ipfs://tech"
        );
        vm.stopPrank();
    }

    receive() external payable {}
}
