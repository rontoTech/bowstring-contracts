// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {StockTokenUpgradeable} from "./StockTokenUpgradeable.sol";

/// @title StockTokenFactoryUpgradeable
/// @notice UUPS-proxied factory that deploys stock tokens as beacon proxies.
///         Owns an UpgradeableBeacon — upgrading the beacon upgrades ALL tokens at once.
///         Auto-authorizes the token router as a minter on each new token.
contract StockTokenFactoryUpgradeable is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    struct StockTokenInfo {
        address token;
        string name;
        string symbol;
        uint256 initialPrice;
    }

    UpgradeableBeacon public beacon;
    StockTokenInfo[] public deployedTokens;
    mapping(string => address) public tokenBySymbol;
    address public tokenRouter;
    mapping(address => bool) public authorizedDeployers;

    event StockTokenCreated(address indexed token, string name, string symbol);
    event TokenRouterUpdated(address indexed router);
    event BeaconUpgraded(address indexed newImplementation);
    event DeployerAuthorized(address indexed deployer, bool authorized);

    error UnauthorizedDeployer();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address stockTokenImpl_) external initializer {
        __Ownable_init(owner_);
        beacon = new UpgradeableBeacon(stockTokenImpl_, address(this));
    }

    // ===================== Access helpers =====================

    modifier onlyOwnerOrDeployer() {
        if (msg.sender != owner() && !authorizedDeployers[msg.sender]) revert UnauthorizedDeployer();
        _;
    }

    // ===================== Admin =====================

    function setAuthorizedDeployer(address deployer, bool authorized) external onlyOwner {
        authorizedDeployers[deployer] = authorized;
        emit DeployerAuthorized(deployer, authorized);
    }

    function setTokenRouter(address _router) external onlyOwner {
        tokenRouter = _router;
        emit TokenRouterUpdated(_router);
    }

    function upgradeTokenImplementation(address newImpl) external onlyOwner {
        beacon.upgradeTo(newImpl);
        emit BeaconUpgraded(newImpl);
    }

    // ===================== Token Creation (owner or authorized deployer) =====================

    function createStockToken(
        string calldata name_,
        string calldata symbol_,
        uint256 initialPrice
    ) external onlyOwnerOrDeployer returns (address token) {
        bytes memory initData = abi.encodeCall(
            StockTokenUpgradeable.initialize,
            (name_, symbol_, 18, address(this))
        );
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        token = address(proxy);

        if (tokenRouter != address(0)) {
            StockTokenUpgradeable(token).addMinter(tokenRouter);
        }

        deployedTokens.push(StockTokenInfo({
            token: token,
            name: name_,
            symbol: symbol_,
            initialPrice: initialPrice
        }));
        tokenBySymbol[symbol_] = token;

        emit StockTokenCreated(token, name_, symbol_);
    }

    // ===================== Minter Management =====================

    function authorizeRouterOnToken(address token) external onlyOwner {
        require(tokenRouter != address(0), "StockTokenFactory: no router");
        StockTokenUpgradeable(token).addMinter(tokenRouter);
    }

    function authorizeRouterOnAllTokens() external onlyOwner {
        require(tokenRouter != address(0), "StockTokenFactory: no router");
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            StockTokenUpgradeable(deployedTokens[i].token).addMinter(tokenRouter);
        }
    }

    function mintToken(string calldata symbol, address to, uint256 amount) external onlyOwnerOrDeployer {
        address token = tokenBySymbol[symbol];
        require(token != address(0), "StockTokenFactory: token not found");
        StockTokenUpgradeable(token).mint(to, amount);
    }

    // ===================== Views =====================

    function getDeployedTokens() external view returns (StockTokenInfo[] memory) {
        return deployedTokens;
    }

    function totalTokens() external view returns (uint256) {
        return deployedTokens.length;
    }

    // ===================== UUPS =====================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[45] private __gap;
}
