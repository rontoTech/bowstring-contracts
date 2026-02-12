// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockStockToken
/// @notice Mock ERC-20 token representing a tokenized stock for testnet.
///         Mintable by owner (deployer/factory). 18 decimals.
contract MockStockToken is ERC20, Ownable {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

/// @title MockUSDC
/// @notice Mock USDC for testnet (6 decimals)
contract MockUSDC is ERC20, Ownable {
    constructor() ERC20("USD Coin", "USDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

/// @title MockStockTokenFactory
/// @notice Factory for creating mock stock tokens on testnet
contract MockStockTokenFactory is Ownable {
    struct StockTokenInfo {
        address token;
        string name;
        string symbol;
        uint256 initialPrice; // price in USD with 18 decimals
    }

    StockTokenInfo[] public deployedTokens;
    mapping(string => address) public tokenBySymbol;

    event StockTokenCreated(address indexed token, string name, string symbol);

    constructor() Ownable(msg.sender) {}

    /// @notice Deploy a single mock stock token
    function createStockToken(string calldata name_, string calldata symbol_, uint256 initialPrice)
        external
        onlyOwner
        returns (address token)
    {
        MockStockToken newToken = new MockStockToken(name_, symbol_, 18);
        token = address(newToken);

        deployedTokens.push(StockTokenInfo({
            token: token,
            name: name_,
            symbol: symbol_,
            initialPrice: initialPrice
        }));
        tokenBySymbol[symbol_] = token;

        emit StockTokenCreated(token, name_, symbol_);
    }

    /// @notice Deploy the standard set of stock tokens for testing
    function deployStandardTokens() external onlyOwner {
        _createToken("Apple Inc.", "AAPL", 195e18);
        _createToken("Microsoft Corp.", "MSFT", 420e18);
        _createToken("NVIDIA Corp.", "NVDA", 875e18);
        _createToken("Tesla Inc.", "TSLA", 250e18);
        _createToken("Amazon.com Inc.", "AMZN", 185e18);
        _createToken("Alphabet Inc.", "GOOGL", 165e18);
        _createToken("Meta Platforms Inc.", "META", 500e18);
        _createToken("JPMorgan Chase", "JPM", 205e18);
        _createToken("Visa Inc.", "V", 290e18);
        _createToken("Johnson & Johnson", "JNJ", 160e18);
    }

    /// @notice Mint tokens to an address (for seeding liquidity)
    function mintToken(string calldata symbol, address to, uint256 amount) external onlyOwner {
        address token = tokenBySymbol[symbol];
        require(token != address(0), "MockStockTokenFactory: token not found");
        MockStockToken(token).mint(to, amount);
    }

    /// @notice Mint all tokens to an address
    function mintAllTokens(address to, uint256 amount) external onlyOwner {
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            MockStockToken(deployedTokens[i].token).mint(to, amount);
        }
    }

    function _createToken(string memory name_, string memory symbol_, uint256 initialPrice) internal {
        MockStockToken newToken = new MockStockToken(name_, symbol_, 18);
        address token = address(newToken);

        deployedTokens.push(StockTokenInfo({
            token: token,
            name: name_,
            symbol: symbol_,
            initialPrice: initialPrice
        }));
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
