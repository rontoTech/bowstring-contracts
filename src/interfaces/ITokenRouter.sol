// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenRouter
/// @notice Abstracted trading interface - supports mock, DEX, and future RFQ (Citadel) settlement
interface ITokenRouter {
    event Swap(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    /// @notice Execute a token swap
    /// @param tokenIn The token to sell
    /// @param tokenOut The token to buy
    /// @param amountIn The amount of tokenIn to sell
    /// @param minAmountOut Minimum amount of tokenOut to receive (slippage protection)
    /// @param recipient The address to receive tokenOut
    /// @return amountOut The actual amount of tokenOut received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Get a quote for a potential swap (no execution)
    /// @param tokenIn The token to sell
    /// @param tokenOut The token to buy
    /// @param amountIn The amount of tokenIn
    /// @return amountOut The estimated amount of tokenOut
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    /// @notice Check if a trading pair is supported
    /// @param tokenIn The token to sell
    /// @param tokenOut The token to buy
    /// @return supported Whether the pair is supported
    function isPairSupported(address tokenIn, address tokenOut) external view returns (bool supported);

    /// @notice Get the stored USD price for a token (18 decimals)
    /// @param token The token address
    /// @return price The price in USD with 18 decimals
    function getTokenPrice(address token) external view returns (uint256 price);
}
