// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";
import {FeeManager} from "./FeeManager.sol";

/// @title BaseVault
/// @notice Abstract ERC-4626-style vault holding a basket of stock tokens.
///         Deposits/withdraws are denominated in a single base asset (bowUSDC).
///         Uses the TokenRouter as a price oracle for accurate NAV calculation.
///         Sub-classes override _getTargetWeights() to source allocations.
abstract contract BaseVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Immutables ---
    IERC20 public immutable baseAsset; // deposit/withdraw token (bowUSDC)
    FeeManager public immutable feeManager;
    IRebalanceEngine public rebalanceEngine;
    ITokenRouter public tokenRouter; // price oracle + swap router

    // --- State ---
    uint256 public highWaterMark; // per-share HWM for performance fees
    uint256 public lastFeeAccrualTimestamp;

    // --- Holdings ---
    address[] public heldTokens;
    mapping(address => uint256) public tokenBalances;
    mapping(address => bool) public isHeldToken;

    // --- Events ---
    event Deposited(address indexed depositor, uint256 assets, uint256 shares);
    event Withdrawn(address indexed withdrawer, uint256 assets, uint256 shares);
    event RebalanceTriggered(uint256 timestamp);

    // --- Errors ---
    error ZeroAmount();
    error ZeroAddress();
    error SlippageExceeded();

    constructor(
        string memory _name,
        string memory _symbol,
        address _baseAsset,
        address _feeManager,
        address _rebalanceEngine,
        address _tokenRouter
    ) ERC20(_name, _symbol) {
        require(_baseAsset != address(0), "BaseVault: zero base asset");
        require(_feeManager != address(0), "BaseVault: zero fee manager");

        baseAsset = IERC20(_baseAsset);
        feeManager = FeeManager(payable(_feeManager));
        rebalanceEngine = IRebalanceEngine(_rebalanceEngine);
        tokenRouter = ITokenRouter(_tokenRouter);
        lastFeeAccrualTimestamp = block.timestamp;
    }

    // ===================== ERC-4626 Core =====================

    /// @notice Deposit base assets and receive vault shares
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        shares = _deposit(assets, receiver);
    }

    /// @notice Deposit base assets, receive shares, and immediately rebalance into target portfolio
    function depositAndRebalance(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        shares = _deposit(assets, receiver);
        _executeRebalance();
    }

    /// @dev Internal deposit logic shared by deposit() and depositAndRebalance()
    function _deposit(uint256 assets, address receiver) internal returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueManagementFee();

        // Charge entry fee
        uint256 entryFeeBps = feeManager.getEntryFee(address(this));
        uint256 feeAmount = (assets * entryFeeBps) / 10000;
        uint256 netAssets = assets - feeAmount;

        // Calculate shares based on current NAV
        shares = _convertToShares(netAssets);
        require(shares > 0, "BaseVault: zero shares");

        // Transfer assets from depositor
        baseAsset.safeTransferFrom(msg.sender, address(this), assets);

        // Record fee
        if (feeAmount > 0) {
            baseAsset.safeTransfer(address(feeManager), feeAmount);
            feeManager.recordFees(feeAmount);
        }

        _mint(receiver, shares);

        emit Deposited(receiver, assets, shares);
    }

    /// @notice Withdraw base assets by burning vault shares
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueManagementFee();

        shares = _convertToShares(assets);
        require(shares > 0, "BaseVault: zero shares");

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Charge exit fee on the gross amount
        uint256 exitFeeBps = feeManager.getExitFee(address(this));
        uint256 feeAmount = (assets * exitFeeBps) / 10000;
        uint256 netAssets = assets - feeAmount;

        // Ensure enough base asset liquidity -- sell held tokens if needed
        _ensureBaseLiquidity(assets);

        _burn(owner, shares);

        // Transfer fee
        if (feeAmount > 0) {
            baseAsset.safeTransfer(address(feeManager), feeAmount);
            feeManager.recordFees(feeAmount);
        }

        // Transfer net assets to receiver
        baseAsset.safeTransfer(receiver, netAssets);

        emit Withdrawn(receiver, assets, shares);
    }

    /// @notice Redeem shares for base assets
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueManagementFee();

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        assets = _convertToAssets(shares);
        require(assets > 0, "BaseVault: zero assets");

        // Charge exit fee
        uint256 exitFeeBps = feeManager.getExitFee(address(this));
        uint256 feeAmount = (assets * exitFeeBps) / 10000;
        uint256 netAssets = assets - feeAmount;

        // Ensure enough base asset liquidity
        _ensureBaseLiquidity(assets);

        _burn(owner, shares);

        if (feeAmount > 0) {
            baseAsset.safeTransfer(address(feeManager), feeAmount);
            feeManager.recordFees(feeAmount);
        }

        baseAsset.safeTransfer(receiver, netAssets);

        emit Withdrawn(receiver, assets, shares);
    }

    // ===================== Views =====================

    /// @notice Total vault value in base asset terms, calculated from live token prices
    function totalAssets() public view returns (uint256) {
        return _totalAssets();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares);
    }

    function getTargetWeights() external view returns (IBaseVault.TokenWeight[] memory) {
        return _getTargetWeights();
    }

    function getCurrentWeights() external view returns (IBaseVault.TokenWeight[] memory) {
        uint256 len = heldTokens.length;
        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](len);
        uint256 total = _totalAssets();

        for (uint256 i = 0; i < len; i++) {
            address token = heldTokens[i];
            uint16 weightBps = 0;
            if (total > 0) {
                uint256 tokenValue = _tokenValueInBase(token);
                weightBps = uint16((tokenValue * 10000) / total);
            }
            weights[i] = IBaseVault.TokenWeight({token: token, weightBps: weightBps});
        }

        return weights;
    }

    function getVaultConfig() external view returns (IBaseVault.VaultConfig memory) {
        return IBaseVault.VaultConfig({
            entryFeeBps: feeManager.getEntryFee(address(this)),
            exitFeeBps: feeManager.getExitFee(address(this)),
            managementFeeBps: feeManager.getManagementFee(address(this)),
            performanceFeeBps: feeManager.getPerformanceFee(address(this)),
            rebalanceThresholdBps: 200 // 2% default
        });
    }

    function accruedFees() external view returns (uint256) {
        return _pendingManagementFee();
    }

    function getHeldTokens() external view returns (address[] memory) {
        return heldTokens;
    }

    // ===================== Rebalance =====================

    /// @notice Trigger a rebalance. Access control is in subclasses.
    function rebalance() external virtual;

    function _executeRebalance() internal {
        IBaseVault.TokenWeight[] memory currentWeights = this.getCurrentWeights();
        IBaseVault.TokenWeight[] memory targetWeights = _getTargetWeights();

        uint256 totalValue = _totalAssets();

        if (address(rebalanceEngine) != address(0) && totalValue > 0) {
            // Approve rebalance engine to move tokens
            uint256 baseBalance = baseAsset.balanceOf(address(this));
            if (baseBalance > 0) {
                baseAsset.safeIncreaseAllowance(address(rebalanceEngine), baseBalance);
            }
            for (uint256 i = 0; i < heldTokens.length; i++) {
                uint256 bal = IERC20(heldTokens[i]).balanceOf(address(this));
                if (bal > 0) {
                    IERC20(heldTokens[i]).safeIncreaseAllowance(address(rebalanceEngine), bal);
                }
            }

            IRebalanceEngine.TradeOrder[] memory trades = rebalanceEngine.calculateRebalance(
                address(this), currentWeights, targetWeights, totalValue
            );

            if (trades.length > 0) {
                rebalanceEngine.executeRebalance(address(this), trades);
            }
        }

        // Update held tokens tracking from target weights
        _updateHeldTokens(targetWeights);

        emit RebalanceTriggered(block.timestamp);
    }

    // ===================== Price Oracle / NAV =====================

    /// @notice Calculate total vault value from actual token balances and prices
    function _totalAssets() internal view returns (uint256 total) {
        // Base asset balance (bowUSDC sitting in the vault, not yet deployed)
        total = baseAsset.balanceOf(address(this));

        // Value of each held stock token, priced via the router oracle
        if (address(tokenRouter) != address(0)) {
            uint256 basePrice = tokenRouter.getTokenPrice(address(baseAsset));
            if (basePrice > 0) {
                for (uint256 i = 0; i < heldTokens.length; i++) {
                    address token = heldTokens[i];
                    uint256 bal = IERC20(token).balanceOf(address(this));
                    if (bal > 0) {
                        uint256 tokenPrice = tokenRouter.getTokenPrice(token);
                        if (tokenPrice > 0) {
                            // Both bowUSDC and stock tokens are 18 decimals
                            // value = balance * tokenPrice / basePrice
                            total += (bal * tokenPrice) / basePrice;
                        }
                    }
                }
            }
        }
    }

    /// @notice Value of a single held token in base asset terms
    function _tokenValueInBase(address token) internal view returns (uint256) {
        if (address(tokenRouter) == address(0)) return 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return 0;

        uint256 tokenPrice = tokenRouter.getTokenPrice(token);
        uint256 basePrice = tokenRouter.getTokenPrice(address(baseAsset));
        if (tokenPrice == 0 || basePrice == 0) return 0;

        return (bal * tokenPrice) / basePrice;
    }

    // ===================== Liquidity Management =====================

    /// @notice Sell held tokens to ensure enough base asset for a withdrawal
    function _ensureBaseLiquidity(uint256 needed) internal {
        uint256 baseBalance = baseAsset.balanceOf(address(this));
        if (baseBalance >= needed) return;
        if (address(rebalanceEngine) == address(0)) return;

        uint256 deficit = needed - baseBalance;

        // Sell held tokens proportionally to cover the deficit
        uint256 totalHeldValue = _totalAssets() - baseBalance;
        if (totalHeldValue == 0) return;

        for (uint256 i = 0; i < heldTokens.length; i++) {
            address token = heldTokens[i];
            uint256 tokenVal = _tokenValueInBase(token);
            if (tokenVal == 0) continue;

            // Proportional amount to sell from this token
            uint256 sellValueBase = (deficit * tokenVal) / totalHeldValue;
            if (sellValueBase == 0) continue;

            // Convert base-asset-denominated value to token units
            uint256 tokenBal = IERC20(token).balanceOf(address(this));
            uint256 sellAmount = (tokenBal * sellValueBase) / tokenVal;
            if (sellAmount > tokenBal) sellAmount = tokenBal;
            if (sellAmount == 0) continue;

            // Approve and swap
            IERC20(token).safeIncreaseAllowance(address(rebalanceEngine), sellAmount);

            IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](1);
            trades[0] = IRebalanceEngine.TradeOrder({
                tokenIn: token,
                tokenOut: address(baseAsset),
                amountIn: sellAmount,
                minAmountOut: 0 // testnet: no slippage protection
            });

            rebalanceEngine.executeRebalance(address(this), trades);
        }
    }

    // ===================== Fee Logic =====================

    function _accrueManagementFee() internal {
        _pendingManagementFee(); // track for analytics
        _accruePerformanceFee();
        lastFeeAccrualTimestamp = block.timestamp;
    }

    function _pendingManagementFee() internal view returns (uint256) {
        uint256 total = _totalAssets();
        if (total == 0 || lastFeeAccrualTimestamp == 0) return 0;

        uint256 elapsed = block.timestamp - lastFeeAccrualTimestamp;
        uint16 mgmtFeeBps = feeManager.getManagementFee(address(this));

        // Annual fee prorated: (totalAssets * feeBps * elapsed) / (10000 * 365 days)
        return (total * mgmtFeeBps * elapsed) / (10000 * 365 days);
    }

    function _accruePerformanceFee() internal {
        if (totalSupply() == 0) return;

        uint256 currentSharePrice = _sharePrice();
        if (currentSharePrice > highWaterMark) {
            highWaterMark = currentSharePrice;
        }
    }

    // ===================== Internal Helpers =====================

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 total = _totalAssets();
        if (supply == 0 || total == 0) {
            return assets; // 1:1 for first deposit
        }
        return assets.mulDiv(supply, total, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 total = _totalAssets();
        if (supply == 0 || total == 0) {
            return shares; // 1:1
        }
        return shares.mulDiv(total, supply, Math.Rounding.Floor);
    }

    function _sharePrice() internal view returns (uint256) {
        if (totalSupply() == 0) return 1e18;
        return (_totalAssets() * 1e18) / totalSupply();
    }

    function _updateHeldTokens(IBaseVault.TokenWeight[] memory weights) internal {
        // Clear existing
        for (uint256 i = 0; i < heldTokens.length; i++) {
            isHeldToken[heldTokens[i]] = false;
        }
        delete heldTokens;

        // Set new
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i].weightBps > 0 && !isHeldToken[weights[i].token]) {
                heldTokens.push(weights[i].token);
                isHeldToken[weights[i].token] = true;
            }
        }
    }

    /// @notice Abstract: subclasses provide target portfolio weights
    function _getTargetWeights() internal view virtual returns (IBaseVault.TokenWeight[] memory);

    function setRebalanceEngine(address _engine) external virtual;

    function setTokenRouter(address _router) external virtual;
}
