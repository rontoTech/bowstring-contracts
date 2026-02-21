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
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @title PoliticianVaultFactory
/// @notice Permissioned factory for creating PoliticianVaults behind BeaconProxy.
///         All vaults share a single implementation via UpgradeableBeacon.
///         Upgrading the beacon upgrades every vault atomically in one tx.
contract PoliticianVaultFactory is Ownable {
    using SafeERC20 for IERC20;

    UpgradeableBeacon public beacon;

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
    event ImplementationUpgraded(address indexed newImplementation);

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

        PoliticianVault impl = new PoliticianVault();
        beacon = new UpgradeableBeacon(address(impl), address(this));
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

        bytes memory initData = abi.encodeCall(
            PoliticianVault.initialize,
            (name, symbol, politicianId, baseAsset, oracleAddr,
             address(feeManager), rebalanceEngine, tokenRouter, msg.sender)
        );

        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        vault = address(proxy);

        allVaults.push(vault);
        isVault[vault] = true;

        feeManager.configureVaultFees(vault, 0, address(0));
        registry.registerVault(vault, VaultRegistry.VaultType.POLITICIAN, address(0), metadataURI);
        RebalanceEngine(rebalanceEngine).setVaultAuthorized(vault, true);

        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), seedDeposit);
        IERC20(baseAsset).forceApprove(vault, seedDeposit);
        PoliticianVault(vault).deposit(DEAD_SHARE_AMOUNT, address(1));
        PoliticianVault(vault).deposit(seedDeposit - DEAD_SHARE_AMOUNT, msg.sender);
        IERC20(baseAsset).forceApprove(vault, 0);

        emit PoliticianVaultCreated(vault, politicianId, name, symbol);
    }

    function upgradeImplementation(address newImplementation) external onlyOwner {
        beacon.upgradeTo(newImplementation);
        emit ImplementationUpgraded(newImplementation);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
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
