// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseVault} from "../../src/core/BaseVault.sol";
import {UserVault} from "../../src/core/UserVault.sol";
import {FeeManager} from "../../src/core/FeeManager.sol";
import {TokenRouterUpgradeable} from "../../src/rebalance/TokenRouterUpgradeable.sol";
import {RebalanceEngineUpgradeable} from "../../src/rebalance/RebalanceEngineUpgradeable.sol";
import {ChainlinkPriceRouter} from "../../src/mainnet/ChainlinkPriceRouter.sol";
import {MockStockToken, TiltUSDC} from "../../src/tokens/MockStockToken.sol";
import {IBaseVault} from "../../src/interfaces/IBaseVault.sol";

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

/// @notice ERC-20 stock stub whose plain transfers can be switched off to
///         simulate a transfer-restricted (e.g. frozen/blocklisted) token, while
///         mint/burn stay open so the router can settle into it. Blocking only
///         real transfers (from != 0 && to != 0) leaves mint/burn working.
contract MockRestrictedToken is ERC20 {
    uint8 private _dec;
    bool public blockTransfers;
    address public owner;
    mapping(address => bool) public minters;

    error NotMinter();
    error TransferBlocked();

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
        owner = msg.sender;
        minters[msg.sender] = true;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function addMinter(address m) external {
        require(msg.sender == owner, "not owner");
        minters[m] = true;
    }

    function setBlockTransfers(bool b) external {
        blockTransfers = b;
    }

    function mint(address to, uint256 amt) external {
        if (!minters[msg.sender]) revert NotMinter();
        _mint(to, amt);
    }

    function burn(address from, uint256 amt) external {
        if (!minters[msg.sender]) revert NotMinter();
        _burn(from, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blockTransfers && from != address(0) && to != address(0)) revert TransferBlocked();
        super._update(from, to, value);
    }
}

// ===================== Tests =====================

