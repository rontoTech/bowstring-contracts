// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {ForkBase, MockAggregatorV3} from "./ForkBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeManagerUpgradeable} from "../../src/core/FeeManagerUpgradeable.sol";
import {VaultRegistryUpgradeable} from "../../src/core/VaultRegistryUpgradeable.sol";
import {ChainlinkPriceRouter} from "../../src/mainnet/ChainlinkPriceRouter.sol";
import {MainnetExecutionEngine} from "../../src/mainnet/MainnetExecutionEngine.sol";
import {TradeDelegateProxyV2} from "../../src/mainnet/TradeDelegateProxyV2.sol";
import {UserVault} from "../../src/core/UserVault.sol";
import {UserVaultFactoryV2} from "../../src/core/UserVaultFactoryV2.sol";

/// @title Fork0xReplay
/// @notice The live-quote replay the plan calls "Fork0xReplay pre-deploy": pull a
///         REAL firm 0x /quote via ffi and settle it through the REAL staged path
///         (TradeDelegateProxyV2.executeTradeWithSettlement → engine stage →
///         vault.executeTrade → engine consumes stage → 0x AllowanceHolder) on a
///         fork of chain 4663. This is the only place the production settlement
///         calldata path is exercised end-to-end before real money touches it.
///
///         What it empirically proves (all previously paper-verified only):
///         1. taker=vault semantics — AllowanceHolder pulls tokenIn from the
///            ENGINE (real msg.sender) while the bought token lands in the VAULT
///            (mainnet-execution.ts banner's re-verify note).
///         2. The engine's balance-delta verification + residual sweep pass on a
///            real Settler fill, and the Swap event carries the true fill.
///         3. quote.transaction.to is the canonical AllowanceHolder we allowlist.
///
///         Pair: USDG→WETH. Stock tokens are the production pair but still 422
///         TOKEN_NOT_AUTHORIZED_FOR_TRADE on our key (tokenized-equities
///         entitlement pending with 0x, 2026-07-17). The staged-settlement
///         mechanics are token-agnostic; RE-RUN with AAPL once the entitlement
///         lands by flipping REPLAY_BUY_TOKEN=AAPL below via env.
///
///         Gating: needs MAINNET_FORK=true AND ZEROX_REPLAY=true AND --ffi
///         (network + secret key). Use script/fork-0x-replay.sh, or:
///           MAINNET_FORK=true ZEROX_REPLAY=true forge test \
///             --match-contract Fork0xReplay --ffi -vvv
contract Fork0xReplay is ForkBase {
    // Canonical 0x AllowanceHolder on 4663 (== ZEROX_ALLOWANCE_HOLDER in the
    // backend .env.mainnet — this test also validates that config value).
    address internal constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    uint256 internal constant SEED = 1_000e6; // 1,000 USDG
    uint256 internal constant TRADE_IN = 100e6; // 100 USDG buy

    FeeManagerUpgradeable internal feeManager;
    VaultRegistryUpgradeable internal registry;
    ChainlinkPriceRouter internal router;
    MainnetExecutionEngine internal engine;
    TradeDelegateProxyV2 internal delegate;
    UpgradeableBeacon internal beacon;
    UserVaultFactoryV2 internal factory;
    MockAggregatorV3 internal buyFeed;

    address internal creator = makeAddr("creator");
    address internal relayer = makeAddr("relayer");

    bool internal replayEnabled;
    address internal buyToken;

    function setUp() public {
        _initFork();
        if (!forkEnabled) return;
        replayEnabled = vm.envOr("ZEROX_REPLAY", false);
        if (!replayEnabled) return;
        // WETH default; switch to a stock token once the 0x equities
        // entitlement is granted (e.g. REPLAY_BUY_TOKEN=<AAPL addr>).
        buyToken = vm.envOr("REPLAY_BUY_TOKEN", WETH);

        address me = address(this);

        FeeManagerUpgradeable fmImpl = new FeeManagerUpgradeable();
        feeManager = FeeManagerUpgradeable(
            payable(
                address(
                    new ERC1967Proxy(
                        address(fmImpl), abi.encodeCall(FeeManagerUpgradeable.initialize, (me, USDG, me))
                    )
                )
            )
        );
        feeManager.setDefaultFees(0, 0, 0, 0);

        VaultRegistryUpgradeable regImpl = new VaultRegistryUpgradeable();
        registry = VaultRegistryUpgradeable(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(VaultRegistryUpgradeable.initialize, (me))))
        );

        ChainlinkPriceRouter prImpl = new ChainlinkPriceRouter();
        router = ChainlinkPriceRouter(
            address(
                new ERC1967Proxy(address(prImpl), abi.encodeCall(ChainlinkPriceRouter.initialize, (me, USDG)))
            )
        );
        // Provisional price — corrected to the live 0x implied price (setAnswer)
        // before execution so the engine's oracle-anchored minOut floor is
        // exercised against the real fill, not a stale guess.
        buyFeed = new MockAggregatorV3(8, 3_000e8);
        router.setFeed(buyToken, address(buyFeed), 1 days, "REPLAY", false);

        MainnetExecutionEngine engImpl = new MainnetExecutionEngine();
        engine = MainnetExecutionEngine(
            address(
                new ERC1967Proxy(
                    address(engImpl),
                    abi.encodeCall(MainnetExecutionEngine.initialize, (address(router), USDG, me))
                )
            )
        );
        engine.setAllowedToken(buyToken, true);
        engine.setAllowedSettlementTarget(ALLOWANCE_HOLDER, true);

        delegate = new TradeDelegateProxyV2(me, address(engine));
        delegate.setAuthorizedSigner(relayer, true);
        // The proxy is the engine's staging caller (it forwards stageSettlement).
        engine.setRelayer(address(delegate), true);

        UserVault vaultImpl = new UserVault();
        beacon = new UpgradeableBeacon(address(vaultImpl), me);

        UserVaultFactoryV2 facImpl = new UserVaultFactoryV2();
        factory = UserVaultFactoryV2(
            payable(
                address(
                    new ERC1967Proxy(
                        address(facImpl),
                        abi.encodeCall(
                            UserVaultFactoryV2.initialize,
                            (address(beacon), USDG, address(feeManager), address(registry), address(engine), address(router), address(delegate))
                        )
                    )
                )
            )
        );
        address[] memory approved = new address[](1);
        approved[0] = buyToken;
        factory.setApprovedTokensBatch(approved, true);

        registry.setRegistrar(address(factory), true);
        feeManager.setAuthorizedCaller(address(factory), true);
        engine.setAuthorizedCaller(address(factory), true);
        beacon.transferOwnership(address(factory));

        router.setMarketOpen(true);
    }

    // Guarded deal (namespaced-storage tokens can resist cheatcode funding).
    function externalDeal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    function _tryFund(address to, uint256 amount) internal returns (bool) {
        try this.externalDeal(USDG, to, amount) {
            return IERC20(USDG).balanceOf(to) >= amount;
        } catch {
            return false;
        }
    }

    function _skipUnlessReplay() internal returns (bool) {
        if (_skipIfNoFork()) return true;
        if (!replayEnabled) {
            vm.skip(true);
            return true;
        }
        return false;
    }

    function test_replayLiveZeroExQuoteThroughStagedSettlement() public {
        if (_skipUnlessReplay()) return;

        require(_tryFund(creator, SEED), "cannot deal USDG on fork");

        // 1. Create a real vault via the factory (delegate proxy wired in).
        address[] memory tokens = new address[](1);
        tokens[0] = buyToken;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        address vaultAddr = factory.createUserVault("0x Replay", "rPLY", tokens, weights, 0, SEED, "");
        vm.stopPrank();

        // 2. Live firm quote via ffi, taker = THE VAULT (production semantics —
        //    mainnet-execution.ts fetches with taker=vault).
        string[] memory cmd = new string[](7);
        cmd[0] = "bash";
        cmd[1] = "script/ffi/fetch-0x-quote.sh";
        cmd[2] = vm.toString(USDG);
        cmd[3] = vm.toString(buyToken);
        cmd[4] = vm.toString(TRADE_IN);
        cmd[5] = vm.toString(vaultAddr);
        cmd[6] = "50";
        bytes memory encoded = vm.ffi(cmd);
        (address to, bytes memory swapData, uint256 buyAmount, uint256 minBuyAmount) =
            abi.decode(encoded, (address, bytes, uint256, uint256));

        console.log("0x quote: buyAmount", buyAmount);
        console.log("0x quote: minBuyAmount", minBuyAmount);
        console.log("0x quote: settlement target", to);

        // 3. The quote must settle through the AllowanceHolder we allowlist in
        //    production — if 0x ever routes 4663 elsewhere, fail HERE, not on
        //    mainnet with TargetNotAllowed.
        assertEq(to, ALLOWANCE_HOLDER, "0x transaction.to != canonical AllowanceHolder");

        // 4. Align the mock feed with the live implied price so the engine's
        //    oracle-anchored floor (150bps) is a REAL constraint on this fill.
        //    getQuote(USDG 6dec -> buy 18dec): out = in * priceIn * 1e12 / priceOut
        //    => priceOut(18d) = in * 1e30 / buyAmount; feed answer is 8-dec.
        uint256 implied18 = (TRADE_IN * 1e30) / buyAmount;
        buyFeed.setAnswer(int256(implied18 / 1e10));

        uint256 vaultUsdgBefore = IERC20(USDG).balanceOf(vaultAddr);
        uint256 vaultBuyBefore = IERC20(buyToken).balanceOf(vaultAddr);

        // 5. Replay through the production entrypoint. Topics checked (tokenIn,
        //    tokenOut, recipient=vault); amountOut asserted from balances below.
        vm.expectEmit(true, true, true, false, address(engine));
        emit MainnetExecutionEngine.Swap(USDG, buyToken, TRADE_IN, 0, vaultAddr);
        vm.prank(relayer);
        delegate.executeTradeWithSettlement(
            vaultAddr, USDG, buyToken, TRADE_IN, minBuyAmount, to, swapData
        );

        // 6. Fill verification — the exact properties the backend fill parser
        //    and the engine's delta check rely on.
        uint256 got = IERC20(buyToken).balanceOf(vaultAddr) - vaultBuyBefore;
        assertGe(got, minBuyAmount, "fill below 0x minBuyAmount");
        assertEq(
            vaultUsdgBefore - IERC20(USDG).balanceOf(vaultAddr),
            TRADE_IN,
            "vault spent != amountIn"
        );
        assertEq(IERC20(USDG).balanceOf(address(engine)), 0, "USDG residual on engine");
        assertEq(IERC20(buyToken).balanceOf(address(engine)), 0, "buy-token residual on engine");
        (bytes32 orderHash,,,) = engine.stagedSettlement(vaultAddr);
        assertEq(orderHash, bytes32(0), "stage not consumed");

        console.log("REPLAY OK: vault received", got);
        console.log("  (taker=vault semantics + balance-delta + sweep verified on live calldata)");
    }
}
