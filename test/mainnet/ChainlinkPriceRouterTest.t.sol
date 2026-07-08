// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ChainlinkPriceRouter} from "../../src/mainnet/ChainlinkPriceRouter.sol";
import {TokenRouterUpgradeable} from "../../src/rebalance/TokenRouterUpgradeable.sol";

// ===================== Local mocks =====================

/// @notice Settable Chainlink-style aggregator. `setDecimals` lets tests prove
///         the router normalizes with the decimals STORED at setFeed time.
contract MockAggregatorV3 {
    uint8 private _decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public shouldRevert;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function setRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert("MockAggregatorV3: down");
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/// @notice ERC-8056-flavored token stub: decimals + uiMultiplier + oraclePaused.
contract MockERC8056Token {
    string public name;
    string public symbol;
    uint8 private _decimals;
    bool private _oraclePaused;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function oraclePaused() external view returns (bool) {
        return _oraclePaused;
    }

    function setOraclePaused(bool paused_) external {
        _oraclePaused = paused_;
    }
}

/// @notice Token WITHOUT oraclePaused() — probes the try/catch guard.
contract MockPlainToken {
    string public name;
    string public symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

// ===================== Tests =====================

contract ChainlinkPriceRouterTest is Test {
    uint256 internal constant START_TS = 1_750_000_000;

    address public deployer = address(this);
    address public alice = makeAddr("alice");
    address public keeper = makeAddr("keeper");

    ChainlinkPriceRouter public router;
    MockERC8056Token public base; // 6 decimals, USDG stand-in
    MockERC8056Token public aapl; // 18 decimals
    MockERC8056Token public msft; // 18 decimals
    MockAggregatorV3 public aaplFeed; // 8-dec feed
    MockAggregatorV3 public msftFeed; // 18-dec feed

    function setUp() public {
        vm.warp(START_TS);

        base = new MockERC8056Token("USD Global", "USDG", 6);
        aapl = new MockERC8056Token("Apple", "AAPL", 18);
        msft = new MockERC8056Token("Microsoft", "MSFT", 18);

        aaplFeed = new MockAggregatorV3(8, 195e8); // $195.00
        msftFeed = new MockAggregatorV3(18, 42e18); // $42.00

        ChainlinkPriceRouter impl = new ChainlinkPriceRouter();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ChainlinkPriceRouter.initialize, (deployer, address(base)))
        );
        router = ChainlinkPriceRouter(address(proxy));

        router.setFeed(address(aapl), address(aaplFeed), 1 hours, "AAPL", true);
        router.setMarketOpen(true);
    }

    function _registerMsft(bool oraclePausedCheck) internal {
        router.setFeed(address(msft), address(msftFeed), 1 hours, "MSFT", oraclePausedCheck);
    }

    // ===================== getTokenPrice: normalization =====================

    function test_getTokenPrice_normalizes8DecimalFeed() public view {
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
    }

    function test_getTokenPrice_passthrough18DecimalFeed() public {
        _registerMsft(true);
        assertEq(router.getTokenPrice(address(msft)), 42e18);
    }

    function test_getTokenPrice_usesStoredFeedDecimals() public {
        // Feed misreports decimals AFTER registration; router must keep using
        // the value stored at setFeed time.
        aaplFeed.setDecimals(18);
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
    }

    // ===================== getTokenPrice: never-revert zero cases =====================

    function test_getTokenPrice_unregisteredToken_returnsZero() public view {
        assertEq(router.getTokenPrice(address(0xDEAD)), 0);
    }

    function test_getTokenPrice_negativeAnswer_returnsZero() public {
        aaplFeed.setAnswer(-1);
        assertEq(router.getTokenPrice(address(aapl)), 0);
    }

    function test_getTokenPrice_zeroAnswer_returnsZero() public {
        aaplFeed.setAnswer(0);
        assertEq(router.getTokenPrice(address(aapl)), 0);
    }

    function test_getTokenPrice_revertingFeed_returnsZero() public {
        aaplFeed.setRevert(true);
        assertEq(router.getTokenPrice(address(aapl)), 0);
    }

    // ===================== getTokenPrice: staleness =====================

    function test_getTokenPrice_pastMaxStaleness_stillPriced() public {
        // Past the per-feed maxStaleness (1h) but under the 7-day hard cap:
        // depositsOpen gating flips, NAV pricing keeps working (weekend parity).
        vm.warp(START_TS + 1 hours + 1);
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
        assertFalse(router.isFeedFresh(address(aapl)));
    }

    function test_getTokenPrice_atHardStalenessCap_stillPriced() public {
        vm.warp(START_TS + 7 days);
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
    }

    function test_getTokenPrice_pastHardStalenessCap_returnsZero() public {
        vm.warp(START_TS + 7 days + 1);
        assertEq(router.getTokenPrice(address(aapl)), 0);
    }

    // ===================== getTokenPrice: base asset =====================

    function test_getTokenPrice_baseAssetWithoutFeed_returnsOne18() public view {
        assertEq(router.getTokenPrice(address(base)), 1e18);
    }

    function test_getTokenPrice_baseAssetWithFeed_usesFeed() public {
        MockAggregatorV3 baseFeed = new MockAggregatorV3(8, 99_980_000); // $0.9998
        router.setFeed(address(base), address(baseFeed), 1 days, "USDG", false);
        assertEq(router.getTokenPrice(address(base)), 0.9998e18);
    }

    function test_getTokenPrice_baseAssetWithFeed_pastHardCap_returnsZero() public {
        MockAggregatorV3 baseFeed = new MockAggregatorV3(8, 1e8);
        router.setFeed(address(base), address(baseFeed), 1 days, "USDG", false);
        vm.warp(START_TS + 7 days + 1);
        assertEq(router.getTokenPrice(address(base)), 0);
    }

    // ===================== getQuote =====================

    function test_getQuote_baseToStock_handComputed() public view {
        // 1000 USDG (6 dec) at base $1.00 into AAPL (18 dec) at $195:
        // (1000e6 * 1e18) * 10^(18-6) / 195e18 = floor(10^21 / 195)
        uint256 amountOut = router.getQuote(address(base), address(aapl), 1_000e6);
        assertEq(amountOut, 5128205128205128205);
    }

    function test_getQuote_stockToBase_handComputed() public view {
        // 2 AAPL (18 dec) at $195 into USDG (6 dec) at $1.00:
        // (2e18 * 195e18) / 1e18 / 10^(18-6) = 390e6
        uint256 amountOut = router.getQuote(address(aapl), address(base), 2e18);
        assertEq(amountOut, 390e6);
    }

    function test_getQuote_matchesTestnetRouterMath() public {
        // Semantics parity: identical inputs must produce identical outputs
        // to TokenRouterUpgradeable.getQuote.
        TokenRouterUpgradeable testnetImpl = new TokenRouterUpgradeable();
        ERC1967Proxy testnetProxy = new ERC1967Proxy(
            address(testnetImpl),
            abi.encodeCall(TokenRouterUpgradeable.initialize, (deployer, address(base)))
        );
        TokenRouterUpgradeable testnetRouter = TokenRouterUpgradeable(address(testnetProxy));
        testnetRouter.setTokenPrice(address(base), 1e18);
        testnetRouter.setTokenPrice(address(aapl), 195e18);

        assertEq(
            router.getQuote(address(base), address(aapl), 1_000e6),
            testnetRouter.getQuote(address(base), address(aapl), 1_000e6)
        );
        assertEq(
            router.getQuote(address(aapl), address(base), 2e18),
            testnetRouter.getQuote(address(aapl), address(base), 2e18)
        );
    }

    function test_getQuote_zeroPriceIn_reverts() public {
        vm.expectRevert(ChainlinkPriceRouter.ZeroPrice.selector);
        router.getQuote(address(0xDEAD), address(aapl), 1e18);
    }

    function test_getQuote_zeroPriceOut_reverts() public {
        vm.expectRevert(ChainlinkPriceRouter.ZeroPrice.selector);
        router.getQuote(address(base), address(0xDEAD), 1e6);
    }

    // ===================== swap =====================

    function test_swap_alwaysRevertsSwapDisabled() public {
        vm.expectRevert(ChainlinkPriceRouter.SwapDisabled.selector);
        router.swap(address(base), address(aapl), 1e6, 0, address(this));

        vm.expectRevert(ChainlinkPriceRouter.SwapDisabled.selector);
        router.swap(address(aapl), address(base), 1e18, 0, address(this));

        vm.prank(alice);
        vm.expectRevert(ChainlinkPriceRouter.SwapDisabled.selector);
        router.swap(address(base), address(aapl), 1e6, 0, alice);
    }

    // ===================== pair support =====================

    function test_isPairSupported_baseAndRegisteredToken() public view {
        assertTrue(router.isPairSupported(address(base), address(aapl)));
        assertTrue(router.isPairSupported(address(aapl), address(base)));
    }

    function test_isPairSupported_falseCases() public {
        _registerMsft(true);
        // stock <-> stock is never routable here
        assertFalse(router.isPairSupported(address(aapl), address(msft)));
        // base <-> unregistered token
        assertFalse(router.isPairSupported(address(base), address(0xDEAD)));
        assertFalse(router.isPairSupported(address(0xDEAD), address(base)));
        // identical sides
        assertFalse(router.isPairSupported(address(base), address(base)));
        assertFalse(router.isPairSupported(address(aapl), address(aapl)));
    }

    function test_pairSupported_aliasMatchesIsPairSupported() public view {
        assertEq(
            router.pairSupported(address(base), address(aapl)),
            router.isPairSupported(address(base), address(aapl))
        );
        assertEq(
            router.pairSupported(address(aapl), address(msft)),
            router.isPairSupported(address(aapl), address(msft))
        );
    }

    // ===================== depositsOpen truth table =====================

    function test_depositsOpen_allGood_true() public view {
        assertTrue(router.depositsOpen());
    }

    function test_depositsOpen_marketClosed_false() public {
        router.setMarketOpen(false);
        assertFalse(router.depositsOpen());
    }

    function test_depositsOpen_staleFeed_false() public {
        vm.warp(START_TS + 1 hours + 1);
        assertFalse(router.depositsOpen());
        // ...while NAV pricing still works:
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
    }

    function test_depositsOpen_zeroAnswerFeed_false() public {
        aaplFeed.setAnswer(0);
        assertFalse(router.depositsOpen());
    }

    function test_depositsOpen_sequencerDown_false() public {
        MockAggregatorV3 seqFeed = new MockAggregatorV3(0, 1); // answer 1 = down
        router.setSequencerFeed(address(seqFeed), 1 hours);
        assertFalse(router.depositsOpen());
    }

    function test_depositsOpen_sequencerUpWithinGrace_false() public {
        MockAggregatorV3 seqFeed = new MockAggregatorV3(0, 0); // answer 0 = up
        seqFeed.setStartedAt(START_TS - 30 minutes); // recovered 30m ago
        router.setSequencerFeed(address(seqFeed), 1 hours);
        assertFalse(router.depositsOpen());
    }

    function test_depositsOpen_sequencerUpPastGrace_true() public {
        MockAggregatorV3 seqFeed = new MockAggregatorV3(0, 0);
        seqFeed.setStartedAt(START_TS - 2 hours);
        router.setSequencerFeed(address(seqFeed), 1 hours);
        assertTrue(router.depositsOpen());
    }

    function test_depositsOpen_oraclePaused_false() public {
        aapl.setOraclePaused(true);
        assertFalse(router.depositsOpen());
    }

    function test_depositsOpen_oraclePausedCheckDisabled_ignoresPause() public {
        _registerMsft(false);
        msft.setOraclePaused(true);
        assertTrue(router.depositsOpen());
    }

    function test_depositsOpen_oraclePausedProbeReverts_failsOpen() public {
        // Token registered with oraclePausedCheck=true but no oraclePaused()
        // implementation: the try/catch guard must not brick the gate.
        MockPlainToken plain = new MockPlainToken("Plain", "PLN", 18);
        MockAggregatorV3 plainFeed = new MockAggregatorV3(8, 10e8);
        router.setFeed(address(plain), address(plainFeed), 1 hours, "PLN", true);
        assertTrue(router.depositsOpen());
    }

    function test_isFeedFresh_basics() public {
        assertTrue(router.isFeedFresh(address(aapl)));
        assertFalse(router.isFeedFresh(address(0xDEAD)));
        vm.warp(START_TS + 1 hours); // age == maxStaleness: still fresh
        assertTrue(router.isFeedFresh(address(aapl)));
    }

    // ===================== compat shims =====================

    function test_tokenPrices_aliasEqualsGetTokenPrice() public view {
        assertEq(router.tokenPrices(address(aapl)), router.getTokenPrice(address(aapl)));
        assertEq(router.tokenPrices(address(base)), router.getTokenPrice(address(base)));
        assertEq(router.tokenPrices(address(0xDEAD)), 0);
    }

    function test_tokenBySymbol_roundtripAndUnknown() public {
        assertEq(router.tokenBySymbol("AAPL"), address(aapl));
        assertEq(router.tokenBySymbol("TSLA"), address(0));
        _registerMsft(true);
        assertEq(router.tokenBySymbol("MSFT"), address(msft));
    }

    // ===================== feed admin =====================

    function test_removeFeed_cleansUp() public {
        _registerMsft(true);
        assertEq(router.registeredTokensLength(), 2);

        router.removeFeed(address(aapl));

        assertEq(router.getTokenPrice(address(aapl)), 0);
        assertEq(router.tokenBySymbol("AAPL"), address(0));
        assertFalse(router.isPairSupported(address(base), address(aapl)));
        assertFalse(router.isFeedFresh(address(aapl)));
        assertEq(router.registeredTokensLength(), 1);
        assertEq(router.registeredTokens(0), address(msft));
        // gate still works with the remaining token
        assertTrue(router.depositsOpen());
    }

    function test_removeFeed_unregistered_reverts() public {
        vm.expectRevert(ChainlinkPriceRouter.FeedNotFound.selector);
        router.removeFeed(address(0xDEAD));
    }

    function test_setFeed_updateDoesNotDuplicateRegistration() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(18, 200e18);
        router.setFeed(address(aapl), address(newFeed), 2 hours, "AAPL", false);
        assertEq(router.registeredTokensLength(), 1);
        assertEq(router.getTokenPrice(address(aapl)), 200e18);
    }

    function test_setFeed_zeroAddress_reverts() public {
        vm.expectRevert(ChainlinkPriceRouter.ZeroAddress.selector);
        router.setFeed(address(0), address(aaplFeed), 1 hours, "X", false);

        vm.expectRevert(ChainlinkPriceRouter.ZeroAddress.selector);
        router.setFeed(address(msft), address(0), 1 hours, "MSFT", false);
    }

    // ===================== access control =====================

    function test_setFeed_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        router.setFeed(address(msft), address(msftFeed), 1 hours, "MSFT", false);
    }

    function test_removeFeed_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        router.removeFeed(address(aapl));
    }

    function test_setSequencerFeed_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        router.setSequencerFeed(address(aaplFeed), 1 hours);
    }

    function test_setHardStalenessCap_onlyOwner_andZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        router.setHardStalenessCap(1 days);

        vm.expectRevert(ChainlinkPriceRouter.ZeroStalenessCap.selector);
        router.setHardStalenessCap(0);

        router.setHardStalenessCap(3 days);
        assertEq(router.hardStalenessCap(), 3 days);
        vm.warp(START_TS + 3 days + 1);
        assertEq(router.getTokenPrice(address(aapl)), 0);
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        router.setKeeper(keeper, true);
    }

    function test_setMarketOpen_ownerAndKeeperOnly() public {
        // owner path (exercised in setUp too)
        router.setMarketOpen(false);
        assertFalse(router.marketOpen());

        // unauthorized
        vm.prank(alice);
        vm.expectRevert(ChainlinkPriceRouter.UnauthorizedKeeper.selector);
        router.setMarketOpen(true);

        // keeper path
        router.setKeeper(keeper, true);
        vm.prank(keeper);
        router.setMarketOpen(true);
        assertTrue(router.marketOpen());

        // revoked keeper
        router.setKeeper(keeper, false);
        vm.prank(keeper);
        vm.expectRevert(ChainlinkPriceRouter.UnauthorizedKeeper.selector);
        router.setMarketOpen(false);
    }

    // ===================== events =====================

    function test_events_feedSetAndMarketOpen() public {
        vm.expectEmit(true, true, false, true);
        emit ChainlinkPriceRouter.FeedSet(address(msft), address(msftFeed), 1 hours, 18, "MSFT", false);
        router.setFeed(address(msft), address(msftFeed), 1 hours, "MSFT", false);

        vm.expectEmit(false, false, false, true);
        emit ChainlinkPriceRouter.MarketOpenUpdated(false);
        router.setMarketOpen(false);

        vm.expectEmit(true, false, false, false);
        emit ChainlinkPriceRouter.FeedRemoved(address(msft));
        router.removeFeed(address(msft));
    }

    // ===================== UUPS =====================

    function test_upgrade_byOwner_preservesState() public {
        ChainlinkPriceRouter newImpl = new ChainlinkPriceRouter();
        router.upgradeToAndCall(address(newImpl), "");

        assertEq(router.baseAsset(), address(base));
        assertEq(router.getTokenPrice(address(aapl)), 195e18);
        assertEq(router.tokenBySymbol("AAPL"), address(aapl));
        assertEq(router.hardStalenessCap(), 7 days);
        assertTrue(router.marketOpen());
    }

    function test_upgrade_nonOwner_reverts() public {
        ChainlinkPriceRouter newImpl = new ChainlinkPriceRouter();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        router.initialize(alice, address(base));
    }

    // ===================== Rider: decimal-normalization overflow guard =====================

    function test_getTokenPrice_absurdFeedDecimals_returnsZeroNeverReverts() public {
        // feedDecimals >= 96 makes 10**(feedDecimals-18) overflow uint256. The
        // >18 branch must fail closed (return 0) instead of reverting inside
        // _readPrice's success block, which would break the never-revert guarantee.
        MockAggregatorV3 absurdFeed = new MockAggregatorV3(96, 1_000e8);
        MockPlainToken weird = new MockPlainToken("Weird", "WRD", 18);
        router.setFeed(address(weird), address(absurdFeed), 1 hours, "WRD", false);
        // Must not revert; returns 0.
        assertEq(router.getTokenPrice(address(weird)), 0);
    }

    function test_getTokenPrice_maxUint8FeedDecimals_returnsZeroNeverReverts() public {
        // Extreme boundary: uint8 max decimals (255) must also fail closed.
        MockAggregatorV3 absurdFeed = new MockAggregatorV3(255, 1e8);
        MockPlainToken weird = new MockPlainToken("Weird2", "WR2", 18);
        router.setFeed(address(weird), address(absurdFeed), 1 hours, "WR2", false);
        assertEq(router.getTokenPrice(address(weird)), 0);
    }

    function test_getTokenPrice_feedDecimals95_atBoundary_noRevert() public {
        // diff == 77 is the largest safe exponent (10**77 fits): must not revert.
        // A normal-magnitude answer divided by 10**77 floors to 0, but the call
        // itself succeeding is what matters (never-revert guarantee).
        MockAggregatorV3 boundaryFeed = new MockAggregatorV3(95, 1e8);
        MockPlainToken weird = new MockPlainToken("Weird3", "WR3", 18);
        router.setFeed(address(weird), address(boundaryFeed), 1 hours, "WR3", false);
        assertEq(router.getTokenPrice(address(weird)), 0);
    }

    // ===================== Rider: sequencer uninitialized-round edge =====================

    function test_depositsOpen_sequencerUninitializedRound_false() public {
        // answer 0 (would read as "up") but startedAt 0 == uninitialized round:
        // must be treated as NOT up. Prior to the fix, block.timestamp - 0 was a
        // huge age that trivially cleared the grace period.
        MockAggregatorV3 seqFeed = new MockAggregatorV3(0, 0); // answer 0 = up
        seqFeed.setStartedAt(0); // uninitialized round
        router.setSequencerFeed(address(seqFeed), 1 hours);
        assertFalse(router.depositsOpen());
    }
}
