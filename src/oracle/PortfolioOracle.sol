// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPortfolioOracle} from "../interfaces/IPortfolioOracle.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";

/// @title PortfolioOracle
/// @notice Stores politician portfolio target weights, updated by Chainlink DON or authorized reporters.
///         Supports historical snapshots for analytics.
contract PortfolioOracle is IPortfolioOracle, Ownable {
    // --- Types ---
    struct PortfolioSnapshot {
        IBaseVault.TokenWeight[] weights;
        uint256 timestamp;
    }

    // --- Storage ---
    // Current portfolio for each politician
    mapping(bytes32 => IBaseVault.TokenWeight[]) private _currentPortfolios;
    mapping(bytes32 => uint256) private _lastUpdated;

    // Historical snapshots
    mapping(bytes32 => PortfolioSnapshot[]) private _snapshots;

    // Registered politicians
    bytes32[] public registeredPoliticians;
    mapping(bytes32 => bool) public isPoliticianRegistered;
    mapping(bytes32 => string) public politicianMetadata; // JSON metadata URI

    // Authorized reporters (Chainlink DON, keepers)
    mapping(address => bool) public authorizedReporters;

    // --- Events ---
    event ReporterUpdated(address indexed reporter, bool authorized);
    event PoliticianRegistered(bytes32 indexed politicianId, string metadataURI);

    // --- Errors ---
    error UnauthorizedReporter();
    error InvalidWeights();
    error PoliticianNotRegistered();

    constructor() Ownable(msg.sender) {}

    // ===================== Admin =====================

    function setReporter(address reporter, bool authorized) external onlyOwner {
        authorizedReporters[reporter] = authorized;
        emit ReporterUpdated(reporter, authorized);
    }

    /// @notice Register a new politician in the oracle
    function registerPolitician(bytes32 politicianId, string calldata metadataURI) external onlyOwner {
        if (!isPoliticianRegistered[politicianId]) {
            registeredPoliticians.push(politicianId);
            isPoliticianRegistered[politicianId] = true;
        }
        politicianMetadata[politicianId] = metadataURI;
        emit PoliticianRegistered(politicianId, metadataURI);
    }

    // ===================== Portfolio Updates =====================

    /// @notice Update portfolio weights for a politician
    /// @dev Callable by authorized reporters (Chainlink DON) or owner
    function updatePortfolio(bytes32 politicianId, IBaseVault.TokenWeight[] calldata weights) external override {
        if (!authorizedReporters[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedReporter();
        }
        if (!isPoliticianRegistered[politicianId]) revert PoliticianNotRegistered();

        // Validate weights sum to 10000 bps
        uint256 totalBps = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            require(weights[i].token != address(0), "PortfolioOracle: zero token");
            totalBps += weights[i].weightBps;
        }
        if (totalBps != 10000) revert InvalidWeights();

        // Store snapshot of previous portfolio
        if (_currentPortfolios[politicianId].length > 0) {
            PortfolioSnapshot storage snapshot = _snapshots[politicianId].push();
            for (uint256 i = 0; i < _currentPortfolios[politicianId].length; i++) {
                snapshot.weights.push(_currentPortfolios[politicianId][i]);
            }
            snapshot.timestamp = _lastUpdated[politicianId];
        }

        // Update current portfolio
        delete _currentPortfolios[politicianId];
        for (uint256 i = 0; i < weights.length; i++) {
            _currentPortfolios[politicianId].push(weights[i]);
        }
        _lastUpdated[politicianId] = block.timestamp;

        emit PortfolioUpdated(politicianId, weights, block.timestamp);
    }

    // ===================== Views =====================

    function getPortfolio(bytes32 politicianId) external view override returns (IBaseVault.TokenWeight[] memory) {
        return _currentPortfolios[politicianId];
    }

    function lastUpdateTimestamp(bytes32 politicianId) external view override returns (uint256) {
        return _lastUpdated[politicianId];
    }

    function getSnapshotCount(bytes32 politicianId) external view returns (uint256) {
        return _snapshots[politicianId].length;
    }

    function getSnapshot(bytes32 politicianId, uint256 index)
        external
        view
        returns (IBaseVault.TokenWeight[] memory weights, uint256 timestamp)
    {
        PortfolioSnapshot storage snapshot = _snapshots[politicianId][index];
        return (snapshot.weights, snapshot.timestamp);
    }

    function getRegisteredPoliticians() external view returns (bytes32[] memory) {
        return registeredPoliticians;
    }

    function totalRegisteredPoliticians() external view returns (uint256) {
        return registeredPoliticians.length;
    }
}
