// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {UserVault} from "./UserVault.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {FeeManager} from "./FeeManager.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RebalanceEngine} from "../rebalance/RebalanceEngine.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @title UserVaultFactoryV2
/// @notice Permissionless factory for creating UserVaults.
///         Prevents duplicate strategy creation per curator and auto-delegates to the TradeDelegateProxy.
contract UserVaultFactoryV2 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
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

    // V2 additions
    mapping(address => mapping(string => bool)) public hasCreatedSymbol;
    address public tradeDelegateProxy;
    mapping(string => bool) public symbolExists;

    event UserVaultCreated(address indexed vault, address indexed curator, string name, string symbol);
    event TokenApprovalUpdated(address indexed token, bool approved);
    event CreationFeeUpdated(uint256 newFee);
    event MinSeedDepositUpdated(uint256 newMin);
    event RebalanceEngineUpdated(address indexed engine);
    event DefaultTimeLockUpdated(uint256 newTimeLock);
    event DefaultRebalanceIntervalUpdated(uint256 newInterval);
    event TradeDelegateProxyUpdated(address indexed proxy);
    event FeeManagerUpdated(address indexed newFeeManager);
    event RegistryUpdated(address indexed newRegistry);
    event TokenRouterUpdated(address indexed newRouter);

    error InsufficientCreationFee();
    error InsufficientSeedDeposit();
    error TokenNotApproved();
    error InvalidWeights();
    error DuplicateToken();
    error DuplicateSymbol();
    /// @notice The rebalance engine is configured with a different token router
    ///         than this factory. Allowing vault creation in that state would
    ///         silently produce vaults whose `allocateIdleAssets()` /
    ///         `executeRebalance()` always revert with `UnsupportedPair()` because
    ///         the swap path goes through the engine's router, not the vault's.
    error RouterDrift();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _beacon,
        address _baseAsset,
        address _feeManager,
        address _registry,
        address _rebalanceEngine,
        address _tokenRouter,
        address _tradeDelegateProxy
    ) external initializer {
        __Ownable_init(msg.sender);

        require(_beacon != address(0), "UVF2: zero beacon");
        require(_baseAsset != address(0), "UVF2: zero base asset");
        require(_feeManager != address(0), "UVF2: zero fee manager");
        require(_registry != address(0), "UVF2: zero registry");
        require(_rebalanceEngine != address(0), "UVF2: zero engine");
        require(_tokenRouter != address(0), "UVF2: zero router");
        
        beacon = UpgradeableBeacon(_beacon);
        baseAsset = _baseAsset;
        feeManager = FeeManager(payable(_feeManager));
        registry = VaultRegistry(_registry);
        rebalanceEngine = _rebalanceEngine;
        tokenRouter = _tokenRouter;
        tradeDelegateProxy = _tradeDelegateProxy;
        
        vaultCreationFee = 0;
        minSeedDeposit = 100e6;
        defaultTimeLock = 24 hours;
        defaultMinRebalanceInterval = 4 hours;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function upgradeImplementation(address newImplementation) external onlyOwner {
        beacon.upgradeTo(newImplementation);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }

    function setTradeDelegateProxy(address _proxy) external onlyOwner {
        tradeDelegateProxy = _proxy;
        emit TradeDelegateProxyUpdated(_proxy);
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
        if (symbolExists[symbol]) revert DuplicateSymbol();

        // Structural safety: the rebalance engine executes all swaps through
        // its own token router, not the one we pass to the vault. If they ever
        // diverge, every vault created here would be born broken — idle USDC
        // can never be allocated because the engine's router doesn't know
        // about the vault's pairs. Fail loudly at creation time instead.
        if (address(RebalanceEngine(rebalanceEngine).tokenRouter()) != tokenRouter) {
            revert RouterDrift();
        }

        require(tokens.length == weights.length, "UVF2: length mismatch");
        require(tokens.length > 0, "UVF2: empty portfolio");

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
            curatorFeeBps <= 10000 - feeManager.MIN_PROTOCOL_SHARE_BPS(), "UVF2: curator fee too high"
        );

        IBaseVault.TokenWeight[] memory initialWeights = new IBaseVault.TokenWeight[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            initialWeights[i] = IBaseVault.TokenWeight({token: tokens[i], weightBps: weights[i]});
        }

        // Initialize with this factory as the curator so we can set the delegate
        bytes memory initData = abi.encodeCall(
            UserVault.initialize,
            (name, symbol, baseAsset, address(feeManager),
             rebalanceEngine, tokenRouter, address(this),
             approvedTokenList, defaultTimeLock, defaultMinRebalanceInterval,
             initialWeights)
        );

        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        vault = address(proxy);

        // Auto-delegate to proxy if configured
        if (tradeDelegateProxy != address(0)) {
            UserVault(vault).setDelegate(tradeDelegateProxy, true);
        }
        
        // Transfer curator role back to the actual creator
        UserVault(vault).transferCurator(msg.sender);

        hasCreatedSymbol[msg.sender][symbol] = true;
        symbolExists[symbol] = true;
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
            require(success, "UVF2: fee transfer failed");
        }

        uint256 excess = msg.value - vaultCreationFee;
        if (excess > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, "UVF2: ETH refund failed");
        }

        emit UserVaultCreated(vault, msg.sender, name, symbol);
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

    /// @notice Repoint the factory at a new FeeManager (e.g. after a
    ///         non-upgradeable FeeManager had to be replaced). New vaults
    ///         created after this call will be configured on the new
    ///         FeeManager. Existing vaults keep pointing at whichever
    ///         FeeManager they were initialised with until their owner calls
    ///         `UserVault.setFeeManager` directly.
    function setFeeManager(address _feeManager) external onlyOwner {
        require(_feeManager != address(0), "UVF2: zero fee manager");
        feeManager = FeeManager(payable(_feeManager));
        emit FeeManagerUpdated(_feeManager);
    }

    /// @notice Repoint the factory at a new VaultRegistry. Mirrors
    ///         `setFeeManager` — useful when an existing registry has to be
    ///         replaced (e.g. migration from non-upgradeable to upgradeable).
    function setRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "UVF2: zero registry");
        registry = VaultRegistry(_registry);
        emit RegistryUpdated(_registry);
    }

    /// @notice Update the token router address used when initialising new
    ///         vaults. Existing vaults continue to use their own router.
    ///         Note: this only updates the factory's copy. For vault creation
    ///         to keep working the RebalanceEngine must also point at
    ///         `_router` (see `RouterDrift`). If the engine's owner is this
    ///         factory, call `syncRebalanceEngineRouter()` to propagate;
    ///         otherwise the engine's owner must call `setRouter` separately.
    function setTokenRouter(address _router) external onlyOwner {
        require(_router != address(0), "UVF2: zero router");
        tokenRouter = _router;
        emit TokenRouterUpdated(_router);
    }

    /// @notice Best-effort one-call heal: push the factory's current
    ///         `tokenRouter` into the `RebalanceEngine` so the two can never
    ///         drift. Only usable when this factory owns the engine — that
    ///         keeps access control clean. Reverts with the engine's own
    ///         error (`OwnableUnauthorizedAccount`) otherwise, which is the
    ///         signal to run the ops migration path instead.
    function syncRebalanceEngineRouter() external onlyOwner {
        RebalanceEngine(rebalanceEngine).setRouter(tokenRouter);
    }

    /// @notice View helper: true iff the engine's router matches the
    ///         factory's router (i.e. vault creation will succeed).
    function isRouterAligned() external view returns (bool) {
        return address(RebalanceEngine(rebalanceEngine).tokenRouter()) == tokenRouter;
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