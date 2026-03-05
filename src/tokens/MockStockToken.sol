// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockStockToken
/// @notice Mock ERC-20 representing a tokenized stock for testnet.
///         Owner and authorized minters can mint/burn (enables mint-burn router).
contract MockStockToken is ERC20, Ownable {
    uint8 private _decimals;
    mapping(address => bool) public minters;

    error NotMinter();

    modifier onlyMinter() {
        if (msg.sender != owner() && !minters[msg.sender]) revert NotMinter();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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
}

/// @title TiltUSDC
/// @notice Tilt Protocol testnet USDC (6 decimals) with EIP-2612 permit support.
///         Includes public faucet and authorized minters for the mint-burn router.
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract TiltUSDC is ERC20, ERC20Permit, Ownable {
    uint256 public constant FAUCET_AMOUNT = 10_000e6;
    uint256 public constant FAUCET_COOLDOWN = 24 hours;

    mapping(address => uint256) public lastFaucetClaim;
    mapping(address => bool) public minters;

    event FaucetClaimed(address indexed user, uint256 amount);

    error NotMinter();

    modifier onlyMinter() {
        if (msg.sender != owner() && !minters[msg.sender]) revert NotMinter();
        _;
    }

    constructor() ERC20("Tilt USDC", "tiltUSDC") ERC20Permit("Tilt USDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function nonces(address owner) public view override(ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
    }

    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
    }

    /// @notice Public faucet - anyone can claim 10,000 tiltUSDC every 24 hours
    function faucet() external {
        require(
            lastFaucetClaim[msg.sender] == 0
                || block.timestamp >= lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN,
            "TiltUSDC: faucet cooldown active"
        );
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}

/// @title MockStockTokenFactory
/// @notice Factory for creating tilt-branded stock tokens on testnet.
///         Auto-authorizes the token router as a minter on each new token.
contract MockStockTokenFactory is Ownable {
    struct StockTokenInfo {
        address token;
        string name;
        string symbol;
        uint256 initialPrice;
    }

    StockTokenInfo[] public deployedTokens;
    mapping(string => address) public tokenBySymbol;

    address public tokenRouter;

    event StockTokenCreated(address indexed token, string name, string symbol);
    event TokenRouterUpdated(address indexed router);

    constructor() Ownable(msg.sender) {}

    function setTokenRouter(address _router) external onlyOwner {
        tokenRouter = _router;
        emit TokenRouterUpdated(_router);
    }

    /// @notice Authorize router as minter on an existing token owned by this factory
    function authorizeRouterOnToken(address token) external onlyOwner {
        require(tokenRouter != address(0), "MockStockTokenFactory: no router");
        MockStockToken(token).addMinter(tokenRouter);
    }

    /// @notice Batch-authorize router on all deployed tokens
    function authorizeRouterOnAllTokens() external onlyOwner {
        require(tokenRouter != address(0), "MockStockTokenFactory: no router");
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            MockStockToken(deployedTokens[i].token).addMinter(tokenRouter);
        }
    }

    function createStockToken(string calldata name_, string calldata symbol_, uint256 initialPrice)
        external
        onlyOwner
        returns (address token)
    {
        MockStockToken newToken = new MockStockToken(name_, symbol_, 18);
        token = address(newToken);

        if (tokenRouter != address(0)) {
            newToken.addMinter(tokenRouter);
        }

        deployedTokens.push(StockTokenInfo({token: token, name: name_, symbol: symbol_, initialPrice: initialPrice}));
        tokenBySymbol[symbol_] = token;

        emit StockTokenCreated(token, name_, symbol_);
    }

    function deployStandardTokens() external onlyOwner {
        _createToken("Tilt Apple", "tiltAAPL", 195e18);
        _createToken("Tilt Microsoft", "tiltMSFT", 420e18);
        _createToken("Tilt NVIDIA", "tiltNVDA", 875e18);
        _createToken("Tilt Tesla", "tiltTSLA", 250e18);
        _createToken("Tilt Amazon", "tiltAMZN", 185e18);
        _createToken("Tilt Alphabet", "tiltGOOGL", 165e18);
        _createToken("Tilt Meta", "tiltMETA", 500e18);
        _createToken("Tilt JPMorgan", "tiltJPM", 205e18);
        _createToken("Tilt Visa", "tiltV", 290e18);
        _createToken("Tilt J&J", "tiltJNJ", 160e18);
    }

    function mintToken(string calldata symbol, address to, uint256 amount) external onlyOwner {
        address token = tokenBySymbol[symbol];
        require(token != address(0), "MockStockTokenFactory: token not found");
        MockStockToken(token).mint(to, amount);
    }

    function mintAllTokens(address to, uint256 amount) external onlyOwner {
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            MockStockToken(deployedTokens[i].token).mint(to, amount);
        }
    }

    function _createToken(string memory name_, string memory symbol_, uint256 initialPrice) internal {
        MockStockToken newToken = new MockStockToken(name_, symbol_, 18);
        address token = address(newToken);

        if (tokenRouter != address(0)) {
            newToken.addMinter(tokenRouter);
        }

        deployedTokens.push(StockTokenInfo({token: token, name: name_, symbol: symbol_, initialPrice: initialPrice}));
        tokenBySymbol[symbol_] = token;

        emit StockTokenCreated(token, name_, symbol_);
    }

    function getDeployedTokens() external view returns (StockTokenInfo[] memory) {
        return deployedTokens;
    }

    function totalTokens() external view returns (uint256) {
        return deployedTokens.length;
    }
}
