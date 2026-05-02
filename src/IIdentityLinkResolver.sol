// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IIdentityLinkResolver
/// @notice EAS schema resolver that verifies the attester owns the claimed
///         agentId in the local ERC-8004 Identity Registry.
interface IIdentityLinkResolver {
    /// @notice The attester does not own the claimed agentId.
    error AttesterNotOwner(address attester, uint256 agentId);

    /// @notice The attestation data could not be decoded.
    error InvalidAttestationData();

    /// @notice Only the AgentIdentityLinker contract can create attestations
    ///         through this resolver.
    error UnauthorizedAttester(address attester);
}
