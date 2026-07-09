// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {MainnetExecutionEngine} from "../../src/mainnet/MainnetExecutionEngine.sol";
import {TradeDelegateProxyV2} from "../../src/mainnet/TradeDelegateProxyV2.sol";
import {ChainlinkPriceRouter} from "../../src/mainnet/ChainlinkPriceRouter.sol";
import {ITokenRouter} from "../../src/interfaces/ITokenRouter.sol";
import {IRebalanceEngine} from "../../src/interfaces/IRebalanceEngine.sol";
import {MockStockToken} from "../../src/tokens/MockStockToken.sol";

// ===================== Local mocks =====================

/// @notice Settable Chainlink-style aggregator (mirrors C1's MockAggregatorV3).
contract MockAggregatorV3 {
    uint8 private _decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/// @notice Simulates a 0x Settler. The engine approves it `amountIn` of tokenIn
///         and calls `settle(...)`; it pulls `pullAmount` of tokenIn and mints
///         `payAmount` of tokenOut to `recipient`. All three are attacker-tunable
///         so tests can exercise wrong-recipient, underpayment, and dust cases.
contract MockSettler {
    function settle(
        address tokenIn,
        address tokenOut,
        uint256 pullAmount,
        uint256 payAmount,
        address recipient
    ) external {
        if (pullAmount > 0) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), pullAmount);
        }
        if (payAmount > 0) {
            MockStockToken(tokenOut).mint(recipient, payAmount);
        }
    }
}

/// @notice Settler that re-enters executeRebalance during settlement.
contract MockReentrantSettler {
    address public engine;
    address public vault;

    function arm(address engine_, address vault_) external {
        engine = engine_;
        vault = vault_;
    }

    function settle(address, address, uint256, uint256, address) external {
        // Attempt re-entry; nonReentrant must revert and bubble up.
        IRebalanceEngine.TradeOrder[] memory t = new IRebalanceEngine.TradeOrder[](0);
        MainnetExecutionEngine(engine).executeRebalance(vault, t);
    }
}

/// @notice Minimal exact-input AMM. Pulls `amountIn` of tokenIn and mints a
///         configurable amount of tokenOut to `recipient`.
contract MockAmmRouter {
    uint256 public nextOut;
    address public payTo; // address(0) => pay recipient

    function setNextOut(uint256 out) external {
        nextOut = out;
    }

    function setPayTo(address to) external {
        payTo = to;
    }

    function exactInput(
        bytes calldata,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        address recipient
    ) external returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        address to = payTo == address(0) ? recipient : payTo;
        MockStockToken(tokenOut).mint(to, nextOut);
        return nextOut;
    }
}

/// @notice Minimal vault: pre-approves the engine and forwards to executeRebalance,
///         mirroring UserVault's approve/execute/zero flow. `executeTrade` is
///         delegate-gated so the proxy path can be exercised.
contract MockVault {
    address public engine;
    mapping(address => bool) public delegates;

    error NotDelegate();

    constructor(address engine_) {
        engine = engine_;
    }

    function setDelegate(address d, bool a) external {
        delegates[d] = a;
    }

    /// @dev Direct rebalance entrypoint for engine unit tests. Approves the
    ///      cumulative amountIn per token (the engine pulls each trade in turn).
    function rebalance(IRebalanceEngine.TradeOrder[] calldata trades) external {
        for (uint256 i = 0; i < trades.length; i++) {
            IERC20 t = IERC20(trades[i].tokenIn);
            t.approve(engine, t.allowance(address(this), engine) + trades[i].amountIn);
        }
        MainnetExecutionEngine(engine).executeRebalance(address(this), trades);
        for (uint256 i = 0; i < trades.length; i++) {
            IERC20(trades[i].tokenIn).approve(engine, 0);
        }
    }

    /// @dev Mirrors UserVault.executeTrade (delegate-gated) for the proxy path.
    function executeTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external {
        if (!delegates[msg.sender]) revert NotDelegate();
        IERC20(tokenIn).approve(engine, amountIn);
        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](1);
        trades[0] = IRebalanceEngine.TradeOrder(tokenIn, tokenOut, amountIn, minAmountOut);
        MainnetExecutionEngine(engine).executeRebalance(address(this), trades);
        IERC20(tokenIn).approve(engine, 0);
    }
}

