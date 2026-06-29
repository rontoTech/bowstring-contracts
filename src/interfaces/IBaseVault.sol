// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IBaseVault
/// @notice Interface for the base vault shared by PoliticianVault and UserVault
interface IBaseVault is IERC4626 {
    /// @notice Token weight in basis points (100 = 1%)
    struct TokenWeight {
        address token;
        uint16 weightBps; // basis points, 10000 = 100%
    }

    /// @notice Vault configuration
    struct VaultConfig {
        uint16 entryFeeBps;
        uint16 exitFeeBps;
        uint16 managementFeeBps; // annualized
        uint16 performanceFeeBps;
        uint256 rebalanceThresholdBps; // kept for ABI compatibility
    }

    event FeesAccrued(uint256 managementFee, uint256 performanceFee);
    event FeesCollected(address indexed recipient, uint256 amount);

    /// @notice Allocate idle base assets into the portfolio proportionally.
    ///         Open to anyone — depositors can immediately put funds to work.
    function allocateIdleAssets() external;

    /// @notice Get the current target weights for the vault
    function getTargetWeights() external view returns (TokenWeight[] memory);

    /// @notice Get the current actual weights of the vault holdings
    function getCurrentWeights() external view returns (TokenWeight[] memory);

    /// @notice Get the vault configuration
    function getVaultConfig() external view returns (VaultConfig memory);

    /// @notice Get accrued but uncollected fees
    function accruedFees() external view returns (uint256);

    /// @notice Materialize pending management/performance fee shares.
    function accrueFees() external returns (uint256 feeShares);
}
