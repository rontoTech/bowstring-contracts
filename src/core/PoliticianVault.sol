// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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
        address _tokenRouter,
        address _owner
    )
        BaseVault(_name, _symbol, _baseAsset, _feeManager, _rebalanceEngine, _tokenRouter)
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

    function setTokenRouter(address _router) external override onlyOwner {
        require(_router != address(0), "PoliticianVault: zero router");
        tokenRouter = ITokenRouter(_router);
    }

    function setBaseAsset(address _baseAsset) external override onlyOwner {
        require(_baseAsset != address(0), "PoliticianVault: zero base asset");
        address old = address(baseAsset);
        baseAsset = IERC20(_baseAsset);
        emit BaseAssetUpdated(old, _baseAsset);
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
}
