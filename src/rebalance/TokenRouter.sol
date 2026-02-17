// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title MockTokenRouter
/// @notice Mock router for testnet - swaps at oracle price instantly.
///         Architecture is ready for future RFQ (Citadel) or DEX router.
contract MockTokenRouter is ITokenRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Price oracle (simple mock) ---
    // token => price in USD with 18 decimals
    mapping(address => uint256) public tokenPrices;

    // --- Supported pairs ---
    mapping(address => mapping(address => bool)) public pairSupported;

    // --- Authorized callers (RebalanceEngine) ---
    mapping(address => bool) public authorizedCallers;

    // --- Events ---
    event PriceUpdated(address indexed token, uint256 price);
    event PairUpdated(address indexed tokenA, address indexed tokenB, bool supported);
    event CallerAuthorized(address indexed caller, bool authorized);

    // --- Errors ---
    error UnauthorizedCaller();
    error UnsupportedPair();
    error InsufficientOutput();
    error ZeroPrice();

    constructor() Ownable(msg.sender) {}

    // ===================== Admin =====================

    function setTokenPrice(address token, uint256 priceUsd18) external onlyOwner {
        require(priceUsd18 > 0, "MockTokenRouter: zero price");
        tokenPrices[token] = priceUsd18;
        emit PriceUpdated(token, priceUsd18);
    }

    function setTokenPricesBatch(address[] calldata tokens, uint256[] calldata prices) external onlyOwner {
        require(tokens.length == prices.length, "MockTokenRouter: length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(prices[i] > 0, "MockTokenRouter: zero price");
            tokenPrices[tokens[i]] = prices[i];
            emit PriceUpdated(tokens[i], prices[i]);
        }
    }

    function setPairSupported(address tokenA, address tokenB, bool supported) external onlyOwner {
        pairSupported[tokenA][tokenB] = supported;
        pairSupported[tokenB][tokenA] = supported;
        emit PairUpdated(tokenA, tokenB, supported);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit CallerAuthorized(caller, authorized);
    }

    // ===================== ITokenRouter =====================

    /// @notice Execute a mock swap at oracle prices
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external override nonReentrant returns (uint256 amountOut) {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        if (!pairSupported[tokenIn][tokenOut]) revert UnsupportedPair();

        amountOut = getQuote(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Transfer tokenIn from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Mint/transfer tokenOut to recipient (mock: assumes we have tokens)
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swap(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Get a price quote
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        override
        returns (uint256 amountOut)
    {
        uint256 priceIn = tokenPrices[tokenIn];
        uint256 priceOut = tokenPrices[tokenOut];

        if (priceIn == 0) revert ZeroPrice();
        if (priceOut == 0) revert ZeroPrice();

        // amountOut = amountIn * priceIn / priceOut
        amountOut = (amountIn * priceIn) / priceOut;
    }

    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool) {
        return pairSupported[tokenIn][tokenOut];
    }

    /// @notice Get the stored USD price for a token
    function getTokenPrice(address token) external view override returns (uint256) {
        return tokenPrices[token];
    }

    // ===================== Liquidity Management (Mock) =====================

    /// @notice Fund the router with tokens for swaps (testnet only)
    function fundRouter(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw tokens from router (admin only)
    function withdrawTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
