// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseVault} from "./BaseVault.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title UserVault
/// @notice Permissionless vault where a curator sets target portfolio weights.
///         Anyone can create one via VaultFactory. Curator earns fee split.
///         Critical config changes (engine, router, base asset) are time-locked
///         to protect depositors from curator rug pulls.
contract UserVault is BaseVault {
    // --- State ---
    address public curator;
    IBaseVault.TokenWeight[] private _targetWeights;

    // --- Weight Management ---
    uint256 public weightChangeTimeLock; // seconds delay for weight changes
    uint256 public pendingWeightChangeTime; // when pending weights take effect
    IBaseVault.TokenWeight[] private _pendingWeights;
    bool public hasPendingWeights;

    // --- Config Change Time-lock ---
    struct PendingAddress {
        address value;
        uint256 effectiveTime;
        bool pending;
    }

    PendingAddress public pendingRebalanceEngine;
    PendingAddress public pendingTokenRouter;
    PendingAddress public pendingBaseAsset;

    uint256 public minRebalanceInterval; // minimum seconds between rebalances
    uint256 public lastRebalanceTimestamp;

    // --- Token whitelist ---
    mapping(address => bool) public approvedTokens;
    address[] public approvedTokenList;

    // --- Events ---
    event CuratorTransferred(address indexed previousCurator, address indexed newCurator);
    event TargetWeightsUpdated(IBaseVault.TokenWeight[] weights);
    event WeightChangePending(IBaseVault.TokenWeight[] weights, uint256 effectiveTime);
    event TimeLockUpdated(uint256 newTimeLock);
    event TokenApproved(address indexed token, bool approved);
    event ConfigChangeProposed(bytes32 indexed configKey, address newValue, uint256 effectiveTime);
    event ConfigChangeApplied(bytes32 indexed configKey, address newValue);
    event ConfigChangeCancelled(bytes32 indexed configKey);

    // --- Errors ---
    error OnlyCurator();
    error InvalidWeights();
    error TokenNotApproved();
    error DuplicateToken();
    error RebalanceTooSoon();
    error PendingWeightsNotReady();
    error WeightsNotChanged();
    error NoPendingChange();
    error TimeLockNotExpired();
    error UnauthorizedRebalance();
    error UnauthorizedUnpause();

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _baseAsset,
        address _feeManager,
        address _rebalanceEngine,
        address _tokenRouter,
        address _curator,
        address[] memory _approvedTokens,
        uint256 _timeLock,
        uint256 _minRebalanceInterval,
        IBaseVault.TokenWeight[] memory _initialWeights
    ) external initializer {
        __BaseVault_init(_name, _symbol, _baseAsset, _feeManager, _rebalanceEngine, _tokenRouter);

        require(_curator != address(0), "UserVault: zero curator");
        curator = _curator;
        weightChangeTimeLock = _timeLock;
        minRebalanceInterval = _minRebalanceInterval;
        highWaterMark = 1e18;

        for (uint256 i = 0; i < _approvedTokens.length; i++) {
            approvedTokens[_approvedTokens[i]] = true;
            approvedTokenList.push(_approvedTokens[i]);
        }

        if (_initialWeights.length > 0) {
            uint256 totalBps = 0;
            for (uint256 i = 0; i < _initialWeights.length; i++) {
                require(approvedTokens[_initialWeights[i].token], "UserVault: token not approved");
                totalBps += _initialWeights[i].weightBps;
                _targetWeights.push(_initialWeights[i]);
            }
            require(totalBps > 0 && totalBps <= 10000, "UserVault: weights must sum to 1-10000");
        }
    }

    // ===================== Curator Management =====================

    function transferCurator(address newCurator) external onlyCurator {
        require(newCurator != address(0), "UserVault: zero curator");
        address prev = curator;
        curator = newCurator;
        emit CuratorTransferred(prev, newCurator);
    }

    // ===================== Weight Management =====================

    /// @notice Set new target weights. If time-lock is active, weights go pending.
    function setTargetWeights(IBaseVault.TokenWeight[] calldata weights) external onlyCurator {
        _validateWeights(weights);

        if (weightChangeTimeLock == 0) {
            _setWeights(weights);
        } else {
            delete _pendingWeights;
            for (uint256 i = 0; i < weights.length; i++) {
                _pendingWeights.push(weights[i]);
            }
            pendingWeightChangeTime = block.timestamp + weightChangeTimeLock;
            hasPendingWeights = true;
            emit WeightChangePending(weights, pendingWeightChangeTime);
        }
    }

    /// @notice Apply pending weights after time-lock expires. Only curator can apply.
    function applyPendingWeights() external onlyCurator {
        if (!hasPendingWeights) revert WeightsNotChanged();
        if (block.timestamp < pendingWeightChangeTime) revert PendingWeightsNotReady();

        delete _targetWeights;
        for (uint256 i = 0; i < _pendingWeights.length; i++) {
            _targetWeights.push(_pendingWeights[i]);
        }
        delete _pendingWeights;
        hasPendingWeights = false;

        emit TargetWeightsUpdated(_targetWeights);
    }

    // ===================== Time-locked Config Changes =====================

    /// @notice Propose a new rebalance engine (time-locked for curators,
    ///         immediate for protocol admin to allow infrastructure upgrades).
    function setRebalanceEngine(address _engine) external override {
        bool isCurator = msg.sender == curator;
        bool isProtocolAdmin = msg.sender == feeManager.owner();
        if (!isCurator && !isProtocolAdmin) revert OnlyCurator();

        require(_engine != address(0), "UserVault: zero engine");
        if (weightChangeTimeLock == 0 || isProtocolAdmin) {
            rebalanceEngine = IRebalanceEngine(_engine);
            emit ConfigChangeApplied("rebalanceEngine", _engine);
        } else {
            pendingRebalanceEngine = PendingAddress({
                value: _engine,
                effectiveTime: block.timestamp + weightChangeTimeLock,
                pending: true
            });
            emit ConfigChangeProposed("rebalanceEngine", _engine, pendingRebalanceEngine.effectiveTime);
        }
    }

    /// @notice Apply pending rebalance engine after time-lock. Only curator can apply.
    function applyRebalanceEngine() external onlyCurator {
        if (!pendingRebalanceEngine.pending) revert NoPendingChange();
        if (block.timestamp < pendingRebalanceEngine.effectiveTime) revert TimeLockNotExpired();
        rebalanceEngine = IRebalanceEngine(pendingRebalanceEngine.value);
        pendingRebalanceEngine.pending = false;
        emit ConfigChangeApplied("rebalanceEngine", pendingRebalanceEngine.value);
    }

    /// @notice Propose a new token router (time-locked for curators,
    ///         immediate for protocol admin).
    function setTokenRouter(address _router) external override {
        bool isCurator = msg.sender == curator;
        bool isProtocolAdmin = msg.sender == feeManager.owner();
        if (!isCurator && !isProtocolAdmin) revert OnlyCurator();

        require(_router != address(0), "UserVault: zero router");
        if (weightChangeTimeLock == 0 || isProtocolAdmin) {
            tokenRouter = ITokenRouter(_router);
            emit ConfigChangeApplied("tokenRouter", _router);
        } else {
            pendingTokenRouter = PendingAddress({
                value: _router,
                effectiveTime: block.timestamp + weightChangeTimeLock,
                pending: true
            });
            emit ConfigChangeProposed("tokenRouter", _router, pendingTokenRouter.effectiveTime);
        }
    }

    /// @notice Apply pending token router after time-lock. Only curator can apply.
    function applyTokenRouter() external onlyCurator {
        if (!pendingTokenRouter.pending) revert NoPendingChange();
        if (block.timestamp < pendingTokenRouter.effectiveTime) revert TimeLockNotExpired();
        tokenRouter = ITokenRouter(pendingTokenRouter.value);
        pendingTokenRouter.pending = false;
        emit ConfigChangeApplied("tokenRouter", pendingTokenRouter.value);
    }

    /// @notice Propose a new base asset (time-locked)
    function setBaseAsset(address _baseAsset) external override onlyCurator {
        require(_baseAsset != address(0), "UserVault: zero base asset");
        if (weightChangeTimeLock == 0) {
            address old = address(baseAsset);
            baseAsset = IERC20(_baseAsset);
            emit BaseAssetUpdated(old, _baseAsset);
        } else {
            pendingBaseAsset = PendingAddress({
                value: _baseAsset,
                effectiveTime: block.timestamp + weightChangeTimeLock,
                pending: true
            });
            emit ConfigChangeProposed("baseAsset", _baseAsset, pendingBaseAsset.effectiveTime);
        }
    }

    /// @notice Apply pending base asset after time-lock
    function applyBaseAsset() external onlyCurator {
        if (!pendingBaseAsset.pending) revert NoPendingChange();
        if (block.timestamp < pendingBaseAsset.effectiveTime) revert TimeLockNotExpired();
        address old = address(baseAsset);
        baseAsset = IERC20(pendingBaseAsset.value);
        pendingBaseAsset.pending = false;
        emit BaseAssetUpdated(old, pendingBaseAsset.value);
    }

    // ===================== Cancel Pending Changes =====================

    /// @notice Cancel a pending rebalance engine change
    function cancelPendingRebalanceEngine() external onlyCurator {
        if (!pendingRebalanceEngine.pending) revert NoPendingChange();
        pendingRebalanceEngine.pending = false;
        emit ConfigChangeCancelled("rebalanceEngine");
    }

    /// @notice Cancel a pending token router change
    function cancelPendingTokenRouter() external onlyCurator {
        if (!pendingTokenRouter.pending) revert NoPendingChange();
        pendingTokenRouter.pending = false;
        emit ConfigChangeCancelled("tokenRouter");
    }

    /// @notice Cancel a pending base asset change
    function cancelPendingBaseAsset() external onlyCurator {
        if (!pendingBaseAsset.pending) revert NoPendingChange();
        pendingBaseAsset.pending = false;
        emit ConfigChangeCancelled("baseAsset");
    }

    /// @notice Cancel pending weight changes
    function cancelPendingWeights() external onlyCurator {
        if (!hasPendingWeights) revert WeightsNotChanged();
        delete _pendingWeights;
        hasPendingWeights = false;
        emit ConfigChangeCancelled("targetWeights");
    }

    // ===================== Withdrawal Slippage (time-locked) =====================

    struct PendingUint256 {
        uint256 value;
        uint256 effectiveTime;
        bool pending;
    }

    PendingUint256 public pendingWithdrawalSlippage;

    function setWithdrawalSlippage(uint256 _slippageBps) external override onlyCurator {
        require(_slippageBps <= 1000, "UserVault: slippage too high");
        if (weightChangeTimeLock == 0) {
            withdrawalSlippageBps = _slippageBps;
            emit WithdrawalSlippageUpdated(_slippageBps);
        } else {
            pendingWithdrawalSlippage = PendingUint256({
                value: _slippageBps,
                effectiveTime: block.timestamp + weightChangeTimeLock,
                pending: true
            });
        }
    }

    function applyWithdrawalSlippage() external onlyCurator {
        if (!pendingWithdrawalSlippage.pending) revert NoPendingChange();
        if (block.timestamp < pendingWithdrawalSlippage.effectiveTime) revert TimeLockNotExpired();
        withdrawalSlippageBps = pendingWithdrawalSlippage.value;
        pendingWithdrawalSlippage.pending = false;
        emit WithdrawalSlippageUpdated(pendingWithdrawalSlippage.value);
    }

    // ===================== Rebalance =====================

    /// @notice Trigger rebalance - only curator. Protected against reentrancy and paused state.
    function rebalance() external override onlyCurator nonReentrant whenNotPaused {
        if (block.timestamp - lastRebalanceTimestamp < minRebalanceInterval) {
            revert RebalanceTooSoon();
        }

        _accrueManagementFee();
        _executeRebalance();
        lastRebalanceTimestamp = block.timestamp;
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
        if (msg.sender != curator) revert UnauthorizedRebalance();
        if (block.timestamp - lastRebalanceTimestamp < minRebalanceInterval) {
            revert RebalanceTooSoon();
        }
        shares = _deposit(assets, receiver);
        _executeRebalance();
        lastRebalanceTimestamp = block.timestamp;
    }

    // ===================== Emergency =====================

    /// @notice Curator can pause vault operations
    function pause() external override onlyCurator {
        _pause();
    }

    /// @notice Emergency unpause — callable by curator OR protocol admin.
    ///         This prevents permanent fund lock if the curator abandons the vault
    ///         or loses access while the vault is paused.
    function unpause() external override {
        if (msg.sender != curator && msg.sender != feeManager.owner()) {
            revert UnauthorizedUnpause();
        }
        _unpause();
    }

    // ===================== Internal =====================

    function _getTargetWeights() internal view override returns (IBaseVault.TokenWeight[] memory) {
        return _targetWeights;
    }

    function _setWeights(IBaseVault.TokenWeight[] calldata weights) internal {
        delete _targetWeights;
        for (uint256 i = 0; i < weights.length; i++) {
            _targetWeights.push(weights[i]);
        }
        emit TargetWeightsUpdated(_targetWeights);
    }

    function _validateWeights(IBaseVault.TokenWeight[] calldata weights) internal view {
        uint256 totalBps = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            if (!approvedTokens[weights[i].token]) revert TokenNotApproved();
            // Check for duplicate tokens
            for (uint256 j = i + 1; j < weights.length; j++) {
                if (weights[i].token == weights[j].token) revert DuplicateToken();
            }
            totalBps += weights[i].weightBps;
        }
        if (totalBps == 0 || totalBps > 10000) revert InvalidWeights();
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return approvedTokenList;
    }

    function getPendingWeights() external view returns (IBaseVault.TokenWeight[] memory) {
        return _pendingWeights;
    }
}
