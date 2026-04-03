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

/// @title TradeDelegateProxy
/// @notice Forwarding proxy for vault trade execution. Curators add this
///         contract as a delegate on their vaults. Backend signers are
///         authorized on the proxy — rotating a signer requires only one
///         call to setAuthorizedSigner, not per-vault delegate updates.
///
///         Flow: backend signer -> proxy.executeTrade(vault, ...) -> vault.executeTrade(...)
///         The vault sees msg.sender == address(this), which must be in its delegates mapping.
contract TradeDelegateProxy is Ownable {
    mapping(address => bool) public authorizedSigners;

    event SignerAuthorized(address indexed signer, bool authorized);

    error UnauthorizedSigner();
    error TradeReverted(bytes reason);

    constructor(address owner_) Ownable(owner_) {}

    function setAuthorizedSigner(address signer, bool authorized) external onlyOwner {
        authorizedSigners[signer] = authorized;
        emit SignerAuthorized(signer, authorized);
    }

    /// @notice Forward an executeTrade call to the target vault.
    ///         Only authorized backend signers can call this.
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
}
