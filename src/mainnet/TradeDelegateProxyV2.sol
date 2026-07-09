// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IUserVaultTrade {
    function executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external;
}

interface IMainnetExecutionEngine {
    function stageSettlement(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address target,
        bytes calldata data
    ) external;
}

/// @title TradeDelegateProxyV2
/// @notice Mainnet relayer entrypoint. Keeps `TradeDelegateProxy`'s byte-compatible
///         `executeTrade` / `executeTradesBatch` (AMM-fallback trades that need no
///         staged calldata) and adds `executeTradeWithSettlement`, which stages 0x
///         RFQ calldata on the MainnetExecutionEngine and triggers the vault's
///         trade in ONE transaction — so a 0x quote cannot expire between staging
///         and execution.
///
///         Flow (staged): signer -> proxy.executeTradeWithSettlement(...)
///           -> engine.stageSettlement(...)                (staged, same block)
///           -> vault.executeTrade(...) -> engine.executeRebalance(...) (consumes stage)
contract TradeDelegateProxyV2 is Ownable {
    mapping(address => bool) public authorizedSigners;
    /// @notice MainnetExecutionEngine that stages/settles trades.
    address public engine;

    event SignerAuthorized(address indexed signer, bool authorized);
    event EngineUpdated(address indexed engine);

    error UnauthorizedSigner();
    error ZeroAddress();

    constructor(address owner_, address engine_) Ownable(owner_) {
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
    }

    function setAuthorizedSigner(address signer, bool authorized) external onlyOwner {
        authorizedSigners[signer] = authorized;
        emit SignerAuthorized(signer, authorized);
    }

    function setEngine(address engine_) external onlyOwner {
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
        emit EngineUpdated(engine_);
    }

    /// @notice Forward an executeTrade call to the target vault (AMM-fallback path;
    ///         no staged calldata). Only authorized backend signers can call this.
    function executeTrade(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external {
        if (!authorizedSigners[msg.sender]) revert UnauthorizedSigner();
        IUserVaultTrade(vault).executeTrade(tokenIn, tokenOut, amountIn, minAmountOut);
    }

    /// @notice Batch-execute trades across multiple vaults in one transaction.
    function executeTradesBatch(
        address[] calldata vaults,
        address[] calldata tokensIn,
        address[] calldata tokensOut,
        uint256[] calldata amountsIn,
        uint256[] calldata minAmountsOut
    ) external {
        if (!authorizedSigners[msg.sender]) revert UnauthorizedSigner();
        uint256 len = vaults.length;
        require(
            tokensIn.length == len &&
            tokensOut.length == len &&
            amountsIn.length == len &&
            minAmountsOut.length == len,
            "TradeDelegateProxy: length mismatch"
        );
        for (uint256 i = 0; i < len; i++) {
            IUserVaultTrade(vaults[i]).executeTrade(tokensIn[i], tokensOut[i], amountsIn[i], minAmountsOut[i]);
        }
    }

    /// @notice Stage RFQ settlement calldata and execute the vault trade atomically.
    ///         The engine records the stage keyed to (vault, tokenIn, tokenOut,
    ///         amountIn) for the current block; the vault's executeTrade then drives
    ///         executeRebalance, which consumes it. Any deviation (mismatched tuple,
    ///         disallowed target) is enforced inside the engine.
    function executeTradeWithSettlement(
        address vault,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address target,
        bytes calldata swapData
    ) external {
        if (!authorizedSigners[msg.sender]) revert UnauthorizedSigner();
        IMainnetExecutionEngine(engine).stageSettlement(vault, tokenIn, tokenOut, amountIn, target, swapData);
        IUserVaultTrade(vault).executeTrade(tokenIn, tokenOut, amountIn, minAmountOut);
    }
}
