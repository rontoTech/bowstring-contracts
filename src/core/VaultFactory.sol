// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoliticianVault} from "./PoliticianVault.sol";
import {UserVault} from "./UserVault.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {FeeManager} from "./FeeManager.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RebalanceEngine} from "../rebalance/RebalanceEngine.sol";

/// @title VaultFactory
/// @notice Factory for creating PoliticianVaults (permissioned) and UserVaults (permissionless).
///         All vaults receive donation attack protection via dead shares.
///         Vaults are auto-registered in VaultRegistry and authorized on RebalanceEngine.
contract VaultFactory is Ownable {
    using SafeERC20 for IERC20;

    // --- Immutables / Config ---
    address public baseAsset; // tiltUSDC or main deposit token
    FeeManager public feeManager;
    VaultRegistry public registry;
    address public rebalanceEngine;
    address public tokenRouter; // price oracle + swap router
    address public defaultOracle; // for politician vaults

    // --- Permissionless config ---
    uint256 public vaultCreationFee; // flat ETH fee for user vault creation
    uint256 public minSeedDeposit; // minimum curator seed deposit
    uint256 public defaultTimeLock; // default time-lock for weight changes (24h)
    uint256 public defaultMinRebalanceInterval; // default min rebalance interval (4h)

    // --- Dead shares constant ---
    uint256 public constant DEAD_SHARE_AMOUNT = 1e3; // negligible: 0.000000000000001 tiltUSDC

    // --- Token whitelist ---
    mapping(address => bool) public approvedTokens;
    address[] public approvedTokenList;

    // --- Tracking ---
    address[] public allVaults;
    mapping(address => bool) public isVault;

    // --- Events ---
    event PoliticianVaultCreated(address indexed vault, bytes32 indexed politicianId, string name, string symbol);
    event UserVaultCreated(address indexed vault, address indexed curator, string name, string symbol);
    event TokenApprovalUpdated(address indexed token, bool approved);
    event CreationFeeUpdated(uint256 newFee);
    event MinSeedDepositUpdated(uint256 newMin);
    event DefaultOracleUpdated(address indexed oracle);
    event RebalanceEngineUpdated(address indexed engine);

    // --- Errors ---
    error InsufficientCreationFee();
    error InsufficientSeedDeposit();
    error TokenNotApproved();
    error InvalidWeights();
    error ZeroAddress();

    constructor(
        address _baseAsset,
        address _feeManager,
        address _registry,
        address _rebalanceEngine,
        address _tokenRouter,
        address _defaultOracle
    ) Ownable(msg.sender) {
        require(_baseAsset != address(0), "VaultFactory: zero base asset");
        baseAsset = _baseAsset;
        feeManager = FeeManager(payable(_feeManager));
        registry = VaultRegistry(_registry);
        rebalanceEngine = _rebalanceEngine;
        tokenRouter = _tokenRouter;
        defaultOracle = _defaultOracle;

        vaultCreationFee = 0.01 ether;
        minSeedDeposit = 100e18; // 100 tiltUSDC (18 decimals)
        defaultTimeLock = 24 hours;
        defaultMinRebalanceInterval = 4 hours;
    }

    // ===================== Admin =====================

    function setApprovedToken(address token, bool approved) external onlyOwner {
        approvedTokens[token] = approved;
        if (approved) {
            // Only add if not already in the list
            bool found = false;
            for (uint256 i = 0; i < approvedTokenList.length; i++) {
                if (approvedTokenList[i] == token) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                approvedTokenList.push(token);
            }
        } else {
            // Remove from list when disapproved
            for (uint256 i = 0; i < approvedTokenList.length; i++) {
                if (approvedTokenList[i] == token) {
                    approvedTokenList[i] = approvedTokenList[approvedTokenList.length - 1];
                    approvedTokenList.pop();
                    break;
                }
            }
        }
        emit TokenApprovalUpdated(token, approved);
    }

    function setApprovedTokensBatch(address[] calldata tokens, bool approved) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            approvedTokens[tokens[i]] = approved;
            if (approved) {
                bool found = false;
                for (uint256 j = 0; j < approvedTokenList.length; j++) {
                    if (approvedTokenList[j] == tokens[i]) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    approvedTokenList.push(tokens[i]);
                }
            } else {
                for (uint256 j = 0; j < approvedTokenList.length; j++) {
                    if (approvedTokenList[j] == tokens[i]) {
                        approvedTokenList[j] = approvedTokenList[approvedTokenList.length - 1];
                        approvedTokenList.pop();
                        break;
                    }
                }
            }
            emit TokenApprovalUpdated(tokens[i], approved);
        }
    }

    function setCreationFee(uint256 _fee) external onlyOwner {
        vaultCreationFee = _fee;
        emit CreationFeeUpdated(_fee);
    }

    function setMinSeedDeposit(uint256 _min) external onlyOwner {
        minSeedDeposit = _min;
        emit MinSeedDepositUpdated(_min);
    }

    function setDefaultOracle(address _oracle) external onlyOwner {
        defaultOracle = _oracle;
        emit DefaultOracleUpdated(_oracle);
    }

    function setRebalanceEngine(address _engine) external onlyOwner {
        rebalanceEngine = _engine;
        emit RebalanceEngineUpdated(_engine);
    }

    function setDefaultTimeLock(uint256 _timeLock) external onlyOwner {
        defaultTimeLock = _timeLock;
    }

    function setDefaultMinRebalanceInterval(uint256 _interval) external onlyOwner {
        defaultMinRebalanceInterval = _interval;
    }

    // ===================== Permissioned: Politician Vaults =====================

    /// @notice Create a politician vault (admin only) with donation attack protection
    /// @param seedDeposit Amount of base asset to seed (pulled from msg.sender)
    function createPoliticianVault(
        bytes32 politicianId,
        string calldata name,
        string calldata symbol,
        address oracle,
        string calldata metadataURI,
        uint256 seedDeposit
    ) external onlyOwner returns (address vault) {
        require(seedDeposit >= minSeedDeposit, "VaultFactory: insufficient seed");

        address oracleAddr = oracle != address(0) ? oracle : defaultOracle;
        require(oracleAddr != address(0), "VaultFactory: no oracle");

        PoliticianVault pVault = new PoliticianVault(
            name, symbol, politicianId, baseAsset, oracleAddr,
            address(feeManager), rebalanceEngine, tokenRouter, msg.sender
        );

        vault = address(pVault);
        _registerVault(vault);

        // Configure fees: 0% curator share for politician vaults
        feeManager.configureVaultFees(vault, 0, address(0));

        // Register in registry
        registry.registerVault(vault, VaultRegistry.VaultType.POLITICIAN, address(0), metadataURI);

        // Authorize vault on rebalance engine
        RebalanceEngine(rebalanceEngine).setVaultAuthorized(vault, true);

        // Seed deposit with dead shares (donation attack protection)
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), seedDeposit);
        IERC20(baseAsset).approve(vault, seedDeposit);

        pVault.deposit(DEAD_SHARE_AMOUNT, address(1));
        pVault.deposit(seedDeposit - DEAD_SHARE_AMOUNT, msg.sender);

        emit PoliticianVaultCreated(vault, politicianId, name, symbol);
    }

    // ===================== Permissionless: User Vaults =====================

    /// @notice Create a user vault (anyone can call)
    function createUserVault(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint16[] calldata weights,
        uint16 curatorFeeBps,
        uint256 seedDeposit,
        string calldata metadataURI
    ) external payable returns (address vault) {
        // Validate creation fee
        if (msg.value < vaultCreationFee) revert InsufficientCreationFee();

        // Validate seed deposit
        if (seedDeposit < minSeedDeposit) revert InsufficientSeedDeposit();

        // Validate tokens and weights
        require(tokens.length == weights.length, "VaultFactory: length mismatch");
        require(tokens.length > 0, "VaultFactory: empty portfolio");

        uint256 totalBps = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!approvedTokens[tokens[i]]) revert TokenNotApproved();
            totalBps += weights[i];
        }
        if (totalBps != 10000) revert InvalidWeights();

        // Validate curator fee
        require(
            curatorFeeBps <= 10000 - feeManager.MIN_PROTOCOL_SHARE_BPS(), "VaultFactory: curator fee too high"
        );

        // Build initial weights array
        IBaseVault.TokenWeight[] memory initialWeights = new IBaseVault.TokenWeight[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            initialWeights[i] = IBaseVault.TokenWeight({token: tokens[i], weightBps: weights[i]});
        }

        // Create vault with initial weights set in constructor
        UserVault uVault = new UserVault(
            name,
            symbol,
            baseAsset,
            address(feeManager),
            rebalanceEngine,
            tokenRouter,
            msg.sender, // curator
            approvedTokenList,
            defaultTimeLock,
            defaultMinRebalanceInterval,
            initialWeights
        );

        vault = address(uVault);
        _registerVault(vault);

        // Configure fees with curator split
        feeManager.configureVaultFees(vault, curatorFeeBps, msg.sender);

        // Register in registry
        registry.registerVault(vault, VaultRegistry.VaultType.USER, msg.sender, metadataURI);

        // Authorize vault on rebalance engine
        RebalanceEngine(rebalanceEngine).setVaultAuthorized(vault, true);

        // Seed deposit with dead shares (donation attack protection)
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), seedDeposit);
        IERC20(baseAsset).approve(vault, seedDeposit);

        uVault.deposit(DEAD_SHARE_AMOUNT, address(1));
        uVault.deposit(seedDeposit - DEAD_SHARE_AMOUNT, msg.sender);

        // Forward creation fee to protocol treasury
        if (msg.value > 0) {
            (bool success,) = feeManager.protocolTreasury().call{value: msg.value}("");
            require(success, "VaultFactory: fee transfer failed");
        }

        emit UserVaultCreated(vault, msg.sender, name, symbol);
    }

    // ===================== Internal =====================

    function _registerVault(address vault) internal {
        allVaults.push(vault);
        isVault[vault] = true;
    }

    // ===================== Views =====================

    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return approvedTokenList;
    }

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    receive() external payable {}
}
