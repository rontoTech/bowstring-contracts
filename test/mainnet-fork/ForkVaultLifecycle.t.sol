// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {ForkBase, MockAggregatorV3} from "./ForkBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeManagerUpgradeable} from "../../src/core/FeeManagerUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../../src/core/VaultRegistryUpgradeable.sol";
import {ChainlinkPriceRouter} from "../../src/mainnet/ChainlinkPriceRouter.sol";
import {MainnetExecutionEngine} from "../../src/mainnet/MainnetExecutionEngine.sol";
import {TradeDelegateProxyV2} from "../../src/mainnet/TradeDelegateProxyV2.sol";
import {UserVault} from "../../src/core/UserVault.sol";
import {UserVaultFactoryV2} from "../../src/core/UserVaultFactoryV2.sol";
import {BaseVault} from "../../src/core/BaseVault.sol";

/// @title ForkVaultLifecycle
/// @notice Best-effort mainnet-fork lifecycle: deploy the full stack on chain
///         4663, create a vault seeded with the REAL AAPL token, and prove the
///         deposit market-gate (blocked when marketOpen=false, open when true).
///
///         A MOCK Chainlink aggregator is used for AAPL so gating is deterministic
///         on the fork (the REAL feed is exercised in ForkPriceFeed when its env
///         address is supplied). Funding uses a guarded `deal` — if USDG's
///         namespaced storage resists cheatcode funding, the deposit-gating
///         portion is SKIPPED-with-note and only the stack wiring is asserted.
///
///         DEFERRED: executeRebalance settlement (0x staged calldata or an AMM
///         pool) is NOT exercised here — there is no live 0x quote / AMM pool in
///         a pure fork. That path needs a live-quote replay script (pull a real
///         0x /quote, stage it via TradeDelegateProxyV2.executeTradeWithSettlement).
contract ForkVaultLifecycle is ForkBase {
    FeeManagerUpgradeable internal feeManager;
    VaultRegistryUpgradeable internal registry;
    ChainlinkPriceRouter internal router;
    MainnetExecutionEngine internal engine;
    TradeDelegateProxyV2 internal delegate;
    UpgradeableBeacon internal beacon;
    UserVaultFactoryV2 internal factory;
    MockAggregatorV3 internal aaplFeed;

    address internal creator = makeAddr("creator");
    address internal lp = makeAddr("lp");

    uint256 internal constant SEED = 1_000e6;

    function setUp() public {
        _initFork();
        if (!forkEnabled) return;

        address me = address(this);

        // FeeManager (treasury = this test for simplicity).
        FeeManagerUpgradeable fmImpl = new FeeManagerUpgradeable();
        feeManager = FeeManagerUpgradeable(
            payable(
                address(
                    new ERC1967Proxy(
                        address(fmImpl), abi.encodeCall(FeeManagerUpgradeable.initialize, (me, USDG, me))
                    )
                )
            )
        );
        feeManager.setDefaultFees(0, 0, 0, 0);

        // Registry.
        VaultRegistryUpgradeable regImpl = new VaultRegistryUpgradeable();
        registry = VaultRegistryUpgradeable(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(VaultRegistryUpgradeable.initialize, (me))))
        );

        // ChainlinkPriceRouter + a deterministic mock AAPL feed.
        ChainlinkPriceRouter prImpl = new ChainlinkPriceRouter();
        router = ChainlinkPriceRouter(
            address(
                new ERC1967Proxy(address(prImpl), abi.encodeCall(ChainlinkPriceRouter.initialize, (me, USDG)))
            )
        );
        aaplFeed = new MockAggregatorV3(8, 195e8); // $195, 8-dec Chainlink-style
        // oraclePausedCheck=false: the real AAPL token's oraclePaused() is not
        // relevant to this deterministic gating test.
        router.setFeed(AAPL, address(aaplFeed), 1 days, "AAPL", false);

        // Execution engine.
        MainnetExecutionEngine engImpl = new MainnetExecutionEngine();
        engine = MainnetExecutionEngine(
            address(
                new ERC1967Proxy(
                    address(engImpl),
                    abi.encodeCall(MainnetExecutionEngine.initialize, (address(router), USDG, me))
                )
            )
        );
        engine.setAllowedToken(AAPL, true);

        // Delegate proxy.
        delegate = new TradeDelegateProxyV2(me, address(engine));

        // UserVault impl + beacon, beacon handed to the factory below.
        UserVault vaultImpl = new UserVault();
        beacon = new UpgradeableBeacon(address(vaultImpl), me);

        // Factory.
        UserVaultFactoryV2 facImpl = new UserVaultFactoryV2();
        factory = UserVaultFactoryV2(
            payable(
                address(
                    new ERC1967Proxy(
                        address(facImpl),
                        abi.encodeCall(
                            UserVaultFactoryV2.initialize,
                            (address(beacon), USDG, address(feeManager), address(registry), address(engine), address(router), address(delegate))
                        )
                    )
                )
            )
        );
        address[] memory approved = new address[](1);
        approved[0] = AAPL;
        factory.setApprovedTokensBatch(approved, true);

        // Wire authority + hand the beacon to the factory.
        registry.setRegistrar(address(factory), true);
        feeManager.setAuthorizedCaller(address(factory), true);
        engine.setAuthorizedCaller(address(factory), true);
        beacon.transferOwnership(address(factory));

        router.setMarketOpen(true);
    }

    // ---- guarded funding: deal can fail on namespaced-storage proxies ----
    function externalDeal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    function _tryFund(address to, uint256 amount) internal returns (bool) {
        try this.externalDeal(USDG, to, amount) {
            return IERC20(USDG).balanceOf(to) >= amount;
        } catch {
            return false;
        }
    }

    // ===================== stack wiring (no funds needed) =====================

    function test_stackWiredCorrectly() public {
        if (_skipIfNoFork()) return;
        assertEq(address(engine.tokenRouter()), address(router), "engine router == price router");
        assertEq(beacon.owner(), address(factory), "beacon owned by factory (trap defused)");
        assertTrue(factory.isRouterAligned(), "factory router aligned (RouterDrift ok)");
        assertEq(factory.tokenRouter(), address(router), "factory token router");
        assertEq(factory.rebalanceEngine(), address(engine), "factory engine");
        // Feed live on the fork-deployed router.
        assertGt(router.getTokenPrice(AAPL), 0, "AAPL priced via mock feed");
        assertTrue(router.depositsOpen(), "market open + fresh feed => depositsOpen");
    }

    // ===================== deposit market-gate lifecycle =====================

    function test_depositGateLifecycle() public {
        if (_skipIfNoFork()) return;

        if (!_tryFund(creator, SEED) || !_tryFund(lp, SEED)) {
            console.log("SKIP: could not fund USDG via cheatcode (namespaced storage).");
            console.log("  -> vault-creation + deposit gating deferred to a live-funded run.");
            vm.skip(true);
            return;
        }

        // Create a vault (market open -> the factory's internal seed deposit passes).
        address[] memory tokens = new address[](1);
        tokens[0] = AAPL;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;

        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        address vaultAddr = factory.createUserVault("Fork Vault", "fVLT", tokens, weights, 0, SEED, "");
        vm.stopPrank();
        UserVault vault = UserVault(vaultAddr);
        assertGt(vault.totalSupply(), 0, "vault created + seeded while market open");

        // Close the market -> a fresh deposit must revert MarketClosed.
        router.setMarketOpen(false);
        assertFalse(router.depositsOpen(), "gate closed");
        vm.startPrank(lp);
        IERC20(USDG).approve(address(vault), SEED);
        vm.expectRevert(BaseVault.MarketClosed.selector);
        vault.deposit(SEED, lp);
        vm.stopPrank();

        // Reopen -> the same deposit now succeeds.
        router.setMarketOpen(true);
        assertTrue(router.depositsOpen(), "gate open");
        vm.prank(lp);
        uint256 shares = vault.deposit(SEED, lp);
        assertGt(shares, 0, "deposit succeeds once market reopens");
        console.log("Deposit gate lifecycle verified on fork. LP shares:", shares);
    }

    // ===================== executeRebalance: documented deferral =====================

    function test_executeRebalance_deferredToLiveQuoteScript() public {
        if (_skipIfNoFork()) return;
        // No 0x settler calldata and no AMM pool are reachable in a pure fork, so
        // a real settlement cannot be produced here. We assert the negative
        // precondition (no AMM route configured) and document the deferral.
        assertEq(engine.ammRouter(), address(0), "no AMM router in fork -> settlement unreachable");
        assertEq(engine.ammRoute(AAPL).length, 0, "no AMM route for AAPL");
        console.log("DEFERRED: executeRebalance settlement needs a live 0x /quote replay script.");
    }
}
