// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRebalanceEngine} from "../interfaces/IRebalanceEngine.sol";
import {ITokenRouter} from "../interfaces/ITokenRouter.sol";

/// @notice AMM fallback router surface. Not part of the frozen public ABI —
///         wired to a Uniswap-style venue (or an adapter) via config. Exact-input
///         semantics: pulls exactly `amountIn` of `tokenIn` from the caller and
///         pays `tokenOut` to `recipient`. `path` is the venue's opaque route.
interface IAmmRouter {
    function exactInput(
        bytes calldata path,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) external returns (uint256 amountOut);
}

/// @title MainnetExecutionEngine
/// @notice Mainnet settlement layer replacing `RebalanceEngineUpgradeable`.
///         Vaults call `executeRebalance` exactly as today; settlement happens
///         either through relayer-staged external calldata (0x RFQ) or a
///         configured AMM fallback route — never mint/burn. Every fill is
///         verified against the VAULT's balance delta and floored by an
///         oracle-anchored minimum read from the ChainlinkPriceRouter.
///
///         Public surface parity (docs/mainnet-execution-abi.md, FROZEN):
///         - `Swap` event byte-identical to `ITokenRouter.Swap`.
///         - `TradeOrder` + `executeRebalance` + `RebalanceExecuted` identical
///           to `IRebalanceEngine`.
///         - `tokenRouter()` getter satisfies `UserVaultFactoryV2` RouterDrift.
///         - `setVaultAuthorized(address,bool)` mirrors the testnet engine so
///           `UserVaultFactoryV2._createVault` authorizes new vaults unchanged.
contract MainnetExecutionEngine is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // TradeOrder is reused from IRebalanceEngine so the calldata layout of
    // executeRebalance stays byte-identical to the testnet engine.
    struct StagedSettlement {
        bytes32 orderHash;
        address target;
        bytes data;
        uint256 stagedBlock;
        address stagedBy;
    }

    struct DailySpend {
        uint256 day;
        uint256 spent;
    }

    // ===================== Storage (append-only) =====================

    /// @notice Oracle-only pricing source (ChainlinkPriceRouter). Read for the
    ///         minOut floor; satisfies the factory's `tokenRouter()` drift check.
    ITokenRouter public tokenRouter;
    /// @notice Base asset (USDG on mainnet).
    address public baseAsset;

    mapping(address => bool) public authorizedVaults;
    /// @notice Addresses (the factory) allowed to authorize vaults.
    mapping(address => bool) public authorizedCallers;
    /// @notice Backend relayers allowed to stage settlement calldata.
    mapping(address => bool) public authorizedRelayers;
    /// @notice Buy-side allowlist: a token must be here to be bought (tokenOut).
    ///         Sells (tokenOut == baseAsset) bypass this so delisting exits work.
    mapping(address => bool) public allowedTokens;
    /// @notice Settlement targets a stage may point at (0x Settler/AllowanceHolder).
    mapping(address => bool) public allowedSettlementTargets;

    /// @notice AMM fallback router (Uniswap-style venue / adapter).
    address public ammRouter;
    /// @notice Per (non-base) token abi-encoded swap path for token<->baseAsset;
    ///         empty bytes = no AMM fallback for that token.
    mapping(address => bytes) public ammRoute;

    /// @notice Oracle-anchored slippage floor tolerance in bps (init 150 = 1.5%).
    uint256 public maxSlippageBps;

    /// @notice Per-vault daily notional cap in base terms (0 = uncapped).
    mapping(address => uint256) public vaultDailyCapBase;
    /// @notice Per-vault rolling day-window spend accounting.
    mapping(address => DailySpend) public dailySpend;

    /// @notice At most one staged settlement per vault, consumable same-block.
    mapping(address => StagedSettlement) internal staged;

    /// @notice Sanity cap on the number of trades per `executeRebalance` call
    ///         (init 20, owner-tunable). Parity with
    ///         RebalanceEngineUpgradeable.maxTradesPerRebalance — bounds gas and
    ///         blast radius of a single rebalance.
    uint256 public maxTradesPerRebalance;

    // ===================== Events =====================

    /// @dev FROZEN: byte-identical to ITokenRouter.Swap. `recipient` is always
    ///      the vault; `amountOut` is the verified vault balance delta.
    event Swap(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );
    /// @dev FROZEN: identical to IRebalanceEngine.RebalanceExecuted.
    event RebalanceExecuted(address indexed vault, IRebalanceEngine.TradeOrder[] trades);

    event RouterUpdated(address indexed newRouter);
    event BaseAssetUpdated(address indexed newBaseAsset);
    event VaultAuthorized(address indexed vault, bool authorized);
    event CallerAuthorized(address indexed caller, bool authorized);
    event RelayerAuthorized(address indexed relayer, bool authorized);
    event TokenAllowed(address indexed token, bool allowed);
    event SettlementTargetAllowed(address indexed target, bool allowed);
    event AmmRouterUpdated(address indexed router);
    event AmmRouteUpdated(address indexed token, bytes path);
    event SlippageUpdated(uint256 newSlippageBps);
    event MaxTradesPerRebalanceUpdated(uint256 maxTrades);
    event VaultDailyCapUpdated(address indexed vault, uint256 capBase);
    event SettlementStaged(address indexed vault, bytes32 orderHash, address indexed target, address indexed relayer);
    event TokensSwept(address indexed token, address indexed vault, uint256 amount);

    // ===================== Errors =====================

    error UnauthorizedVault();
    error UnauthorizedRelayer();
    error UnauthorizedCaller();
    error RouterNotSet();
    error TokenNotAllowed();
    error TargetNotAllowed();
    error SlippageTooHigh();
    error TooManyTrades();
    error DailyCapExceeded();
    error NoRoute();
    error InsufficientOutput();
    error ZeroAddress();
    error ZeroAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Signature mirrors RebalanceEngineUpgradeable.initialize for deploy parity.
    function initialize(address tokenRouter_, address baseAsset_, address owner_) external initializer {
        __Ownable_init(owner_);
        if (tokenRouter_ == address(0) || baseAsset_ == address(0)) revert ZeroAddress();
        tokenRouter = ITokenRouter(tokenRouter_);
        baseAsset = baseAsset_;
        maxSlippageBps = 150;
        maxTradesPerRebalance = 20;
    }

    // ===================== Admin =====================

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        tokenRouter = ITokenRouter(router_);
        emit RouterUpdated(router_);
    }

    function setBaseAsset(address baseAsset_) external onlyOwner {
        if (baseAsset_ == address(0)) revert ZeroAddress();
        baseAsset = baseAsset_;
        emit BaseAssetUpdated(baseAsset_);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit CallerAuthorized(caller, authorized);
    }

    /// @notice Authorize/deauthorize a vault. Callable by the owner or an
    ///         authorized caller (the factory), mirroring the testnet engine's
    ///         exact signature so `UserVaultFactoryV2._createVault` works unchanged.
    function setVaultAuthorized(address vault, bool authorized) external {
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        authorizedVaults[vault] = authorized;
        emit VaultAuthorized(vault, authorized);
    }

    function setRelayer(address relayer, bool authorized) external onlyOwner {
        authorizedRelayers[relayer] = authorized;
        emit RelayerAuthorized(relayer, authorized);
    }

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        allowedTokens[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setAllowedSettlementTarget(address target, bool allowed) external onlyOwner {
        allowedSettlementTargets[target] = allowed;
        emit SettlementTargetAllowed(target, allowed);
    }

    function setAmmRouter(address router_) external onlyOwner {
        ammRouter = router_;
        emit AmmRouterUpdated(router_);
    }

    function setAmmRoute(address token, bytes calldata path) external onlyOwner {
        ammRoute[token] = path;
        emit AmmRouteUpdated(token, path);
    }

    function setMaxSlippage(uint256 slippageBps) external onlyOwner {
        if (slippageBps > 1000) revert SlippageTooHigh();
        maxSlippageBps = slippageBps;
        emit SlippageUpdated(slippageBps);
    }

    function setMaxTradesPerRebalance(uint256 maxTrades) external onlyOwner {
        maxTradesPerRebalance = maxTrades;
        emit MaxTradesPerRebalanceUpdated(maxTrades);
    }

    function setVaultDailyCap(address vault, uint256 capBase) external onlyOwner {
        vaultDailyCapBase[vault] = capBase;
        emit VaultDailyCapUpdated(vault, capBase);
    }

    // ===================== Relayer =====================

    /// @notice Stage external settlement calldata for a vault's next trade.
    ///         Consumable only within the same block by `executeRebalance` when
    ///         the (vault, tokenIn, tokenOut, amountIn) tuple matches. Overwrites
    ///         any prior stage for the vault.
    function stageSettlement(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address target,
        bytes calldata data
    ) external {
        if (!authorizedRelayers[msg.sender]) revert UnauthorizedRelayer();
        if (!allowedSettlementTargets[target]) revert TargetNotAllowed();

        bytes32 orderHash = keccak256(abi.encode(vault, tokenIn, tokenOut, amountIn));
        staged[vault] = StagedSettlement({
            orderHash: orderHash,
            target: target,
            data: data,
            stagedBlock: block.number,
            stagedBy: msg.sender
        });
        emit SettlementStaged(vault, orderHash, target, msg.sender);
    }

    // ===================== Core execution =====================

    /// @notice Execute settlement for a vault's trades. Same auth invariant as
    ///         the testnet engine: only the vault itself, and only if authorized.
    function executeRebalance(address vault, IRebalanceEngine.TradeOrder[] calldata trades)
        external
        nonReentrant
    {
        if (msg.sender != vault) revert UnauthorizedVault();
        if (!authorizedVaults[vault]) revert UnauthorizedVault();
        if (trades.length > maxTradesPerRebalance) revert TooManyTrades();
        if (address(tokenRouter) == address(0)) revert RouterNotSet();

        uint256 today = block.timestamp / 1 days;
        for (uint256 i = 0; i < trades.length; i++) {
            _executeTrade(vault, trades[i], today);
        }

        emit RebalanceExecuted(vault, trades);
    }

    function _executeTrade(address vault, IRebalanceEngine.TradeOrder calldata trade, uint256 today) internal {
        address tokenIn = trade.tokenIn;
        address tokenOut = trade.tokenOut;
        uint256 amountIn = trade.amountIn;
        if (amountIn == 0) revert ZeroAmount();

        bool isSell = (tokenOut == baseAsset);
        // Buys require the allowlist; sells are always allowed (delisting exits).
        if (!isSell && !allowedTokens[tokenOut]) revert TokenNotAllowed();

        // Oracle-anchored floor: never settle below the quoted value minus tolerance.
        uint256 quotedOut = tokenRouter.getQuote(tokenIn, tokenOut, amountIn);
        uint256 floor = (quotedOut * (10_000 - maxSlippageBps)) / 10_000;
        uint256 effMinOut = trade.minAmountOut > floor ? trade.minAmountOut : floor;

        // Daily notional cap (base terms). Accounted BEFORE any external call (CEI).
        uint256 cap = vaultDailyCapBase[vault];
        if (cap != 0) {
            uint256 notional =
                (tokenIn == baseAsset) ? amountIn : tokenRouter.getQuote(tokenIn, baseAsset, amountIn);
            DailySpend storage ds = dailySpend[vault];
            uint256 spent = ds.day == today ? ds.spent : 0;
            if (spent + notional > cap) revert DailyCapExceeded();
            ds.day = today;
            ds.spent = spent + notional;
        }

        // Pull exactly amountIn from the vault (vault pre-approved exactly this).
        IERC20(tokenIn).safeTransferFrom(vault, address(this), amountIn);

        // Measure on the VAULT, not the engine — settlement must pay the vault.
        uint256 balBefore = IERC20(tokenOut).balanceOf(vault);

        StagedSettlement memory s = staged[vault];
        bytes32 wantHash = keccak256(abi.encode(vault, tokenIn, tokenOut, amountIn));
        if (s.stagedBlock == block.number && s.orderHash == wantHash) {
            // Consume the stage BEFORE the external call: no replay, no reentry reuse.
            delete staged[vault];
            _settleViaTarget(tokenIn, s.target, amountIn, s.data);
        } else {
            _settleViaAmm(vault, tokenIn, tokenOut, amountIn, effMinOut, isSell);
        }

        uint256 balAfter = IERC20(tokenOut).balanceOf(vault);
        uint256 actualOut = balAfter - balBefore; // reverts if vault balance dropped
        if (actualOut < effMinOut) revert InsufficientOutput();

        // Sweep any residual left on the engine back to the vault (unused input,
        // over-delivered dust). Done AFTER verification so a settler paying the
        // engine instead of the vault cannot be laundered into a passing delta.
        _sweep(tokenIn, vault);
        _sweep(tokenOut, vault);

        emit Swap(tokenIn, tokenOut, amountIn, actualOut, vault);
    }

    function _settleViaTarget(address tokenIn, address target, uint256 amountIn, bytes memory data) internal {
        IERC20(tokenIn).forceApprove(target, amountIn);
        (bool ok, bytes memory ret) = target.call(data);
        IERC20(tokenIn).forceApprove(target, 0);
        if (!ok) {
            // bubble the exact revert reason
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _settleViaAmm(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 effMinOut,
        bool isSell
    ) internal {
        if (ammRouter == address(0)) revert NoRoute();
        // Route is keyed by the non-base token in either direction.
        address routeKey = isSell ? tokenIn : tokenOut;
        bytes memory path = ammRoute[routeKey];
        if (path.length == 0) revert NoRoute();

        IERC20(tokenIn).forceApprove(ammRouter, amountIn);
        IAmmRouter(ammRouter).exactInput(path, tokenIn, tokenOut, amountIn, effMinOut, vault);
        IERC20(tokenIn).forceApprove(ammRouter, 0);
    }

    function _sweep(address token, address vault) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(vault, bal);
            emit TokensSwept(token, vault, bal);
        }
    }

    // ===================== Views =====================

    /// @notice Read-only view of a vault's current stage (for backend/relayer).
    function stagedSettlement(address vault)
        external
        view
        returns (bytes32 orderHash, address target, uint256 stagedBlock, address stagedBy)
    {
        StagedSettlement memory s = staged[vault];
        return (s.orderHash, s.target, s.stagedBlock, s.stagedBy);
    }

    // ===================== UUPS =====================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[36] private __gap;
}
