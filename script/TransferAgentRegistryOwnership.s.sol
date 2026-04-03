// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Transfer AgentRegistry ownership to a dedicated agent-services wallet.
///         Run with: forge script script/TransferAgentRegistryOwnership.s.sol \
///                     --rpc-url robinhood_testnet --broadcast --private-key $PRIVATE_KEY
contract TransferAgentRegistryOwnership is Script {
    function run() external {
        address agentRegistry = vm.envAddress("AGENT_REGISTRY_ADDRESS");
        address newOwner = vm.envAddress("NEW_AGENT_SERVICES_WALLET");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        console.log("AgentRegistry:", agentRegistry);
        console.log("Current owner:", IOwnable(agentRegistry).owner());
        console.log("Transferring to:", newOwner);

        vm.startBroadcast(pk);
        IOwnable(agentRegistry).transferOwnership(newOwner);
        vm.stopBroadcast();

        console.log("New owner:", IOwnable(agentRegistry).owner());
    }
}
