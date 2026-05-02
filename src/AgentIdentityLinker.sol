// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IEAS,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData,
    Attestation
} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry} from "@eas/contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "@eas/contracts/resolver/ISchemaResolver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IAgentIdentityLinker} from "./IAgentIdentityLinker.sol";

/// @title AgentIdentityLinker
/// @notice Main contract for cross-chain ERC-8004 identity linking via EAS.
///         Verifies NFT ownership before attesting, maintains O(1) lookup
///         mappings, and supports revocable, paired attestations.
contract AgentIdentityLinker is IAgentIdentityLinker {
    /// @dev EAS contract (immutable).
    IEAS public immutable eas;

    /// @dev Identity Registry on this chain (immutable).
    address public immutable identityRegistry;

    /// @dev EAS schema UID registered in the constructor (immutable).
    bytes32 public immutable schemaUID;

    /// @dev Schema string used for registration. Public for transparency.
    string public constant SCHEMA =
        "uint256 localAgentId,uint256 remoteChainId,address remoteRegistryAddress,uint256 remoteAgentId";

    /// @dev Attestation UID → LinkRecord.
    mapping(bytes32 => LinkRecord) internal _links;

    /// @dev localAgentId → array of attestation UIDs.
    mapping(uint256 => bytes32[]) internal _agentLinks;

    /// @dev keccak256(localAgentId, remoteChainId, remoteRegistry, remoteAgentId) → UID.
    mapping(bytes32 => bytes32) internal _linkKeys;

    constructor(
        IEAS _eas,
        ISchemaRegistry _schemaRegistry,
        address _identityRegistry,
        address _resolver
    ) {
        eas = _eas;
        identityRegistry = _identityRegistry;
        schemaUID = _schemaRegistry.register(SCHEMA, ISchemaResolver(_resolver), true);
    }

    // ──────────────────────────────────────────────
    //  Write functions
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentIdentityLinker
    function createLink(LinkParams calldata params)
        external
        returns (bytes32 attestationUID)
    {
        address owner = IERC721(identityRegistry).ownerOf(params.localAgentId);
        if (msg.sender != owner) {
            revert NotAgentOwner(params.localAgentId, msg.sender);
        }
        if (params.remoteChainId == 0 || params.remoteChainId == block.chainid) {
            revert InvalidRemoteChain(params.remoteChainId);
        }
        if (params.remoteRegistryAddress == address(0)) {
            revert InvalidRemoteRegistry();
        }

        bytes32 dedupKey = _computeDedupKey(
            params.localAgentId,
            params.remoteChainId,
            params.remoteRegistryAddress,
            params.remoteAgentId
        );
        bytes32 existing = _linkKeys[dedupKey];
        if (existing != bytes32(0) && !_links[existing].revoked) {
            revert LinkAlreadyExists(
                params.localAgentId,
                params.remoteChainId,
                params.remoteRegistryAddress,
                params.remoteAgentId
            );
        }

        bytes memory data = abi.encode(
            params.localAgentId,
            params.remoteChainId,
            params.remoteRegistryAddress,
            params.remoteAgentId
        );

        attestationUID = eas.attest(
            AttestationRequest({
                schema: schemaUID,
                data: AttestationRequestData({
                    recipient: msg.sender,
                    expirationTime: params.expirationTime,
                    revocable: true,
                    refUID: params.refUID,
                    data: data,
                    value: 0
                })
            })
        );

        _links[attestationUID] = LinkRecord({
            attestationUID: attestationUID,
            localAgentId: params.localAgentId,
            remoteChainId: params.remoteChainId,
            remoteRegistryAddress: params.remoteRegistryAddress,
            remoteAgentId: params.remoteAgentId,
            pairedAttestationUID: bytes32(0),
            owner: msg.sender,
            createdAt: uint64(block.timestamp),
            revoked: false
        });
        _agentLinks[params.localAgentId].push(attestationUID);
        _linkKeys[dedupKey] = attestationUID;

        emit LinkCreated(
            attestationUID,
            params.localAgentId,
            params.remoteChainId,
            params.remoteRegistryAddress,
            params.remoteAgentId,
            msg.sender
        );
    }

    /// @inheritdoc IAgentIdentityLinker
    function completePairing(bytes32 localUID, bytes32 remoteUID) external {
        LinkRecord storage record = _links[localUID];
        if (record.attestationUID == bytes32(0)) {
            revert LinkNotFound(localUID);
        }
        if (msg.sender != record.owner) {
            revert NotLinkOwner(localUID, msg.sender);
        }
        if (record.revoked) {
            revert LinkAlreadyRevoked(localUID);
        }
        if (record.pairedAttestationUID != bytes32(0)) {
            revert AlreadyPaired(localUID);
        }
        record.pairedAttestationUID = remoteUID;
        emit LinkPaired(localUID, remoteUID);
    }

    /// @inheritdoc IAgentIdentityLinker
    function revokeLink(bytes32 attestationUID) external {
        LinkRecord storage record = _links[attestationUID];
        if (record.attestationUID == bytes32(0)) {
            revert LinkNotFound(attestationUID);
        }
        if (msg.sender != record.owner) {
            revert NotLinkOwner(attestationUID, msg.sender);
        }
        if (record.revoked) {
            revert LinkAlreadyRevoked(attestationUID);
        }

        record.revoked = true;
        bytes32 dedupKey = _computeDedupKey(
            record.localAgentId,
            record.remoteChainId,
            record.remoteRegistryAddress,
            record.remoteAgentId
        );
        delete _linkKeys[dedupKey];

        eas.revoke(
            RevocationRequest({
                schema: schemaUID,
                data: RevocationRequestData({uid: attestationUID, value: 0})
            })
        );

        emit LinkRevoked(attestationUID, record.localAgentId, msg.sender);
    }

    // ──────────────────────────────────────────────
    //  Read functions
    // ──────────────────────────────────────────────

    /// @inheritdoc IAgentIdentityLinker
    function isLinked(uint256 localAgentId) external view returns (bool) {
        bytes32[] storage uids = _agentLinks[localAgentId];
        uint256 length = uids.length;
        for (uint256 i = 0; i < length; ++i) {
            LinkRecord storage record = _links[uids[i]];
            if (record.revoked) {
                continue;
            }
            Attestation memory att = eas.getAttestation(uids[i]);
            if (att.revocationTime != 0) {
                continue;
            }
            if (att.expirationTime != 0 && att.expirationTime <= block.timestamp) {
                continue;
            }
            return true;
        }
        return false;
    }

    /// @inheritdoc IAgentIdentityLinker
    function getLinks(uint256 localAgentId)
        external
        view
        returns (LinkRecord[] memory records)
    {
        bytes32[] storage uids = _agentLinks[localAgentId];
        uint256 length = uids.length;
        records = new LinkRecord[](length);
        for (uint256 i = 0; i < length; ++i) {
            records[i] = _links[uids[i]];
        }
    }

    /// @inheritdoc IAgentIdentityLinker
    function getLinkByRemote(
        uint256 localAgentId,
        uint256 remoteChainId,
        address remoteRegistryAddress,
        uint256 remoteAgentId
    )
        external
        view
        returns (LinkRecord memory record)
    {
        bytes32 dedupKey = _computeDedupKey(
            localAgentId, remoteChainId, remoteRegistryAddress, remoteAgentId
        );
        bytes32 uid = _linkKeys[dedupKey];
        if (uid == bytes32(0)) {
            revert LinkNotFound(bytes32(0));
        }
        record = _links[uid];
    }

    /// @inheritdoc IAgentIdentityLinker
    function getSchemaUID() external view returns (bytes32) {
        return schemaUID;
    }

    /// @inheritdoc IAgentIdentityLinker
    function getIdentityRegistry() external view returns (address) {
        return identityRegistry;
    }

    /// @inheritdoc IAgentIdentityLinker
    function getEAS() external view returns (address) {
        return address(eas);
    }

    // ──────────────────────────────────────────────
    //  Internals
    // ──────────────────────────────────────────────

    function _computeDedupKey(
        uint256 localAgentId,
        uint256 remoteChainId,
        address remoteRegistryAddress,
        uint256 remoteAgentId
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(localAgentId, remoteChainId, remoteRegistryAddress, remoteAgentId)
        );
    }
}
