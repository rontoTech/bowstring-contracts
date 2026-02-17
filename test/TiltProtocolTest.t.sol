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
import {MockStockToken, TiltUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {BaseVault} from "../src/core/BaseVault.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../src/interfaces/IRebalanceEngine.sol";

/// @title TiltProtocolTest
/// @notice Comprehensive tests for the Tilt Protocol
contract TiltProtocolTest is Test {
    // --- Actors ---
    address public deployer = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public curator = makeAddr("curator");
    address public keeper = makeAddr("keeper");

    // --- Core contracts ---
    TiltUSDC public usdc;
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
    uint256 public constant INITIAL_USDC = 100_000e18; // 100k tiltUSDC (18 dec)
    uint256 public constant DEPOSIT_AMOUNT = 10_000e18; // 10k tiltUSDC
    uint256 public constant SEED_AMOUNT = 1000e18; // 1k tiltUSDC seed

    function setUp() public {
        // Deploy base tokens
        usdc = new TiltUSDC();

        aapl = new MockStockToken("Tilt Apple", "tiltAAPL", 18);
        msft = new MockStockToken("Tilt Microsoft", "tiltMSFT", 18);
        nvda = new MockStockToken("Tilt NVIDIA", "tiltNVDA", 18);

        // Deploy core infrastructure
        feeManager = new FeeManager(treasury, address(usdc));
        registry = new VaultRegistry();
        oracle = new PortfolioOracle();
        router = new MockTokenRouter();
        engine = new RebalanceEngine(address(router), address(usdc));
        tokenFactory = new MockStockTokenFactory();

        // Deploy factory
        factory = new VaultFactory(
            address(usdc), address(feeManager), address(registry), address(engine), address(router), address(oracle)
        );

        // Setup permissions
        registry.setRegistrar(address(factory), true);
        registry.setRegistrar(deployer, true);

        // FeeManager: deployer stays owner, factory is authorized caller
        feeManager.setAuthorizedCaller(address(factory), true);

        // Set all fees to 0 for test simplicity
        feeManager.setDefaultFees(0, 0, 0, 0);

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

        // Engine: authorize factory to register vaults
        engine.setAuthorizedCaller(address(factory), true);

        // Setup approved tokens in factory
        factory.setApprovedToken(address(aapl), true);
        factory.setApprovedToken(address(msft), true);
        factory.setApprovedToken(address(nvda), true);

        // Fund test accounts
        usdc.mint(deployer, INITIAL_USDC);
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
        // We set all fees to 0 in setUp
        assertEq(feeManager.defaultEntryFeeBps(), 0);
        assertEq(feeManager.defaultExitFeeBps(), 0);
        assertEq(feeManager.protocolTreasury(), treasury);
    }

    function test_FeeManager_ERC20_withdrawal() public {
        // Send some tiltUSDC to feeManager to simulate accumulated fees
        usdc.mint(address(feeManager), 1000e18);

        // Configure vault fees (deployer is FeeManager owner, so authorized)
        address mockVault = address(0x1234);
        feeManager.configureVaultFees(mockVault, 0, address(0));

        // Accumulate protocol fees by calling recordFees from the mock vault
        vm.prank(mockVault);
        feeManager.recordFees(500e18);

        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        feeManager.collectProtocolFees();
        uint256 treasuryBalanceAfter = usdc.balanceOf(treasury);

        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, 500e18);
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

    function test_Oracle_stalenessCheck() public {
        // Set max staleness
        oracle.setMaxStaleness(1 days);

        // Update portfolio
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](3);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 4000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3500});
        weights[2] = IBaseVault.TokenWeight({token: address(nvda), weightBps: 2500});

        vm.prank(keeper);
        oracle.updatePortfolio(PELOSI_ID, weights);

        // Should work immediately
        oracle.getPortfolio(PELOSI_ID);

        // Fast forward past staleness
        vm.warp(block.timestamp + 2 days);

        // Should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioOracle.StaleData.selector, PELOSI_ID, block.timestamp - 2 days, 1 days
            )
        );
        oracle.getPortfolio(PELOSI_ID);
    }

    // ===================== Factory Tests =====================

    function test_Factory_createPoliticianVault() public {
        // Seed oracle portfolio first
        _seedOraclePortfolio();

        // Approve seed deposit
        usdc.approve(address(factory), SEED_AMOUNT);

        address vault = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "tiltPELOSI", address(0), "ipfs://pelosi", SEED_AMOUNT
        );

        assertTrue(vault != address(0));
        assertTrue(factory.isVault(vault));
        assertEq(factory.totalVaults(), 1);
        assertTrue(registry.isRegistered(vault));

        // Dead shares should exist at address(1)
        PoliticianVault pVault = PoliticianVault(vault);
        assertTrue(pVault.balanceOf(address(1)) > 0);
        assertTrue(pVault.totalSupply() > 0);
    }

    function test_Factory_approvedTokenList_removal() public {
        // Add a token
        factory.setApprovedToken(address(0xBEEF), true);
        address[] memory tokens = factory.getApprovedTokens();
        uint256 lenBefore = tokens.length;

        // Remove it
        factory.setApprovedToken(address(0xBEEF), false);
        tokens = factory.getApprovedTokens();

        assertEq(tokens.length, lenBefore - 1);
        assertFalse(factory.approvedTokens(address(0xBEEF)));
    }

    // ===================== Politician Vault Tests =====================

    function test_PoliticianVault_deposit() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_PoliticianVault_rebalance_onlyKeeper() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        vm.prank(alice);
        vm.expectRevert(PoliticianVault.UnauthorizedRebalance.selector);
        vault.rebalance();

        vault.setKeeper(keeper, true);
    }

    function test_PoliticianVault_pause() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Pause
        vault.pause();
        assertTrue(vault.paused());

        // Deposit should revert when paused
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Unpause
        vault.unpause();
        assertFalse(vault.paused());

        // Deposit should work again
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_PoliticianVault_depositAndRebalance() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // depositAndRebalance now requires keeper/owner access
        vault.setKeeper(alice, true);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.depositAndRebalance(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0);

        // Should have held tokens after rebalance
        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length > 0);
    }

    function test_PoliticianVault_depositAndRebalance_unauthorized() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Random user should NOT be able to call depositAndRebalance
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert(PoliticianVault.UnauthorizedRebalance.selector);
        vault.depositAndRebalance(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    // ===================== User Vault Tests =====================

    function test_UserVault_create() public {
        address vaultAddr = _createUserVault();
        assertTrue(vaultAddr != address(0));
        assertTrue(factory.isVault(vaultAddr));
    }

    function test_UserVault_timelocked_setRebalanceEngine() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        // The factory sets a 24h timelock by default
        assertEq(vault.weightChangeTimeLock(), 24 hours);

        // Propose a new engine
        vm.prank(curator);
        vault.setRebalanceEngine(address(0xDEAD));

        // Should have pending change
        (address value, uint256 effectiveTime, bool pending) = vault.pendingRebalanceEngine();
        assertTrue(pending);
        assertEq(value, address(0xDEAD));

        // Try to apply before timelock expires (as curator)
        vm.prank(curator);
        vm.expectRevert(UserVault.TimeLockNotExpired.selector);
        vault.applyRebalanceEngine();

        // Fast forward past timelock
        vm.warp(block.timestamp + 25 hours);
        vm.prank(curator);
        vault.applyRebalanceEngine();

        // Verify applied
        assertEq(address(vault.rebalanceEngine()), address(0xDEAD));
    }

    function test_UserVault_timelocked_setTokenRouter() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(curator);
        vault.setTokenRouter(address(0xBEEF));

        (address value,, bool pending) = vault.pendingTokenRouter();
        assertTrue(pending);
        assertEq(value, address(0xBEEF));

        vm.warp(block.timestamp + 25 hours);
        vm.prank(curator);
        vault.applyTokenRouter();

        assertEq(address(vault.tokenRouter()), address(0xBEEF));
    }

    function test_UserVault_pause() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        // Curator can pause
        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        // Curator can unpause
        vm.prank(curator);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ===================== Router Tests =====================

    function test_Router_getQuote() public view {
        // 195 tiltUSDC should get 1 tiltAAPL
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

    // ===================== TiltUSDC Faucet Tests =====================

    function test_TiltUSDC_faucet() public {
        vm.prank(alice);
        usdc.faucet();
        // Alice had INITIAL_USDC from setUp, plus 10,000 from faucet
        assertEq(usdc.balanceOf(alice), INITIAL_USDC + 10_000e18);
    }

    function test_TiltUSDC_faucet_cooldown() public {
        vm.startPrank(alice);
        usdc.faucet();
        vm.expectRevert("TiltUSDC: faucet cooldown active");
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

        assertTrue(tokenFactory.tokenBySymbol("tiltAAPL") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("tiltMSFT") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("tiltNVDA") != address(0));
    }

    // ===================== Slippage Protection Tests =====================

    function test_withdrawalSlippage_configurable() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Default is 100 bps (1%)
        assertEq(vault.withdrawalSlippageBps(), 100);

        // Owner can change it
        vault.setWithdrawalSlippage(200); // 2%
        assertEq(vault.withdrawalSlippageBps(), 200);

        // Too high should revert
        vm.expectRevert("PoliticianVault: slippage too high");
        vault.setWithdrawalSlippage(1500); // 15% - too high
    }

    // ===================== Engine Authorization Tests =====================

    function test_Engine_authorizedCallers() public {
        // Factory should be authorized
        assertTrue(engine.authorizedCallers(address(factory)));

        // Factory can authorize a vault
        vm.prank(address(factory));
        engine.setVaultAuthorized(address(0xABCD), true);
        assertTrue(engine.authorizedVaults(address(0xABCD)));
    }

    // ===================== Security Fix Tests =====================

    function test_FeeManager_recordFees_accessControl() public {
        // Unconfigured vault should not be able to record fees
        vm.prank(alice);
        vm.expectRevert("FeeManager: caller not a configured vault");
        feeManager.recordFees(100e18);
    }

    function test_FeeManager_treasuryMigration() public {
        // Give feeManager some USDC
        usdc.mint(address(feeManager), 1000e18);
        address mockVault = address(0x1234);
        feeManager.configureVaultFees(mockVault, 0, address(0));
        vm.prank(mockVault);
        feeManager.recordFees(500e18);

        // Verify fees accumulated to old treasury
        assertEq(feeManager.accumulatedProtocolFees(treasury), 500e18);

        // Change treasury
        address newTreasury = makeAddr("newTreasury");
        feeManager.setTreasury(newTreasury);

        // Old treasury should have 0, new treasury should have the fees
        assertEq(feeManager.accumulatedProtocolFees(treasury), 0);
        assertEq(feeManager.accumulatedProtocolFees(newTreasury), 500e18);
    }

    function test_UserVault_cancelPendingEngine() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(curator);
        vault.setRebalanceEngine(address(0xDEAD));

        (,, bool pending) = vault.pendingRebalanceEngine();
        assertTrue(pending);

        vm.prank(curator);
        vault.cancelPendingRebalanceEngine();

        (,, bool pendingAfter) = vault.pendingRebalanceEngine();
        assertFalse(pendingAfter);
    }

    function test_UserVault_cancelPendingWeights() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 7000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3000});

        vm.prank(curator);
        vault.setTargetWeights(weights);
        assertTrue(vault.hasPendingWeights());

        vm.prank(curator);
        vault.cancelPendingWeights();
        assertFalse(vault.hasPendingWeights());
    }

    function test_UserVault_duplicateToken_reverts() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});
        weights[1] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});

        vm.prank(curator);
        vm.expectRevert(UserVault.DuplicateToken.selector);
        vault.setTargetWeights(weights);
    }

    function test_UserVault_depositAndRebalance_accessControl() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        // Random user should NOT be able to call depositAndRebalance
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert(UserVault.UnauthorizedRebalance.selector);
        vault.depositAndRebalance(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_Engine_accessControl_executeRebalance() public {
        address vaultAddr = _createPoliticianVault();

        // Random caller should not be able to execute rebalance for a vault
        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](0);
        vm.prank(alice);
        vm.expectRevert(RebalanceEngine.UnauthorizedVault.selector);
        engine.executeRebalance(vaultAddr, trades);
    }

    function test_Oracle_duplicateToken_reverts() public {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});
        weights[1] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 5000});

        vm.prank(keeper);
        vm.expectRevert("PortfolioOracle: duplicate token");
        oracle.updatePortfolio(PELOSI_ID, weights);
    }

    function test_FeeManager_rescueToken_guard() public {
        // Give feeManager some USDC
        usdc.mint(address(feeManager), 1000e18);
        address mockVault = address(0x1234);
        feeManager.configureVaultFees(mockVault, 0, address(0));
        vm.prank(mockVault);
        feeManager.recordFees(500e18);

        // Should not be able to rescue more than unreserved amount
        vm.expectRevert("FeeManager: would drain reserved fees");
        feeManager.rescueToken(address(usdc), deployer, 600e18);

        // Should be able to rescue up to the unreserved amount
        feeManager.rescueToken(address(usdc), deployer, 500e18);
    }

    // ===================== F-01: Rebalance Buy Budget includes Unallocated Base =====================

    function test_RebalanceEngine_unallocatedBase_buyBudget() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Deposit but DON'T rebalance — vault is 100% base asset
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Get current weights (should be empty since no held tokens)
        IBaseVault.TokenWeight[] memory currentWeights = vault.getCurrentWeights();
        IBaseVault.TokenWeight[] memory targetWeights = vault.getTargetWeights();
        uint256 totalValue = vault.totalAssets();

        // Calculate rebalance: should produce buy trades for the full base value
        IRebalanceEngine.TradeOrder[] memory trades =
            engine.calculateRebalance(vaultAddr, currentWeights, targetWeights, totalValue);

        // Must have buy trades (previously would return 0 buys)
        uint256 totalBuyValue = 0;
        for (uint256 i = 0; i < trades.length; i++) {
            if (trades[i].tokenIn == address(usdc)) {
                totalBuyValue += trades[i].amountIn;
            }
        }
        assertTrue(totalBuyValue > 0, "Buy budget should include unallocated base");
        // Buy budget should be approximately equal to totalValue (within rounding)
        assertApproxEqRel(totalBuyValue, totalValue, 0.02e18); // within 2%
    }

    // ===================== F-02: Emergency Unpause by Protocol Admin =====================

    function test_UserVault_emergencyUnpause_protocolAdmin() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        // Curator pauses
        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        // Random user cannot unpause
        vm.prank(alice);
        vm.expectRevert(UserVault.UnauthorizedUnpause.selector);
        vault.unpause();

        // Protocol admin (feeManager.owner() = deployer) CAN unpause
        vm.prank(feeManager.owner());
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_UserVault_curatorCanStillUnpause() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        // Curator can still unpause (backwards compatible)
        vm.prank(curator);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ===================== F-03: Curator Fees Protected in rescueToken =====================

    function test_FeeManager_rescueToken_protectsCuratorFees() public {
        usdc.mint(address(feeManager), 1000e18);

        // Configure vault with 50% curator split
        address mockVault = address(0x5678);
        feeManager.configureVaultFees(mockVault, 5000, curator);

        // Record fees (500 protocol + 500 curator)
        vm.prank(mockVault);
        feeManager.recordFees(1000e18);

        // Total reserved = 500 protocol + 500 curator = 1000
        // Contract balance is 1000, so nothing should be rescuable
        vm.expectRevert("FeeManager: would drain reserved fees");
        feeManager.rescueToken(address(usdc), deployer, 1);
    }

    // ===================== F-04: Graceful Zero-Price Token Handling =====================

    function test_totalAssets_zeroPriceToken_noRevert() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Deposit and rebalance to get held tokens
        vault.setKeeper(keeper, true);
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance();

        // Verify vault has held tokens
        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length > 0);

        // Clear one token price (simulate oracle failure)
        router.clearTokenPrice(address(aapl));

        // totalAssets should NOT revert — it should just skip the zero-price token
        uint256 total = vault.totalAssets();
        assertTrue(total > 0, "totalAssets should still return a value");
    }

    // ===================== M-01: Deposit Circuit Breaker on Zero-Price Oracle =====================

    function test_deposit_blockedOnZeroPriceOracle() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Deposit and rebalance to get held tokens
        vault.setKeeper(keeper, true);
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance();

        // Clear one token price (simulate oracle failure)
        router.clearTokenPrice(address(aapl));

        // NEW deposits should be BLOCKED (circuit breaker)
        vm.startPrank(bob);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert(BaseVault.OracleDegraded.selector);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Restore price — deposits should work again
        router.setTokenPrice(address(aapl), 195e18);

        vm.startPrank(bob);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();
        assertTrue(shares > 0, "deposit should succeed after oracle recovery");
    }

    function test_withdraw_allowedDuringZeroPriceOracle() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Deposit WITHOUT rebalance — vault holds 100% base asset
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Clear a token price (even though vault doesn't hold it yet, test the logic path)
        // Since vault has no held tokens with balance, _hasZeroPriceToken = false
        // This proves withdrawals aren't blocked when vault is in base-only mode
        router.clearTokenPrice(address(aapl));

        // Alice can still withdraw (vault is 100% base, no held tokens affected)
        uint256 aliceShares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.redeem(aliceShares / 2, alice, alice);
        vm.stopPrank();
        assertTrue(vault.balanceOf(alice) < aliceShares, "shares should have decreased");
    }

    function test_deposit_allowedWhenOracleHealthy() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // Deposit and rebalance
        vault.setKeeper(keeper, true);
        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance();

        // All prices are healthy — deposit should work
        vm.startPrank(bob);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();
        assertTrue(shares > 0);
    }

    // ===================== M-02: Held Tokens Cap =====================

    function test_heldTokens_cappedAtMax() public {
        address vaultAddr = _createPoliticianVault();
        PoliticianVault vault = PoliticianVault(vaultAddr);

        // The vault starts with max 3 target tokens (aapl, msft, nvda).
        // After rebalance, heldTokens should be <= MAX_HELD_TOKENS.
        vault.setKeeper(keeper, true);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance();

        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length <= vault.MAX_HELD_TOKENS(), "heldTokens should be capped");
        assertTrue(held.length == 3, "should have exactly 3 target tokens");
    }

    // ===================== F-05: One-Time Fee Configuration =====================

    function test_FeeManager_configureVaultFees_onlyOnce() public {
        address mockVault = address(0x9999);

        // First configuration succeeds
        feeManager.configureVaultFees(mockVault, 0, address(0));

        // Second configuration on the same vault MUST revert
        vm.expectRevert("FeeManager: vault fees already configured");
        feeManager.configureVaultFees(mockVault, 5000, curator);
    }

    // ===================== Helpers =====================

    function _seedOraclePortfolio() internal {
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](3);
        weights[0] = IBaseVault.TokenWeight({token: address(aapl), weightBps: 4000});
        weights[1] = IBaseVault.TokenWeight({token: address(msft), weightBps: 3500});
        weights[2] = IBaseVault.TokenWeight({token: address(nvda), weightBps: 2500});

        vm.prank(keeper);
        oracle.updatePortfolio(PELOSI_ID, weights);
    }

    function _createPoliticianVault() internal returns (address vault) {
        _seedOraclePortfolio();

        usdc.approve(address(factory), SEED_AMOUNT);
        vault = factory.createPoliticianVault(
            PELOSI_ID, "Pelosi Tracker", "tiltPELOSI", address(0), "ipfs://pelosi", SEED_AMOUNT
        );
    }

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
