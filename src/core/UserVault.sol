// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseVault} from "./BaseVault.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @title UserVault
/// @notice Permissionless vault where a curator sets target portfolio weights.
///         Anyone can create one via VaultFactory. Curator earns fee split.
contract UserVault is BaseVault {
    // --- State ---
    address public curator;
    IBaseVault.TokenWeight[] private _targetWeights;

    // --- Configuration ---
    uint256 public weightChangeTimeLock; // seconds delay for weight changes
    uint256 public pendingWeightChangeTime; // when pending weights take effect
    IBaseVault.TokenWeight[] private _pendingWeights;
    bool public hasPendingWeights;

    uint256 public minRebalanceInterval; // minimum seconds between rebalances
    uint256 public lastRebalanceTimestamp;

    // --- Token whitelist (enforced by factory, stored here for reference) ---
    mapping(address => bool) public approvedTokens;
    address[] public approvedTokenList;

    // --- Events ---
    event CuratorTransferred(address indexed previousCurator, address indexed newCurator);
    event TargetWeightsUpdated(IBaseVault.TokenWeight[] weights);
    event WeightChangePending(IBaseVault.TokenWeight[] weights, uint256 effectiveTime);
    event TimeLockUpdated(uint256 newTimeLock);
    event TokenApproved(address indexed token, bool approved);

    // --- Errors ---
    error OnlyCurator();
    error InvalidWeights();
    error TokenNotApproved();
    error RebalanceTooSoon();
    error PendingWeightsNotReady();
    error WeightsNotChanged();

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    constructor(
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
    )
        BaseVault(_name, _symbol, _baseAsset, _feeManager, _rebalanceEngine, _tokenRouter)
    {
        require(_curator != address(0), "UserVault: zero curator");
        curator = _curator;
        weightChangeTimeLock = _timeLock;
        minRebalanceInterval = _minRebalanceInterval;
        highWaterMark = 1e18;

        // Initialize approved tokens
        for (uint256 i = 0; i < _approvedTokens.length; i++) {
            approvedTokens[_approvedTokens[i]] = true;
            approvedTokenList.push(_approvedTokens[i]);
        }

        // Set initial target weights (validated by factory before passing)
        if (_initialWeights.length > 0) {
            uint256 totalBps = 0;
            for (uint256 i = 0; i < _initialWeights.length; i++) {
                require(approvedTokens[_initialWeights[i].token], "UserVault: token not approved");
                totalBps += _initialWeights[i].weightBps;
                _targetWeights.push(_initialWeights[i]);
            }
            require(totalBps == 10000, "UserVault: weights must sum to 10000");
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
            // Immediate effect
            _setWeights(weights);
        } else {
            // Queue pending weights
            delete _pendingWeights;
            for (uint256 i = 0; i < weights.length; i++) {
                _pendingWeights.push(weights[i]);
            }
            pendingWeightChangeTime = block.timestamp + weightChangeTimeLock;
            hasPendingWeights = true;
            emit WeightChangePending(weights, pendingWeightChangeTime);
        }
    }

    /// @notice Apply pending weights after time-lock expires
    function applyPendingWeights() external {
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

    // ===================== Rebalance =====================

    /// @notice Trigger rebalance - only curator
    function rebalance() external override onlyCurator {
        if (block.timestamp - lastRebalanceTimestamp < minRebalanceInterval) {
            revert RebalanceTooSoon();
        }

        _accrueManagementFee();
        _executeRebalance();
        lastRebalanceTimestamp = block.timestamp;
    }

    // ===================== Admin (Curator) =====================

    function setRebalanceEngine(address _engine) external override onlyCurator {
        require(_engine != address(0), "UserVault: zero engine");
        rebalanceEngine = IRebalanceEngine(_engine);
    }

    function setTokenRouter(address _router) external override onlyCurator {
        require(_router != address(0), "UserVault: zero router");
        tokenRouter = ITokenRouter(_router);
    }

    function setBaseAsset(address _baseAsset) external override onlyCurator {
        require(_baseAsset != address(0), "UserVault: zero base asset");
        address old = address(baseAsset);
        baseAsset = IERC20(_baseAsset);
        emit BaseAssetUpdated(old, _baseAsset);
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
            totalBps += weights[i].weightBps;
        }
        if (totalBps != 10000) revert InvalidWeights();
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return approvedTokenList;
    }

    function getPendingWeights() external view returns (IBaseVault.TokenWeight[] memory) {
        return _pendingWeights;
    }
}
