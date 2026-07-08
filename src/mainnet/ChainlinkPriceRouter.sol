// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IERC8056} from "../interfaces/IERC8056.sol";
import {IMarketGate} from "../interfaces/IMarketGate.sol";

/// @title ChainlinkPriceRouter
/// @notice Mainnet NAV/pricing source. Implements the full `ITokenRouter` view
///         surface (drop-in for `BaseVault._totalAssets`, `_hasZeroPriceToken`,
///         and `PriceOracleUpgradeable`) reading per-token Chainlink feeds
///         instead of stored prices, plus the `depositsOpen()` market gate.
///         Swapping is disabled — execution lives in MainnetExecutionEngine.
///
///         Pricing semantics (parity with the testnet TokenRouterUpgradeable):
///         - `getTokenPrice` NEVER reverts; it returns 0 for unregistered
///           tokens, non-positive answers, reverting feeds, or answers older
///           than `hardStalenessCap` (default 7 days — NAV keeps working over
///           weekends while markets are closed).
///         - The per-feed `maxStaleness` does NOT zero the price; it only
///           gates `depositsOpen()`.
contract ChainlinkPriceRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable, ITokenRouter, IMarketGate {
    struct FeedConfig {
        address feed;
        uint48 maxStaleness;
        uint8 feedDecimals;
        bool oraclePausedCheck;
        bool exists;
    }

    /// @notice Base asset (USDG). Priced by its own optional feed, else a constant 1e18.
    address public baseAsset;

    mapping(address => FeedConfig) public feeds;
    address[] public registeredTokens;

    /// @notice Chainlink L2 sequencer uptime feed (0x0 = check disabled).
    address public sequencerUptimeFeed;
    uint256 public sequencerGracePeriod;

    /// @notice Age beyond which `getTokenPrice` returns 0 (NAV circuit breaker).
    uint256 public hardStalenessCap;

    /// @notice Keeper-controlled market-hours flag; first conjunct of `depositsOpen`.
    bool public marketOpen;
    mapping(address => bool) public authorizedKeepers;

    mapping(bytes32 => address) private symbolToToken;
    mapping(address => bytes32) private tokenSymbolHash;

    event FeedSet(
        address indexed token,
        address indexed feed,
        uint48 maxStaleness,
        uint8 feedDecimals,
        string symbol,
        bool oraclePausedCheck
    );
    event FeedRemoved(address indexed token);
    event SequencerFeedUpdated(address indexed feed, uint256 gracePeriod);
    event HardStalenessCapUpdated(uint256 cap);
    event KeeperUpdated(address indexed keeper, bool authorized);
    event MarketOpenUpdated(bool open);

    error SwapDisabled();
    error ZeroPrice();
    error ZeroAddress();
    error FeedNotFound();
    error UnauthorizedKeeper();
    error ZeroStalenessCap();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address baseAsset_) external initializer {
        __Ownable_init(owner_);
        if (baseAsset_ == address(0)) revert ZeroAddress();
        baseAsset = baseAsset_;
        hardStalenessCap = 7 days;
    }

    // ===================== Admin =====================

    /// @notice Register or update a token's Chainlink feed. Stores the feed's
    ///         decimals at registration time (normalization never trusts a
    ///         later-mutating `decimals()`).
    function setFeed(
        address token,
        address feed,
        uint48 maxStaleness,
        string calldata symbol,
        bool oraclePausedCheck
    ) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();

        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        bool existed = feeds[token].exists;
        feeds[token] = FeedConfig({
            feed: feed,
            maxStaleness: maxStaleness,
            feedDecimals: feedDecimals,
            oraclePausedCheck: oraclePausedCheck,
            exists: true
        });
        if (!existed) registeredTokens.push(token);

        if (bytes(symbol).length > 0) {
            bytes32 symbolHash = keccak256(bytes(symbol));
            bytes32 previous = tokenSymbolHash[token];
            if (previous != bytes32(0) && previous != symbolHash) delete symbolToToken[previous];
            symbolToToken[symbolHash] = token;
            tokenSymbolHash[token] = symbolHash;
        }

        emit FeedSet(token, feed, maxStaleness, feedDecimals, symbol, oraclePausedCheck);
    }

    /// @notice Deregister a token: feed config, registry entry, and symbol mapping.
    function removeFeed(address token) external onlyOwner {
        if (!feeds[token].exists) revert FeedNotFound();
        delete feeds[token];

        uint256 len = registeredTokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (registeredTokens[i] == token) {
                registeredTokens[i] = registeredTokens[len - 1];
                registeredTokens.pop();
                break;
            }
        }

        bytes32 symbolHash = tokenSymbolHash[token];
        if (symbolHash != bytes32(0)) {
            if (symbolToToken[symbolHash] == token) delete symbolToToken[symbolHash];
            delete tokenSymbolHash[token];
        }

        emit FeedRemoved(token);
    }

    function setSequencerFeed(address feed, uint256 gracePeriod) external onlyOwner {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedUpdated(feed, gracePeriod);
    }

    function setHardStalenessCap(uint256 cap) external onlyOwner {
        if (cap == 0) revert ZeroStalenessCap();
        hardStalenessCap = cap;
        emit HardStalenessCapUpdated(cap);
    }

    function setKeeper(address keeper, bool authorized) external onlyOwner {
        authorizedKeepers[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    /// @notice Flip the market-hours gate. Owner or authorized keeper.
    function setMarketOpen(bool open) external {
        if (msg.sender != owner() && !authorizedKeepers[msg.sender]) revert UnauthorizedKeeper();
        marketOpen = open;
        emit MarketOpenUpdated(open);
    }

    // ===================== ITokenRouter views =====================

    /// @notice USD price with 18 decimals. NEVER reverts.
    ///         Base asset: its feed price if registered, else a constant 1e18.
    ///         Registered token: latest feed answer normalized to 18 decimals;
    ///         0 when unregistered, answer <= 0, feed reverts, or the answer
    ///         is older than `hardStalenessCap`.
    function getTokenPrice(address token) public view override returns (uint256) {
        FeedConfig memory cfg = feeds[token];
        if (!cfg.exists) {
            return token == baseAsset ? 1e18 : 0;
        }
        return _readPrice(cfg);
    }

    /// @notice Quote with the exact decimal-handling semantics of
    ///         `TokenRouterUpgradeable.getQuote` (both prices 18-dec USD,
    ///         scaled by token decimals). Reverts `ZeroPrice` if either side
    ///         has no usable price.
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        override
        returns (uint256 amountOut)
    {
        uint256 priceIn = getTokenPrice(tokenIn);
        uint256 priceOut = getTokenPrice(tokenOut);
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

    /// @notice True iff one side is the base asset and the other is a
    ///         registered (non-base) token, in either ordering.
    function isPairSupported(address tokenIn, address tokenOut) public view override returns (bool) {
        if (tokenIn == baseAsset) return tokenOut != baseAsset && feeds[tokenOut].exists;
        if (tokenOut == baseAsset) return feeds[tokenIn].exists;
        return false;
    }

    /// @notice Swapping is disabled: this contract is pricing-only. Execution
    ///         lives in MainnetExecutionEngine (docs/mainnet-execution-abi.md).
    function swap(address, address, uint256, uint256, address) external pure override returns (uint256) {
        revert SwapDisabled();
    }

    // ===================== Market gate =====================

    /// @notice Deposit gate: market open AND sequencer OK AND every registered
    ///         feed fresh within its own `maxStaleness` AND no registered
    ///         token (with `oraclePausedCheck`) reporting `oraclePaused()`.
    function depositsOpen() external view override returns (bool) {
        if (!marketOpen) return false;
        if (!_sequencerOk()) return false;

        uint256 len = registeredTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = registeredTokens[i];
            if (!isFeedFresh(token)) return false;
            if (feeds[token].oraclePausedCheck) {
                try IERC8056(token).oraclePaused() returns (bool paused) {
                    if (paused) return false;
                } catch {
                    // Token does not answer the probe — it cannot "report
                    // true", so it does not close the gate.
                }
            }
        }
        return true;
    }

    /// @notice True when the token's feed answers with a positive price no
    ///         older than its per-feed `maxStaleness`.
    function isFeedFresh(address token) public view returns (bool) {
        FeedConfig memory cfg = feeds[token];
        if (!cfg.exists) return false;
        try AggregatorV3Interface(cfg.feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return false;
            uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            return age <= cfg.maxStaleness;
        } catch {
            return false;
        }
    }

    // ===================== Compat shims =====================

    /// @notice Alias of `getTokenPrice` matching the testnet router's public
    ///         `tokenPrices` mapping getter (consumed by PriceOracleUpgradeable).
    function tokenPrices(address token) external view returns (uint256) {
        return getTokenPrice(token);
    }

    /// @notice Resolve a registered symbol to its token; 0x0 when unknown
    ///         (matches the stock factory's getter consumed by PriceOracleUpgradeable).
    function tokenBySymbol(string calldata symbol) external view returns (address) {
        return symbolToToken[keccak256(bytes(symbol))];
    }

    /// @notice Alias of `isPairSupported` matching the testnet router's public
    ///         `pairSupported` mapping getter.
    function pairSupported(address tokenA, address tokenB) external view returns (bool) {
        return isPairSupported(tokenA, tokenB);
    }

    function registeredTokensLength() external view returns (uint256) {
        return registeredTokens.length;
    }

    // ===================== Internals =====================

    function _readPrice(FeedConfig memory cfg) internal view returns (uint256) {
        try AggregatorV3Interface(cfg.feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return 0;
            uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
            if (age > hardStalenessCap) return 0;
            // safe cast: answer > 0 checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            return _normalize(uint256(answer), cfg.feedDecimals);
        } catch {
            return 0;
        }
    }

    /// @dev Scale a positive feed answer to 18 decimals. Returns 0 instead of
    ///      overflowing on absurd answers (never-revert guarantee).
    function _normalize(uint256 answer, uint8 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals == 18) return answer;
        if (feedDecimals < 18) {
            uint256 scale = 10 ** (18 - uint256(feedDecimals));
            if (answer > type(uint256).max / scale) return 0;
            return answer * scale;
        }
        return answer / 10 ** (uint256(feedDecimals) - 18);
    }

    /// @dev Chainlink L2 pattern: answer 0 = sequencer up; must have been up
    ///      for longer than the grace period. No feed configured = check off.
    function _sequencerOk() internal view returns (bool) {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return true;
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            if (answer != 0) return false;
            uint256 upFor = block.timestamp > startedAt ? block.timestamp - startedAt : 0;
            return upFor > sequencerGracePeriod;
        } catch {
            return false;
        }
    }

    /// @dev Token decimals with the testnet router's fallback semantics.
    function _decimals(address token) internal view returns (uint256) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return uint256(d);
        } catch {
            return 18;
        }
    }

    // ===================== UUPS =====================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[40] private __gap;
}
