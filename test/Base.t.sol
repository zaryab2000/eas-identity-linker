// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {EAS} from "@eas/contracts/EAS.sol";
import {SchemaRegistry} from "@eas/contracts/SchemaRegistry.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry} from "@eas/contracts/ISchemaRegistry.sol";

import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";
import {IdentityLinkResolver} from "../src/IdentityLinkResolver.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice Shared deployment harness for unit tests.
abstract contract Base is Test {
    EAS internal eas;
    SchemaRegistry internal schemaRegistry;
    MockIdentityRegistry internal registry;
    IdentityLinkResolver internal resolver;
    AgentIdentityLinker internal linker;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant LOCAL_AGENT_ID = 42;
    uint256 internal constant REMOTE_AGENT_ID = 17;
    uint256 internal constant REMOTE_CHAIN_ID = 8_453;
    address internal constant REMOTE_REGISTRY = address(uint160(0x8004));

    function setUp() public virtual {
        vm.startPrank(deployer);

        schemaRegistry = new SchemaRegistry();
        eas = new EAS(ISchemaRegistry(address(schemaRegistry)));
        registry = new MockIdentityRegistry();

        // The resolver must know the linker address; the linker must reference
        // the resolver in its constructor. Predict the linker address based on
        // deployer nonce.
        uint256 nonce = vm.getNonce(deployer);
        // resolver will be deployed at nonce, linker at nonce+1
        address predictedLinker = vm.computeCreateAddress(deployer, nonce + 1);
        resolver = new IdentityLinkResolver(IEAS(address(eas)), predictedLinker, address(registry));
        linker = new AgentIdentityLinker(
            IEAS(address(eas)),
            ISchemaRegistry(address(schemaRegistry)),
            address(registry),
            address(resolver)
        );

        require(address(linker) == predictedLinker, "linker address mismatch");

        vm.stopPrank();

        registry.mint(alice, LOCAL_AGENT_ID);
    }

    function _defaultParams() internal view returns (AgentIdentityLinker.LinkParams memory) {
        // Use the interface struct via the contract type; identical layout.
        return _params(LOCAL_AGENT_ID, REMOTE_CHAIN_ID, REMOTE_REGISTRY, REMOTE_AGENT_ID, 0, bytes32(0));
    }

    function _params(
        uint256 localAgentId,
        uint256 remoteChainId,
        address remoteRegistry,
        uint256 remoteAgentId,
        uint64 expirationTime,
        bytes32 refUID
    )
        internal
        pure
        returns (AgentIdentityLinker.LinkParams memory p)
    {
        p.localAgentId = localAgentId;
        p.remoteChainId = remoteChainId;
        p.remoteRegistryAddress = remoteRegistry;
        p.remoteAgentId = remoteAgentId;
        p.expirationTime = expirationTime;
        p.refUID = refUID;
    }
}
