// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoliticianVault} from "./PoliticianVault.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {FeeManager} from "./FeeManager.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RebalanceEngine} from "../rebalance/RebalanceEngine.sol";

/// @title PoliticianVaultFactory
/// @notice Permissioned factory for creating PoliticianVaults.
///         Vaults receive donation attack protection via dead shares,
///         are auto-registered in VaultRegistry and authorized on RebalanceEngine.
contract PoliticianVaultFactory is Ownable {
    using SafeERC20 for IERC20;

    address public baseAsset;
    FeeManager public feeManager;
    VaultRegistry public registry;
    address public rebalanceEngine;
    address public tokenRouter;
    address public defaultOracle;

    uint256 public minSeedDeposit;
    uint256 public constant DEAD_SHARE_AMOUNT = 1e6;

    address[] public allVaults;
    mapping(address => bool) public isVault;

    event PoliticianVaultCreated(address indexed vault, bytes32 indexed politicianId, string name, string symbol);
    event DefaultOracleUpdated(address indexed oracle);
    event RebalanceEngineUpdated(address indexed engine);
    event MinSeedDepositUpdated(uint256 newMin);

    constructor(
        address _baseAsset,
        address _feeManager,
        address _registry,
        address _rebalanceEngine,
        address _tokenRouter,
        address _defaultOracle
    ) Ownable(msg.sender) {
        require(_baseAsset != address(0), "PVF: zero base asset");
        require(_feeManager != address(0), "PVF: zero fee manager");
        require(_registry != address(0), "PVF: zero registry");
        require(_rebalanceEngine != address(0), "PVF: zero engine");
        require(_tokenRouter != address(0), "PVF: zero router");
        baseAsset = _baseAsset;
        feeManager = FeeManager(payable(_feeManager));
        registry = VaultRegistry(_registry);
        rebalanceEngine = _rebalanceEngine;
        tokenRouter = _tokenRouter;
        defaultOracle = _defaultOracle;
        minSeedDeposit = 100e6;
    }

    function createPoliticianVault(
        bytes32 politicianId,
        string calldata name,
        string calldata symbol,
        address oracle,
        string calldata metadataURI,
        uint256 seedDeposit
    ) external onlyOwner returns (address vault) {
        require(seedDeposit >= minSeedDeposit, "PVF: insufficient seed");

        address oracleAddr = oracle != address(0) ? oracle : defaultOracle;
        require(oracleAddr != address(0), "PVF: no oracle");

        PoliticianVault pVault = new PoliticianVault(
            name, symbol, politicianId, baseAsset, oracleAddr,
            address(feeManager), rebalanceEngine, tokenRouter, msg.sender
        );

        vault = address(pVault);
        allVaults.push(vault);
        isVault[vault] = true;

        feeManager.configureVaultFees(vault, 0, address(0));
        registry.registerVault(vault, VaultRegistry.VaultType.POLITICIAN, address(0), metadataURI);
        RebalanceEngine(rebalanceEngine).setVaultAuthorized(vault, true);

        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), seedDeposit);
        IERC20(baseAsset).forceApprove(vault, seedDeposit);
        pVault.deposit(DEAD_SHARE_AMOUNT, address(1));
        pVault.deposit(seedDeposit - DEAD_SHARE_AMOUNT, msg.sender);
        IERC20(baseAsset).forceApprove(vault, 0);

        emit PoliticianVaultCreated(vault, politicianId, name, symbol);
    }

    function setDefaultOracle(address _oracle) external onlyOwner {
        defaultOracle = _oracle;
        emit DefaultOracleUpdated(_oracle);
    }

    function setRebalanceEngine(address _engine) external onlyOwner {
        rebalanceEngine = _engine;
        emit RebalanceEngineUpdated(_engine);
    }

    function setMinSeedDeposit(uint256 _min) external onlyOwner {
        minSeedDeposit = _min;
        emit MinSeedDepositUpdated(_min);
    }

    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }
}
