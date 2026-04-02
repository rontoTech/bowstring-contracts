// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StockTokenFactoryUpgradeable} from "../src/tokens/StockTokenFactoryUpgradeable.sol";
import {TiltUSDC} from "../src/tokens/MockStockToken.sol";

/// @title FundRouter
/// @notice Mint massive token liquidity to the active TokenRouter so swaps never run dry.
///         Uses only the current StockTokenFactoryUpgradeable (beacon factory).
contract FundRouter is Script {
    address constant ROUTER = 0x9fA2D96Ef53912162f3F8bcd73620Bf93D39808D;
    address constant TILT_USDC = 0x941A382852E989078e15b381f921C488a7Ca5299;
    address constant STOCK_TOKEN_FACTORY = 0x1C65b83B16Fce8f8c420b299EE1A101b724d1F3D;

    uint256 constant USDC_AMOUNT = 1_000_000_000_000e6; // 1 trillion tiltUSDC
    uint256 constant STOCK_AMOUNT = 1_000_000_000_000e18; // 1 trillion of each stock

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TiltUSDC(TILT_USDC).mint(ROUTER, USDC_AMOUNT);
        console.log("Minted 1T tiltUSDC to router");

        StockTokenFactoryUpgradeable factory = StockTokenFactoryUpgradeable(STOCK_TOKEN_FACTORY);
        uint256 n = factory.totalTokens();
        console.log("Factory tokens:", n);
        if (n > 0) {
            StockTokenFactoryUpgradeable.StockTokenInfo[] memory tokens = factory.getDeployedTokens();
            for (uint256 i = 0; i < tokens.length; i++) {
                factory.mintToken(tokens[i].symbol, ROUTER, STOCK_AMOUNT);
            }
            console.log("Minted 1T of each token from StockTokenFactoryUpgradeable");
        }

        vm.stopBroadcast();
        console.log("Done - router fully funded");
    }
}