// ===================== Tests =====================

contract MainnetExecutionEngineTest is Test {
    uint256 internal constant START_TS = 1_750_000_000;
    uint256 internal constant SLIPPAGE_BPS = 150;

    address public owner = address(this);
    address public relayer = makeAddr("relayer");
    address public signer = makeAddr("signer");
    address public stranger = makeAddr("stranger");

    ChainlinkPriceRouter public router;
    MainnetExecutionEngine public engine;
    TradeDelegateProxyV2 public proxy;

    MockStockToken public base; // 6-dec USDG stand-in
    MockStockToken public aapl; // 18-dec stock
    MockAggregatorV3 public baseFeed;
    MockAggregatorV3 public aaplFeed;

    MockSettler public settler;
    MockAmmRouter public amm;
    MockVault public vault;

    function setUp() public {
        vm.warp(START_TS);

        // Tokens (open minter model: owner can add minters).
        base = new MockStockToken("USD Global", "USDG", 6);
        aapl = new MockStockToken("Apple", "AAPL", 18);

        baseFeed = new MockAggregatorV3(8, 1e8); // $1.00
        aaplFeed = new MockAggregatorV3(8, 195e8); // $195.00

        // Price router (real C1 contract, behind a proxy).
        ChainlinkPriceRouter routerImpl = new ChainlinkPriceRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(ChainlinkPriceRouter.initialize, (owner, address(base)))
        );
        router = ChainlinkPriceRouter(address(routerProxy));
        router.setFeed(address(base), address(baseFeed), 1 days, "USDG", false);
        router.setFeed(address(aapl), address(aaplFeed), 1 hours, "AAPL", true);

        // Engine (behind a proxy).
        MainnetExecutionEngine engineImpl = new MainnetExecutionEngine();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl),
            abi.encodeCall(MainnetExecutionEngine.initialize, (address(router), address(base), owner))
        );
        engine = MainnetExecutionEngine(address(engineProxy));

        // Proxy V2.
        proxy = new TradeDelegateProxyV2(owner, address(engine));
        proxy.setAuthorizedSigner(signer, true);

        // Settlement infrastructure.
        settler = new MockSettler();
        amm = new MockAmmRouter();

        // Engine config.
        engine.setRelayer(relayer, true);
        engine.setAllowedToken(address(aapl), true);
        engine.setAllowedSettlementTarget(address(settler), true);
        engine.setAmmRouter(address(amm));
        engine.setAmmRoute(address(aapl), abi.encode(address(aapl))); // opaque path

        // Vault.
        vault = new MockVault(address(engine));
        engine.setVaultAuthorized(address(vault), true);

        // Minting rights so settlement can deliver tokenOut.
        aapl.addMinter(address(settler));
        aapl.addMinter(address(amm));
        base.addMinter(address(settler));
        base.addMinter(address(amm));
        base.addMinter(owner);
        aapl.addMinter(owner);
    }

    // ===================== helpers =====================

    function _fundVault(MockStockToken token, uint256 amount) internal {
        token.mint(address(vault), amount);
    }

    function _order(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (IRebalanceEngine.TradeOrder[] memory trades)
    {
        trades = new IRebalanceEngine.TradeOrder[](1);
        trades[0] = IRebalanceEngine.TradeOrder(tokenIn, tokenOut, amountIn, minOut);
    }

    /// @dev Stage a settler fill for a buy (base -> aapl) and return the calldata.
    function _stageBuy(uint256 amountIn, uint256 pull, uint256 pay, address recipient) internal {
        bytes memory data = abi.encodeCall(
            MockSettler.settle, (address(base), address(aapl), pull, pay, recipient)
        );
        vm.prank(relayer);
        engine.stageSettlement(address(vault), address(base), address(aapl), amountIn, address(settler), data);
    }

    function _floor(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 quote = router.getQuote(tokenIn, tokenOut, amountIn);
        return (quote * (10_000 - SLIPPAGE_BPS)) / 10_000;
    }

    // ===================== auth =====================

    // MATRIX: non-vault caller reverts
    function test_executeRebalance_nonVaultCaller_reverts() public {
        IRebalanceEngine.TradeOrder[] memory trades = _order(address(base), address(aapl), 1_000e6, 0);
        vm.expectRevert(MainnetExecutionEngine.UnauthorizedVault.selector);
        engine.executeRebalance(address(vault), trades); // msg.sender = test != vault
    }

    // MATRIX: unauthorized vault reverts
    function test_executeRebalance_unauthorizedVault_reverts() public {
        MockVault rogue = new MockVault(address(engine)); // never authorized
        _fundVault(base, 1_000e6);
        base.mint(address(rogue), 1_000e6);
        vm.expectRevert(MainnetExecutionEngine.UnauthorizedVault.selector);
        rogue.rebalance(_order(address(base), address(aapl), 1_000e6, 0));
    }

    // MATRIX: non-relayer stageSettlement reverts
    function test_stageSettlement_nonRelayer_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(MainnetExecutionEngine.UnauthorizedRelayer.selector);
        engine.stageSettlement(address(vault), address(base), address(aapl), 1e6, address(settler), "");
    }

    // MATRIX: non-allowlisted target reverts
    function test_stageSettlement_nonAllowlistedTarget_reverts() public {
        vm.prank(relayer);
        vm.expectRevert(MainnetExecutionEngine.TargetNotAllowed.selector);
        engine.stageSettlement(address(vault), address(base), address(aapl), 1e6, address(0xBEEF), "");
    }

    // ===================== allowlist: buys vs sells =====================

    // MATRIX: buy of non-allowlisted token reverts
    function test_buy_nonAllowlistedToken_reverts() public {
        engine.setAllowedToken(address(aapl), false);
        _fundVault(base, 1_000e6);
        _stageBuy(1_000e6, 1_000e6, router.getQuote(address(base), address(aapl), 1_000e6), address(vault));
        vm.expectRevert(MainnetExecutionEngine.TokenNotAllowed.selector);
        vault.rebalance(_order(address(base), address(aapl), 1_000e6, 0));
    }

    // MATRIX: sell of non-allowlisted (delisted) token succeeds
    function test_sell_nonAllowlistedToken_succeeds() public {
        // aapl is NOT in allowedTokens, but selling it (tokenOut == base) is allowed.
        engine.setAllowedToken(address(aapl), false);
        uint256 amountIn = 2e18;
        _fundVault(aapl, amountIn);
        uint256 payBase = router.getQuote(address(aapl), address(base), amountIn); // 390e6
        bytes memory data = abi.encodeCall(
            MockSettler.settle, (address(aapl), address(base), amountIn, payBase, address(vault))
        );
        vm.prank(relayer);
        engine.stageSettlement(address(vault), address(aapl), address(base), amountIn, address(settler), data);

        vault.rebalance(_order(address(aapl), address(base), amountIn, 0));
        assertEq(base.balanceOf(address(vault)), payBase);
    }

    // ===================== oracle floor =====================

    // MATRIX: relayer minOut=1 raised by floor; settler below floor reverts
    function test_oracleFloor_belowFloor_reverts() public {
        uint256 amountIn = 1_000e6;
        uint256 floor = _floor(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        // Pay 1 wei below the floor to the vault.
        _stageBuy(amountIn, amountIn, floor - 1, address(vault));
        vm.expectRevert(MainnetExecutionEngine.InsufficientOutput.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 1)); // minOut=1, floor dominates
    }

    // MATRIX: settler at/above floor succeeds (with relayer minOut=1)
    function test_oracleFloor_atFloor_succeeds() public {
        uint256 amountIn = 1_000e6;
        uint256 floor = _floor(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, floor, address(vault));
        vault.rebalance(_order(address(base), address(aapl), amountIn, 1));
        assertEq(aapl.balanceOf(address(vault)), floor);
    }

    // ===================== staged path =====================

    // MATRIX: matching stage consumed same-block
    function test_stagedPath_matchingStageConsumed() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, pay, address(vault));

        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
        assertEq(aapl.balanceOf(address(vault)), pay);
        // stage cleared
        (bytes32 h,,,) = engine.stagedSettlement(address(vault));
        assertEq(h, bytes32(0));
    }

    // MATRIX: stale stage (different block) falls through to AMM
    function test_stagedPath_staleStage_fallsThroughToAmm() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, pay, address(vault));

        // Advance a block: the stage is now stale; AMM must serve it.
        vm.roll(block.number + 1);
        amm.setNextOut(pay);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
        assertEq(aapl.balanceOf(address(vault)), pay);
    }

    // MATRIX: stale stage with no AMM route reverts
    function test_stagedPath_staleStage_noRoute_reverts() public {
        uint256 amountIn = 1_000e6;
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, router.getQuote(address(base), address(aapl), amountIn), address(vault));
        engine.setAmmRoute(address(aapl), ""); // remove route
        vm.roll(block.number + 1);
        vm.expectRevert(MainnetExecutionEngine.NoRoute.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
    }

    // MATRIX: mismatched orderHash falls through to AMM
    function test_stagedPath_mismatchedHash_fallsThroughToAmm() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        // Stage with a DIFFERENT amountIn -> hash mismatch for the real trade.
        _stageBuy(amountIn + 1, amountIn, pay, address(vault));
        amm.setNextOut(pay);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
        assertEq(aapl.balanceOf(address(vault)), pay);
    }

    // MATRIX: stage cannot be replayed after consumption
    function test_stagedPath_cannotReplayAfterConsumption() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn * 2);
        _stageBuy(amountIn, amountIn, pay, address(vault));

        // Two identical trades in one rebalance: first consumes the stage, the
        // second must fall through to AMM (stage already deleted).
        amm.setNextOut(pay);
        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](2);
        trades[0] = IRebalanceEngine.TradeOrder(address(base), address(aapl), amountIn, 0);
        trades[1] = IRebalanceEngine.TradeOrder(address(base), address(aapl), amountIn, 0);
        vault.rebalance(trades);
        // settler paid `pay` once, AMM paid `pay` once => 2*pay total.
        assertEq(aapl.balanceOf(address(vault)), pay * 2);
    }

    // ===================== balance-delta verification =====================

    // MATRIX: settler paying the wrong recipient reverts
    function test_balanceDelta_wrongRecipient_reverts() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        // Pay the settler itself, not the vault -> vault delta 0.
        _stageBuy(amountIn, amountIn, pay, address(settler));
        vm.expectRevert(MainnetExecutionEngine.InsufficientOutput.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
    }

    // MATRIX: partial payment below effMinOut reverts
    function test_balanceDelta_partialBelowMin_reverts() public {
        uint256 amountIn = 1_000e6;
        uint256 floor = _floor(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, floor - 1, address(vault));
        vm.expectRevert(MainnetExecutionEngine.InsufficientOutput.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
    }

    // MATRIX: residue on engine swept to vault
    function test_balanceDelta_residueSweptToVault() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        // Settler pulls only part of the approved input -> leftover tokenIn on engine.
        uint256 pull = amountIn - 100e6;
        _stageBuy(amountIn, pull, pay, address(vault));

        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));

        // The 100e6 unpulled base is swept back to the vault; engine holds nothing.
        assertEq(base.balanceOf(address(engine)), 0);
        assertEq(aapl.balanceOf(address(engine)), 0);
        assertEq(base.balanceOf(address(vault)), 100e6);
        assertEq(aapl.balanceOf(address(vault)), pay);
    }

    // ===================== daily cap =====================

    // MATRIX: second trade crossing cap reverts; cap resets next day
    function test_dailyCap_crossingCapReverts_thenResetsNextDay() public {
        uint256 amountIn = 1_000e6; // notional == 1_000e6 base
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        engine.setVaultDailyCap(address(vault), 1_500e6); // room for one, not two

        // Trade 1 within cap.
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, pay, address(vault));
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));

        // Trade 2 same day pushes to 2_000e6 > 1_500e6 -> revert.
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, pay, address(vault));
        vm.expectRevert(MainnetExecutionEngine.DailyCapExceeded.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));

        // Next day: window resets, trade succeeds.
        vm.warp(START_TS + 1 days);
        _stageBuy(amountIn, amountIn, pay, address(vault));
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
        assertEq(aapl.balanceOf(address(vault)), pay * 2);
    }

    // MATRIX: cap 0 = unlimited
    function test_dailyCap_zeroMeansUnlimited() public {
        uint256 amountIn = 1_000_000e6; // huge
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        // cap left at default 0
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, pay, address(vault));
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
        assertEq(aapl.balanceOf(address(vault)), pay);
    }

    // ===================== AMM fallback (no stage) =====================

    // MATRIX: AMM fallback path end-to-end
    function test_ammFallback_endToEnd() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        amm.setNextOut(pay);
        // no stage at all
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
        assertEq(aapl.balanceOf(address(vault)), pay);
        assertEq(base.balanceOf(address(engine)), 0);
    }

    // MATRIX: AMM below floor reverts (delta gate applies to AMM path too)
    function test_ammFallback_belowFloor_reverts() public {
        uint256 amountIn = 1_000e6;
        uint256 floor = _floor(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        amm.setNextOut(floor - 1);
        vm.expectRevert(MainnetExecutionEngine.InsufficientOutput.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
    }

    // ===================== Swap event byte-parity =====================

    // MATRIX: Swap event emitted with actualOut and recipient=vault (exact match
    // against ITokenRouter.Swap => compiler-enforced byte parity)
    function test_swapEvent_byteParityWithITokenRouter() public {
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        _stageBuy(amountIn, amountIn, pay, address(vault));

        vm.expectEmit(true, true, true, true, address(engine));
        emit ITokenRouter.Swap(address(base), address(aapl), amountIn, pay, address(vault));
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
    }

    // ===================== proxy V2 =====================

    // MATRIX: executeTradeWithSettlement stages + executes atomically
    function test_proxyV2_executeTradeWithSettlement_atomic() public {
        vault.setDelegate(address(proxy), true);
        engine.setRelayer(address(proxy), true); // proxy stages as the relayer

        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);

        bytes memory data = abi.encodeCall(
            MockSettler.settle, (address(base), address(aapl), amountIn, pay, address(vault))
        );
        vm.prank(signer);
        proxy.executeTradeWithSettlement(
            address(vault), address(base), address(aapl), amountIn, 1, address(settler), data
        );
        assertEq(aapl.balanceOf(address(vault)), pay);
    }

    // MATRIX: plain executeTrade still works (AMM path)
    function test_proxyV2_plainExecuteTrade_ammPath() public {
        vault.setDelegate(address(proxy), true);
        uint256 amountIn = 1_000e6;
        uint256 pay = router.getQuote(address(base), address(aapl), amountIn);
        _fundVault(base, amountIn);
        amm.setNextOut(pay);

        vm.prank(signer);
        proxy.executeTrade(address(vault), address(base), address(aapl), amountIn, 0);
        assertEq(aapl.balanceOf(address(vault)), pay);
    }

    // MATRIX: non-signer proxy call reverts
    function test_proxyV2_nonSigner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(TradeDelegateProxyV2.UnauthorizedSigner.selector);
        proxy.executeTrade(address(vault), address(base), address(aapl), 1e6, 0);
    }

    // ===================== reentrancy =====================

    // MATRIX: malicious settler re-entering executeRebalance reverts
    function test_reentrancy_maliciousSettlerReverts() public {
        MockReentrantSettler evil = new MockReentrantSettler();
        evil.arm(address(engine), address(vault));
        engine.setAllowedSettlementTarget(address(evil), true);

        uint256 amountIn = 1_000e6;
        _fundVault(base, amountIn);
        bytes memory data = abi.encodeCall(
            MockReentrantSettler.settle, (address(base), address(aapl), 0, 0, address(vault))
        );
        vm.prank(relayer);
        engine.stageSettlement(address(vault), address(base), address(aapl), amountIn, address(evil), data);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.rebalance(_order(address(base), address(aapl), amountIn, 0));
    }

    // ===================== factory compatibility =====================

    // tokenRouter() getter selector matches what the factory reads.
    function test_factoryCompat_tokenRouterGetter() public view {
        assertEq(address(engine.tokenRouter()), address(router));
    }

    // setVaultAuthorized callable by an authorized caller (the factory), mirroring
    // the testnet engine.
    function test_factoryCompat_setVaultAuthorizedByCaller() public {
        address factory = makeAddr("factory");
        engine.setAuthorizedCaller(factory, true);
        MockVault v2 = new MockVault(address(engine));
        vm.prank(factory);
        engine.setVaultAuthorized(address(v2), true);
        assertTrue(engine.authorizedVaults(address(v2)));
    }

    function test_setVaultAuthorized_unauthorizedCaller_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(MainnetExecutionEngine.UnauthorizedCaller.selector);
        engine.setVaultAuthorized(address(0x1234), true);
    }

    // ===================== admin / misc =====================

    // ===================== Rider: trades-per-rebalance cap =====================

    // MATRIX: trades.length above the cap reverts (before any pull/settlement)
    function test_maxTradesPerRebalance_capEnforced() public {
        assertEq(engine.maxTradesPerRebalance(), 20);
        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](21);
        for (uint256 i = 0; i < 21; i++) {
            trades[i] = IRebalanceEngine.TradeOrder(address(base), address(aapl), 1e6, 0);
        }
        // Authorized vault caller so the cap check (not the auth check) is what reverts.
        vm.prank(address(vault));
        vm.expectRevert(MainnetExecutionEngine.TooManyTrades.selector);
        engine.executeRebalance(address(vault), trades);
    }

    // MATRIX: owner setter re-caps and takes effect; non-owner blocked
    function test_setMaxTradesPerRebalance_ownerOnlyAndTakesEffect() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        engine.setMaxTradesPerRebalance(5);

        vm.expectEmit(false, false, false, true);
        emit MainnetExecutionEngine.MaxTradesPerRebalanceUpdated(1);
        engine.setMaxTradesPerRebalance(1);
        assertEq(engine.maxTradesPerRebalance(), 1);

        // Two trades now exceed the tightened cap.
        IRebalanceEngine.TradeOrder[] memory trades = new IRebalanceEngine.TradeOrder[](2);
        trades[0] = IRebalanceEngine.TradeOrder(address(base), address(aapl), 1e6, 0);
        trades[1] = IRebalanceEngine.TradeOrder(address(base), address(aapl), 1e6, 0);
        vm.prank(address(vault));
        vm.expectRevert(MainnetExecutionEngine.TooManyTrades.selector);
        engine.executeRebalance(address(vault), trades);
    }

    function test_setMaxSlippage_boundAndOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        engine.setMaxSlippage(200);

        vm.expectRevert(MainnetExecutionEngine.SlippageTooHigh.selector);
        engine.setMaxSlippage(1001);

        engine.setMaxSlippage(300);
        assertEq(engine.maxSlippageBps(), 300);
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert();
        engine.initialize(address(router), address(base), owner);
    }

    function test_zeroAmountTrade_reverts() public {
        _fundVault(base, 1_000e6);
        vm.expectRevert(MainnetExecutionEngine.ZeroAmount.selector);
        vault.rebalance(_order(address(base), address(aapl), 0, 0));
    }

    function test_upgrade_onlyOwner() public {
        MainnetExecutionEngine newImpl = new MainnetExecutionEngine();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        engine.upgradeToAndCall(address(newImpl), "");
        // owner can upgrade and state persists
        engine.upgradeToAndCall(address(newImpl), "");
        assertEq(engine.baseAsset(), address(base));
        assertEq(address(engine.tokenRouter()), address(router));
    }
}
