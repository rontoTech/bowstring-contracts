// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title RebalanceEngine
/// @notice Calculates and executes portfolio rebalancing trades.
///         Reads current vs target weights, computes optimal trade set,
///         and routes through TokenRouter.
contract RebalanceEngine is IRebalanceEngine, Ownable {
    using SafeERC20 for IERC20;

    // --- Config ---
    ITokenRouter public tokenRouter;
    address public baseAsset; // USDC - used as intermediate for routing
    uint256 public maxSlippageBps = 100; // 1% default max slippage
    uint256 public maxTradesPerRebalance = 20;

    // --- Access control ---
    mapping(address => bool) public authorizedVaults;

    // --- Events ---
    event RouterUpdated(address indexed newRouter);
    event SlippageUpdated(uint256 newSlippageBps);
    event VaultAuthorized(address indexed vault, bool authorized);

    // --- Errors ---
    error UnauthorizedVault();
    error TooManyTrades();
    error RouterNotSet();

    constructor(address _tokenRouter, address _baseAsset) Ownable(msg.sender) {
        tokenRouter = ITokenRouter(_tokenRouter);
        baseAsset = _baseAsset;
    }

    // ===================== Admin =====================

    function setRouter(address _router) external onlyOwner {
        tokenRouter = ITokenRouter(_router);
        emit RouterUpdated(_router);
    }

    function setMaxSlippage(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= 1000, "RebalanceEngine: slippage too high"); // max 10%
        maxSlippageBps = _slippageBps;
        emit SlippageUpdated(_slippageBps);
    }

    function setVaultAuthorized(address vault, bool authorized) external onlyOwner {
        authorizedVaults[vault] = authorized;
        emit VaultAuthorized(vault, authorized);
    }

    // ===================== Rebalance Calculation =====================

    /// @notice Calculate trades needed to move from current to target weights
    function calculateRebalance(
        address vault,
        IBaseVault.TokenWeight[] calldata currentWeights,
        IBaseVault.TokenWeight[] calldata targetWeights,
        uint256 totalValue
    ) external view override returns (TradeOrder[] memory trades) {
        if (address(tokenRouter) == address(0)) revert RouterNotSet();

        // Build a list of sells (overweight tokens) and buys (underweight tokens)
        // Strategy: sell overweight to base asset, buy underweight from base asset

        uint256 maxTrades = currentWeights.length + targetWeights.length;
        TradeOrder[] memory tempTrades = new TradeOrder[](maxTrades);
        uint256 tradeCount = 0;

        // Find tokens to sell (in current but not in target, or overweight)
        for (uint256 i = 0; i < currentWeights.length; i++) {
            uint16 targetBps = _findWeight(currentWeights[i].token, targetWeights);
            if (currentWeights[i].weightBps > targetBps) {
                uint256 excessBps = currentWeights[i].weightBps - targetBps;
                uint256 sellValueBase = (totalValue * excessBps) / 10000; // value in base asset terms

                if (sellValueBase > 0) {
                    // Convert base-asset value to token units using router quote
                    // getQuote(baseAsset, token, amount) = how many tokens is this base amount worth
                    uint256 sellAmountTokens = tokenRouter.getQuote(
                        baseAsset, currentWeights[i].token, sellValueBase
                    );
                    uint256 minOut = (sellValueBase * (10000 - maxSlippageBps)) / 10000;
                    tempTrades[tradeCount] = TradeOrder({
                        tokenIn: currentWeights[i].token,
                        tokenOut: baseAsset,
                        amountIn: sellAmountTokens,
                        minAmountOut: minOut
                    });
                    tradeCount++;
                }
            }
        }

        // Find tokens to buy (in target but not in current, or underweight)
        for (uint256 i = 0; i < targetWeights.length; i++) {
            uint16 currentBps = _findWeight(targetWeights[i].token, currentWeights);
            if (targetWeights[i].weightBps > currentBps) {
                uint256 deficitBps = targetWeights[i].weightBps - currentBps;
                uint256 buyValue = (totalValue * deficitBps) / 10000;
                if (buyValue > 0) {
                    // Get expected output in target token units, then apply slippage
                    uint256 expectedOut = tokenRouter.getQuote(baseAsset, targetWeights[i].token, buyValue);
                    uint256 minOut = (expectedOut * (10000 - maxSlippageBps)) / 10000;
                    tempTrades[tradeCount] = TradeOrder({
                        tokenIn: baseAsset,
                        tokenOut: targetWeights[i].token,
                        amountIn: buyValue,
                        minAmountOut: minOut
                    });
                    tradeCount++;
                }
            }
        }

        // Copy to correctly sized array
        trades = new TradeOrder[](tradeCount);
        for (uint256 i = 0; i < tradeCount; i++) {
            trades[i] = tempTrades[i];
        }
    }

    /// @notice Execute rebalance trades through the token router
    function executeRebalance(address vault, TradeOrder[] calldata trades) external override {
        if (!authorizedVaults[msg.sender] && !authorizedVaults[vault]) revert UnauthorizedVault();
        if (trades.length > maxTradesPerRebalance) revert TooManyTrades();
        if (address(tokenRouter) == address(0)) revert RouterNotSet();

        for (uint256 i = 0; i < trades.length; i++) {
            TradeOrder calldata trade = trades[i];

            // Pull tokens from vault
            IERC20(trade.tokenIn).safeTransferFrom(vault, address(this), trade.amountIn);

            // Approve router
            IERC20(trade.tokenIn).safeIncreaseAllowance(address(tokenRouter), trade.amountIn);

            // Execute swap, sending output back to vault
            tokenRouter.swap(trade.tokenIn, trade.tokenOut, trade.amountIn, trade.minAmountOut, vault);
        }

        emit RebalanceExecuted(vault, trades);
    }

    // ===================== Internal =====================

    function _findWeight(address token, IBaseVault.TokenWeight[] calldata weights)
        internal
        pure
        returns (uint16)
    {
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i].token == token) return weights[i].weightBps;
        }
        return 0;
    }
}
