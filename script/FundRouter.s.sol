// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TiltUSDC, MockStockTokenFactory} from "../src/tokens/MockStockToken.sol";

/// @title FundRouter
/// @notice Mint massive token liquidity to the router so swaps never run dry.
contract FundRouter is Script {
    address constant ROUTER = 0x969FeCdfa7b0036837AD964662d387a2dCd38d6B;
    address constant TILT_USDC = 0x941A382852E989078e15b381f921C488a7Ca5299;
    address constant FACTORY_1 = 0x446A2EF3DFEC73330F30C5b25Ee8fdAAb789Fe20;
    address constant FACTORY_2 = 0x26F1E4b0Fd4e7f0Bb69cC8274099C77f374a4EB8;

    uint256 constant USDC_AMOUNT = 1_000_000_000_000e6;   // 1 trillion tiltUSDC
    uint256 constant STOCK_AMOUNT = 1_000_000_000_000e18;  // 1 trillion of each stock

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TiltUSDC(TILT_USDC).mint(ROUTER, USDC_AMOUNT);
        console.log("Minted 1T tiltUSDC to router");

        MockStockTokenFactory f1 = MockStockTokenFactory(FACTORY_1);
        uint256 n1 = f1.totalTokens();
        console.log("Factory 1 tokens:", n1);
        if (n1 > 0) {
            f1.mintAllTokens(ROUTER, STOCK_AMOUNT);
            console.log("Minted 1T of each token from factory 1");
        }

        MockStockTokenFactory f2 = MockStockTokenFactory(FACTORY_2);
        uint256 n2 = f2.totalTokens();
        console.log("Factory 2 tokens:", n2);
        if (n2 > 0) {
            f2.mintAllTokens(ROUTER, STOCK_AMOUNT);
            console.log("Minted 1T of each token from factory 2");
        }

        vm.stopBroadcast();
        console.log("Done - router fully funded");
    }
}
