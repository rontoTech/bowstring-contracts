// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title VaultRegistryUpgradeable
/// @notice UUPS-proxied on-chain registry for vault discovery, curator profiles, and metrics.
contract VaultRegistryUpgradeable is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    enum VaultType {
        POLITICIAN,
        USER
    }

    struct VaultInfo {
        address vault;
        VaultType vaultType;
        address curator;
        string metadataURI;
        uint256 createdAt;
        bool active;
    }

    struct CuratorProfile {
        string metadataURI;
        uint256 totalVaults;
        bool registered;
    }

    VaultInfo[] public allVaults;
    mapping(address => uint256) public vaultIndex;
    mapping(address => bool) public isRegistered;

    mapping(VaultType => address[]) public vaultsByType;
    mapping(address => address[]) public vaultsByCurator;
    mapping(address => CuratorProfile) public curatorProfiles;
    mapping(address => bool) public authorizedRegistrars;

    event VaultRegistered(address indexed vault, VaultType vaultType, address indexed curator);
    event VaultDeactivated(address indexed vault);
    event VaultMetadataUpdated(address indexed vault, string metadataURI);
    event CuratorProfileUpdated(address indexed curator, string metadataURI);
    event RegistrarUpdated(address indexed registrar, bool authorized);

    error AlreadyRegistered();
    error NotRegistered();
    error UnauthorizedRegistrar();
    error NotCurator();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    // ===================== Admin =====================

    function setRegistrar(address registrar, bool authorized) external onlyOwner {
        authorizedRegistrars[registrar] = authorized;
        emit RegistrarUpdated(registrar, authorized);
    }

    // ===================== Registration =====================

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
                curatorProfiles[curator] = CuratorProfile({metadataURI: "", totalVaults: 0, registered: true});
            }
            curatorProfiles[curator].totalVaults++;
        }

        emit VaultRegistered(vault, vaultType, curator);
    }

    /// @notice Bulk-register vaults during migration (owner-only).
    function bulkRegister(VaultInfo[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            VaultInfo calldata v = vaults[i];
            if (isRegistered[v.vault]) continue;

            vaultIndex[v.vault] = allVaults.length;
            allVaults.push(v);
            isRegistered[v.vault] = true;
            vaultsByType[v.vaultType].push(v.vault);

            if (v.curator != address(0)) {
                vaultsByCurator[v.curator].push(v.vault);
                if (!curatorProfiles[v.curator].registered) {
                    curatorProfiles[v.curator] = CuratorProfile({metadataURI: "", totalVaults: 0, registered: true});
                }
                curatorProfiles[v.curator].totalVaults++;
            }
        }
    }

    function deactivateVault(address vault) external onlyOwner {
        if (!isRegistered[vault]) revert NotRegistered();
        allVaults[vaultIndex[vault]].active = false;
        emit VaultDeactivated(vault);
    }

    function updateVaultMetadata(address vault, string calldata metadataURI) external {
        if (!isRegistered[vault]) revert NotRegistered();
        VaultInfo storage info = allVaults[vaultIndex[vault]];
        if (msg.sender != info.curator && msg.sender != owner()) revert NotCurator();
        info.metadataURI = metadataURI;
        emit VaultMetadataUpdated(vault, metadataURI);
    }

    // ===================== Curator Profiles =====================

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

    // ===================== UUPS =====================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[43] private __gap;
}
