// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PortfolioOracle} from "./PortfolioOracle.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";

/// @title ChainlinkAdapter
/// @notice Adapter for Chainlink Automation (Keepers) and Chainlink Functions
///         to trigger portfolio updates and vault rebalances.
///
///         - checkUpkeep / performUpkeep: Chainlink Automation compatible
///         - handleOracleFulfillment: Chainlink Functions callback
contract ChainlinkAdapter is Ownable {
    // --- State ---
    PortfolioOracle public oracle;

    // Politicians to monitor
    bytes32[] public monitoredPoliticians;
    mapping(bytes32 => bool) public isMonitored;

    // Vaults to rebalance per politician
    mapping(bytes32 => address[]) public politicianVaults;

    // Monitoring config
    uint256 public checkInterval = 15 minutes;
    uint256 public lastCheckTimestamp;

    // Chainlink Functions
    bytes32 public latestRequestId;
    mapping(bytes32 => bytes32) public requestToPolitician; // requestId => politicianId

    // --- Events ---
    event UpkeepPerformed(bytes32 indexed politicianId, uint256 timestamp);
    event OracleUpdateReceived(bytes32 indexed politicianId, uint256 numTokens);
    event PoliticianMonitored(bytes32 indexed politicianId, bool status);
    event VaultLinked(bytes32 indexed politicianId, address indexed vault);

    // --- Errors ---
    error UpkeepNotNeeded();
    error InvalidRequestId();

    constructor(address _oracle) Ownable(msg.sender) {
        require(_oracle != address(0), "ChainlinkAdapter: zero oracle");
        oracle = PortfolioOracle(_oracle);
    }

    // ===================== Admin =====================

    function setOracle(address _oracle) external onlyOwner {
        oracle = PortfolioOracle(_oracle);
    }

    function setCheckInterval(uint256 _interval) external onlyOwner {
        checkInterval = _interval;
    }

    function monitorPolitician(bytes32 politicianId) external onlyOwner {
        if (!isMonitored[politicianId]) {
            monitoredPoliticians.push(politicianId);
            isMonitored[politicianId] = true;
            emit PoliticianMonitored(politicianId, true);
        }
    }

    function linkVault(bytes32 politicianId, address vault) external onlyOwner {
        politicianVaults[politicianId].push(vault);
        emit VaultLinked(politicianId, vault);
    }

    // ===================== Chainlink Automation =====================

    /// @notice Check if upkeep is needed (called by Chainlink Automation)
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (block.timestamp - lastCheckTimestamp < checkInterval) {
            return (false, "");
        }

        // Check if any monitored politician has a stale portfolio
        for (uint256 i = 0; i < monitoredPoliticians.length; i++) {
            bytes32 pid = monitoredPoliticians[i];
            uint256 lastUpdate = oracle.lastUpdateTimestamp(pid);

            // If portfolio was updated recently, check if vaults need rebalancing
            if (lastUpdate > lastCheckTimestamp) {
                return (true, abi.encode(pid));
            }
        }

        return (false, "");
    }

    /// @notice Perform upkeep - trigger vault rebalances
    function performUpkeep(bytes calldata performData) external {
        bytes32 politicianId = abi.decode(performData, (bytes32));

        // Trigger rebalance on all linked vaults
        address[] memory vaults = politicianVaults[politicianId];
        for (uint256 i = 0; i < vaults.length; i++) {
            // Call rebalance on each vault - they handle their own auth
            (bool success,) = vaults[i].call(abi.encodeWithSignature("rebalance()"));
            // Don't revert if one vault fails
            if (success) {
                emit UpkeepPerformed(politicianId, block.timestamp);
            }
        }

        lastCheckTimestamp = block.timestamp;
    }

    // ===================== Chainlink Functions Callback =====================

    /// @notice Handle oracle fulfillment from Chainlink Functions
    /// @dev Expected data format: abi.encode(bytes32 politicianId, address[] tokens, uint16[] weights)
    function handleOracleFulfillment(bytes32 requestId, bytes calldata response, bytes calldata /* err */ )
        external
    {
        // In production, verify the caller is the Chainlink Functions router
        // For testnet, we allow any caller (to be restricted)

        (bytes32 politicianId, address[] memory tokens, uint16[] memory weights) =
            abi.decode(response, (bytes32, address[], uint16[]));

        IBaseVault.TokenWeight[] memory tokenWeights = new IBaseVault.TokenWeight[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenWeights[i] = IBaseVault.TokenWeight({token: tokens[i], weightBps: weights[i]});
        }

        // Update the oracle
        oracle.updatePortfolio(politicianId, tokenWeights);

        emit OracleUpdateReceived(politicianId, tokens.length);
    }

    // ===================== Views =====================

    function getMonitoredPoliticians() external view returns (bytes32[] memory) {
        return monitoredPoliticians;
    }

    function getVaultsForPolitician(bytes32 politicianId) external view returns (address[] memory) {
        return politicianVaults[politicianId];
    }
}
