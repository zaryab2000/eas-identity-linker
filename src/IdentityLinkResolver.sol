// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SchemaResolver} from "@eas/contracts/resolver/SchemaResolver.sol";
import {IEAS, Attestation} from "@eas/contracts/IEAS.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IIdentityLinkResolver} from "./IIdentityLinkResolver.sol";

/// @title IdentityLinkResolver
/// @notice EAS schema resolver verifying that the recipient of an identity-link
///         attestation owns the claimed `localAgentId` in the local ERC-8004
///         Identity Registry. Only the configured AgentIdentityLinker contract
///         is authorized to attest through this resolver.
contract IdentityLinkResolver is SchemaResolver, IIdentityLinkResolver {
    /// @dev The AgentIdentityLinker address (immutable). Only attestations
    ///      created through the linker are accepted.
    address public immutable linker;

    /// @dev The ERC-8004 Identity Registry on this chain (immutable).
    address public immutable identityRegistry;

    constructor(IEAS _eas, address _linker, address _identityRegistry) SchemaResolver(_eas) {
        linker = _linker;
        identityRegistry = _identityRegistry;
    }

    /// @inheritdoc SchemaResolver
    function onAttest(Attestation calldata attestation, uint256 /*value*/ )
        internal
        view
        override
        returns (bool)
    {
        if (attestation.attester != linker) {
            revert UnauthorizedAttester(attestation.attester);
        }

        // Schema is `uint256 localAgentId, uint256 remoteChainId,
        // address remoteRegistryAddress, uint256 remoteAgentId`.
        if (attestation.data.length != 32 * 4) {
            revert InvalidAttestationData();
        }

        uint256 localAgentId = abi.decode(attestation.data, (uint256));

        // The linker passes the original caller as `recipient`; we verify
        // that address still owns the local agentId.
        address claimedOwner = attestation.recipient;
        address actualOwner = IERC721(identityRegistry).ownerOf(localAgentId);

        if (claimedOwner != actualOwner) {
            revert AttesterNotOwner(claimedOwner, localAgentId);
        }

        return true;
    }

    /// @inheritdoc SchemaResolver
    function onRevoke(Attestation calldata, /*attestation*/ uint256 /*value*/ )
        internal
        pure
        override
        returns (bool)
    {
        return true;
    }

    /// @inheritdoc SchemaResolver
    function isPayable() public pure override returns (bool) {
        return false;
    }
}
