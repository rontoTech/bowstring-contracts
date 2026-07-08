// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IERC8056
/// @notice Surface of ERC-8056 tokenized equities (Robinhood Chain mainnet stock
///         tokens) consumed by the protocol: the corporate-action UI multiplier
///         (1e18 fixed-point) and the issuer's oracle pause flag.
interface IERC8056 {
    function uiMultiplier() external view returns (uint256);

    function oraclePaused() external view returns (bool);
}
