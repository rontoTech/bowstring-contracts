// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IMarketGate
/// @notice Deposit gating surface capability-probed by vaults: true when market
///         conditions allow NAV-sensitive inflows (market open, oracles fresh).
interface IMarketGate {
    function depositsOpen() external view returns (bool);
}
