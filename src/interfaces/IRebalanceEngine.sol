// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBaseVault} from "./IBaseVault.sol";

/// @title IRebalanceEngine
/// @notice Interface for the engine that executes portfolio rebalancing
interface IRebalanceEngine {
    struct TradeOrder {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    event RebalanceExecuted(address indexed vault, TradeOrder[] trades);

    /// @notice Calculate the trades needed to rebalance a vault
    /// @param vault The vault to rebalance
    /// @param currentWeights Current token weights
    /// @param targetWeights Target token weights
    /// @param totalValue Total vault value in base asset
    /// @return trades Array of trade orders to execute
    function calculateRebalance(
        address vault,
        IBaseVault.TokenWeight[] calldata currentWeights,
        IBaseVault.TokenWeight[] calldata targetWeights,
        uint256 totalValue
    ) external view returns (TradeOrder[] memory trades);

    /// @notice Execute the rebalance trades for a vault
    /// @param vault The vault being rebalanced
    /// @param trades Array of trades to execute
    function executeRebalance(address vault, TradeOrder[] calldata trades) external;
}
