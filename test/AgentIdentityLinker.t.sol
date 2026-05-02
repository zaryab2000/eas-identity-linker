// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "./Base.t.sol";
import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";
import {IAgentIdentityLinker} from "../src/IAgentIdentityLinker.sol";
import {Attestation} from "@eas/contracts/IEAS.sol";

contract AgentIdentityLinkerTest is Base {
    // ──────────────────────────────────────────────
    //  createLink
    // ──────────────────────────────────────────────

    function test_CreateLink_ValidOwner_CreatesAttestation() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        assertTrue(uid != bytes32(0));

        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.recipient, alice);
        assertEq(att.attester, address(linker));
        assertEq(att.schema, linker.schemaUID());
        assertTrue(att.revocable);
    }

    function test_CreateLink_NotOwner_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.NotAgentOwner.selector, LOCAL_AGENT_ID, bob
            )
        );
        linker.createLink(_defaultParams());
    }

    function test_CreateLink_ZeroRemoteChainId_Reverts() public {
        AgentIdentityLinker.LinkParams memory p = _defaultParams();
        p.remoteChainId = 0;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityLinker.InvalidRemoteChain.selector, 0));
        linker.createLink(p);
    }

    function test_CreateLink_SameChainId_Reverts() public {
        AgentIdentityLinker.LinkParams memory p = _defaultParams();
        p.remoteChainId = block.chainid;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.InvalidRemoteChain.selector, block.chainid)
        );
        linker.createLink(p);
    }

    function test_CreateLink_ZeroRemoteRegistry_Reverts() public {
        AgentIdentityLinker.LinkParams memory p = _defaultParams();
        p.remoteRegistryAddress = address(0);
        vm.prank(alice);
        vm.expectRevert(IAgentIdentityLinker.InvalidRemoteRegistry.selector);
        linker.createLink(p);
    }

    function test_CreateLink_DuplicateLink_Reverts() public {
        vm.prank(alice);
        linker.createLink(_defaultParams());

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.LinkAlreadyExists.selector,
                LOCAL_AGENT_ID,
                REMOTE_CHAIN_ID,
                REMOTE_REGISTRY,
                REMOTE_AGENT_ID
            )
        );
        linker.createLink(_defaultParams());
    }

    function test_CreateLink_AfterRevocation_Succeeds() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        vm.prank(alice);
        bytes32 uid2 = linker.createLink(_defaultParams());
        assertTrue(uid2 != bytes32(0));
        assertTrue(uid != uid2);
    }

    function test_CreateLink_WithRefUID_SetsReference() public {
        vm.prank(alice);
        bytes32 firstUid = linker.createLink(_defaultParams());

        // Mint a different agent so dedup key differs.
        registry.mint(alice, 99);

        AgentIdentityLinker.LinkParams memory p =
            _params(99, REMOTE_CHAIN_ID, REMOTE_REGISTRY, REMOTE_AGENT_ID, 0, firstUid);
        vm.prank(alice);
        bytes32 secondUid = linker.createLink(p);
        Attestation memory att = eas.getAttestation(secondUid);
        assertEq(att.refUID, firstUid);
    }

    function test_CreateLink_WithExpiration_SetsExpiry() public {
        uint64 expiry = uint64(block.timestamp + 365 days);
        AgentIdentityLinker.LinkParams memory p = _defaultParams();
        p.expirationTime = expiry;
        vm.prank(alice);
        bytes32 uid = linker.createLink(p);
        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.expirationTime, expiry);
    }

    function test_CreateLink_StorageConsistency() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());

        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(LOCAL_AGENT_ID);
        assertEq(recs.length, 1);
        assertEq(recs[0].attestationUID, uid);
        assertEq(recs[0].localAgentId, LOCAL_AGENT_ID);
        assertEq(recs[0].remoteChainId, REMOTE_CHAIN_ID);
        assertEq(recs[0].remoteRegistryAddress, REMOTE_REGISTRY);
        assertEq(recs[0].remoteAgentId, REMOTE_AGENT_ID);
        assertEq(recs[0].owner, alice);
        assertFalse(recs[0].revoked);

        AgentIdentityLinker.LinkRecord memory r = linker.getLinkByRemote(
            LOCAL_AGENT_ID, REMOTE_CHAIN_ID, REMOTE_REGISTRY, REMOTE_AGENT_ID
        );
        assertEq(r.attestationUID, uid);
    }

    function test_CreateLink_EmitsLinkCreated() public {
        vm.prank(alice);
        vm.recordLogs();
        bytes32 uid = linker.createLink(_defaultParams());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 sig = keccak256(
            "LinkCreated(bytes32,uint256,uint256,address,uint256,address)"
        );
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                assertEq(logs[i].topics[1], uid);
                assertEq(uint256(logs[i].topics[2]), LOCAL_AGENT_ID);
                assertEq(uint256(logs[i].topics[3]), REMOTE_CHAIN_ID);
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    // ──────────────────────────────────────────────
    //  completePairing
    // ──────────────────────────────────────────────

    function test_CompletePairing_ValidOwner_SetsPairedUID() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        bytes32 remoteUid = bytes32(uint256(0xC0FFEE));
        vm.prank(alice);
        linker.completePairing(uid, remoteUid);
        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(LOCAL_AGENT_ID);
        assertEq(recs[0].pairedAttestationUID, remoteUid);
    }

    function test_CompletePairing_NotOwner_Reverts() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.NotLinkOwner.selector, uid, bob)
        );
        linker.completePairing(uid, bytes32(uint256(1)));
    }

    function test_CompletePairing_AlreadyPaired_Reverts() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.completePairing(uid, bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.AlreadyPaired.selector, uid)
        );
        linker.completePairing(uid, bytes32(uint256(2)));
    }

    function test_CompletePairing_RevokedLink_Reverts() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.LinkAlreadyRevoked.selector, uid)
        );
        linker.completePairing(uid, bytes32(uint256(1)));
    }

    function test_CompletePairing_NonexistentUID_Reverts() public {
        bytes32 fakeUid = bytes32(uint256(0xDEAD));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.LinkNotFound.selector, fakeUid)
        );
        linker.completePairing(fakeUid, bytes32(uint256(1)));
    }

    function test_CompletePairing_EmitsLinkPaired() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        bytes32 remoteUid = bytes32(uint256(0xBEEF));
        vm.expectEmit(true, true, false, false, address(linker));
        emit IAgentIdentityLinker.LinkPaired(uid, remoteUid);
        vm.prank(alice);
        linker.completePairing(uid, remoteUid);
    }

    // ──────────────────────────────────────────────
    //  revokeLink
    // ──────────────────────────────────────────────

    function test_RevokeLink_ValidOwner_RevokesAttestation() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        Attestation memory att = eas.getAttestation(uid);
        assertTrue(att.revocationTime != 0);
        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(LOCAL_AGENT_ID);
        assertTrue(recs[0].revoked);
    }

    function test_RevokeLink_NotOwner_Reverts() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.NotLinkOwner.selector, uid, bob)
        );
        linker.revokeLink(uid);
    }

    function test_RevokeLink_AlreadyRevoked_Reverts() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.LinkAlreadyRevoked.selector, uid)
        );
        linker.revokeLink(uid);
    }

    function test_RevokeLink_NonexistentUID_Reverts() public {
        bytes32 fakeUid = bytes32(uint256(0xDEAD));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.LinkNotFound.selector, fakeUid)
        );
        linker.revokeLink(fakeUid);
    }

    function test_RevokeLink_ClearsDedupKey() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        // Same params should now succeed.
        vm.prank(alice);
        bytes32 uid2 = linker.createLink(_defaultParams());
        assertTrue(uid2 != uid);
    }

    function test_RevokeLink_EmitsLinkRevoked() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.expectEmit(true, true, false, true, address(linker));
        emit IAgentIdentityLinker.LinkRevoked(uid, LOCAL_AGENT_ID, alice);
        vm.prank(alice);
        linker.revokeLink(uid);
    }

    // ──────────────────────────────────────────────
    //  Read functions
    // ──────────────────────────────────────────────

    function test_IsLinked_ActiveLink_ReturnsTrue() public {
        vm.prank(alice);
        linker.createLink(_defaultParams());
        assertTrue(linker.isLinked(LOCAL_AGENT_ID));
    }

    function test_IsLinked_NoLinks_ReturnsFalse() public view {
        assertFalse(linker.isLinked(LOCAL_AGENT_ID));
    }

    function test_IsLinked_AllRevoked_ReturnsFalse() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        assertFalse(linker.isLinked(LOCAL_AGENT_ID));
    }

    function test_IsLinked_ExpiredLink_ReturnsFalse() public {
        AgentIdentityLinker.LinkParams memory p = _defaultParams();
        p.expirationTime = uint64(block.timestamp + 100);
        vm.prank(alice);
        linker.createLink(p);
        vm.warp(block.timestamp + 200);
        assertFalse(linker.isLinked(LOCAL_AGENT_ID));
    }

    function test_IsLinked_MixedLinks_ReturnsTrue() public {
        vm.prank(alice);
        bytes32 uid1 = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid1);

        AgentIdentityLinker.LinkParams memory p2 =
            _params(LOCAL_AGENT_ID, 1, REMOTE_REGISTRY, REMOTE_AGENT_ID, 0, bytes32(0));
        vm.prank(alice);
        linker.createLink(p2);

        assertTrue(linker.isLinked(LOCAL_AGENT_ID));
    }

    function test_GetLinks_ReturnsAllIncludingRevoked() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        linker.revokeLink(uid);
        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(LOCAL_AGENT_ID);
        assertEq(recs.length, 1);
        assertTrue(recs[0].revoked);
    }

    function test_GetLinks_EmptyAgent_ReturnsEmpty() public view {
        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(9_999);
        assertEq(recs.length, 0);
    }

    function test_GetLinkByRemote_ExistingLink_ReturnsRecord() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        AgentIdentityLinker.LinkRecord memory r = linker.getLinkByRemote(
            LOCAL_AGENT_ID, REMOTE_CHAIN_ID, REMOTE_REGISTRY, REMOTE_AGENT_ID
        );
        assertEq(r.attestationUID, uid);
    }

    function test_GetLinkByRemote_NoLink_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAgentIdentityLinker.LinkNotFound.selector, bytes32(0))
        );
        linker.getLinkByRemote(LOCAL_AGENT_ID, REMOTE_CHAIN_ID, REMOTE_REGISTRY, REMOTE_AGENT_ID);
    }

    function test_GetSchemaUID_ReturnsNonZero() public view {
        assertTrue(linker.getSchemaUID() != bytes32(0));
    }

    function test_GetIdentityRegistry_ReturnsCorrectAddress() public view {
        assertEq(linker.getIdentityRegistry(), address(registry));
    }

    function test_GetEAS_ReturnsCorrectAddress() public view {
        assertEq(linker.getEAS(), address(eas));
    }

    // ──────────────────────────────────────────────
    //  NFT transfer scenarios
    // ──────────────────────────────────────────────

    function test_CreateLink_AfterTransfer_NewOwnerCanLink() public {
        vm.prank(alice);
        registry.transferFrom(alice, bob, LOCAL_AGENT_ID);
        vm.prank(bob);
        bytes32 uid = linker.createLink(_defaultParams());
        assertTrue(uid != bytes32(0));
    }

    function test_RevokeLink_AfterTransfer_OriginalCreatorCanRevoke() public {
        vm.prank(alice);
        bytes32 uid = linker.createLink(_defaultParams());
        vm.prank(alice);
        registry.transferFrom(alice, bob, LOCAL_AGENT_ID);
        vm.prank(alice);
        linker.revokeLink(uid);
        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(LOCAL_AGENT_ID);
        assertTrue(recs[0].revoked);
    }

    function test_CreateLink_AfterTransfer_OldOwnerCannotLink() public {
        vm.prank(alice);
        registry.transferFrom(alice, bob, LOCAL_AGENT_ID);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.NotAgentOwner.selector, LOCAL_AGENT_ID, alice
            )
        );
        linker.createLink(_defaultParams());
    }
}
