// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title VaultRegistry
/// @notice On-chain registry for vault discovery, curator profiles, and metrics
contract VaultRegistry is Ownable {
    enum VaultType {
        POLITICIAN,
        USER
    }

    struct VaultInfo {
        address vault;
        VaultType vaultType;
        address curator; // address(0) for politician vaults
        string metadataURI; // IPFS URI for description, avatar, etc.
        uint256 createdAt;
        bool active;
    }

    struct CuratorProfile {
        string metadataURI; // IPFS URI for bio, links, avatar
        uint256 totalVaults;
        bool registered;
    }

    // --- Storage ---
    VaultInfo[] public allVaults;
    mapping(address => uint256) public vaultIndex; // vault address => index in allVaults
    mapping(address => bool) public isRegistered;

    // Indexes for discovery
    mapping(VaultType => address[]) public vaultsByType;
    mapping(address => address[]) public vaultsByCurator;

    // Curator profiles
    mapping(address => CuratorProfile) public curatorProfiles;

    // Authorized registrars (VaultFactory)
    mapping(address => bool) public authorizedRegistrars;

    // --- Events ---
    event VaultRegistered(address indexed vault, VaultType vaultType, address indexed curator);
    event VaultDeactivated(address indexed vault);
    event VaultMetadataUpdated(address indexed vault, string metadataURI);
    event CuratorProfileUpdated(address indexed curator, string metadataURI);
    event RegistrarUpdated(address indexed registrar, bool authorized);

    // --- Errors ---
    error AlreadyRegistered();
    error NotRegistered();
    error UnauthorizedRegistrar();
    error NotCurator();

    constructor() Ownable(msg.sender) {}

    // ===================== Admin =====================

    function setRegistrar(address registrar, bool authorized) external onlyOwner {
        authorizedRegistrars[registrar] = authorized;
        emit RegistrarUpdated(registrar, authorized);
    }

    // ===================== Registration =====================

    /// @notice Register a new vault (called by VaultFactory)
    function registerVault(
        address vault,
        VaultType vaultType,
        address curator,
        string calldata metadataURI
    ) external {
        if (!authorizedRegistrars[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedRegistrar();
        }
        if (isRegistered[vault]) revert AlreadyRegistered();

        VaultInfo memory info = VaultInfo({
            vault: vault,
            vaultType: vaultType,
            curator: curator,
            metadataURI: metadataURI,
            createdAt: block.timestamp,
            active: true
        });

        vaultIndex[vault] = allVaults.length;
        allVaults.push(info);
        isRegistered[vault] = true;

        vaultsByType[vaultType].push(vault);

        if (curator != address(0)) {
            vaultsByCurator[curator].push(vault);
            if (!curatorProfiles[curator].registered) {
                curatorProfiles[curator] = CuratorProfile({
                    metadataURI: "",
                    totalVaults: 0,
                    registered: true
                });
            }
            curatorProfiles[curator].totalVaults++;
        }

        emit VaultRegistered(vault, vaultType, curator);
    }

    /// @notice Deactivate a vault
    function deactivateVault(address vault) external onlyOwner {
        if (!isRegistered[vault]) revert NotRegistered();
        allVaults[vaultIndex[vault]].active = false;
        emit VaultDeactivated(vault);
    }

    /// @notice Update vault metadata (callable by curator or owner)
    function updateVaultMetadata(address vault, string calldata metadataURI) external {
        if (!isRegistered[vault]) revert NotRegistered();
        VaultInfo storage info = allVaults[vaultIndex[vault]];
        if (msg.sender != info.curator && msg.sender != owner()) revert NotCurator();
        info.metadataURI = metadataURI;
        emit VaultMetadataUpdated(vault, metadataURI);
    }

    // ===================== Curator Profiles =====================

    /// @notice Update curator profile metadata
    function updateCuratorProfile(string calldata metadataURI) external {
        if (!curatorProfiles[msg.sender].registered) revert NotCurator();
        curatorProfiles[msg.sender].metadataURI = metadataURI;
        emit CuratorProfileUpdated(msg.sender, metadataURI);
    }

    // ===================== Views =====================

    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        require(isRegistered[vault], "VaultRegistry: not registered");
        return allVaults[vaultIndex[vault]];
    }

    function getVaultsByType(VaultType vaultType) external view returns (address[] memory) {
        return vaultsByType[vaultType];
    }

    function getVaultsByCurator(address curator) external view returns (address[] memory) {
        return vaultsByCurator[curator];
    }

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    function totalVaultsByType(VaultType vaultType) external view returns (uint256) {
        return vaultsByType[vaultType].length;
    }

    function getCuratorProfile(address curator) external view returns (CuratorProfile memory) {
        return curatorProfiles[curator];
    }

    function getAllVaults() external view returns (VaultInfo[] memory) {
        return allVaults;
    }
}
