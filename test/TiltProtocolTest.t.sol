// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {FeeManager} from "../src/core/FeeManager.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {UserVaultFactory} from "../src/core/UserVaultFactory.sol";
import {VaultRegistry} from "../src/core/VaultRegistry.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter} from "../src/rebalance/TokenRouter.sol";
import {MockStockToken, TiltUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";
import {BaseVault} from "../src/core/BaseVault.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../src/interfaces/IRebalanceEngine.sol";

/// @title TiltProtocolTest
/// @notice Comprehensive tests for the Tilt Protocol (unified UserVault architecture)
contract TiltProtocolTest is Test {
    // --- Actors ---
    address public deployer = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public curator = makeAddr("curator");

    // --- Core contracts ---
    TiltUSDC public usdc;
    FeeManager public feeManager;
    VaultRegistry public registry;
    MockTokenRouter public router;
    RebalanceEngine public engine;
    UserVaultFactory public uvFactory;
    MockStockTokenFactory public tokenFactory;

    // --- Mock stock tokens ---
    MockStockToken public aapl;
    MockStockToken public msft;
    MockStockToken public nvda;

    // --- Test constants ---
    uint256 public constant INITIAL_USDC = 100_000e6;
    uint256 public constant DEPOSIT_AMOUNT = 10_000e6;
    uint256 public constant SEED_AMOUNT = 1000e6;

    function setUp() public {
        usdc = new TiltUSDC();

        aapl = new MockStockToken("Tilt Apple", "tiltAAPL", 18);
        msft = new MockStockToken("Tilt Microsoft", "tiltMSFT", 18);
        nvda = new MockStockToken("Tilt NVIDIA", "tiltNVDA", 18);

        feeManager = new FeeManager(treasury, address(usdc));
        registry = new VaultRegistry();
        router = new MockTokenRouter();
        engine = new RebalanceEngine(address(router), address(usdc));
        tokenFactory = new MockStockTokenFactory();

        uvFactory = new UserVaultFactory(
            address(usdc), address(feeManager), address(registry), address(engine), address(router)
        );

        registry.setRegistrar(address(uvFactory), true);
        registry.setRegistrar(deployer, true);

        feeManager.setAuthorizedCaller(address(uvFactory), true);
        feeManager.setDefaultFees(0, 0, 0, 0);

        router.setTokenPrice(address(usdc), 1e18);
        router.setTokenPrice(address(aapl), 195e18);
        router.setTokenPrice(address(msft), 420e18);
        router.setTokenPrice(address(nvda), 875e18);

        router.setPairSupported(address(usdc), address(aapl), true);
        router.setPairSupported(address(usdc), address(msft), true);
        router.setPairSupported(address(usdc), address(nvda), true);
        router.setAuthorizedCaller(address(engine), true);

        engine.setAuthorizedCaller(address(uvFactory), true);

        uvFactory.setApprovedToken(address(aapl), true);
        uvFactory.setApprovedToken(address(msft), true);
        uvFactory.setApprovedToken(address(nvda), true);

        usdc.mint(deployer, INITIAL_USDC);
        usdc.mint(alice, INITIAL_USDC);
        usdc.mint(bob, INITIAL_USDC);
        usdc.mint(curator, INITIAL_USDC);

        aapl.mint(address(router), 1_000_000e18);
        msft.mint(address(router), 1_000_000e18);
        nvda.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 1_000_000e6);
    }

    // ===================== FeeManager Tests =====================

    function test_FeeManager_defaults() public view {
        assertEq(feeManager.defaultEntryFeeBps(), 0);
        assertEq(feeManager.defaultExitFeeBps(), 0);
        assertEq(feeManager.protocolTreasury(), treasury);
    }

    function test_FeeManager_ERC20_withdrawal() public {
        usdc.mint(address(feeManager), 1000e6);
        address mockVault = address(0x1234);
        feeManager.configureVaultFees(mockVault, 0, address(0));

        vm.prank(mockVault);
        feeManager.recordFees(500e6);

        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        feeManager.collectProtocolFees();
        uint256 treasuryBalanceAfter = usdc.balanceOf(treasury);

        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, 500e6);
    }

    function test_FeeManager_recordFees_accessControl() public {
        vm.prank(alice);
        vm.expectRevert("FeeManager: caller not a configured vault");
        feeManager.recordFees(100e6);
    }

    function test_FeeManager_treasuryMigration() public {
        usdc.mint(address(feeManager), 1000e6);
        address mockVault = address(0x1234);
        feeManager.configureVaultFees(mockVault, 0, address(0));
        vm.prank(mockVault);
        feeManager.recordFees(500e6);

        assertEq(feeManager.accumulatedProtocolFees(treasury), 500e6);

        address newTreasury = makeAddr("newTreasury");
        feeManager.setTreasury(newTreasury);

        assertEq(feeManager.accumulatedProtocolFees(treasury), 0);
        assertEq(feeManager.accumulatedProtocolFees(newTreasury), 500e6);
    }

    function test_FeeManager_configureVaultFees_onlyOnce() public {
        address mockVault = address(0x9999);
        feeManager.configureVaultFees(mockVault, 0, address(0));
        vm.expectRevert("FeeManager: vault fees already configured");
        feeManager.configureVaultFees(mockVault, 5000, curator);
    }

    function test_FeeManager_rescueToken_guard() public {
        usdc.mint(address(feeManager), 1000e6);
        address mockVault = address(0x1234);
        feeManager.configureVaultFees(mockVault, 0, address(0));
        vm.prank(mockVault);
        feeManager.recordFees(500e6);

        vm.expectRevert("FeeManager: would drain reserved fees");
        feeManager.rescueToken(address(usdc), deployer, 600e6);

        feeManager.rescueToken(address(usdc), deployer, 500e6);
    }

    function test_FeeManager_rescueToken_protectsCuratorFees() public {
        usdc.mint(address(feeManager), 1000e6);
        address mockVault = address(0x5678);
        feeManager.configureVaultFees(mockVault, 5000, curator);
        vm.prank(mockVault);
        feeManager.recordFees(1000e6);

        vm.expectRevert("FeeManager: would drain reserved fees");
        feeManager.rescueToken(address(usdc), deployer, 1);
    }

    // ===================== Factory Tests =====================

    function test_Factory_createUserVault() public {
        address vaultAddr = _createUserVault();
        assertTrue(vaultAddr != address(0));
        assertTrue(uvFactory.isVault(vaultAddr));
        assertTrue(registry.isRegistered(vaultAddr));
    }

    function test_Factory_approvedTokenList_removal() public {
        uvFactory.setApprovedToken(address(0xBEEF), true);
        address[] memory tokens = uvFactory.getApprovedTokens();
        uint256 lenBefore = tokens.length;

        uvFactory.setApprovedToken(address(0xBEEF), false);
        tokens = uvFactory.getApprovedTokens();

        assertEq(tokens.length, lenBefore - 1);
        assertFalse(uvFactory.approvedTokens(address(0xBEEF)));
    }

    // ===================== UserVault Core Tests =====================

    function test_UserVault_deposit() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_UserVault_rebalance_onlyCurator() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(alice);
        vm.expectRevert(UserVault.OnlyCurator.selector);
        vault.rebalance();
    }

    function test_UserVault_pause() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(curator);
        vault.unpause();
        assertFalse(vault.paused());

        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_UserVault_depositAndRebalance() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.warp(block.timestamp + 5 hours);
        vm.startPrank(curator);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.depositAndRebalance(DEPOSIT_AMOUNT, curator);
        vm.stopPrank();

        assertTrue(shares > 0);
        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length > 0);
    }

    function test_UserVault_depositAndRebalance_unauthorized() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert(UserVault.UnauthorizedRebalance.selector);
        vault.depositAndRebalance(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    // ===================== UserVault Time-lock Tests =====================

    function test_UserVault_timelocked_setRebalanceEngine() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        assertEq(vault.weightChangeTimeLock(), 24 hours);

        vm.prank(curator);
        vault.setRebalanceEngine(address(0xDEAD));

        (address value, uint256 effectiveTime, bool pending) = vault.pendingRebalanceEngine();
        assertTrue(pending);
        assertEq(value, address(0xDEAD));

        vm.prank(curator);
        vm.expectRevert(UserVault.TimeLockNotExpired.selector);
        vault.applyRebalanceEngine();

        vm.warp(block.timestamp + 25 hours);
        vm.prank(curator);
        vault.applyRebalanceEngine();

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

    // ===================== Router Tests =====================

    function test_Router_getQuote() public view {
        uint256 quote = router.getQuote(address(usdc), address(aapl), 195e6);
        assertEq(quote, 1e18);
    }

    function test_Router_swap() public {
        usdc.mint(address(this), 195e6);
        usdc.approve(address(router), 195e6);

        router.setAuthorizedCaller(address(this), true);
        uint256 out = router.swap(address(usdc), address(aapl), 195e6, 0, address(this));
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
        assertEq(usdc.balanceOf(alice), INITIAL_USDC + 10_000e6);
    }

    function test_TiltUSDC_faucet_cooldown() public {
        vm.startPrank(alice);
        usdc.faucet();
        vm.expectRevert("TiltUSDC: faucet cooldown active");
        usdc.faucet();
        vm.stopPrank();

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice);
        usdc.faucet();
    }

    // ===================== Mock Token Factory Tests =====================

    function test_MockTokenFactory_deployStandard() public {
        tokenFactory.deployStandardTokens();
        assertEq(tokenFactory.totalTokens(), 10);

        assertTrue(tokenFactory.tokenBySymbol("tiltAAPL") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("tiltMSFT") != address(0));
        assertTrue(tokenFactory.tokenBySymbol("tiltNVDA") != address(0));
    }

    // ===================== Engine Authorization Tests =====================

    function test_Engine_authorizedCallers() public {
        assertTrue(engine.authorizedCallers(address(uvFactory)));

        vm.prank(address(uvFactory));
        engine.setVaultAuthorized(address(0xABCD), true);
        assertTrue(engine.authorizedVaults(address(0xABCD)));
    }

    function test_Engine_accessControl_executeRebalance() public {
        address vaultAddr = _createUserVault();

        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](0);
        vm.prank(alice);
        vm.expectRevert(RebalanceEngine.UnauthorizedVault.selector);
        engine.executeRebalance(vaultAddr, trades);
    }

    // ===================== Rebalance Buy Budget Tests =====================

    function test_RebalanceEngine_unallocatedBase_buyBudget() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        IBaseVault.TokenWeight[] memory currentWeights = vault.getCurrentWeights();
        IBaseVault.TokenWeight[] memory targetWeights = vault.getTargetWeights();
        uint256 totalValue = vault.totalAssets();

        IRebalanceEngine.TradeOrder[] memory trades =
            engine.calculateRebalance(vaultAddr, currentWeights, targetWeights, totalValue);

        uint256 totalBuyValue = 0;
        for (uint256 i = 0; i < trades.length; i++) {
            if (trades[i].tokenIn == address(usdc)) {
                totalBuyValue += trades[i].amountIn;
            }
        }
        assertTrue(totalBuyValue > 0, "Buy budget should include unallocated base");
        assertApproxEqRel(totalBuyValue, totalValue, 0.02e18);
    }

    // ===================== Emergency Unpause by Protocol Admin =====================

    function test_UserVault_emergencyUnpause_protocolAdmin() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(alice);
        vm.expectRevert(UserVault.UnauthorizedUnpause.selector);
        vault.unpause();

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

        vm.prank(curator);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ===================== Withdraw / Redeem while Paused =====================

    function test_withdrawAllowedWhilePaused() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        vm.startPrank(bob);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.startPrank(alice);
        uint256 assets = vault.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        assertTrue(assets > 0, "should receive assets while paused");
        assertEq(vault.balanceOf(alice), 0, "all shares should be burned");
    }

    // ===================== Zero-Price Token Handling =====================

    function test_totalAssets_zeroPriceToken_noRevert() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.warp(block.timestamp + 5 hours);
        vm.startPrank(curator);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.depositAndRebalance(DEPOSIT_AMOUNT, curator);
        vm.stopPrank();

        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length > 0);

        router.clearTokenPrice(address(aapl));

        uint256 total = vault.totalAssets();
        assertTrue(total > 0, "totalAssets should still return a value");
    }

    // ===================== Deposit Circuit Breaker on Zero-Price Oracle =====================

    function test_deposit_blockedOnZeroPriceOracle() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.warp(block.timestamp + 5 hours);
        vm.startPrank(curator);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.depositAndRebalance(DEPOSIT_AMOUNT, curator);
        vm.stopPrank();

        router.clearTokenPrice(address(aapl));

        vm.startPrank(bob);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vm.expectRevert(BaseVault.OracleDegraded.selector);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        router.setTokenPrice(address(aapl), 195e18);

        vm.startPrank(bob);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();
        assertTrue(shares > 0, "deposit should succeed after oracle recovery");
    }

    // ===================== Held Tokens Cap =====================

    function test_heldTokens_cappedAtMax() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.warp(block.timestamp + 5 hours);
        vm.startPrank(curator);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.depositAndRebalance(DEPOSIT_AMOUNT, curator);
        vm.stopPrank();

        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length <= vault.MAX_HELD_TOKENS(), "heldTokens should be capped");
        assertTrue(held.length == 2, "should have exactly 2 target tokens");
    }

    // ===================== Emergency Withdraw =====================

    function test_emergencyWithdraw_afterRebalance() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 hours);
        vm.prank(curator);
        vault.rebalance();

        assertTrue(aapl.balanceOf(vaultAddr) > 0, "vault should hold AAPL");

        uint256 aliceShares = vault.balanceOf(alice);
        assertTrue(aliceShares > 0);

        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        assertTrue(usdc.balanceOf(alice) > 0 || aapl.balanceOf(alice) > 0, "should receive tokens");
    }

    function test_emergencyWithdraw_whilePaused() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 hours);
        vm.prank(curator);
        vault.rebalance();

        vm.prank(curator);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(vault.balanceOf(alice), 0, "all shares burned");
    }

    function test_emergencyWithdraw_oracleDown() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 hours);
        vm.prank(curator);
        vault.rebalance();

        router.clearTokenPrice(address(aapl));
        router.clearTokenPrice(address(msft));

        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        assertTrue(
            aapl.balanceOf(alice) > 0 || msft.balanceOf(alice) > 0,
            "should receive stock tokens"
        );
    }

    // ===================== Integration: Full Lifecycle =====================

    function test_integration_fullCycle_crossDecimal() public {
        address vaultAddr = _createUserVault();
        UserVault vault = UserVault(vaultAddr);

        assertEq(vault.decimals(), 6, "share decimals should match USDC");

        vm.startPrank(alice);
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertTrue(shares > 0, "should receive shares");
        uint256 priceBefore = vault.sharePrice();
        assertApproxEqRel(priceBefore, 1e18, 0.01e18);

        vm.warp(block.timestamp + 5 hours);
        vm.prank(curator);
        vault.rebalance();

        uint256 navAfterRebalance = vault.totalAssets();
        uint256 expectedNav = SEED_AMOUNT + DEPOSIT_AMOUNT;
        assertApproxEqRel(navAfterRebalance, expectedNav, 0.02e18);

        address[] memory held = vault.getHeldTokens();
        assertTrue(held.length == 2, "should hold 2 stock tokens");

        assertApproxEqRel(vault.sharePrice(), 1e18, 0.02e18);

        // Simulate price increase: AAPL $195 -> $250
        router.setTokenPrice(address(aapl), 250e18);
        uint256 navAfterPriceUp = vault.totalAssets();
        assertTrue(navAfterPriceUp > navAfterRebalance, "NAV should increase with AAPL price");

        uint256 priceAfterUp = vault.sharePrice();
        assertTrue(priceAfterUp > 1e18, "share price should reflect gains");

        // Withdraw half of Alice's shares
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 redeemShares = aliceShares / 2;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        uint256 assetsOut = vault.redeem(redeemShares, alice, alice);
        vm.stopPrank();

        assertTrue(assetsOut > 0, "should receive assets");
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        assertEq(aliceUsdcAfter - aliceUsdcBefore, assetsOut, "USDC balance should match redeem");
        assertTrue(assetsOut >= DEPOSIT_AMOUNT / 2, "withdrawal should reflect gains");
    }

    function test_integration_routerCrossDecimalQuotes() public view {
        uint256 aaplOut = router.getQuote(address(usdc), address(aapl), 195e6);
        assertEq(aaplOut, 1e18, "195 USDC should buy 1 AAPL");

        uint256 usdcOut = router.getQuote(address(aapl), address(usdc), 1e18);
        assertEq(usdcOut, 195e6, "1 AAPL should sell for 195 USDC");

        uint256 msftOut = router.getQuote(address(usdc), address(msft), 420e6);
        assertEq(msftOut, 1e18, "420 USDC should buy 1 MSFT");
        uint256 usdcFromMsft = router.getQuote(address(msft), address(usdc), 1e18);
        assertEq(usdcFromMsft, 420e6, "1 MSFT should sell for 420 USDC");

        uint256 nvdaFrac = router.getQuote(address(usdc), address(nvda), 100e6);
        assertApproxEqRel(nvdaFrac, 0.114285714285714285e18, 0.01e18);
    }

    // ===================== VaultRegistry Tests =====================

    function test_VaultRegistry_updateMetadata() public {
        address vaultAddr = _createUserVault();

        vm.prank(curator);
        registry.updateVaultMetadata(vaultAddr, "ipfs://new-metadata");

        VaultRegistry.VaultInfo memory info = registry.getVaultInfo(vaultAddr);
        assertEq(info.metadataURI, "ipfs://new-metadata");
    }

    function test_VaultRegistry_updateMetadata_onlyOwnerOrCurator() public {
        address vaultAddr = _createUserVault();

        vm.prank(alice);
        vm.expectRevert(VaultRegistry.NotCurator.selector);
        registry.updateVaultMetadata(vaultAddr, "ipfs://hacked");
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
        usdc.approve(address(uvFactory), 1000e6);
        vault = uvFactory.createUserVault{value: 0.01 ether}(
            "Tech Growth", "vTECH", tokens, weights, 5000, 1000e6, "ipfs://tech"
        );
        vm.stopPrank();
    }

    receive() external payable {}
}