/// @title VaultMarketGateTest
/// @notice C3: BaseVault deposit market-gate probe + emergencyWithdraw escrow.
///         Exercises the real testnet TokenRouterUpgradeable (catch path) and the
///         real ChainlinkPriceRouter (gate path), plus the failed-transfer escrow
///         accounting and its NAV invariant.
contract VaultMarketGateTest is Test {
    uint256 internal constant START_TS = 1_750_000_000;
    uint256 internal constant DEPOSIT = 10_000e6;

    address public owner = address(this); // FeeManager + router + engine owner
    address public treasury = makeAddr("treasury");
    address public curator = makeAddr("curator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 internal permitPk = 0xA11CE;
    address internal permitUser; // derived from permitPk

    TiltUSDC public usdc; // base, 6-dec, EIP-2612
    MockStockToken public good; // 18-dec, transfers always succeed
    MockRestrictedToken public restricted; // 18-dec, transfers can be blocked

    FeeManager public feeManager;
    TokenRouterUpgradeable public tnRouter; // real testnet router (no depositsOpen)
    RebalanceEngineUpgradeable public engine;
    ChainlinkPriceRouter public chainlink; // real mainnet market-gate router

    MockAggregatorV3 public goodFeed;
    MockAggregatorV3 public restrictedFeed;

    UserVault public vault; // wired to the testnet router by default

    function setUp() public {
        vm.warp(START_TS);
        permitUser = vm.addr(permitPk);

        usdc = new TiltUSDC();
        good = new MockStockToken("Good Co", "GOOD", 18);
        restricted = new MockRestrictedToken("Restricted Co", "RST", 18);

        feeManager = new FeeManager(treasury, address(usdc));
        feeManager.setDefaultFees(0, 0, 0, 0);

        // --- Real testnet router (behind a proxy) ---
        TokenRouterUpgradeable routerImpl = new TokenRouterUpgradeable();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl), abi.encodeCall(TokenRouterUpgradeable.initialize, (owner, address(usdc)))
        );
        tnRouter = TokenRouterUpgradeable(address(routerProxy));
        tnRouter.setTokenPrice(address(usdc), 1e18);
        tnRouter.setTokenPrice(address(good), 100e18);
        tnRouter.setTokenPrice(address(restricted), 50e18);
        tnRouter.setPairSupported(address(usdc), address(good), true);
        tnRouter.setPairSupported(address(usdc), address(restricted), true);

        // --- Real rebalance engine (behind a proxy) ---
        RebalanceEngineUpgradeable engineImpl = new RebalanceEngineUpgradeable();
        ERC1967Proxy engineProxy = new ERC1967Proxy(
            address(engineImpl),
            abi.encodeCall(RebalanceEngineUpgradeable.initialize, (address(tnRouter), address(usdc), owner))
        );
        engine = RebalanceEngineUpgradeable(address(engineProxy));
        tnRouter.setAuthorizedCaller(address(engine), true);

        // Minting rights so the mint/burn router can settle swaps.
        usdc.addMinter(address(tnRouter));
        good.addMinter(address(tnRouter));
        restricted.addMinter(address(tnRouter));

        // --- Real mainnet market-gate router (behind a proxy) ---
        ChainlinkPriceRouter clImpl = new ChainlinkPriceRouter();
        ERC1967Proxy clProxy = new ERC1967Proxy(
            address(clImpl), abi.encodeCall(ChainlinkPriceRouter.initialize, (owner, address(usdc)))
        );
        chainlink = ChainlinkPriceRouter(address(clProxy));
        goodFeed = new MockAggregatorV3(8, 100e8);
        restrictedFeed = new MockAggregatorV3(8, 50e8);
        chainlink.setFeed(address(good), address(goodFeed), 1 hours, "GOOD", false);
        chainlink.setFeed(address(restricted), address(restrictedFeed), 1 hours, "RST", false);
        chainlink.setMarketOpen(true);

        vault = _newVault();

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(permitUser, 1_000_000e6);
    }

    // ===================== helpers =====================

    function _newVault() internal returns (UserVault v) {
        address[] memory approved = new address[](2);
        approved[0] = address(good);
        approved[1] = address(restricted);

        IBaseVault.TokenWeight[] memory weights = new IBaseVault.TokenWeight[](2);
        weights[0] = IBaseVault.TokenWeight({token: address(good), weightBps: 6000});
        weights[1] = IBaseVault.TokenWeight({token: address(restricted), weightBps: 4000});

        UserVault impl = new UserVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                UserVault.initialize,
                (
                    "Vault",
                    "vV",
                    address(usdc),
                    address(feeManager),
                    address(engine),
                    address(tnRouter),
                    curator,
                    approved,
                    0, // timelock
                    0, // minRebalanceInterval (unused)
                    weights
                )
            )
        );
        v = UserVault(address(proxy));
        engine.setVaultAuthorized(address(v), true);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Curator buys `amountIn` base into `token` (minOut 0 for test simplicity).
    function _curatorBuy(address token, uint256 amountIn) internal {
        vm.prank(curator);
        vault.executeTrade(address(usdc), token, amountIn, 0);
    }

    /// @dev Switch the vault's router to the Chainlink market gate. The test
    ///      contract is the FeeManager owner (protocol admin) so the change is
    ///      instant (no timelock).
    function _switchToChainlink() internal {
        vault.setTokenRouter(address(chainlink));
        assertEq(address(vault.tokenRouter()), address(chainlink));
    }

    /// @dev Build a vault holding base + good + restricted, with alice and bob
    ///      each owning half the supply. Deterministic: base 15_000e6, good 30e18
    ///      ($3_000), restricted 40e18 ($2_000); NAV 20_000e6, sharePrice 1e18.
    function _seedMixedVault() internal {
        _deposit(alice, DEPOSIT); // 10_000e6 base, 10_000e6 shares
        _deposit(bob, DEPOSIT); //   10_000e6 base, 10_000e6 shares
        _curatorBuy(address(good), 3_000e6); // -> 30e18 good
        _curatorBuy(address(restricted), 2_000e6); // -> 40e18 restricted
    }

    function _signPermit(uint256 pk, address ownerAddr, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, ownerAddr, spender, value, usdc.nonces(ownerAddr), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    // ===================== catch path: real testnet router =====================

    // The testnet TokenRouterUpgradeable does NOT implement depositsOpen(): the
    // staticcall reverts on the missing selector and lands in catch, so the probe
    // is a no-op and deposits proceed exactly as before this change.
    function test_catchPath_tnRouterHasNoDepositsOpen() public view {
        (bool ok,) = address(tnRouter).staticcall(abi.encodeWithSignature("depositsOpen()"));
        assertFalse(ok, "testnet router must not answer depositsOpen()");
    }

    function test_catchPath_depositSucceeds() public {
        uint256 shares = _deposit(alice, DEPOSIT);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_catchPath_depositAndAllocateSucceeds() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        uint256 shares = vault.depositAndAllocate(DEPOSIT, alice);
        vm.stopPrank();
        assertGt(shares, 0);
        assertGt(good.balanceOf(address(vault)), 0, "allocated into good");
        assertGt(restricted.balanceOf(address(vault)), 0, "allocated into restricted");
    }

    function test_catchPath_depositWithPermitSucceeds() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(permitPk, permitUser, address(vault), DEPOSIT, deadline);
        vm.prank(permitUser);
        uint256 shares = vault.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(permitUser), shares);
    }

    // ===================== gate path: real ChainlinkPriceRouter =====================

    function test_gate_depositWorksWhenOpen() public {
        _switchToChainlink();
        assertTrue(chainlink.depositsOpen());
        uint256 shares = _deposit(alice, DEPOSIT);
        assertGt(shares, 0);
    }

    function test_gate_depositRevertsWhenClosed() public {
        _switchToChainlink();
        chainlink.setMarketOpen(false);
        assertFalse(chainlink.depositsOpen());

        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        vm.expectRevert(BaseVault.MarketClosed.selector);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    function test_gate_depositRecoversWhenReopened() public {
        _switchToChainlink();
        chainlink.setMarketOpen(false);
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        vm.expectRevert(BaseVault.MarketClosed.selector);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        chainlink.setMarketOpen(true);
        uint256 shares = _deposit(alice, DEPOSIT);
        assertGt(shares, 0);
    }

    function test_gate_depositWithPermitAlsoGated() public {
        _switchToChainlink();
        chainlink.setMarketOpen(false);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(permitPk, permitUser, address(vault), DEPOSIT, deadline);
        vm.prank(permitUser);
        vm.expectRevert(BaseVault.MarketClosed.selector);
        vault.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_gate_depositAndAllocateAlsoGated() public {
        _switchToChainlink();
        chainlink.setMarketOpen(false);

        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT);
        vm.expectRevert(BaseVault.MarketClosed.selector);
        vault.depositAndAllocate(DEPOSIT, alice);
        vm.stopPrank();
    }

    function test_gate_withdrawWorksWhileClosed() public {
        _switchToChainlink();
        _deposit(alice, DEPOSIT); // while open
        chainlink.setMarketOpen(false);
        assertFalse(chainlink.depositsOpen());

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(DEPOSIT / 2, alice, alice);
        assertEq(usdc.balanceOf(alice) - balBefore, DEPOSIT / 2, "net assets received while closed");
    }

    function test_gate_redeemWorksWhileClosed() public {
        _switchToChainlink();
        uint256 shares = _deposit(alice, DEPOSIT);
        chainlink.setMarketOpen(false);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares / 2, alice, alice);
        assertGt(assets, 0);
        assertEq(usdc.balanceOf(alice) - balBefore, assets);
    }

    function test_gate_emergencyWithdrawWorksWhileClosed() public {
        _switchToChainlink();
        _deposit(alice, DEPOSIT);
        chainlink.setMarketOpen(false);

        vm.prank(alice);
        vault.emergencyWithdraw();
        assertEq(vault.balanceOf(alice), 0, "shares burned while market closed");
    }

    // ===================== emergency escrow accounting =====================

    function test_emergency_restrictedTokenEscrowed() public {
        _seedMixedVault();
        restricted.setBlockTransfers(true);

        uint256 aliceBaseBefore = usdc.balanceOf(alice);

        // Expected pro-rata (alice owns 50% of supply): base 7_500e6, good 15e18,
        // restricted 20e18 (escrowed).
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaseVault.EmergencyTransferFailed(alice, address(restricted), 20e18);

        vm.prank(alice);
        vault.emergencyWithdraw();

        // Shares burned exactly once.
        assertEq(vault.balanceOf(alice), 0, "alice shares burned");
        // Base + good delivered in kind; restricted NOT delivered.
        assertEq(usdc.balanceOf(alice) - aliceBaseBefore, 7_500e6, "base delivered");
        assertEq(good.balanceOf(alice), 15e18, "good delivered");
        assertEq(restricted.balanceOf(alice), 0, "restricted not delivered");
        // Escrow recorded once.
        assertEq(vault.unclaimedEmergency(alice, address(restricted)), 20e18, "escrow recorded");
        assertEq(vault.totalUnclaimed(address(restricted)), 20e18, "totalUnclaimed tracked");
        // The escrowed tokens still physically sit on the vault.
        assertEq(restricted.balanceOf(address(vault)), 40e18, "escrow held on vault");
    }

    // NAV invariant: whether the restricted token is delivered (control) or
    // escrowed-and-excluded (treatment), the remaining holder's share price and
    // the vault NAV must be identical — the escrow is accounted out exactly once.
    function test_emergency_navInvariantForRemainingHolder() public {
        // --- Control vault A: restricted delivers normally ---
        UserVault a = vault; // default vault
        _seedMixedVault();
        uint256 preSharePrice = a.sharePrice();
        assertEq(preSharePrice, 1e18, "clean 1:1 setup");

        restricted.setBlockTransfers(false);
        vm.prank(alice);
        a.emergencyWithdraw();
        uint256 aSharePrice = a.sharePrice();
        uint256 aNav = a.totalAssets();

        // --- Treatment vault B: identical, but restricted transfer is blocked ---
        vault = _newVault();
        _seedMixedVault();
        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();
        uint256 bSharePrice = vault.sharePrice();
        uint256 bNav = vault.totalAssets();

        // Remaining holder (bob) is unaffected by the escrow: identical outcomes.
        assertEq(bSharePrice, aSharePrice, "share price identical whether delivered or escrowed");
        assertEq(bNav, aNav, "NAV identical whether delivered or escrowed");
        // And unchanged from before alice exited (pro-rata exit is price-neutral).
        assertEq(bSharePrice, preSharePrice, "remaining holder share price unchanged");
    }

    function test_emergency_claimAfterRestrictionLifted() public {
        _seedMixedVault();
        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();
        assertEq(vault.totalUnclaimed(address(restricted)), 20e18);

        // Restriction lifts; alice claims the escrowed tokens.
        restricted.setBlockTransfers(false);
        vm.prank(alice);
        uint256 claimed = vault.claimEmergencyTokens(address(restricted));

        assertEq(claimed, 20e18, "claimed escrowed amount");
        assertEq(restricted.balanceOf(alice), 20e18, "tokens delivered on claim");
        assertEq(vault.unclaimedEmergency(alice, address(restricted)), 0, "escrow cleared");
        assertEq(vault.totalUnclaimed(address(restricted)), 0, "totalUnclaimed cleared");
    }

    function test_emergency_claimStillRestricted_revertsAndKeepsEscrow() public {
        _seedMixedVault();
        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();

        // Still restricted: claim reverts and escrow is preserved for a retry.
        vm.prank(alice);
        vm.expectRevert(MockRestrictedToken.TransferBlocked.selector);
        vault.claimEmergencyTokens(address(restricted));

        assertEq(vault.unclaimedEmergency(alice, address(restricted)), 20e18, "escrow preserved after failed claim");
        assertEq(vault.totalUnclaimed(address(restricted)), 20e18, "totalUnclaimed preserved");
    }

    function test_emergency_secondClaimIsNoOp() public {
        _seedMixedVault();
        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();

        restricted.setBlockTransfers(false);
        vm.prank(alice);
        vault.claimEmergencyTokens(address(restricted));

        // Second claim: nothing left, returns 0 and moves no tokens.
        vm.prank(alice);
        uint256 second = vault.claimEmergencyTokens(address(restricted));
        assertEq(second, 0, "second claim is a no-op");
        assertEq(restricted.balanceOf(alice), 20e18, "no double delivery");
    }

    // Two users both escrow the same token: totalUnclaimed accumulates and
    // _totalAssets excludes the sum exactly once (no phantom NAV).
    function test_emergency_multiUserEscrowExcludedFromNavOnce() public {
        _seedMixedVault();
        restricted.setBlockTransfers(true);

        vm.prank(alice);
        vault.emergencyWithdraw(); // escrows 20e18 (alice's 50%)
        vm.prank(bob);
        vault.emergencyWithdraw(); // escrows the remaining 20e18 (bob's 100% of rest)

        assertEq(vault.totalUnclaimed(address(restricted)), 40e18, "both escrows summed");
        assertEq(restricted.balanceOf(address(vault)), 40e18, "all restricted still on vault");
        // Entire remaining vault value is escrowed -> NAV excludes it -> 0.
        assertEq(vault.totalAssets(), 0, "escrow excluded from NAV exactly once");

        // Both users can claim once the restriction lifts.
        restricted.setBlockTransfers(false);
        vm.prank(alice);
        assertEq(vault.claimEmergencyTokens(address(restricted)), 20e18);
        vm.prank(bob);
        assertEq(vault.claimEmergencyTokens(address(restricted)), 20e18);
        assertEq(vault.totalUnclaimed(address(restricted)), 0);
        assertEq(restricted.balanceOf(alice), 20e18);
        assertEq(restricted.balanceOf(bob), 20e18);
    }

    // ===================== escrow reserved from sell paths (review fix) =====================

    // Reviewer repro (Critical): TEMPORARY halt. (1) token frozen -> alice
    // emergencyWithdraw escrows 20e18 (40e18 physically on vault); (2) token
    // UNFREEZES; (3) bob withdraw() triggers _ensureBaseLiquidity. Pre-fix the
    // sell used the RAW balanceOf and burned the position below the escrow, so
    // (4) alice's claim reverted forever — her assets had gone to bob. Post-fix
    // only the 20e18 NON-escrowed tokens are sellable and the claim transfers
    // exactly 20e18. All amounts wei-exact.
    function test_escrowReserved_unfreezeThenWithdrawThenClaim() public {
        _seedMixedVault(); // base 15_000e6, good 30e18 ($3_000), restricted 40e18 ($2_000)

        // (1) frozen -> alice's emergency exit escrows her 20e18 restricted.
        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();
        assertEq(vault.totalUnclaimed(address(restricted)), 20e18);
        assertEq(restricted.balanceOf(address(vault)), 40e18, "all restricted still on vault");
        assertEq(vault.sharePrice(), 1e18, "bob unaffected by escrow");

        // (2) restriction lifts.
        restricted.setBlockTransfers(false);
        assertEq(vault.sharePrice(), 1e18, "bob unaffected by unfreeze");

        // (3) bob withdraws his full 10_000e6. Deficit 2_500e6 is covered by
        // selling ALL 15e18 good ($1_500) plus exactly the 20e18 non-escrowed
        // restricted ($1_000) — never the escrow.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(10_000e6, bob, bob);
        assertEq(usdc.balanceOf(bob) - bobBefore, 10_000e6, "bob receives full value");
        assertEq(good.balanceOf(address(vault)), 0, "good fully sold");
        assertEq(
            restricted.balanceOf(address(vault)),
            20e18,
            "escrow physically reserved: exactly the escrowed 20e18 remain"
        );

        // (4) alice's claim succeeds, wei-exact.
        vm.prank(alice);
        uint256 claimed = vault.claimEmergencyTokens(address(restricted));
        assertEq(claimed, 20e18, "claim transfers exactly the escrowed amount");
        assertEq(restricted.balanceOf(alice), 20e18, "alice made whole");
        assertEq(restricted.balanceOf(address(vault)), 0);
        assertEq(vault.totalUnclaimed(address(restricted)), 0);
    }

    // Ordering flipped: unfreeze -> alice claims FIRST -> bob withdraws. The
    // claim is NAV-neutral (escrow and balance leave together) and bob's
    // liquidity path then sells his 20e18 normally.
    function test_escrowReserved_unfreezeThenClaimThenWithdraw() public {
        _seedMixedVault();
        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();

        restricted.setBlockTransfers(false);
        vm.prank(alice);
        assertEq(vault.claimEmergencyTokens(address(restricted)), 20e18);
        assertEq(restricted.balanceOf(address(vault)), 20e18, "bob's 20e18 remain, none escrowed");
        assertEq(vault.sharePrice(), 1e18, "claim is NAV-neutral");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(10_000e6, bob, bob);
        assertEq(usdc.balanceOf(bob) - bobBefore, 10_000e6, "bob receives full value");
        assertEq(restricted.balanceOf(address(vault)), 0, "bob's restricted sellable after claim");
    }

    // sharePrice neutrality for the remaining holder at EVERY step of the
    // freeze -> emergency -> unfreeze -> claim sequence, then a full-value redeem.
    function test_escrowReserved_sharePriceNeutralAcrossSequence() public {
        _seedMixedVault();
        assertEq(vault.sharePrice(), 1e18);

        restricted.setBlockTransfers(true);
        vm.prank(alice);
        vault.emergencyWithdraw();
        assertEq(vault.sharePrice(), 1e18, "after escrowing emergency exit");

        restricted.setBlockTransfers(false);
        assertEq(vault.sharePrice(), 1e18, "after unfreeze");

        vm.prank(alice);
        vault.claimEmergencyTokens(address(restricted));
        assertEq(vault.sharePrice(), 1e18, "after claim");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(10_000e6, bob, bob);
        assertEq(usdc.balanceOf(bob) - bobBefore, 10_000e6, "bob redeems every share at 1:1");
    }

    // Sanity: with no failed transfers, emergencyWithdraw delivers everything in
    // kind and records no escrow (zero behavior change vs the old path).
    function test_emergency_noEscrowWhenAllTransfersSucceed() public {
        _seedMixedVault();
        // restricted transfers enabled (default)
        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(good.balanceOf(alice), 15e18, "good delivered");
        assertEq(restricted.balanceOf(alice), 20e18, "restricted delivered");
        assertEq(vault.totalUnclaimed(address(restricted)), 0, "no escrow");
        assertEq(vault.unclaimedEmergency(alice, address(restricted)), 0, "no escrow");
    }
}
