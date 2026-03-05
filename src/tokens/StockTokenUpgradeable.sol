// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title StockTokenUpgradeable
/// @notice Beacon-proxied ERC-20 representing a tokenized stock.
///         Owner and authorized minters can mint/burn (enables mint-burn router).
///         All instances share a single implementation via UpgradeableBeacon.
contract StockTokenUpgradeable is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    uint8 private _tokenDecimals;
    mapping(address => bool) public minters;

    error NotMinter();

    modifier onlyMinter() {
        if (msg.sender != owner() && !minters[msg.sender]) revert NotMinter();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
    }

    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    uint256[48] private __gap;
}
