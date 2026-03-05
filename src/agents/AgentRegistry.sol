// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title AgentRegistry (ERC-8004 compatible)
/// @notice On-chain identity registry for AI agents on Tilt Protocol.
///         Each agent is an ERC-721 NFT with a URI pointing to a registration
///         file (name, description, endpoints, supported trust models).
///         Follows the ERC-8004 Identity Registry specification.
contract AgentRegistry is ERC721URIStorage, EIP712, Ownable {
    uint256 private _nextAgentId = 1;

    // ERC-8004: arbitrary key-value metadata per agent
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    // ERC-8004: verified agent wallet (separate from NFT owner)
    mapping(uint256 => address) private _agentWallets;

    bytes32 private constant SET_WALLET_TYPEHASH =
        keccak256("SetAgentWallet(uint256 agentId,address newWallet,uint256 deadline)");

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue);
    event AgentWalletSet(uint256 indexed agentId, address indexed newWallet);

    constructor() ERC721("Tilt Agent", "TAGENT") EIP712("TiltAgentRegistry", "1") Ownable(msg.sender) {}

    // ===================== Registration =====================

    /// @notice Register a new agent. Mints an NFT to msg.sender.
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        _agentWallets[agentId] = msg.sender;
        emit Registered(agentId, agentURI, msg.sender);
        emit AgentWalletSet(agentId, msg.sender);
    }

    /// @notice Register on behalf of another address (owner-only, for faucet bootstrap).
    function registerFor(address to, string calldata agentURI) external onlyOwner returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _safeMint(to, agentId);
        _setTokenURI(agentId, agentURI);
        _agentWallets[agentId] = to;
        emit Registered(agentId, agentURI, to);
        emit AgentWalletSet(agentId, to);
    }

    // ===================== URI Management =====================

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "AgentRegistry: not authorized");
        _setTokenURI(agentId, newURI);
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    // ===================== Metadata =====================

    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory) {
        return _metadata[agentId][metadataKey];
    }

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "AgentRegistry: not authorized");
        require(keccak256(bytes(metadataKey)) != keccak256("agentWallet"), "AgentRegistry: use setAgentWallet");
        _metadata[agentId][metadataKey] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    // ===================== Agent Wallet (EIP-712 verified) =====================

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _agentWallets[agentId];
    }

    /// @notice Change the agent wallet. Requires an EIP-712 signature from the new wallet
    ///         to prove ownership (prevents pointing to wallets you don't control).
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "AgentRegistry: not authorized");
        require(block.timestamp <= deadline, "AgentRegistry: signature expired");

        bytes32 structHash = keccak256(abi.encode(SET_WALLET_TYPEHASH, agentId, newWallet, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == newWallet, "AgentRegistry: invalid wallet signature");

        _agentWallets[agentId] = newWallet;
        emit AgentWalletSet(agentId, newWallet);
    }

    function unsetAgentWallet(uint256 agentId) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "AgentRegistry: not authorized");
        delete _agentWallets[agentId];
        emit AgentWalletSet(agentId, address(0));
    }

    // Clear wallet on transfer (per ERC-8004 spec)
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            delete _agentWallets[tokenId];
            emit AgentWalletSet(tokenId, address(0));
        }
        return from;
    }

    // ===================== View Helpers =====================

    function totalAgents() external view returns (uint256) {
        return _nextAgentId - 1;
    }

    function nextAgentId() external view returns (uint256) {
        return _nextAgentId;
    }
}
