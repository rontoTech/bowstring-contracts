// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeManager
/// @notice Centralized fee configuration and collection with protocol/curator splits.
///         Entry/exit fees are collected in the base asset (ERC-20).
///         Management/performance fees are collected via share dilution in BaseVault
///         and minted directly to protocol treasury and curator addresses.
contract FeeManager is Ownable {
    using SafeERC20 for IERC20;

    // --- Constants ---
    uint16 public constant MAX_ENTRY_FEE_BPS = 100; // 1%
    uint16 public constant MAX_EXIT_FEE_BPS = 200; // 2%
    uint16 public constant MAX_MANAGEMENT_FEE_BPS = 200; // 2%
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 3000; // 30%
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2000; // 20% minimum protocol cut
    uint16 public constant BPS_DENOMINATOR = 10000;

    // --- Default fee schedule ---
    uint16 public defaultEntryFeeBps = 30; // 0.3%
    uint16 public defaultExitFeeBps = 50; // 0.5%
    uint16 public defaultManagementFeeBps = 50; // 0.5%
    uint16 public defaultPerformanceFeeBps = 1500; // 15%

    // --- Protocol fee recipient ---
    address public protocolTreasury;

    // --- Base asset for fee collection (ERC-20) ---
    IERC20 public baseAsset;

    // --- Per-vault fee overrides ---
    struct VaultFeeConfig {
        uint16 entryFeeBps;
        uint16 exitFeeBps;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        uint16 curatorShareBps; // curator's share of management + performance fees
        address curator;
        bool isConfigured;
    }

    mapping(address => VaultFeeConfig) public vaultFees;

    // --- Accumulated fees (base asset amounts from entry/exit fees) ---
    mapping(address => uint256) public accumulatedProtocolFees;
    mapping(address => uint256) public accumulatedCuratorFees; // curator address => fees

    // --- Authorized callers (factories, admin scripts) ---
    mapping(address => bool) public authorizedCallers;

    // --- Events ---
    event DefaultFeesUpdated(uint16 entryBps, uint16 exitBps, uint16 mgmtBps, uint16 perfBps);
    event VaultFeeConfigured(address indexed vault, VaultFeeConfig config);
    event FeesAccumulated(address indexed vault, uint256 protocolAmount, uint256 curatorAmount);
    event ProtocolFeesCollected(address indexed recipient, uint256 amount);
    event CuratorFeesCollected(address indexed curator, uint256 amount);
    event TreasuryUpdated(address indexed newTreasury);
    event BaseAssetUpdated(address indexed newBaseAsset);
    event CallerAuthorized(address indexed caller, bool authorized);

    constructor(address _treasury, address _baseAsset) Ownable(msg.sender) {
        require(_treasury != address(0), "FeeManager: zero treasury");
        require(_baseAsset != address(0), "FeeManager: zero base asset");
        protocolTreasury = _treasury;
        baseAsset = IERC20(_baseAsset);
    }

    // --- Admin functions ---

    modifier onlyAuthorized() {
        require(msg.sender == owner() || authorizedCallers[msg.sender], "FeeManager: not authorized");
        _;
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit CallerAuthorized(caller, authorized);
    }

    function setDefaultFees(uint16 _entryBps, uint16 _exitBps, uint16 _mgmtBps, uint16 _perfBps) external onlyOwner {
        require(_entryBps <= MAX_ENTRY_FEE_BPS, "FeeManager: entry fee too high");
        require(_exitBps <= MAX_EXIT_FEE_BPS, "FeeManager: exit fee too high");
        require(_mgmtBps <= MAX_MANAGEMENT_FEE_BPS, "FeeManager: mgmt fee too high");
        require(_perfBps <= MAX_PERFORMANCE_FEE_BPS, "FeeManager: perf fee too high");

        defaultEntryFeeBps = _entryBps;
        defaultExitFeeBps = _exitBps;
        defaultManagementFeeBps = _mgmtBps;
        defaultPerformanceFeeBps = _perfBps;

        emit DefaultFeesUpdated(_entryBps, _exitBps, _mgmtBps, _perfBps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "FeeManager: zero treasury");
        // Migrate accumulated fees to new treasury
        uint256 pending = accumulatedProtocolFees[protocolTreasury];
        if (pending > 0) {
            accumulatedProtocolFees[protocolTreasury] = 0;
            accumulatedProtocolFees[_treasury] = pending;
        }
        protocolTreasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setBaseAsset(address _baseAsset) external onlyOwner {
        require(_baseAsset != address(0), "FeeManager: zero base asset");
        baseAsset = IERC20(_baseAsset);
        emit BaseAssetUpdated(_baseAsset);
    }

    /// @notice Configure fees for a specific vault (called by VaultFactory on creation)
    function configureVaultFees(address vault, uint16 curatorShareBps, address curator) external onlyAuthorized {
        require(
            curatorShareBps <= BPS_DENOMINATOR - MIN_PROTOCOL_SHARE_BPS, "FeeManager: curator share too high"
        );

        vaultFees[vault] = VaultFeeConfig({
            entryFeeBps: defaultEntryFeeBps,
            exitFeeBps: defaultExitFeeBps,
            managementFeeBps: defaultManagementFeeBps,
            performanceFeeBps: defaultPerformanceFeeBps,
            curatorShareBps: curatorShareBps,
            curator: curator,
            isConfigured: true
        });

        emit VaultFeeConfigured(vault, vaultFees[vault]);
    }

    // --- Fee calculation ---

    function getEntryFee(address vault) external view returns (uint16) {
        if (vaultFees[vault].isConfigured) return vaultFees[vault].entryFeeBps;
        return defaultEntryFeeBps;
    }

    function getExitFee(address vault) external view returns (uint16) {
        if (vaultFees[vault].isConfigured) return vaultFees[vault].exitFeeBps;
        return defaultExitFeeBps;
    }

    function getManagementFee(address vault) external view returns (uint16) {
        if (vaultFees[vault].isConfigured) return vaultFees[vault].managementFeeBps;
        return defaultManagementFeeBps;
    }

    function getPerformanceFee(address vault) external view returns (uint16) {
        if (vaultFees[vault].isConfigured) return vaultFees[vault].performanceFeeBps;
        return defaultPerformanceFeeBps;
    }

    /// @notice Record entry/exit fees from a vault, splitting between protocol and curator.
    ///         The vault must have already transferred the base asset to this contract.
    function recordFees(uint256 totalFeeAmount) external {
        require(vaultFees[msg.sender].isConfigured, "FeeManager: caller not a configured vault");
        address vault = msg.sender;
        VaultFeeConfig memory config = vaultFees[vault];

        uint256 curatorAmount = 0;
        uint256 protocolAmount = totalFeeAmount;

        if (config.isConfigured && config.curator != address(0) && config.curatorShareBps > 0) {
            curatorAmount = (totalFeeAmount * config.curatorShareBps) / BPS_DENOMINATOR;
            protocolAmount = totalFeeAmount - curatorAmount;
            accumulatedCuratorFees[config.curator] += curatorAmount;
        }

        accumulatedProtocolFees[protocolTreasury] += protocolAmount;

        emit FeesAccumulated(vault, protocolAmount, curatorAmount);
    }

    /// @notice Collect accumulated protocol fees via ERC-20 transfer
    function collectProtocolFees() external {
        uint256 amount = accumulatedProtocolFees[protocolTreasury];
        require(amount > 0, "FeeManager: no fees to collect");
        accumulatedProtocolFees[protocolTreasury] = 0;

        baseAsset.safeTransfer(protocolTreasury, amount);

        emit ProtocolFeesCollected(protocolTreasury, amount);
    }

    /// @notice Curator collects their accumulated fees via ERC-20 transfer
    function collectCuratorFees() external {
        uint256 amount = accumulatedCuratorFees[msg.sender];
        require(amount > 0, "FeeManager: no fees to collect");
        accumulatedCuratorFees[msg.sender] = 0;

        baseAsset.safeTransfer(msg.sender, amount);

        emit CuratorFeesCollected(msg.sender, amount);
    }

    /// @notice Emergency rescue for any ERC-20 accidentally sent to this contract
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "FeeManager: zero address");
        // Prevent draining accumulated base asset fees
        if (token == address(baseAsset)) {
            uint256 reservedFees = accumulatedProtocolFees[protocolTreasury];
            uint256 contractBalance = baseAsset.balanceOf(address(this));
            require(amount <= contractBalance - reservedFees, "FeeManager: would drain reserved fees");
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Get full fee config for a vault
    function getVaultFeeConfig(address vault) external view returns (VaultFeeConfig memory) {
        if (vaultFees[vault].isConfigured) return vaultFees[vault];
        return VaultFeeConfig({
            entryFeeBps: defaultEntryFeeBps,
            exitFeeBps: defaultExitFeeBps,
            managementFeeBps: defaultManagementFeeBps,
            performanceFeeBps: defaultPerformanceFeeBps,
            curatorShareBps: 0,
            curator: address(0),
            isConfigured: false
        });
    }

    /// @notice Rescue ETH accidentally sent to this contract
    function rescueEth(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "FeeManager: zero address");
        (bool success,) = to.call{value: amount}("");
        require(success, "FeeManager: ETH transfer failed");
    }

    receive() external payable {}
}
