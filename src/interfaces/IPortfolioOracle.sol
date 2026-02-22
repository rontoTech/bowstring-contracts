// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IBaseVault} from "./IBaseVault.sol";

/// @title IPortfolioOracle
/// @notice Interface for the oracle that provides politician portfolio target weights
interface IPortfolioOracle {
    event PortfolioUpdated(bytes32 indexed politicianId, IBaseVault.TokenWeight[] weights, uint256 timestamp);

    /// @notice Get the target portfolio weights for a politician
    /// @param politicianId Unique identifier for the politician
    /// @return weights Array of token weights in basis points
    function getPortfolio(bytes32 politicianId) external view returns (IBaseVault.TokenWeight[] memory weights);

    /// @notice Update the portfolio weights for a politician
    /// @param politicianId Unique identifier for the politician
    /// @param weights Array of token weights (must sum to 10000 bps)
    function updatePortfolio(bytes32 politicianId, IBaseVault.TokenWeight[] calldata weights) external;

    /// @notice Get the last update timestamp for a politician's portfolio
    /// @param politicianId Unique identifier for the politician
    /// @return timestamp The last update timestamp
    function lastUpdateTimestamp(bytes32 politicianId) external view returns (uint256 timestamp);
}
