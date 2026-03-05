// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IPriceOracleRouter {
    function tokenPrices(address token) external view returns (uint256);
}

interface IPriceOracleFactory {
    function tokenBySymbol(string calldata symbol) external view returns (address);
}

/// @title PriceOracleUpgradeable
/// @notice UUPS-proxied wrapper that resolves a stock ticker to its on-chain price.
///         Accepts plain tickers ("NVDA") or tilt-prefixed symbols ("tiltNVDA").
contract PriceOracleUpgradeable is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    IPriceOracleRouter public tokenRouter;
    IPriceOracleFactory public stockTokenFactory;

    error TokenNotFound(string ticker);
    error PriceNotSet(string ticker);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address tokenRouter_, address stockTokenFactory_, address owner_) external initializer {
        __Ownable_init(owner_);
        tokenRouter = IPriceOracleRouter(tokenRouter_);
        stockTokenFactory = IPriceOracleFactory(stockTokenFactory_);
    }

    function setTokenRouter(address _router) external onlyOwner {
        tokenRouter = IPriceOracleRouter(_router);
    }

    function setStockTokenFactory(address _factory) external onlyOwner {
        stockTokenFactory = IPriceOracleFactory(_factory);
    }

    function getTokenPrice(string calldata ticker) external view returns (uint256 priceUsd18) {
        address token = _resolve(ticker);
        priceUsd18 = tokenRouter.tokenPrices(token);
        if (priceUsd18 == 0) revert PriceNotSet(ticker);
    }

    function getTokenPrices(string[] calldata tickers) external view returns (uint256[] memory prices) {
        prices = new uint256[](tickers.length);
        for (uint256 i = 0; i < tickers.length; i++) {
            address token = _resolve(tickers[i]);
            prices[i] = tokenRouter.tokenPrices(token);
        }
    }

    function resolveToken(string calldata ticker) external view returns (address token) {
        token = _resolve(ticker);
    }

    function _resolve(string calldata ticker) internal view returns (address token) {
        token = stockTokenFactory.tokenBySymbol(ticker);
        if (token != address(0)) return token;
        token = stockTokenFactory.tokenBySymbol(string.concat("tilt", ticker));
        if (token == address(0)) revert TokenNotFound(ticker);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[48] private __gap;
}
