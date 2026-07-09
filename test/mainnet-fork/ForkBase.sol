// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @title ForkBase
/// @notice Shared gate for the mainnet fork suite. All tests are OFF unless
///         `MAINNET_FORK=true`, so a normal `forge test` never touches the
///         network and the non-fork test count is unchanged. When enabled, the
///         suite forks Robinhood Chain mainnet (chain 4663) via the
///         `robinhood_mainnet` rpc alias in foundry.toml.
///
///         Each test starts with `_skipIfNoFork()` which calls `vm.skip(true)`
///         and returns, so unset runs report as SKIPPED (not passed, not failed).
abstract contract ForkBase is Test {
    // ---- Mainnet ground-truth constants (global-constraints.md §6) ----
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6-dec base
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // Seed stock tokens (18-dec ERC-20 + ERC-8056).
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    bool internal forkEnabled;

    function _initFork() internal {
        forkEnabled = vm.envOr("MAINNET_FORK", false);
        if (!forkEnabled) return;
        vm.createSelectFork("robinhood_mainnet");
        require(block.chainid == CHAIN_ID, "ForkBase: wrong chain, check robinhood_mainnet rpc alias");
    }

    /// @dev Call at the top of every test. Returns true when the body should be
    ///      SKIPPED (fork disabled) — caller must `return` immediately after.
    function _skipIfNoFork() internal returns (bool) {
        if (!forkEnabled) {
            vm.skip(true);
            return true;
        }
        return false;
    }
}

/// @notice Settable Chainlink-style aggregator for deterministic fork gating
///         (used where a REAL feed address is not supplied via env).
contract MockAggregatorV3 {
    uint8 private _decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}
