// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UserVault} from "./UserVault.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {FeeManager} from "./FeeManager.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RebalanceEngine} from "../rebalance/RebalanceEngine.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @title UserVaultFactory
/// @notice Permissionless factory for creating UserVaults.
///         Anyone can create a vault by paying the creation fee and seeding
///         initial liquidity. Vaults receive dead-share protection,
///         auto-register in VaultRegistry and authorize on RebalanceEngine.
contract UserVaultFactory is Ownable {
    using SafeERC20 for IERC20;

    UpgradeableBeacon public beacon;

    address public baseAsset;
    FeeManager public feeManager;
    VaultRegistry public registry;
    address public rebalanceEngine;
    address public tokenRouter;

    uint256 public vaultCreationFee;
    uint256 public minSeedDeposit;
    uint256 public defaultTimeLock;
    uint256 public defaultMinRebalanceInterval;
    uint256 public constant DEAD_SHARE_AMOUNT = 1e6;

    mapping(address => bool) public approvedTokens;
    address[] public approvedTokenList;

    address[] public allVaults;
    mapping(address => bool) public isVault;

    event UserVaultCreated(address indexed vault, address indexed curator, string name, string symbol);
    event TokenApprovalUpdated(address indexed token, bool approved);
    event CreationFeeUpdated(uint256 newFee);
    event MinSeedDepositUpdated(uint256 newMin);
    event RebalanceEngineUpdated(address indexed engine);
    event DefaultTimeLockUpdated(uint256 newTimeLock);
    event DefaultRebalanceIntervalUpdated(uint256 newInterval);

    error InsufficientCreationFee();
    error InsufficientSeedDeposit();
    error TokenNotApproved();
    error InvalidWeights();
    error DuplicateToken();

    constructor(
        address _baseAsset,
        address _feeManager,
        address _registry,
        address _rebalanceEngine,
        address _tokenRouter
    ) Ownable(msg.sender) {
        require(_baseAsset != address(0), "UVF: zero base asset");
        require(_feeManager != address(0), "UVF: zero fee manager");
        require(_registry != address(0), "UVF: zero registry");
        require(_rebalanceEngine != address(0), "UVF: zero engine");
        require(_tokenRouter != address(0), "UVF: zero router");
        baseAsset = _baseAsset;
        feeManager = FeeManager(payable(_feeManager));
        registry = VaultRegistry(_registry);
        rebalanceEngine = _rebalanceEngine;
        tokenRouter = _tokenRouter;
        vaultCreationFee = 0.01 ether;
        minSeedDeposit = 100e6;
        defaultTimeLock = 24 hours;
        defaultMinRebalanceInterval = 4 hours;

        UserVault impl = new UserVault();
        beacon = new UpgradeableBeacon(address(impl), address(this));
    }

    function setApprovedToken(address token, bool approved) external onlyOwner {
        approvedTokens[token] = approved;
        if (approved) {
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

    function createUserVault(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint16[] calldata weights,
        uint16 curatorFeeBps,
        uint256 seedDeposit,
        string calldata metadataURI
    ) external payable returns (address vault) {
        return _createVault(name, symbol, tokens, weights, 0, 0, curatorFeeBps, seedDeposit, metadataURI);
    }

    function createUserVaultWithFees(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint16[] calldata weights,
        uint16 managementFeeBps,
        uint16 performanceFeeBps,
        uint16 curatorFeeBps,
        uint256 seedDeposit,
        string calldata metadataURI
    ) external payable returns (address vault) {
        return _createVault(name, symbol, tokens, weights, managementFeeBps, performanceFeeBps, curatorFeeBps, seedDeposit, metadataURI);
    }

    function _createVault(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint16[] calldata weights,
        uint16 managementFeeBps,
        uint16 performanceFeeBps,
        uint16 curatorFeeBps,
        uint256 seedDeposit,
        string calldata metadataURI
    ) internal returns (address vault) {
        if (msg.value < vaultCreationFee) revert InsufficientCreationFee();
        if (seedDeposit < minSeedDeposit) revert InsufficientSeedDeposit();

        require(tokens.length == weights.length, "UVF: length mismatch");
        require(tokens.length > 0, "UVF: empty portfolio");

        uint256 totalBps = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!approvedTokens[tokens[i]]) revert TokenNotApproved();
            for (uint256 j = i + 1; j < tokens.length; j++) {
                if (tokens[i] == tokens[j]) revert DuplicateToken();
            }
            totalBps += weights[i];
        }
        if (totalBps == 0 || totalBps > 10000) revert InvalidWeights();

        require(
            curatorFeeBps <= 10000 - feeManager.MIN_PROTOCOL_SHARE_BPS(), "UVF: curator fee too high"
        );

        IBaseVault.TokenWeight[] memory initialWeights = new IBaseVault.TokenWeight[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            initialWeights[i] = IBaseVault.TokenWeight({token: tokens[i], weightBps: weights[i]});
        }

        bytes memory initData = abi.encodeCall(
            UserVault.initialize,
            (name, symbol, baseAsset, address(feeManager),
             rebalanceEngine, tokenRouter, msg.sender,
             approvedTokenList, defaultTimeLock, defaultMinRebalanceInterval,
             initialWeights)
        );

        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        vault = address(proxy);

        allVaults.push(vault);
        isVault[vault] = true;

        if (managementFeeBps > 0 || performanceFeeBps > 0) {
            feeManager.configureVaultFeesWithRates(vault, managementFeeBps, performanceFeeBps, curatorFeeBps, msg.sender);
        } else {
            feeManager.configureVaultFees(vault, curatorFeeBps, msg.sender);
        }
        registry.registerVault(vault, VaultRegistry.VaultType.USER, msg.sender, metadataURI);
        RebalanceEngine(rebalanceEngine).setVaultAuthorized(vault, true);

        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), seedDeposit);
        IERC20(baseAsset).forceApprove(vault, seedDeposit);
        UserVault(vault).deposit(DEAD_SHARE_AMOUNT, address(1));
        UserVault(vault).deposit(seedDeposit - DEAD_SHARE_AMOUNT, msg.sender);
        IERC20(baseAsset).forceApprove(vault, 0);

        if (vaultCreationFee > 0) {
            (bool success,) = feeManager.protocolTreasury().call{value: vaultCreationFee}("");
            require(success, "UVF: fee transfer failed");
        }

        uint256 excess = msg.value - vaultCreationFee;
        if (excess > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, "UVF: ETH refund failed");
        }

        emit UserVaultCreated(vault, msg.sender, name, symbol);
    }

    function upgradeImplementation(address newImplementation) external onlyOwner {
        beacon.upgradeTo(newImplementation);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }

    function setCreationFee(uint256 _fee) external onlyOwner {
        vaultCreationFee = _fee;
        emit CreationFeeUpdated(_fee);
    }

    function setMinSeedDeposit(uint256 _min) external onlyOwner {
        minSeedDeposit = _min;
        emit MinSeedDepositUpdated(_min);
    }

    function setRebalanceEngine(address _engine) external onlyOwner {
        rebalanceEngine = _engine;
        emit RebalanceEngineUpdated(_engine);
    }

    function setDefaultTimeLock(uint256 _timeLock) external onlyOwner {
        defaultTimeLock = _timeLock;
        emit DefaultTimeLockUpdated(_timeLock);
    }

    function setDefaultMinRebalanceInterval(uint256 _interval) external onlyOwner {
        defaultMinRebalanceInterval = _interval;
        emit DefaultRebalanceIntervalUpdated(_interval);
    }

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
