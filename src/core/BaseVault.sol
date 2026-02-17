// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";
import {FeeManager} from "./FeeManager.sol";

/// @title BaseVault
/// @notice Abstract ERC-4626-style vault holding a basket of stock tokens.
///         Deposits/withdraws are denominated in a single base asset (tiltUSDC).
///         Uses the TokenRouter as a price oracle for accurate NAV calculation.
///         Management/performance fees collected via share dilution to fee recipients.
///         Sub-classes override _getTargetWeights() to source allocations.
abstract contract BaseVault is ERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Core ---
    IERC20 public baseAsset; // deposit/withdraw token (tiltUSDC) — mutable by admin
    FeeManager public immutable feeManager;
    IRebalanceEngine public rebalanceEngine;
    ITokenRouter public tokenRouter; // price oracle + swap router

    // --- Fee State ---
    uint256 public highWaterMark; // per-share HWM for performance fees
    uint256 public lastFeeAccrualTimestamp;

    // --- Holdings ---
    address[] public heldTokens;
    mapping(address => bool) public isHeldToken;

    // --- Slippage ---
    uint256 public withdrawalSlippageBps = 100; // 1% default

    // --- Events ---
    event Deposited(address indexed depositor, uint256 assets, uint256 shares);
    event Withdrawn(address indexed withdrawer, uint256 assets, uint256 shares);
    event RebalanceTriggered(uint256 timestamp);
    event BaseAssetUpdated(address indexed oldAsset, address indexed newAsset);
    event FeeSharesMinted(uint256 feeShares, address indexed recipient);
    event WithdrawalSlippageUpdated(uint256 newSlippageBps);

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
    function deposit(uint256 assets, address receiver)
        public
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = _deposit(assets, receiver);
    }

    /// @notice Deposit base assets, receive shares, and immediately rebalance into target portfolio
    function depositAndRebalance(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = _deposit(assets, receiver);
        _executeRebalance();
    }

    /// @notice Deposit using EIP-2612 permit — approve + deposit in a single transaction
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        IERC20Permit(address(baseAsset)).permit(msg.sender, address(this), assets, deadline, v, r, s);
        shares = _deposit(assets, receiver);
    }

    /// @dev Internal deposit logic shared by all deposit variants
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

        // Record entry fee
        if (feeAmount > 0) {
            baseAsset.safeTransfer(address(feeManager), feeAmount);
            feeManager.recordFees(feeAmount);
        }

        _mint(receiver, shares);

        emit Deposited(receiver, assets, shares);
    }

    /// @notice Withdraw base assets by burning vault shares
    function withdraw(uint256 assets, address receiver, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
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

        // Ensure enough base asset liquidity
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
    function redeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
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

    /// @notice Current price per share (18 decimal precision)
    function sharePrice() external view returns (uint256) {
        return _sharePrice();
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
        return _pendingManagementFeeShares() + _pendingPerformanceFeeShares();
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
        total = baseAsset.balanceOf(address(this));

        if (address(tokenRouter) != address(0)) {
            uint256 basePrice = tokenRouter.getTokenPrice(address(baseAsset));
            if (basePrice > 0) {
                for (uint256 i = 0; i < heldTokens.length; i++) {
                    address token = heldTokens[i];
                    uint256 bal = IERC20(token).balanceOf(address(this));
                    if (bal > 0) {
                        uint256 tokenPrice = tokenRouter.getTokenPrice(token);
                        if (tokenPrice > 0) {
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

    /// @notice Sell held tokens to ensure enough base asset for a withdrawal.
    ///         Uses configurable slippage protection.
    function _ensureBaseLiquidity(uint256 needed) internal {
        uint256 baseBalance = baseAsset.balanceOf(address(this));
        if (baseBalance >= needed) return;
        if (address(rebalanceEngine) == address(0)) return;

        uint256 deficit = needed - baseBalance;

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

            // Approve and swap with slippage protection
            IERC20(token).safeIncreaseAllowance(address(rebalanceEngine), sellAmount);

            uint256 minOut = (sellValueBase * (10000 - withdrawalSlippageBps)) / 10000;

            IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](1);
            trades[0] = IRebalanceEngine.TradeOrder({
                tokenIn: token,
                tokenOut: address(baseAsset),
                amountIn: sellAmount,
                minAmountOut: minOut
            });

            rebalanceEngine.executeRebalance(address(this), trades);
        }
    }

    // ===================== Fee Logic =====================

    /// @notice Accrue management and performance fees via share dilution.
    ///         Fee shares are minted directly to protocol treasury and curator.
    function _accrueManagementFee() internal {
        if (totalSupply() == 0) {
            lastFeeAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 mgmtShares = _pendingManagementFeeShares();
        uint256 perfShares = _pendingPerformanceFeeShares();
        uint256 totalFeeShares = mgmtShares + perfShares;

        if (totalFeeShares > 0) {
            _mintFeeShares(totalFeeShares);
        }

        // Update HWM after performance fee collection
        uint256 currentPrice = _sharePrice();
        if (currentPrice > highWaterMark) {
            highWaterMark = currentPrice;
        }

        lastFeeAccrualTimestamp = block.timestamp;
    }

    /// @notice Calculate pending management fee as share count
    function _pendingManagementFeeShares() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || lastFeeAccrualTimestamp == 0) return 0;

        uint256 elapsed = block.timestamp - lastFeeAccrualTimestamp;
        if (elapsed == 0) return 0;

        uint16 mgmtFeeBps = feeManager.getManagementFee(address(this));
        if (mgmtFeeBps == 0) return 0;

        // Annualized fee prorated: shares = supply * feeBps * elapsed / (BPS * 365 days)
        return (supply * mgmtFeeBps * elapsed) / (10000 * 365 days);
    }

    /// @notice Calculate pending performance fee as share count
    function _pendingPerformanceFeeShares() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 currentPrice = _sharePrice();
        if (currentPrice <= highWaterMark) return 0;

        uint16 perfFeeBps = feeManager.getPerformanceFee(address(this));
        if (perfFeeBps == 0) return 0;

        // Performance fee on profit above high-water mark
        uint256 profit = currentPrice - highWaterMark;
        return (supply * profit * perfFeeBps) / (currentPrice * 10000);
    }

    /// @notice Mint fee shares, split between protocol treasury and curator
    function _mintFeeShares(uint256 totalFeeShares) internal {
        address protocolRecipient = feeManager.protocolTreasury();
        FeeManager.VaultFeeConfig memory config = feeManager.getVaultFeeConfig(address(this));

        if (config.curator != address(0) && config.curatorShareBps > 0) {
            uint256 curatorShares = (totalFeeShares * config.curatorShareBps) / 10000;
            uint256 protocolShares = totalFeeShares - curatorShares;
            if (protocolShares > 0) {
                _mint(protocolRecipient, protocolShares);
                emit FeeSharesMinted(protocolShares, protocolRecipient);
            }
            if (curatorShares > 0) {
                _mint(config.curator, curatorShares);
                emit FeeSharesMinted(curatorShares, config.curator);
            }
        } else {
            _mint(protocolRecipient, totalFeeShares);
            emit FeeSharesMinted(totalFeeShares, protocolRecipient);
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

    // --- Abstract admin functions (access control in subclasses) ---
    function setRebalanceEngine(address _engine) external virtual;
    function setTokenRouter(address _router) external virtual;
    function setBaseAsset(address _baseAsset) external virtual;
    function setWithdrawalSlippage(uint256 _slippageBps) external virtual;
    function pause() external virtual;
    function unpause() external virtual;
}
