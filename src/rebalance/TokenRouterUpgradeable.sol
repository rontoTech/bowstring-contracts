// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

interface IMintBurnable {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @title TokenRouterUpgradeable
/// @notice UUPS-proxied hybrid router: mint/burn for stock tokens, transfer for base asset.
///         On swap the router burns the incoming stock token and mints the outgoing stock
///         token (infinite liquidity). For the base asset (tiltUSDC) it uses held balances
///         instead of mint/burn, since the existing TiltUSDC contract is kept as-is.
contract TokenRouterUpgradeable is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard, ITokenRouter {
    using SafeERC20 for IERC20;

    address public baseAsset;

    mapping(address => uint256) public tokenPrices;
    mapping(address => mapping(address => bool)) public pairSupported;
    mapping(address => bool) public authorizedCallers;
    mapping(address => uint8) public decimalOverride;
    mapping(address => bool) public hasDecimalOverride;

    event PriceUpdated(address indexed token, uint256 price);
    event PairUpdated(address indexed tokenA, address indexed tokenB, bool supported);
    event CallerAuthorized(address indexed caller, bool authorized);

    error UnauthorizedCaller();
    error UnsupportedPair();
    error InsufficientOutput();
    error ZeroPrice();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address baseAsset_) external initializer {
        __Ownable_init(owner_);
        require(baseAsset_ != address(0), "TokenRouter: zero base asset");
        baseAsset = baseAsset_;
    }

    // ===================== Admin =====================

    function setTokenPrice(address token, uint256 priceUsd18) external onlyOwner {
        require(priceUsd18 > 0, "TokenRouter: zero price");
        tokenPrices[token] = priceUsd18;
        emit PriceUpdated(token, priceUsd18);
    }

    function clearTokenPrice(address token) external onlyOwner {
        delete tokenPrices[token];
        emit PriceUpdated(token, 0);
    }

    function setTokenPricesBatch(address[] calldata tokens, uint256[] calldata prices) external onlyOwner {
        require(tokens.length == prices.length, "TokenRouter: length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(prices[i] > 0, "TokenRouter: zero price");
            tokenPrices[tokens[i]] = prices[i];
            emit PriceUpdated(tokens[i], prices[i]);
        }
    }

    function setPairSupported(address tokenA, address tokenB, bool supported) external onlyOwner {
        pairSupported[tokenA][tokenB] = supported;
        pairSupported[tokenB][tokenA] = supported;
        emit PairUpdated(tokenA, tokenB, supported);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit CallerAuthorized(caller, authorized);
    }

    function setDecimalOverride(address token, uint8 dec) external onlyOwner {
        decimalOverride[token] = dec;
        hasDecimalOverride[token] = true;
    }

    // ===================== Swap =====================

    /// @notice Hybrid swap: mint/burn for stock tokens, transfer for base asset.
    ///   BUY stock  (baseAsset -> stock): receive baseAsset (hold it), mint stock to recipient
    ///   SELL stock (stock -> baseAsset): receive stock (burn it), transfer baseAsset to recipient
    ///   stock-to-stock: receive tokenIn (burn), mint tokenOut
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external override nonReentrant returns (uint256 amountOut) {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        if (!pairSupported[tokenIn][tokenOut]) revert UnsupportedPair();

        amountOut = getQuote(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (tokenIn != baseAsset) {
            IMintBurnable(tokenIn).burn(address(this), amountIn);
        }

        if (tokenOut == baseAsset) {
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
        } else {
            IMintBurnable(tokenOut).mint(recipient, amountOut);
        }

        emit Swap(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    // ===================== Views =====================

    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        override
        returns (uint256 amountOut)
    {
        uint256 priceIn = tokenPrices[tokenIn];
        uint256 priceOut = tokenPrices[tokenOut];
        if (priceIn == 0) revert ZeroPrice();
        if (priceOut == 0) revert ZeroPrice();

        uint256 decIn = _decimals(tokenIn);
        uint256 decOut = _decimals(tokenOut);

        if (decIn >= decOut) {
            amountOut = (amountIn * priceIn) / priceOut / (10 ** (decIn - decOut));
        } else {
            amountOut = (amountIn * priceIn) * (10 ** (decOut - decIn)) / priceOut;
        }
    }

    function isPairSupported(address tokenIn, address tokenOut) external view override returns (bool) {
        return pairSupported[tokenIn][tokenOut];
    }

    function getTokenPrice(address token) external view override returns (uint256) {
        return tokenPrices[token];
    }

    function _decimals(address token) internal view returns (uint256) {
        if (hasDecimalOverride[token]) return uint256(decimalOverride[token]);
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return uint256(d);
        } catch {
            return 18;
        }
    }

    // ===================== UUPS =====================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[43] private __gap;
}
