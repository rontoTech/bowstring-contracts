// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseVault} from "./BaseVault.sol";
import {FeeManager} from "./FeeManager.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title UserVault
/// @notice Permissionless vault where a curator manages a stock portfolio.
///         Curator executes individual trades via executeTrade().
///         Investor deposits are auto-allocated into the current portfolio composition.
///         Critical config changes (engine, router, base asset) are time-locked
///         to protect depositors from curator rug pulls.
contract UserVault is BaseVault {
    using SafeERC20 for IERC20;

    // ===========================================================
    //  STORAGE — layout must not change (beacon proxy compatibility)
    // ===========================================================
    address public curator;
    IBaseVault.TokenWeight[] private _targetWeights;

    uint256 public weightChangeTimeLock; // used for config change time-locks
    uint256 private __deprecated_pendingWeightChangeTime;
    IBaseVault.TokenWeight[] private __deprecated_pendingWeights;
    bool private __deprecated_hasPendingWeights;

    struct PendingAddress {
        address value;
        uint256 effectiveTime;
        bool pending;
    }

    PendingAddress public pendingRebalanceEngine;
    PendingAddress public pendingTokenRouter;
    PendingAddress public pendingBaseAsset;

    uint256 private __deprecated_minRebalanceInterval;
    uint256 private __deprecated_lastRebalanceTimestamp;

    mapping(address => bool) public approvedTokens;
    address[] public approvedTokenList;

    // --- Events ---
    event CuratorTransferred(address indexed previousCurator, address indexed newCurator);
    event TimeLockUpdated(uint256 newTimeLock);
    event TokenApproved(address indexed token, bool approved);
    event ConfigChangeProposed(bytes32 indexed configKey, address newValue, uint256 effectiveTime);
    event ConfigChangeApplied(bytes32 indexed configKey, address newValue);
    event ConfigChangeCancelled(bytes32 indexed configKey);

    // --- Errors ---
    error OnlyCurator();
    error NoPendingChange();
    error TimeLockNotExpired();
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
        // _minRebalanceInterval accepted for factory ABI compatibility but unused
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

    /// @notice Update the config change time lock. Curator or protocol admin.
    function setWeightChangeTimeLock(uint256 _timeLock) external {
        bool isCurator = msg.sender == curator;
        bool isProtocolAdmin = msg.sender == feeManager.owner();
        if (!isCurator && !isProtocolAdmin) revert OnlyCurator();
        weightChangeTimeLock = _timeLock;
    }

    // ===================== Time-locked Config Changes =====================

    /// @notice Update the FeeManager reference. Protocol admin only.
    function setFeeManager(address _feeManager) external override {
        require(msg.sender == feeManager.owner(), "UserVault: only protocol admin");
        require(_feeManager != address(0), "UserVault: zero fee manager");
        feeManager = FeeManager(payable(_feeManager));
    }

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

    // ===================== Trading =====================

    /// @notice Execute a single buy or sell.
    ///         Curator specifies the exact trade; held tokens and target weights
    ///         are updated afterward so new deposits allocate proportionally.
    function executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external onlyCurator nonReentrant whenNotPaused {
        require(address(rebalanceEngine) != address(0), "UserVault: no engine");
        require(amountIn > 0, "UserVault: zero amount");

        _accrueManagementFee();

        IERC20(tokenIn).forceApprove(address(rebalanceEngine), type(uint256).max);

        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](1);
        trades[0] = IRebalanceEngine.TradeOrder({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut
        });

        rebalanceEngine.executeRebalance(address(this), trades);

        IERC20(tokenIn).forceApprove(address(rebalanceEngine), 0);

        if (tokenOut != address(baseAsset) && !isHeldToken[tokenOut]) {
            heldTokens.push(tokenOut);
            isHeldToken[tokenOut] = true;
        }

        // Sync target weights to actual portfolio (used as first-allocation
        // fallback when _allocateUnallocated sees an empty getCurrentWeights)
        IBaseVault.TokenWeight[] memory current = this.getCurrentWeights();
        delete _targetWeights;
        for (uint256 i = 0; i < current.length; i++) {
            if (current[i].weightBps > 0) {
                _targetWeights.push(current[i]);
            }
        }
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

    // ===================== Migration =====================

    event TokenMigrated(address indexed oldToken, address indexed newToken);

    /// @notice Swap an old token address for a new one across all vault accounting.
    ///         Protocol admin only. The migration script must mint matching new-token
    ///         balances to this vault BEFORE calling this function.
    function migrateToken(address oldToken, address newToken) external {
        require(msg.sender == feeManager.owner(), "UserVault: only protocol admin");
        require(oldToken != newToken, "UserVault: same token");
        require(newToken != address(0), "UserVault: zero new token");

        for (uint256 i = 0; i < heldTokens.length; i++) {
            if (heldTokens[i] == oldToken) {
                heldTokens[i] = newToken;
                break;
            }
        }
        if (isHeldToken[oldToken]) {
            isHeldToken[oldToken] = false;
            isHeldToken[newToken] = true;
        }

        for (uint256 i = 0; i < _targetWeights.length; i++) {
            if (_targetWeights[i].token == oldToken) {
                _targetWeights[i].token = newToken;
                break;
            }
        }

        if (approvedTokens[oldToken]) {
            approvedTokens[oldToken] = false;
            approvedTokens[newToken] = true;
            for (uint256 i = 0; i < approvedTokenList.length; i++) {
                if (approvedTokenList[i] == oldToken) {
                    approvedTokenList[i] = newToken;
                    break;
                }
            }
        }

        emit TokenMigrated(oldToken, newToken);
    }

    // ===================== Internal =====================

    function _getTargetWeights() internal view override returns (IBaseVault.TokenWeight[] memory) {
        return _targetWeights;
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return approvedTokenList;
    }
}
