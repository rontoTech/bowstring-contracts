// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @title TransferMainnetToSafe
/// @notice Hand ownership of EVERY mainnet-owned contract to the Gnosis Safe.
///
///   Ownership graph after this script:
///     Safe --owns--> FeeManager, VaultRegistry, ChainlinkPriceRouter,
///                    MainnetExecutionEngine, UserVaultFactoryV2,
///                    TradeDelegateProxyV2, PriceOracle, AgentRegistry
///     UserVaultFactoryV2 --owns--> UpgradeableBeacon   (already, from deploy)
///
///   The beacon is NOT transferred directly: it is owned by the factory proxy,
///   which is Safe-owned after this script, so beacon upgrades already require a
///   Safe tx (factory.upgradeImplementation is onlyOwner => the Safe). We ASSERT
///   the beacon still points at the factory rather than re-owning it.
///
///   All singletons use single-step OwnableUpgradeable / Ownable (NOT
///   Ownable2Step) — transferOwnership takes effect immediately, no accept step.
///
///   Required env:
///     PRIVATE_KEY               — current owner (deployer)
///     SAFE_ADDRESS              — Gnosis Safe
///     FEE_MANAGER               VAULT_REGISTRY            PRICE_ROUTER
///     EXECUTION_ENGINE          USER_VAULT_FACTORY        TRADE_DELEGATE_PROXY_V2
///     PRICE_ORACLE              AGENT_REGISTRY            USER_VAULT_BEACON
///
///   WARNING: irreversible. Dry-run on a fork first (no --broadcast).
contract TransferMainnetToSafe is Script {
    address constant LEAKED_EOA = 0xd3f9Dcd6011E1aA13eEB277d9CE5F2f7c9BB6070;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("SAFE_ADDRESS");
        require(safe != address(0), "Transfer: SAFE_ADDRESS zero");
        require(safe != LEAKED_EOA, "Transfer: SAFE is the leaked EOA");

        address beacon = vm.envAddress("USER_VAULT_BEACON");
        address factory = vm.envAddress("USER_VAULT_FACTORY");

        // Everything that carries an owner() and must end up Safe-owned.
        address[] memory targets = new address[](8);
        string[] memory labels = new string[](8);
        targets[0] = vm.envAddress("FEE_MANAGER");
        labels[0] = "FeeManager";
        targets[1] = vm.envAddress("VAULT_REGISTRY");
        labels[1] = "VaultRegistry";
        targets[2] = vm.envAddress("PRICE_ROUTER");
        labels[2] = "ChainlinkPriceRouter";
        targets[3] = vm.envAddress("EXECUTION_ENGINE");
        labels[3] = "MainnetExecutionEngine";
        targets[4] = factory;
        labels[4] = "UserVaultFactoryV2";
        targets[5] = vm.envAddress("TRADE_DELEGATE_PROXY_V2");
        labels[5] = "TradeDelegateProxyV2";
        targets[6] = vm.envAddress("PRICE_ORACLE");
        labels[6] = "PriceOracle";
        targets[7] = vm.envAddress("AGENT_REGISTRY");
        labels[7] = "AgentRegistry";

        console.log("=== TransferMainnetToSafe ===");
        console.log("Safe:", safe);

        // Precondition: the beacon must already be owned by the factory. If it is
        // not, the deploy is broken and we must NOT proceed (transferring the
        // factory to the Safe would strand the beacon on the deployer).
        require(UpgradeableBeacon(beacon).owner() == factory, "Transfer: beacon not owned by factory");

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != address(0), string.concat("Transfer: zero addr for ", labels[i]));
            address cur = IOwnable(targets[i]).owner();
            console.log(labels[i], targets[i]);
            console.log("  owner:", cur, "->", safe);
            require(cur != LEAKED_EOA, string.concat("Transfer: leaked EOA still owns ", labels[i]));
            IOwnable(targets[i]).transferOwnership(safe);
        }
        vm.stopBroadcast();

        // ===================== Post-checks =====================
        for (uint256 i = 0; i < targets.length; i++) {
            require(IOwnable(targets[i]).owner() == safe, string.concat("post: not Safe-owned ", labels[i]));
            require(IOwnable(targets[i]).owner() != LEAKED_EOA, string.concat("post: leaked owns ", labels[i]));
        }
        // Beacon unchanged: still owned by the (now Safe-owned) factory.
        require(UpgradeableBeacon(beacon).owner() == factory, "post: beacon drifted off factory");
        require(IOwnable(factory).owner() == safe, "post: factory not Safe-owned");

        console.log("\nAll ownership transferred to the Safe. Deployer owns nothing.");
        console.log("Beacon remains owned by the (Safe-owned) factory:", factory);
    }
}
