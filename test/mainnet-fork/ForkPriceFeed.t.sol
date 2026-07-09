// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {ForkBase} from "./ForkBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ChainlinkPriceRouter} from "../../src/mainnet/ChainlinkPriceRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @title ForkPriceFeed
/// @notice Reads the REAL AAPL stock token on chain 4663 and, when a real
///         Chainlink feed is supplied via `AAPL_FEED`, wires it into a freshly
///         deployed ChainlinkPriceRouter and asserts a live positive price +
///         reports freshness. Without a feed env it asserts the ERC-20 surface
///         and SKIPS the price assertions with a logged note (no guessed feed).
contract ForkPriceFeed is ForkBase {
    ChainlinkPriceRouter internal router;

    function setUp() public {
        _initFork();
        if (!forkEnabled) return;

        ChainlinkPriceRouter impl = new ChainlinkPriceRouter();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(ChainlinkPriceRouter.initialize, (address(this), USDG))
        );
        router = ChainlinkPriceRouter(address(proxy));
    }

    function test_aapl_isEighteenDecimals() public {
        if (_skipIfNoFork()) return;
        assertEq(IERC20Metadata(AAPL).decimals(), 18, "AAPL stock token must be 18 decimals");
        console.log("AAPL symbol:", IERC20Metadata(AAPL).symbol());
    }

    function test_priceRouter_unregisteredTokenPriceIsZero() public {
        if (_skipIfNoFork()) return;
        // Before registering any feed, getTokenPrice for a non-base token is 0
        // (never reverts) and base USDG is the constant 1e18.
        assertEq(router.getTokenPrice(AAPL), 0, "unregistered AAPL price must be 0");
        assertEq(router.getTokenPrice(USDG), 1e18, "USDG base price must be constant 1e18");
    }

    function test_aapl_liveFeedPriceWhenProvided() public {
        if (_skipIfNoFork()) return;

        address feed = vm.envOr("AAPL_FEED", address(0));
        if (feed == address(0)) {
            console.log("SKIP: AAPL_FEED unset - no guessed feed address. Asserting ERC-20 surface only.");
            assertEq(IERC20Metadata(AAPL).decimals(), 18);
            return;
        }

        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        console.log("AAPL_FEED:", feed);
        console.log("  feed decimals:", feedDecimals);

        // maxStaleness generous (1 day) so a weekend/closed-market fork still
        // yields a positive NAV price; depositsOpen()/isFeedFresh reflect the
        // per-feed freshness separately.
        router.setFeed(AAPL, feed, 1 days, "AAPL", true);

        uint256 price = router.getTokenPrice(AAPL);
        console.log("  getTokenPrice(AAPL) [1e18]:", price);
        assertGt(price, 0, "live AAPL price must be > 0");

        bool fresh = router.isFeedFresh(AAPL);
        console.log("  isFeedFresh(AAPL):", fresh);

        // Market gate: marketOpen defaults false -> depositsOpen is false
        // regardless of feed freshness; flip and re-read to show the gate is
        // feed-driven once the market flag is on.
        assertFalse(router.depositsOpen(), "depositsOpen must be false while marketOpen=false");
        router.setMarketOpen(true);
        console.log("  depositsOpen() with marketOpen=true:", router.depositsOpen());
    }
}
