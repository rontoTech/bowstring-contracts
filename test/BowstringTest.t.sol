// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {FeeManager} from "../src/core/FeeManager.sol";
import {PoliticianVault} from "../src/core/PoliticianVault.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {PortfolioOracle} from "../src/oracle/PortfolioOracle.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {MockStockToken, BowUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";

/// @title BowstringTest
/// @notice Comprehensive tests for the Bowstring protocol
contract BowstringTest is Test {
    // --- Actors ---
    address public deployer = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public curator = makeAddr("curator");
    address public keeper = makeAddr("keeper");

    // --- Core contracts ---
    BowUSDC public usdc;
    FeeManager public feeManager;
    VaultRegistry public registry;
    PortfolioOracle public oracle;
    MockTokenRouter public router;
    RebalanceEngine public engine;
    VaultFactory public factory;
    MockStockTokenFactory public tokenFactory;

    // --- Mock stock tokens ---
    MockStockToken public aapl;
    MockStockToken public msft;
    MockStockToken public nvda;

    // --- Test constants ---
    bytes32 public constant PELOSI_ID = keccak256("nancy-pelosi");
    uint256 public constant INITIAL_USDC = 100_000e18; // 100k bowUSDC (18 dec)
    uint256 public constant DEPOSIT_AMOUNT = 10_000e18; // 10k bowUSDC

    function setUp() public {
        // Deploy base tokens
        usdc = new BowUSDC();

        aapl = new MockStockToken("Bowstring Apple", "bowAAPL", 18);
        msft = new MockStockToken("Bowstring Microsoft", "bowMSFT", 18);
        nvda = new MockStockToken("Bowstring NVIDIA", "bowNVDA", 18);

        // Deploy core infrastructure
        feeManager = new FeeManager(treasury);
        registry = new VaultRegistry();
        oracle = new PortfolioOracle();
        router = new MockTokenRouter();
        engine = new RebalanceEngine(address(router), address(usdc));
        tokenFactory = new MockStockTokenFactory();

        // Deploy factory
        factory = new VaultFactory(
            address(usdc),
            address(feeManager),
            address(registry),
            address(engine),
            address(router),
            address(oracle)
        );

        // Setup permissions
        registry.setRegistrar(address(factory), true);
        registry.setRegistrar(deployer, true);
        feeManager.transferOwnership(address(factory));

        // Setup oracle
        oracle.registerPolitician(PELOSI_ID, "ipfs://pelosi-metadata");
        oracle.setReporter(keeper, true);

        // Setup router prices
        router.setTokenPrice(address(usdc), 1e18);   // $1
        router.setTokenPrice(address(aapl), 195e18);  // $195
        router.setTokenPrice(address(msft), 420e18);  // $420
        router.setTokenPrice(address(nvda), 875e18);  // $875

        // Setup pairs
        router.setPairSupported(address(usdc), address(aapl), true);
        router.setPairSupported(address(usdc), address(msft), true);
        router.setPairSupported(address(usdc), address(nvda), true);
        router.setAuthorizedCaller(address(engine), true);

        // Setup approved tokens in factory
        factory.setApprovedToken(address(aapl), true);
        factory.setApprovedToken(address(msft), true);
        factory.setApprovedToken(address(nvda), true);

        // Fund test accounts
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
        usdc.mint(curator, INITIAL_USDC);

        // Fund router with stock tokens for swaps
        aapl.mint(address(router), 1_000_000e18);
        msft.mint(address(router), 1_000_000e18);
        nvda.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 1_000_000e18);
    }

    // ===================== FeeManager Tests =====================

    function test_FeeManager_defaults() public view {
        assertEq(feeManager.defaultEntryFeeBps(), 30);
        assertEq(feeManager.defaultExitFeeBps(), 50);
        assertEq(feeManager.defaultManagementFeeBps(), 50);
        assertEq(feeManager.defaultPerformanceFeeBps(), 1500);
        assertEq(feeManager.protocolTreasury(), treasury);
    }

    // ===================== Oracle Tests =====================

    function test_Oracle_registerPolitician() public view {
        assertTrue(oracle.isPoliticianRegistered(PELOSI_ID));
        assertEq(oracle.totalRegisteredPoliticians(), 1);
    }

    function test_Oracle_updatePortfolio() public {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](3);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 4000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3500});
        weights[2] = IBaseVault.TokenWeight({token: address(nvda), weightBps: 2500});

        vm.prank(keeper);
        oracle.updatePortfolio(PELOSI_ID, weights);

        IBaseVault.TokenWeight[] memory stored = oracle.getPortfolio(PELOSI_ID);
        assertEq(stored.length, 3);
        assertEq(stored[0].token, address(aapl));
        assertEq(stored[0].weightBps, 4000);
    }

    function test_Oracle_invalidWeights_reverts() public {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3000});

        vm.prank(keeper);
        vm.expectRevert(PortfolioOracle.InvalidWeights.selector);
        oracle.updatePortfolio(PELOSI_ID, weights);
    }

    // ===================== Factory Tests =====================

    function test_Factory_createPoliticianVault() public {
        address vault = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "bowPELOSI", address(0), "ipfs://pelosi"
        );

        assertTrue(vault != address(0));
        assertTrue(factory.isVault(vault));
        assertEq(factory.totalVaults(), 1);
        assertTrue(registry.isRegistered(vault));
    }

    // ===================== Politician Vault Tests =====================

    function test_PoliticianVault_deposit() public {
        address vaultAddr = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "bowPELOSI", address(0), ""
        );
        PoliticianVault vault = PoliticianVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0);
        assertEq(vault.balanceOf(alice), shares);

        // Entry fee = 0.3% of 10,000 = 30 bowUSDC deducted
        uint256 expectedNet = DEPOSIT_AMOUNT - (DEPOSIT_AMOUNT * 30 / 10000);
        assertEq(vault.totalAssets(), expectedNet);
    }

    function test_PoliticianVault_rebalance_onlyKeeper() public {
        address vaultAddr = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "bowPELOSI", address(0), ""
        );
        PoliticianVault vault = PoliticianVault(vaultAddr);

        vm.prank(alice);
        vm.expectRevert(PoliticianVault.UnauthorizedRebalance.selector);
        vault.rebalance();

        vault.setKeeper(keeper, true);
    }

    // ===================== Router Tests =====================

    function test_Router_getQuote() public view {
        // 195 bowUSDC should get 1 bowAAPL
        uint256 quote = router.getQuote(address(usdc), address(aapl), 195e18);
        assertEq(quote, 1e18);
    }

    function test_Router_swap() public {
        usdc.mint(address(this), 195e18);
        usdc.approve(address(router), 195e18);

        router.setAuthorizedCaller(address(this), true);
        uint256 out = router.swap(address(usdc), address(aapl), 195e18, 0, address(this));
        assertEq(out, 1e18);
        assertEq(aapl.balanceOf(address(this)), 1e18);
    }

    function test_Router_getTokenPrice() public view {
        assertEq(router.getTokenPrice(address(usdc)), 1e18);
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
    }

    // ===================== BowUSDC Faucet Tests =====================

    function test_BowUSDC_faucet() public {
        vm.prank(alice);
        usdc.faucet();
        // Alice had INITIAL_USDC from setUp, plus 10,000 from faucet
        assertEq(usdc.balanceOf(alice), INITIAL_USDC + 10_000e18);
    }

    function test_BowUSDC_faucet_cooldown() public {
        vm.startPrank(alice);
        usdc.faucet();
        vm.expectRevert("BowUSDC: faucet cooldown active");
        usdc.faucet();
        vm.stopPrank();

        // Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice);
        usdc.faucet(); // Should succeed now
    }

    // ===================== Mock Token Factory Tests =====================

    function test_MockTokenFactory_deployStandard() public {
        tokenFactory.deployStandardTokens();
        assertEq(tokenFactory.totalTokens(), 10);

        assertTrue(tokenFactory.tokenBySymbol("bowAAPL") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("bowMSFT") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("bowNVDA") != address(0));
    }

    // ===================== Helpers =====================

    function _createUserVault() internal returns (address vault) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aapl);
        tokens[1] = address(msft);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;

        vm.deal(curator, 1 ether);
        vm.startPrank(curator);
        usdc.approve(address(factory), 1000e18);
        vault = factory.createUserVault{value: 0.01 ether}(
            "Tech Growth", "vTECH", tokens, weights, 5000, 1000e18, "ipfs://tech"
        );
        vm.stopPrank();
    }

    receive() external payable {}
}
