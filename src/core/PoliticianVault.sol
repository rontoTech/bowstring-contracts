// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseVault} from "./BaseVault.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IPortfolioOracle} from "../interfaces/IPortfolioOracle.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title PoliticianVault
/// @notice ERC-4626 vault that mirrors a politician's portfolio.
///         Target weights are sourced from PortfolioOracle (Chainlink-fed).
///         Only admin or Chainlink Automation can trigger rebalances.
///         Includes emergency pause capability.
contract PoliticianVault is BaseVault, OwnableUpgradeable {
    // --- State ---
    bytes32 public politicianId;
    IPortfolioOracle public oracle;

    // --- Access control ---
    mapping(address => bool) public isKeeper; // Chainlink Automation addresses

    // --- Admin time-lock (prevents instant infrastructure swaps) ---
    uint256 public adminTimeLock = 24 hours;

    struct PendingAddress {
        address value;
        uint256 effectiveTime;
        bool pending;
    }

    PendingAddress public pendingRebalanceEngine;
    PendingAddress public pendingTokenRouter;
    PendingAddress public pendingBaseAsset;

    // --- Events ---
    event KeeperUpdated(address indexed keeper, bool status);
    event OracleUpdated(address indexed newOracle);
    event AdminTimeLockUpdated(uint256 newTimeLock);
    event ConfigChangeProposed(bytes32 indexed configKey, address newValue, uint256 effectiveTime);
    event ConfigChangeApplied(bytes32 indexed configKey, address newValue);
    event ConfigChangeCancelled(bytes32 indexed configKey);

    // --- Errors ---
    error UnauthorizedRebalance();
    error NoPendingChange();
    error TimeLockNotExpired();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        bytes32 _politicianId,
        address _baseAsset,
        address _oracle,
        address _feeManager,
        address _rebalanceEngine,
        address _tokenRouter,
        address _owner
    ) external initializer {
        __BaseVault_init(_name, _symbol, _baseAsset, _feeManager, _rebalanceEngine, _tokenRouter);
        __Ownable_init(_owner);

        require(_oracle != address(0), "PoliticianVault: zero oracle");
        politicianId = _politicianId;
        oracle = IPortfolioOracle(_oracle);
        highWaterMark = 1e18;
    }

    // ===================== Admin =====================

    function setKeeper(address keeper, bool status) external onlyOwner {
        isKeeper[keeper] = status;
        emit KeeperUpdated(keeper, status);
    }

    function setAdminTimeLock(uint256 _timeLock) external onlyOwner {
        adminTimeLock = _timeLock;
        emit AdminTimeLockUpdated(_timeLock);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "PoliticianVault: zero oracle");
        oracle = IPortfolioOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    // --- Time-locked infrastructure changes ---

    function setRebalanceEngine(address _engine) external override onlyOwner {
        require(_engine != address(0), "PoliticianVault: zero engine");
        pendingRebalanceEngine = PendingAddress({
            value: _engine,
            effectiveTime: block.timestamp + adminTimeLock,
            pending: true
        });
        emit ConfigChangeProposed("rebalanceEngine", _engine, pendingRebalanceEngine.effectiveTime);
    }

    function applyRebalanceEngine() external onlyOwner {
        if (!pendingRebalanceEngine.pending) revert NoPendingChange();
        if (block.timestamp < pendingRebalanceEngine.effectiveTime) revert TimeLockNotExpired();
        rebalanceEngine = IRebalanceEngine(pendingRebalanceEngine.value);
        pendingRebalanceEngine.pending = false;
        emit ConfigChangeApplied("rebalanceEngine", pendingRebalanceEngine.value);
    }

    function cancelPendingRebalanceEngine() external onlyOwner {
        if (!pendingRebalanceEngine.pending) revert NoPendingChange();
        pendingRebalanceEngine.pending = false;
        emit ConfigChangeCancelled("rebalanceEngine");
    }

    function setTokenRouter(address _router) external override onlyOwner {
        require(_router != address(0), "PoliticianVault: zero router");
        pendingTokenRouter = PendingAddress({
            value: _router,
            effectiveTime: block.timestamp + adminTimeLock,
            pending: true
        });
        emit ConfigChangeProposed("tokenRouter", _router, pendingTokenRouter.effectiveTime);
    }

    function applyTokenRouter() external onlyOwner {
        if (!pendingTokenRouter.pending) revert NoPendingChange();
        if (block.timestamp < pendingTokenRouter.effectiveTime) revert TimeLockNotExpired();
        tokenRouter = ITokenRouter(pendingTokenRouter.value);
        pendingTokenRouter.pending = false;
        emit ConfigChangeApplied("tokenRouter", pendingTokenRouter.value);
    }

    function cancelPendingTokenRouter() external onlyOwner {
        if (!pendingTokenRouter.pending) revert NoPendingChange();
        pendingTokenRouter.pending = false;
        emit ConfigChangeCancelled("tokenRouter");
    }

    function setBaseAsset(address _baseAsset) external override onlyOwner {
        require(_baseAsset != address(0), "PoliticianVault: zero base asset");
        pendingBaseAsset = PendingAddress({
            value: _baseAsset,
            effectiveTime: block.timestamp + adminTimeLock,
            pending: true
        });
        emit ConfigChangeProposed("baseAsset", _baseAsset, pendingBaseAsset.effectiveTime);
    }

    function applyBaseAsset() external onlyOwner {
        if (!pendingBaseAsset.pending) revert NoPendingChange();
        if (block.timestamp < pendingBaseAsset.effectiveTime) revert TimeLockNotExpired();
        address old = address(baseAsset);
        baseAsset = IERC20(pendingBaseAsset.value);
        pendingBaseAsset.pending = false;
        emit BaseAssetUpdated(old, pendingBaseAsset.value);
    }

    function cancelPendingBaseAsset() external onlyOwner {
        if (!pendingBaseAsset.pending) revert NoPendingChange();
        pendingBaseAsset.pending = false;
        emit ConfigChangeCancelled("baseAsset");
    }

    function setWithdrawalSlippage(uint256 _slippageBps) external override onlyOwner {
        require(_slippageBps <= 1000, "PoliticianVault: slippage too high");
        withdrawalSlippageBps = _slippageBps;
        emit WithdrawalSlippageUpdated(_slippageBps);
    }

    // ===================== Emergency =====================

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    // ===================== Rebalance =====================

    /// @notice Trigger rebalance - only keepers or owner. Protected against reentrancy and paused state.
    function rebalance() external override nonReentrant whenNotPaused {
        if (!isKeeper[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedRebalance();
        }
        _accrueManagementFee();
        _executeRebalance();
    }

    /// @notice Deposit + rebalance with same access control as rebalance().
    ///         Prevents unauthorized callers from triggering rebalances via deposit.
    function depositAndRebalance(uint256 assets, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (!isKeeper[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedRebalance();
        }
        shares = _deposit(assets, receiver);
        _executeRebalance();
    }

    // ===================== Target Weights =====================

    function _getTargetWeights() internal view override returns (IBaseVault.TokenWeight[] memory) {
        return oracle.getPortfolio(politicianId);
    }

    uint256[50] private __gap;
}
