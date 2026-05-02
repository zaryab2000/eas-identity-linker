// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAgentIdentityLinker
/// @notice Creates and manages EAS attestations that link ERC-8004 agent
///         identities across chains. Each link is a paired attestation:
///         one on the source chain, one on the destination chain.
interface IAgentIdentityLinker {
    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────

    /// @notice Parameters for creating an identity link attestation.
    /// @param localAgentId The agent's tokenId in the local Identity Registry.
    /// @param remoteChainId The chain ID where the agent has another registration.
    /// @param remoteRegistryAddress The Identity Registry address on the remote chain.
    /// @param remoteAgentId The agent's tokenId in the remote Identity Registry.
    /// @param expirationTime Unix timestamp when this link expires (0 = no expiry).
    /// @param refUID UID of the paired attestation on the remote chain (bytes32(0)
    ///        if this is the first attestation in the pair).
    struct LinkParams {
        uint256 localAgentId;
        uint256 remoteChainId;
        address remoteRegistryAddress;
        uint256 remoteAgentId;
        uint64 expirationTime;
        bytes32 refUID;
    }

    /// @notice Stored record of an identity link.
    struct LinkRecord {
        bytes32 attestationUID;
        uint256 localAgentId;
        uint256 remoteChainId;
        address remoteRegistryAddress;
        uint256 remoteAgentId;
        bytes32 pairedAttestationUID;
        address owner;
        uint64 createdAt;
        bool revoked;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event LinkCreated(
        bytes32 indexed attestationUID,
        uint256 indexed localAgentId,
        uint256 indexed remoteChainId,
        address remoteRegistryAddress,
        uint256 remoteAgentId,
        address owner
    );

    event LinkPaired(bytes32 indexed localUID, bytes32 indexed remoteUID);

    event LinkRevoked(
        bytes32 indexed attestationUID,
        uint256 indexed localAgentId,
        address revokedBy
    );

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error NotAgentOwner(uint256 agentId, address caller);
    error InvalidRemoteChain(uint256 remoteChainId);
    error InvalidRemoteRegistry();
    error LinkAlreadyExists(
        uint256 localAgentId,
        uint256 remoteChainId,
        address remoteRegistry,
        uint256 remoteAgentId
    );
    error LinkNotFound(bytes32 attestationUID);
    error NotLinkOwner(bytes32 attestationUID, address caller);
    error LinkAlreadyRevoked(bytes32 attestationUID);
    error PairingMismatch(bytes32 localUID, bytes32 remoteUID);
    error AlreadyPaired(bytes32 attestationUID);
    error SchemaNotInitialized();

    // ──────────────────────────────────────────────
    //  Write functions
    // ──────────────────────────────────────────────

    function createLink(LinkParams calldata params) external returns (bytes32 attestationUID);

    function completePairing(bytes32 localUID, bytes32 remoteUID) external;

    function revokeLink(bytes32 attestationUID) external;

    // ──────────────────────────────────────────────
    //  Read functions
    // ──────────────────────────────────────────────

    function isLinked(uint256 localAgentId) external view returns (bool linked);

    function getLinks(uint256 localAgentId) external view returns (LinkRecord[] memory records);

    function getLinkByRemote(
        uint256 localAgentId,
        uint256 remoteChainId,
        address remoteRegistryAddress,
        uint256 remoteAgentId
    )
        external
        view
        returns (LinkRecord memory record);

    function getSchemaUID() external view returns (bytes32 schemaUID);

    function getIdentityRegistry() external view returns (address registry);

    function getEAS() external view returns (address eas);
}
