// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {FeeManager} from "./FeeManager.sol";

/// @title BaseVault
/// @notice Abstract ERC-4626-style vault holding a basket of stock tokens.
///         Deposits/withdraws are denominated in a single base asset (e.g. USDC).
///         Sub-classes override _getTargetWeights() to source allocations.
abstract contract BaseVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Immutables ---
    IERC20 public immutable baseAsset; // deposit/withdraw token (USDC)
    FeeManager public immutable feeManager;
    IRebalanceEngine public rebalanceEngine;

    // --- State ---
    uint256 public highWaterMark; // per-share HWM for performance fees
    uint256 public lastFeeAccrualTimestamp;
    uint256 public totalManagedAssets; // cached total value

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
        address _rebalanceEngine
    ) ERC20(_name, _symbol) {
        require(_baseAsset != address(0), "BaseVault: zero base asset");
        require(_feeManager != address(0), "BaseVault: zero fee manager");

        baseAsset = IERC20(_baseAsset);
        feeManager = FeeManager(payable(_feeManager));
        rebalanceEngine = IRebalanceEngine(_rebalanceEngine);
        lastFeeAccrualTimestamp = block.timestamp;
    }

    // ===================== ERC-4626 Core =====================

    /// @notice Deposit base assets and receive vault shares
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueManagementFee();

        // Charge entry fee
        uint256 entryFeeBps = feeManager.getEntryFee(address(this));
        uint256 feeAmount = (assets * entryFeeBps) / 10000;
        uint256 netAssets = assets - feeAmount;

        // Calculate shares
        shares = _convertToShares(netAssets);
        require(shares > 0, "BaseVault: zero shares");

        // Transfer assets from depositor
        baseAsset.safeTransferFrom(msg.sender, address(this), assets);

        // Record fee
        if (feeAmount > 0) {
            baseAsset.safeTransfer(address(feeManager), feeAmount);
            feeManager.recordFees(feeAmount);
        }

        totalManagedAssets += netAssets;
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

        require(baseAsset.balanceOf(address(this)) >= assets, "BaseVault: insufficient liquidity");

        _burn(owner, shares);
        totalManagedAssets -= assets;

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

        require(baseAsset.balanceOf(address(this)) >= assets, "BaseVault: insufficient liquidity");

        _burn(owner, shares);
        totalManagedAssets -= assets;

        if (feeAmount > 0) {
            baseAsset.safeTransfer(address(feeManager), feeAmount);
            feeManager.recordFees(feeAmount);
        }

        baseAsset.safeTransfer(receiver, netAssets);

        emit Withdrawn(receiver, assets, shares);
    }

    // ===================== Views =====================

    function totalAssets() public view returns (uint256) {
        return totalManagedAssets;
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
        uint256 total = totalManagedAssets;

        for (uint256 i = 0; i < len; i++) {
            address token = heldTokens[i];
            uint16 weightBps = 0;
            if (total > 0) {
                weightBps = uint16((tokenBalances[token] * 10000) / total);
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

        if (address(rebalanceEngine) != address(0) && totalManagedAssets > 0) {
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
                address(this), currentWeights, targetWeights, totalManagedAssets
            );

            if (trades.length > 0) {
                rebalanceEngine.executeRebalance(address(this), trades);
            }
        }

        // Update held tokens tracking from target weights
        _updateHeldTokens(targetWeights);

        emit RebalanceTriggered(block.timestamp);
    }

    // ===================== Fee Logic =====================

    function _accrueManagementFee() internal {
        uint256 pending = _pendingManagementFee();
        if (pending > 0 && totalManagedAssets > pending) {
            totalManagedAssets -= pending;
            // Fee is recorded but stays in the vault as base asset until collected
        }
        _accruePerformanceFee();
        lastFeeAccrualTimestamp = block.timestamp;
    }

    function _pendingManagementFee() internal view returns (uint256) {
        if (totalManagedAssets == 0 || lastFeeAccrualTimestamp == 0) return 0;

        uint256 elapsed = block.timestamp - lastFeeAccrualTimestamp;
        uint16 mgmtFeeBps = feeManager.getManagementFee(address(this));

        // Annual fee prorated: (totalAssets * feeBps * elapsed) / (10000 * 365 days)
        return (totalManagedAssets * mgmtFeeBps * elapsed) / (10000 * 365 days);
    }

    function _accruePerformanceFee() internal {
        if (totalSupply() == 0) return;

        uint256 currentSharePrice = _sharePrice();
        if (currentSharePrice > highWaterMark) {
            uint256 profit = currentSharePrice - highWaterMark;
            uint16 perfFeeBps = feeManager.getPerformanceFee(address(this));
            uint256 feePerShare = (profit * perfFeeBps) / 10000;
            uint256 totalFee = (feePerShare * totalSupply()) / 1e18;

            if (totalFee > 0 && totalManagedAssets > totalFee) {
                totalManagedAssets -= totalFee;
            }

            highWaterMark = currentSharePrice;
        }
    }

    // ===================== Internal Helpers =====================

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets; // 1:1 for first deposit
        }
        return assets.mulDiv(supply, totalManagedAssets, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares; // 1:1
        }
        return shares.mulDiv(totalManagedAssets, supply, Math.Rounding.Floor);
    }

    function _sharePrice() internal view returns (uint256) {
        if (totalSupply() == 0) return 1e18;
        return (totalManagedAssets * 1e18) / totalSupply();
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
}
