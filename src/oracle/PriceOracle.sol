// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface ITokenRouter {
    function tokenPrices(address token) external view returns (uint256);
}

interface IStockTokenFactory {
    function tokenBySymbol(string calldata symbol) external view returns (address);
}

/// @title PriceOracle
/// @notice Public wrapper that resolves a stock ticker to its on-chain price.
///         Accepts plain tickers ("NVDA") or tilt-prefixed symbols ("tiltNVDA").
contract PriceOracle {
    ITokenRouter public immutable tokenRouter;
    IStockTokenFactory public immutable stockTokenFactory;

    error TokenNotFound(string ticker);
    error PriceNotSet(string ticker);

    constructor(address _tokenRouter, address _stockTokenFactory) {
        tokenRouter = ITokenRouter(_tokenRouter);
        stockTokenFactory = IStockTokenFactory(_stockTokenFactory);
    }

    /// @notice Get the USD price (18 decimals) for a stock ticker.
    /// @param ticker Plain ticker like "NVDA" or full symbol like "tiltNVDA".
    /// @return priceUsd18 Price in USD with 18 decimals (e.g. 875e18 = $875).
    function getTokenPrice(string calldata ticker) external view returns (uint256 priceUsd18) {
        address token = _resolve(ticker);
        priceUsd18 = tokenRouter.tokenPrices(token);
        if (priceUsd18 == 0) revert PriceNotSet(ticker);
    }

    /// @notice Get prices for multiple tickers in a single call.
    /// @param tickers Array of plain tickers or tilt-prefixed symbols.
    /// @return prices Array of USD prices with 18 decimals (0 if not set).
    function getTokenPrices(string[] calldata tickers) external view returns (uint256[] memory prices) {
        prices = new uint256[](tickers.length);
        for (uint256 i = 0; i < tickers.length; i++) {
            address token = _resolve(tickers[i]);
            prices[i] = tokenRouter.tokenPrices(token);
        }
    }

    /// @notice Resolve a ticker to its token address.
    /// @param ticker Plain ticker like "NVDA" or full symbol like "tiltNVDA".
    /// @return token The on-chain token address.
    function resolveToken(string calldata ticker) external view returns (address token) {
        token = _resolve(ticker);
    }

    function _resolve(string calldata ticker) internal view returns (address token) {
        token = stockTokenFactory.tokenBySymbol(ticker);
        if (token != address(0)) return token;

        token = stockTokenFactory.tokenBySymbol(string.concat("tilt", ticker));
        if (token == address(0)) revert TokenNotFound(ticker);
    }
}
