// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";
import {IAgentIdentityLinker} from "../src/IAgentIdentityLinker.sol";
import {IIdentityLinkResolver} from "../src/IIdentityLinkResolver.sol";
import {
    IEAS,
    AttestationRequest,
    AttestationRequestData
} from "@eas/contracts/IEAS.sol";

contract IdentityLinkResolverTest is Base {
    function test_OnAttest_ValidOwner_ReturnsTrue() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        assertTrue(uid != bytes32(0));
    }

    function test_OnAttest_NotOwner_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.NotAgentOwner.selector, LOCAL_AGENT_ID, bob
            )
        );
        linker.createLink(_defaultParams());
    }

    function test_OnAttest_UnauthorizedAttester_Reverts() public {
        // Direct attestation (not via linker) must be rejected.
        bytes memory data = abi.encode(
            LOCAL_AGENT_ID, REMOTE_CHAIN_ID, REMOTE_REGISTRY, REMOTE_AGENT_ID
        );
        bytes32 uid = linker.schemaUID();
        AttestationRequest memory req = AttestationRequest({
            schema: uid,
            data: AttestationRequestData({
                recipient: alice,
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: data,
                value: 0
            })
        });
        vm.prank(alice);
        // EAS bubbles resolver reverts; we just assert the call fails.
        vm.expectRevert();
        eas.attest(req);
    }

    function test_OnRevoke_AlwaysReturnsTrue() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        // Revocation succeeded; record updated.
        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(LOCAL_AGENT_ID);
        assertTrue(recs[0].revoked);
    }
}
