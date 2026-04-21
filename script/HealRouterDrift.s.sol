// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UserVaultFactoryV2} from "../src/core/UserVaultFactoryV2.sol";
import {UserVault} from "../src/core/UserVault.sol";
import {BaseVault} from "../src/core/BaseVault.sol";
import {RebalanceEngine} from "../src/rebalance/RebalanceEngine.sol";
import {MockTokenRouter as TokenRouter} from "../src/rebalance/TokenRouter.sol";

/// @title HealRouterDrift
/// @notice One-shot migration that closes the "silently-broken vault" failure
///         mode observed on Robinhood testnet.
///
/// Background
/// ----------
/// A UserVault's `allocateIdleAssets` and `executeRebalance` paths do two
/// different things with two routers:
///   - quoting: `vault.tokenRouter().getQuote(...)`
///   - execution: `rebalanceEngine.executeRebalance(...)` → which internally
///     calls `rebalanceEngine.tokenRouter().swap(...)`
///
/// If the engine's router was deployed earlier than the canonical router and
/// never repointed, every new vault is born unable to deploy its seed capital:
/// quotes succeed (against the fresh router), but swaps revert with
/// `UnsupportedPair()` (against the stale one). The UI swallowed that revert
/// in a try/catch, so vault creation reported "done" while the USDC seed sat
/// idle forever.
///
/// What this script does
/// ---------------------
/// 1. Reads the authoritative router from the factory (`factory.tokenRouter`).
/// 2. Upgrades the `UserVaultFactoryV2` proxy to an impl that carries the
///    new `RouterDrift` invariant — any future drift reverts at creation.
/// 3. Heals the current deployment:
///      a. `RebalanceEngine.setRouter(factory.tokenRouter)` if drifted.
///      b. `factory.tokenRouter.setAuthorizedCaller(engine, true)` if the
///         engine isn't a whitelisted caller on the (new) router.
///      c. For every vault on the factory:
///           - repoint its own `tokenRouter` to match (immediate — caller is
///             `feeManager.owner()`, which matches the deployer)
///           - if it has idle USDC, drain it via `allocateIdleAssets()` so
///             existing stuck vaults catch up with their target weights.
/// 4. Asserts the post-invariants.
///
/// Required env:
///   - PRIVATE_KEY: deployer key (must own the factory proxy, the engine,
///                  the canonical router, and the current FeeManager).
///
/// Optional env (defaulted to Robinhood testnet addresses):
///   - USER_VAULT_FACTORY, REBALANCE_ENGINE, CANONICAL_ROUTER
contract HealRouterDrift is Script {
    address constant DEFAULT_FACTORY = 0xD5210C45C7B65E4D9Eed53391D2199a2aB9DcF57;
    address constant DEFAULT_ENGINE = 0xAfe9CA99AB3CFa2523553E25743eA1463ae35eF2;
    address constant DEFAULT_ROUTER = 0x9fA2D96Ef53912162f3F8bcd73620Bf93D39808D;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factoryAddr = _envOr("USER_VAULT_FACTORY", DEFAULT_FACTORY);
        address engineAddr = _envOr("REBALANCE_ENGINE", DEFAULT_ENGINE);
        address routerAddr = _envOr("CANONICAL_ROUTER", DEFAULT_ROUTER);

        UserVaultFactoryV2 factory = UserVaultFactoryV2(payable(factoryAddr));
        RebalanceEngine engine = RebalanceEngine(engineAddr);
        TokenRouter router = TokenRouter(routerAddr);

        console.log("===== HealRouterDrift =====");
        console.log("deployer:     ", deployer);
        console.log("factory:      ", factoryAddr);
        console.log("engine:       ", engineAddr);
        console.log("canonical RT: ", routerAddr);

        // --- Preflight ---
        require(factory.tokenRouter() == routerAddr, "factory.tokenRouter != canonical (fix factory first)");
        require(factory.rebalanceEngine() == engineAddr, "factory.rebalanceEngine != engine");
        require(factory.owner() == deployer, "deployer must own factory");
        require(engine.owner() == deployer, "deployer must own engine");
        require(router.owner() == deployer, "deployer must own canonical router");

        address engineRouterBefore = address(engine.tokenRouter());
        bool engineAuthorizedOnRouterBefore = router.authorizedCallers(engineAddr);
        address[] memory vaults = factory.getAllVaults();

        console.log("engine.tokenRouter (before):       ", engineRouterBefore);
        console.log("router.authorizedCallers[engine]:   ", engineAuthorizedOnRouterBefore);
        console.log("vaults to heal:                     ", vaults.length);

        vm.startBroadcast(pk);

        // ---------- 1. Upgrade factory impl (adds RouterDrift invariant) ----------
        UserVaultFactoryV2 newFactoryImpl = new UserVaultFactoryV2();
        factory.upgradeToAndCall(address(newFactoryImpl), "");
        console.log("factory upgraded to new impl:", address(newFactoryImpl));

        // ---------- 2. Heal engine router ----------
        if (engineRouterBefore != routerAddr) {
            engine.setRouter(routerAddr);
            console.log("engine.setRouter -> canonical");
        } else {
            console.log("engine.tokenRouter already canonical (no-op)");
        }

        // ---------- 3. Authorize engine on canonical router ----------
        if (!engineAuthorizedOnRouterBefore) {
            router.setAuthorizedCaller(engineAddr, true);
            console.log("router.authorizedCallers[engine] = true");
        } else {
            console.log("engine already authorised on canonical router (no-op)");
        }

        // ---------- 4. Per-vault heal ----------
        for (uint256 i = 0; i < vaults.length; i++) {
            address v = vaults[i];
            BaseVault bv = BaseVault(v);

            // Repoint the vault's own router (used for quoting) so internal
            // slippage math keeps matching what the engine actually executes.
            if (address(bv.tokenRouter()) != routerAddr) {
                // Caller is `feeManager.owner()` = deployer → immediate (no timelock).
                UserVault(v).setTokenRouter(routerAddr);
                console.log("vault: repointed tokenRouter", v);
            }

            // Drain stuck idle USDC, if any.
            uint256 idle = bv.unallocatedDeposits();
            if (idle > 0) {
                bv.allocateIdleAssets();
                console.log("vault: drained idle USDC", v, idle);
            }
        }

        vm.stopBroadcast();

        // --- Post-invariants (read-only, outside broadcast) ---
        require(factory.isRouterAligned(), "post: router drift not closed");
        require(address(engine.tokenRouter()) == routerAddr, "post: engine.tokenRouter not canonical");
        require(router.authorizedCallers(engineAddr), "post: engine not authorised on router");

        console.log("===== HealRouterDrift complete =====");
        console.log("factory impl: ", address(newFactoryImpl));
        console.log("engine.tokenRouter:", address(engine.tokenRouter()));
        console.log("router.authorizedCallers[engine]:", router.authorizedCallers(engineAddr));
    }

    function _envOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v == address(0) ? fallback_ : v;
        } catch {
            return fallback_;
        }
    }
}
