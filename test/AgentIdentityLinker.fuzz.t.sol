// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";
import {IAgentIdentityLinker} from "../src/IAgentIdentityLinker.sol";

contract AgentIdentityLinkerFuzz is Base {
    function _bound(
        uint256 agentId,
        uint256 remoteChainId,
        address remoteRegistry,
        address caller
    )
        internal
        view
        returns (uint256, uint256, address, address)
    {
        // Bound chainId to a non-zero value distinct from the local chain.
        remoteChainId = bound(remoteChainId, 1, type(uint64).max);
        if (remoteChainId == block.chainid) {
            remoteChainId = remoteChainId == 1 ? 2 : remoteChainId - 1;
        }
        // Avoid zero registry.
        if (remoteRegistry == address(0)) {
            remoteRegistry = address(uint160(0xBEEF));
        }
        // Ensure caller is non-zero (mintable to).
        if (caller == address(0)) {
            caller = address(uint160(0xCAFE));
        }
        // Avoid colliding with already-minted token id.
        agentId = bound(agentId, 1_000, type(uint128).max);
        return (agentId, remoteChainId, remoteRegistry, caller);
    }

    function testFuzz_CreateLink_AlwaysVerifiesOwnership(
        uint256 agentId,
        uint256 remoteChainId,
        address remoteRegistry,
        uint256 remoteAgentId,
        address caller
    )
        public
    {
        (agentId, remoteChainId, remoteRegistry, caller) =
            _bound(agentId, remoteChainId, remoteRegistry, caller);

        registry.mint(caller, agentId);

        AgentIdentityLinker.LinkParams memory p = _params(
            agentId, remoteChainId, remoteRegistry, remoteAgentId, 0, bytes32(0)
        );

        // Owner can create.
        vm.prank(caller);
        bytes32 uid = linker.createLink(p);
        assertTrue(uid != bytes32(0));

        // Non-owner cannot create another link for same agent (any other params).
        address attacker = caller == address(0xDEAD) ? address(0xBEEF1) : address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.NotAgentOwner.selector, agentId, attacker
            )
        );
        linker.createLink(
            _params(agentId, remoteChainId + 1, remoteRegistry, remoteAgentId, 0, bytes32(0))
        );
    }

    function testFuzz_CreateLink_NoDuplicates(
        uint256 agentId,
        uint256 remoteChainId,
        address remoteRegistry,
        uint256 remoteAgentId,
        address caller
    )
        public
    {
        (agentId, remoteChainId, remoteRegistry, caller) =
            _bound(agentId, remoteChainId, remoteRegistry, caller);

        registry.mint(caller, agentId);

        AgentIdentityLinker.LinkParams memory p = _params(
            agentId, remoteChainId, remoteRegistry, remoteAgentId, 0, bytes32(0)
        );

        vm.prank(caller);
        linker.createLink(p);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.LinkAlreadyExists.selector,
                agentId,
                remoteChainId,
                remoteRegistry,
                remoteAgentId
            )
        );
        linker.createLink(p);
    }

    function testFuzz_RevokeAndRelink_AlwaysSucceeds(
        uint256 agentId,
        uint256 remoteChainId,
        address remoteRegistry,
        uint256 remoteAgentId,
        address caller
    )
        public
    {
        (agentId, remoteChainId, remoteRegistry, caller) =
            _bound(agentId, remoteChainId, remoteRegistry, caller);

        registry.mint(caller, agentId);

        AgentIdentityLinker.LinkParams memory p = _params(
            agentId, remoteChainId, remoteRegistry, remoteAgentId, 0, bytes32(0)
        );

        vm.prank(caller);
        bytes32 uid = linker.createLink(p);
        vm.prank(caller);
        linker.revokeLink(uid);
        vm.prank(caller);
        bytes32 uid2 = linker.createLink(p);
        assertTrue(uid2 != uid);
        assertTrue(uid2 != bytes32(0));
    }

    function testFuzz_IsLinked_ConsistentWithGetLinks(uint256 agentId, address caller) public {
        agentId = bound(agentId, 1_000, type(uint128).max);
        if (caller == address(0)) caller = address(uint160(0xCAFE));

        // Initially: no links.
        assertFalse(linker.isLinked(agentId));

        registry.mint(caller, agentId);
        // Create a link.
        AgentIdentityLinker.LinkParams memory p =
            _params(agentId, 999_001, address(uint160(0xBEEF)), 1, 0, bytes32(0));
        vm.prank(caller);
        bytes32 uid = linker.createLink(p);

        AgentIdentityLinker.LinkRecord[] memory recs = linker.getLinks(agentId);
        bool anyActive;
        for (uint256 i = 0; i < recs.length; ++i) {
            if (!recs[i].revoked) {
                anyActive = true;
                break;
            }
        }
        assertEq(linker.isLinked(agentId), anyActive);

        vm.prank(caller);
        linker.revokeLink(uid);

        recs = linker.getLinks(agentId);
        anyActive = false;
        for (uint256 i = 0; i < recs.length; ++i) {
            if (!recs[i].revoked) {
                anyActive = true;
                break;
            }
        }
        assertEq(linker.isLinked(agentId), anyActive);
    }
}
