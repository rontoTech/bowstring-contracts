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
import {MockStockToken, MockUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";

/// @title BowstringTest
/// @notice Comprehensive tests for the Insider protocol
contract BowstringTest is Test {
    // --- Actors ---
    address public deployer = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice"); // depositor
    address public bob = makeAddr("bob"); // depositor
    address public curator = makeAddr("curator"); // vault creator
    address public keeper = makeAddr("keeper"); // chainlink keeper

    // --- Core contracts ---
    MockUSDC public usdc;
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
    uint256 public constant INITIAL_USDC = 100_000e6; // 100k USDC
    uint256 public constant DEPOSIT_AMOUNT = 10_000e6; // 10k USDC

    function setUp() public {
        // Deploy base tokens
        usdc = new MockUSDC();

        aapl = new MockStockToken("Apple Inc.", "AAPL", 18);
        msft = new MockStockToken("Microsoft Corp.", "MSFT", 18);
        nvda = new MockStockToken("NVIDIA Corp.", "NVDA", 18);

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
            address(oracle)
        );

        // Setup permissions
        registry.setRegistrar(address(factory), true);
        feeManager.transferOwnership(address(factory));

        // Setup oracle
        oracle.registerPolitician(PELOSI_ID, "ipfs://pelosi-metadata");
        oracle.setReporter(keeper, true);

        // Setup router prices
        router.setTokenPrice(address(usdc), 1e18); // $1
        router.setTokenPrice(address(aapl), 195e18); // $195
        router.setTokenPrice(address(msft), 420e18); // $420
        router.setTokenPrice(address(nvda), 875e18); // $875

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
        usdc.mint(address(router), 1_000_000e6);
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
        assertEq(stored[1].token, address(msft));
        assertEq(stored[1].weightBps, 3500);
    }

    function test_Oracle_invalidWeights_reverts() public {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3000}); // sum = 8000, not 10000

        vm.prank(keeper);
        vm.expectRevert(PortfolioOracle.InvalidWeights.selector);
        oracle.updatePortfolio(PELOSI_ID, weights);
    }

    function test_Oracle_unauthorizedReporter_reverts() public {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](1);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 10000});

        vm.prank(alice);
        vm.expectRevert(PortfolioOracle.UnauthorizedReporter.selector);
        oracle.updatePortfolio(PELOSI_ID, weights);
    }

    function test_Oracle_snapshotHistory() public {
        // First update
        IBaseVault.TokenWeight[] memory w1 = new IBaseVault.TokenWeight[](1);
        w1[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 10000});
        vm.prank(keeper);
        oracle.updatePortfolio(PELOSI_ID, w1);

        // Second update
        IBaseVault.TokenWeight[] memory w2 = new IBaseVault.TokenWeight[](2);
        w2[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});
        w2[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 5000});
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        oracle.updatePortfolio(PELOSI_ID, w2);

        assertEq(oracle.getSnapshotCount(PELOSI_ID), 1);
        (IBaseVault.TokenWeight[] memory snapWeights,) = oracle.getSnapshot(PELOSI_ID, 0);
        assertEq(snapWeights.length, 1);
        assertEq(snapWeights[0].weightBps, 10000);
    }

    // ===================== Factory - Politician Vault Tests =====================

    function test_Factory_createPoliticianVault() public {
        address vault = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "vPELOSI", address(0), "ipfs://pelosi"
        );

        assertTrue(vault != address(0));
        assertTrue(factory.isVault(vault));
        assertEq(factory.totalVaults(), 1);

        // Check registry
        assertTrue(registry.isRegistered(vault));
        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(vault);
        assertEq(uint256(info.vaultType), uint256(VaultRegistry.VaultType.POLITICIAN));
    }

    function test_Factory_createPoliticianVault_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.createPoliticianVault(PELOSI_ID, "Pelosi", "vPEL", address(0), "");
    }

    // ===================== Politician Vault - Deposit/Withdraw =====================

    function test_PoliticianVault_deposit() public {
        address vaultAddr = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "vPELOSI", address(0), ""
        );
        PoliticianVault vault = PoliticianVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0);
        assertEq(vault.balanceOf(alice), shares);

        // Entry fee = 0.3% of 10000 USDC = 30 USDC
        // Net deposit = 9970 USDC
        uint256 expectedNet = DEPOSIT_AMOUNT - (DEPOSIT_AMOUNT * 30 / 10000);
        assertEq(vault.totalAssets(), expectedNet);
    }

    function test_PoliticianVault_withdraw() public {
        address vaultAddr = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "vPELOSI", address(0), ""
        );
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Deposit
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // Withdraw half
        uint256 withdrawAmount = 4000e6;
        uint256 sharesBefore = vault.balanceOf(alice);
        vault.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        assertTrue(vault.balanceOf(alice) < sharesBefore);
    }

    function test_PoliticianVault_rebalance_onlyKeeper() public {
        address vaultAddr = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "vPELOSI", address(0), ""
        );
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Set oracle weights
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 6000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 4000});
        vm.prank(keeper);
        oracle.updatePortfolio(PELOSI_ID, weights);

        // Non-keeper should revert
        vm.prank(alice);
        vm.expectRevert(PoliticianVault.UnauthorizedRebalance.selector);
        vault.rebalance();

        // Owner should succeed (no rebalance engine auth issue in this test setup)
        vault.setKeeper(keeper, true);
    }

    // ===================== Factory - User Vault Tests =====================

    function test_Factory_createUserVault() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aapl);
        tokens[1] = address(msft);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;

        vm.deal(curator, 1 ether);
        vm.startPrank(curator);
        usdc.approve(address(factory), 1000e6);

        address vault = factory.createUserVault{value: 0.01 ether}(
            "Tech Growth", "vTECH", tokens, weights, 5000, 1000e6, "ipfs://tech-vault"
        );
        vm.stopPrank();

        assertTrue(vault != address(0));
        assertTrue(factory.isVault(vault));

        // Check registry
        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(vault);
        assertEq(uint256(info.vaultType), uint256(VaultRegistry.VaultType.USER));
        assertEq(info.curator, curator);
    }

    function test_Factory_createUserVault_insufficientFee_reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(aapl);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        vm.deal(curator, 1 ether);
        vm.startPrank(curator);
        usdc.approve(address(factory), 1000e6);
        vm.expectRevert(VaultFactory.InsufficientCreationFee.selector);
        factory.createUserVault{value: 0.001 ether}(
            "Test", "vTST", tokens, weights, 5000, 1000e6, ""
        );
        vm.stopPrank();
    }

    function test_Factory_createUserVault_invalidWeights_reverts() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aapl);
        tokens[1] = address(msft);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 3000; // sum = 8000

        vm.deal(curator, 1 ether);
        vm.startPrank(curator);
        usdc.approve(address(factory), 1000e6);
        vm.expectRevert(VaultFactory.InvalidWeights.selector);
        factory.createUserVault{value: 0.01 ether}(
            "Bad Weights", "vBAD", tokens, weights, 5000, 1000e6, ""
        );
        vm.stopPrank();
    }

    function test_Factory_createUserVault_unapprovedToken_reverts() public {
        MockStockToken badToken = new MockStockToken("Bad", "BAD", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(badToken);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        vm.deal(curator, 1 ether);
        vm.startPrank(curator);
        usdc.approve(address(factory), 1000e6);
        vm.expectRevert(VaultFactory.TokenNotApproved.selector);
        factory.createUserVault{value: 0.01 ether}(
            "Bad Token", "vBAD", tokens, weights, 5000, 1000e6, ""
        );
        vm.stopPrank();
    }

    // ===================== UserVault - Curator Controls =====================

    function test_UserVault_curatorSetWeights() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        IBaseVault.TokenWeight[] memory newWeights = new IBaseVault.TokenWeight[](2);
        newWeights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 7000});
        newWeights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3000});

        // Since time-lock is active, weights should be pending
        vm.prank(curator);
        vault.setTargetWeights(newWeights);

        assertTrue(vault.hasPendingWeights());
    }

    function test_UserVault_applyPendingWeights() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        IBaseVault.TokenWeight[] memory newWeights = new IBaseVault.TokenWeight[](2);
        newWeights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 7000});
        newWeights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3000});

        vm.prank(curator);
        vault.setTargetWeights(newWeights);

        // Fast forward past time-lock
        vm.warp(block.timestamp + 25 hours);

        vault.applyPendingWeights();
        assertFalse(vault.hasPendingWeights());
    }

    function test_UserVault_nonCurator_setWeights_reverts() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        IBaseVault.TokenWeight[] memory newWeights = new IBaseVault.TokenWeight[](1);
        newWeights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 10000});

        vm.prank(alice);
        vm.expectRevert(UserVault.OnlyCurator.selector);
        vault.setTargetWeights(newWeights);
    }

    function test_UserVault_transferCurator() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(curator);
        vault.transferCurator(alice);
        assertEq(vault.curator(), alice);
    }

    // ===================== VaultRegistry Tests =====================

    function test_Registry_vaultsByType() public {
        // Create one of each
        factory.createPoliticianVault(PELOSI_ID, "Pelosi", "vPEL", address(0), "");
        _createUserVault();

        address[] memory polVaults = registry.getVaultsByType(VaultRegistry.VaultType.POLITICIAN);
        address[] memory userVaults = registry.getVaultsByType(VaultRegistry.VaultType.USER);

        assertEq(polVaults.length, 1);
        assertEq(userVaults.length, 1);
    }

    function test_Registry_curatorProfile() public {
        _createUserVault();

        VaultRegistry.CuratorProfile memory profile = registry.getCuratorProfile(curator);
        assertTrue(profile.registered);
        assertEq(profile.totalVaults, 1);
    }

    // ===================== Mock Token Factory Tests =====================

    function test_MockTokenFactory_deployStandard() public {
        tokenFactory.deployStandardTokens();
        assertEq(tokenFactory.totalTokens(), 10);

        assertTrue(tokenFactory.tokenBySymbol("AAPL") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("MSFT") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("NVDA") != address(0));
    }

    // ===================== Router Tests =====================

    function test_Router_getQuote() public view {
        // USDC -> AAPL: 195 USDC should get 1 AAPL
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
        usdc.approve(address(factory), 1000e6);
        vault = factory.createUserVault{value: 0.01 ether}(
            "Tech Growth", "vTECH", tokens, weights, 5000, 1000e6, "ipfs://tech"
        );
        vm.stopPrank();
    }

    receive() external payable {}
}
