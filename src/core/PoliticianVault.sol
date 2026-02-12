// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseVault} from "./BaseVault.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IPortfolioOracle} from "../interfaces/IPortfolioOracle.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";

/// @title PoliticianVault
/// @notice ERC-4626 vault that mirrors a politician's portfolio.
///         Target weights are sourced from PortfolioOracle (Chainlink-fed).
///         Only admin or Chainlink Automation can trigger rebalances.
contract PoliticianVault is BaseVault, Ownable {
    // --- State ---
    bytes32 public immutable politicianId;
    IPortfolioOracle public oracle;

    // --- Access control ---
    mapping(address => bool) public isKeeper; // Chainlink Automation addresses

    // --- Events ---
    event KeeperUpdated(address indexed keeper, bool status);
    event OracleUpdated(address indexed newOracle);

    // --- Errors ---
    error UnauthorizedRebalance();

    constructor(
        string memory _name,
        string memory _symbol,
        bytes32 _politicianId,
        address _baseAsset,
        address _oracle,
        address _feeManager,
        address _rebalanceEngine,
        address _owner
    )
        BaseVault(_name, _symbol, _baseAsset, _feeManager, _rebalanceEngine)
        Ownable(_owner)
    {
        require(_oracle != address(0), "PoliticianVault: zero oracle");
        politicianId = _politicianId;
        oracle = IPortfolioOracle(_oracle);
        highWaterMark = 1e18; // initial share price
    }

    // ===================== Admin =====================

    function setKeeper(address keeper, bool status) external onlyOwner {
        isKeeper[keeper] = status;
        emit KeeperUpdated(keeper, status);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "PoliticianVault: zero oracle");
        oracle = IPortfolioOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setRebalanceEngine(address _engine) external override onlyOwner {
        require(_engine != address(0), "PoliticianVault: zero engine");
        rebalanceEngine = IRebalanceEngine(_engine);
    }

    // ===================== Rebalance =====================

    /// @notice Trigger rebalance - only keepers or owner
    function rebalance() external override {
        if (!isKeeper[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedRebalance();
        }
        _accrueManagementFee();
        _executeRebalance();
    }

    // ===================== Target Weights =====================

    function _getTargetWeights() internal view override returns (IBaseVault.TokenWeight[] memory) {
        return oracle.getPortfolio(politicianId);
    }
}
