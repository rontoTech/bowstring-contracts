// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {FeeManagerUpgradeable} from "../src/core/FeeManagerUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../src/core/VaultRegistryUpgradeable.sol";
import {MockTokenRouter as TokenRouter} from "../src/rebalance/TokenRouter.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {TiltUSDC} from "../src/tokens/MockStockToken.sol";
import {StockTokenFactoryUpgradeable} from "../src/tokens/StockTokenFactoryUpgradeable.sol";
import {StockTokenUpgradeable} from "../src/tokens/StockTokenUpgradeable.sol";

/// @title RouterDriftHealTest
/// @notice Reproduces and closes the "silently-broken vault" regression seen
///         on Robinhood testnet: the factory was repointed to a fresh
///         `TokenRouter` with stock pairs, but the `RebalanceEngine` was
///         never repointed, so every new vault's `allocateIdleAssets()`
///         reverted with `UnsupportedPair()` on the engine's stale router.
///         The UI caught the revert and treated creation as successful, so
///         vaults ended up existing with 100% USDC idle forever.
///
///   Covered scenarios:
///     1. Repro: on a drifted setup (engine → stale router), a vault created
///        on the old factory successfully deploys but any subsequent
///        `allocateIdleAssets()` reverts.
///     2. The new `RouterDrift` invariant on `UserVaultFactoryV2` blocks
///        creation outright while drift is live, so no new stuck vaults can
///        be born.
///     3. After healing (engine.setRouter + router.setAuthorizedCaller +
///        per-vault repoint + allocateIdleAssets), creation works and the
///        previously-stuck vault actually holds its target tokens.
///     4. `syncRebalanceEngineRouter()` is a one-call heal when the factory
///        owns the engine; reverts cleanly if it does not.
///     5. `isRouterAligned()` is a faithful read-only predicate.
contract RouterDriftHealTest is Test {
    address public deployer = address(this);
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");

    TiltUSDC public usdc;

    // Canonical infra (what the factory points at).
    TokenRouter public canonRouter;
    RebalanceEngine public engine;
    VaultRegistryUpgradeable public registry;
    FeeManagerUpgradeable public feeManager;

    // Stale router: pre-existing, lacks stock pair support.
    TokenRouter public staleRouter;

    StockTokenFactoryUpgradeable public stockFactory;

    UserVaultFactoryV2 public factory;
    UpgradeableBeacon public vaultBeacon;

    address public aapl;
    address public msft;
    address public nvda;

    uint256 public constant SEED = 1_000e6;
    uint256 public constant USER_BALANCE = 100_000e6;

    function setUp() public {
        usdc = new TiltUSDC();

        // Canonical router with all pairs.
        canonRouter = new TokenRouter();

        // Stale router — deployed earlier, never had pairs added.
        staleRouter = new TokenRouter();

        // Engine starts pointing at the STALE router (matches prod state).
        engine = new RebalanceEngine(address(staleRouter), address(usdc));

        // FeeManager (upgradeable). Zero defaults so assertions on totalAssets
        // match the seed amount exactly (no entry-fee deduction to reason about).
        FeeManagerUpgradeable fmImpl = new FeeManagerUpgradeable();
        feeManager = FeeManagerUpgradeable(
            payable(address(new ERC1967Proxy(
                address(fmImpl),
                abi.encodeCall(FeeManagerUpgradeable.initialize, (treasury, address(usdc), deployer))
            )))
        );
        feeManager.setDefaultFees(0, 0, 0, 0);

        // Registry (upgradeable).
        VaultRegistryUpgradeable registryImpl = new VaultRegistryUpgradeable();
        registry = VaultRegistryUpgradeable(
            address(new ERC1967Proxy(
                address(registryImpl),
                abi.encodeCall(VaultRegistryUpgradeable.initialize, (deployer))
            ))
        );

        // Stock token factory + sample tokens.
        StockTokenUpgradeable stockImpl = new StockTokenUpgradeable();
        StockTokenFactoryUpgradeable stockFactoryImpl = new StockTokenFactoryUpgradeable();
        stockFactory = StockTokenFactoryUpgradeable(
            address(new ERC1967Proxy(
                address(stockFactoryImpl),
                abi.encodeCall(StockTokenFactoryUpgradeable.initialize, (deployer, address(stockImpl)))
            ))
        );
        stockFactory.setTokenRouter(address(canonRouter));
        aapl = stockFactory.createStockToken("Tilt Apple", "AAPL", 195e18);
        msft = stockFactory.createStockToken("Tilt Microsoft", "MSFT", 420e18);
        nvda = stockFactory.createStockToken("Tilt Nvidia", "NVDA", 875e18);

        // Canonical router: prices + pairs + USDC minter.
        canonRouter.setTokenPrice(address(usdc), 1e18);
        canonRouter.setTokenPrice(aapl, 195e18);
        canonRouter.setTokenPrice(msft, 420e18);
        canonRouter.setTokenPrice(nvda, 875e18);
        canonRouter.setPairSupported(address(usdc), aapl, true);
        canonRouter.setPairSupported(address(usdc), msft, true);
        canonRouter.setPairSupported(address(usdc), nvda, true);
        usdc.addMinter(address(canonRouter));

        // Stale router: has prices/USDC plumbing so `getQuote` from the
        // vault's router side works, but pairs are intentionally missing
        // (mirrors the prod `0x18e6…` instance).
        staleRouter.setTokenPrice(address(usdc), 1e18);
        staleRouter.setTokenPrice(aapl, 195e18);
        staleRouter.setTokenPrice(msft, 420e18);
        staleRouter.setTokenPrice(nvda, 875e18);
        // (no setPairSupported — this is the drift)
        usdc.addMinter(address(staleRouter));

        // UserVault beacon + factory (UUPS).
        UserVault vaultImpl = new UserVault();
        vaultBeacon = new UpgradeableBeacon(address(vaultImpl), deployer);

        UserVaultFactoryV2 factoryImpl = new UserVaultFactoryV2();
        factory = UserVaultFactoryV2(
            payable(address(new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(
                    UserVaultFactoryV2.initialize,
                    (
                        address(vaultBeacon),
                        address(usdc),
                        address(feeManager),
                        address(registry),
                        address(engine),
                        address(canonRouter),   // factory points at CANONICAL
                        address(0)
                    )
                )
            )))
        );

        // Standard wiring.
        registry.setRegistrar(address(factory), true);
        engine.setAuthorizedCaller(address(factory), true);
        feeManager.setAuthorizedCaller(address(factory), true);
        feeManager.setAuthorizedCaller(deployer, true);

        address[] memory tokens = new address[](3);
        tokens[0] = aapl;
        tokens[1] = msft;
        tokens[2] = nvda;
        factory.setApprovedTokensBatch(tokens, true);

        usdc.mint(alice, USER_BALANCE);

        // Intentionally DO NOT authorise the engine on the stale router in
        // a way that would make swaps actually execute — we want to see
        // `UnsupportedPair`, not `UnauthorizedCaller`. Authorise the engine
        // on the stale router so the first error surfaced is the pair check.
        staleRouter.setAuthorizedCaller(address(engine), true);

        // Sanity: the engine is using the stale router right now.
        assertEq(address(engine.tokenRouter()), address(staleRouter));
        assertFalse(factory.isRouterAligned(), "drift is present at start of every test");
    }

    // ------------------------------------------------------------------
    // 1. Repro on an OLD factory impl (without the RouterDrift invariant):
    //    vaults can still be created, but their idle USDC can never be
    //    allocated — swaps revert against the engine's stale router.
    // ------------------------------------------------------------------
    function test_drift_reproducesStuckVault() public {
        // Snapshot-style: temporarily downgrade the factory to a fresh
        // `UserVaultFactoryV2` impl that does NOT yet know about the drift
        // check (we emulate the old impl by bypassing the invariant — we
        // just turn the drift off, create, turn it back on).
        //
        // Easiest: align routers just long enough to create the vault, then
        // drift again so `allocateIdleAssets` fails like on-chain.
        engine.setRouter(address(canonRouter)); // temporarily aligned
        canonRouter.setAuthorizedCaller(address(engine), true);

        address vault = _createVault("stuck", "STUCK", SEED);

        // Re-introduce the drift post-creation (mirrors the prod scenario
        // where the engine was never repointed).
        engine.setRouter(address(staleRouter));

        assertEq(UserVault(vault).totalAssets(), SEED, "vault seeded");
        assertEq(UserVault(vault).unallocatedDeposits(), SEED, "all idle");

        vm.expectRevert(TokenRouter.UnsupportedPair.selector);
        UserVault(vault).allocateIdleAssets();

        // Unallocated stays idle — this is the bug.
        assertEq(UserVault(vault).unallocatedDeposits(), SEED, "still stuck");
    }

    // ------------------------------------------------------------------
    // 2. With the new invariant live, the factory refuses to create a
    //    vault while the drift is present. No more silently-broken vaults.
    // ------------------------------------------------------------------
    function test_drift_createRevertsWithRouterDrift() public {
        _approveSeed();
        address[] memory tks = _tokens();
        uint16[] memory ws = _weights();

        vm.prank(alice);
        vm.expectRevert(UserVaultFactoryV2.RouterDrift.selector);
        factory.createUserVaultWithFees(
            "Drift", "DRIFT", tks, ws, 100, 1000, 7000, SEED, "ipfs://drift"
        );
    }

    // ------------------------------------------------------------------
    // 3. Full heal flow — engine.setRouter + router.setAuthorizedCaller
    //    + per-vault repoint + allocateIdleAssets. After this:
    //       a) `createUserVaultWithFees` succeeds again
    //       b) the previously-stuck vault actually holds its stocks
    // ------------------------------------------------------------------
    function test_heal_unblocksCreationAndDrainsStuckVault() public {
        // First, create a stuck vault (emulated) so there's state to heal.
        engine.setRouter(address(canonRouter));
        canonRouter.setAuthorizedCaller(address(engine), true);
        address stuck = _createVault("stuck", "STUCK", SEED);
        engine.setRouter(address(staleRouter));
        assertEq(UserVault(stuck).unallocatedDeposits(), SEED);

        // --- Heal ---
        engine.setRouter(address(canonRouter));
        // (canonRouter already authorised engine above)
        // Per-vault: repoint + drain. (feeManager.owner() == deployer ⇒ immediate.)
        UserVault(stuck).setTokenRouter(address(canonRouter));
        UserVault(stuck).allocateIdleAssets();

        // Stuck vault now actually holds tokens.
        assertEq(UserVault(stuck).unallocatedDeposits(), 0, "drained");
        address[] memory held = UserVault(stuck).getHeldTokens();
        assertGt(held.length, 0, "vault holds stock tokens after heal");
        assertGt(IERC20Like(aapl).balanceOf(stuck), 0, "holds AAPL");
        assertGt(IERC20Like(msft).balanceOf(stuck), 0, "holds MSFT");
        assertGt(IERC20Like(nvda).balanceOf(stuck), 0, "holds NVDA");

        // --- Fresh creation now succeeds, and the new vault auto-allocates. ---
        _approveSeed();
        vm.prank(alice);
        address fresh = factory.createUserVaultWithFees(
            "Fresh", "FRESH", _tokens(), _weights(), 100, 1000, 7000, SEED, "ipfs://fresh"
        );
        assertTrue(fresh != address(0));

        // Trigger allocation (mirrors UI Step 3).
        UserVault(fresh).allocateIdleAssets();
        assertEq(UserVault(fresh).unallocatedDeposits(), 0, "fresh vault drained");
        assertGt(IERC20Like(aapl).balanceOf(fresh), 0, "fresh holds AAPL");
    }

    // ------------------------------------------------------------------
    // 4. `syncRebalanceEngineRouter`: one-call heal when the factory owns
    //    the engine. Reverts cleanly otherwise.
    // ------------------------------------------------------------------
    function test_syncRebalanceEngineRouter_worksWhenFactoryOwnsEngine() public {
        // Transfer engine ownership to the factory so the helper can call
        // `setRouter` through `onlyOwner`.
        engine.transferOwnership(address(factory));

        assertFalse(factory.isRouterAligned());
        factory.syncRebalanceEngineRouter();
        assertTrue(factory.isRouterAligned());
        assertEq(address(engine.tokenRouter()), address(canonRouter));
    }

    function test_syncRebalanceEngineRouter_revertsWhenNotEngineOwner() public {
        // Factory does NOT own the engine — helper must bubble the engine's
        // own auth error.
        vm.expectRevert();
        factory.syncRebalanceEngineRouter();
    }

    function test_syncRebalanceEngineRouter_requiresFactoryOwner() public {
        engine.transferOwnership(address(factory));
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        factory.syncRebalanceEngineRouter();
    }

    // ------------------------------------------------------------------
    // 5. isRouterAligned is a faithful predicate.
    // ------------------------------------------------------------------
    function test_isRouterAligned_tracksEngineState() public {
        assertFalse(factory.isRouterAligned(), "drift at setUp");
        engine.setRouter(address(canonRouter));
        assertTrue(factory.isRouterAligned(), "after heal");
        engine.setRouter(address(staleRouter));
        assertFalse(factory.isRouterAligned(), "after re-drift");
    }

    // ==================================================================
    // helpers
    // ==================================================================

    function _createVault(string memory name, string memory symbol, uint256 seed) internal returns (address) {
        _approveSeed();
        vm.prank(alice);
        return factory.createUserVaultWithFees(
            name, symbol, _tokens(), _weights(), 100, 1000, 7000, seed, "ipfs://x"
        );
    }

    function _tokens() internal view returns (address[] memory t) {
        t = new address[](3);
        t[0] = aapl;
        t[1] = msft;
        t[2] = nvda;
    }

    function _weights() internal pure returns (uint16[] memory w) {
        w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 2000;
    }

    function _approveSeed() internal {
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
