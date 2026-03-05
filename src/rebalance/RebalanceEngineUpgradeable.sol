// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title RebalanceEngineUpgradeable
/// @notice UUPS-proxied rebalance engine. Calculates and executes portfolio trades
///         by routing through the TokenRouter.
contract RebalanceEngineUpgradeable is Initializable, OwnableUpgradeable, UUPSUpgradeable, IRebalanceEngine {
    using SafeERC20 for IERC20;

    ITokenRouter public tokenRouter;
    address public baseAsset;
    uint256 public maxSlippageBps;
    uint256 public maxTradesPerRebalance;

    mapping(address => bool) public authorizedVaults;
    mapping(address => bool) public authorizedCallers;

    event RouterUpdated(address indexed newRouter);
    event SlippageUpdated(uint256 newSlippageBps);
    event VaultAuthorized(address indexed vault, bool authorized);
    event CallerAuthorized(address indexed caller, bool authorized);

    error UnauthorizedVault();
    error TooManyTrades();
    error RouterNotSet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address tokenRouter_, address baseAsset_, address owner_) external initializer {
        __Ownable_init(owner_);
        tokenRouter = ITokenRouter(tokenRouter_);
        baseAsset = baseAsset_;
        maxSlippageBps = 100;
        maxTradesPerRebalance = 20;
    }

    // ===================== Admin =====================

    function setRouter(address _router) external onlyOwner {
        tokenRouter = ITokenRouter(_router);
        emit RouterUpdated(_router);
    }

    function setMaxSlippage(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= 1000, "RebalanceEngine: slippage too high");
        maxSlippageBps = _slippageBps;
        emit SlippageUpdated(_slippageBps);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit CallerAuthorized(caller, authorized);
    }

    function setVaultAuthorized(address vault, bool authorized) external {
        require(msg.sender == owner() || authorizedCallers[msg.sender], "RebalanceEngine: not authorized");
        authorizedVaults[vault] = authorized;
        emit VaultAuthorized(vault, authorized);
    }

    // ===================== Rebalance Calculation =====================

    function calculateRebalance(
        address vault,
        IBaseVault.TokenWeight[] calldata currentWeights,
        IBaseVault.TokenWeight[] calldata targetWeights,
        uint256 totalValue
    ) external view override returns (TradeOrder[] memory trades) {
        if (address(tokenRouter) == address(0)) revert RouterNotSet();

        uint256 maxTrades = currentWeights.length + targetWeights.length;
        TradeOrder[] memory tempTrades = new TradeOrder[](maxTrades);
        uint256 tradeCount = 0;

        uint256 totalCurrentBps = 0;
        for (uint256 i = 0; i < currentWeights.length; i++) {
            totalCurrentBps += currentWeights[i].weightBps;
        }

        uint256 availableBaseFromSells = 0;
        for (uint256 i = 0; i < currentWeights.length; i++) {
            uint16 targetBps = _findWeight(currentWeights[i].token, targetWeights);
            if (currentWeights[i].weightBps > targetBps) {
                uint256 excessBps = currentWeights[i].weightBps - targetBps;
                uint256 sellValueBase = (totalValue * excessBps) / 10000;
                if (sellValueBase > 0) {
                    availableBaseFromSells += sellValueBase;
                    uint256 sellAmountTokens =
                        tokenRouter.getQuote(baseAsset, currentWeights[i].token, sellValueBase);
                    uint256 vaultBal = IERC20(currentWeights[i].token).balanceOf(vault);
                    if (sellAmountTokens > vaultBal) sellAmountTokens = vaultBal;
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

        uint256 unallocatedBase =
            totalCurrentBps < 10000 ? (totalValue * (10000 - totalCurrentBps)) / 10000 : 0;

        uint256 rawBudget = availableBaseFromSells + unallocatedBase;
        uint256 haircut = (rawBudget * 200) / 10000;
        uint256 availableForBuys = rawBudget - haircut;

        uint256 totalDeficitBps = 0;
        for (uint256 i = 0; i < targetWeights.length; i++) {
            uint16 currentBps = _findWeight(targetWeights[i].token, currentWeights);
            if (targetWeights[i].weightBps > currentBps) {
                totalDeficitBps += targetWeights[i].weightBps - currentBps;
            }
        }

        for (uint256 i = 0; i < targetWeights.length; i++) {
            uint16 currentBps = _findWeight(targetWeights[i].token, currentWeights);
            if (targetWeights[i].weightBps > currentBps) {
                uint256 deficitBps = targetWeights[i].weightBps - currentBps;
                uint256 buyValue =
                    totalDeficitBps > 0 ? (availableForBuys * deficitBps) / totalDeficitBps : 0;
                if (buyValue > 0) {
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

        trades = new TradeOrder[](tradeCount);
        for (uint256 i = 0; i < tradeCount; i++) {
            trades[i] = tempTrades[i];
        }
    }

    function executeRebalance(address vault, TradeOrder[] calldata trades) external override {
        if (msg.sender != vault) revert UnauthorizedVault();
        if (!authorizedVaults[vault]) revert UnauthorizedVault();
        if (trades.length > maxTradesPerRebalance) revert TooManyTrades();
        if (address(tokenRouter) == address(0)) revert RouterNotSet();

        for (uint256 i = 0; i < trades.length; i++) {
            TradeOrder calldata trade = trades[i];
            IERC20(trade.tokenIn).safeTransferFrom(vault, address(this), trade.amountIn);
            IERC20(trade.tokenIn).forceApprove(address(tokenRouter), trade.amountIn);
            tokenRouter.swap(trade.tokenIn, trade.tokenOut, trade.amountIn, trade.minAmountOut, vault);
            IERC20(trade.tokenIn).forceApprove(address(tokenRouter), 0);
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

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[44] private __gap;
}
