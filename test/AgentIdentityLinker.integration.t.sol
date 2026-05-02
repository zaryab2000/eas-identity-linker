// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IEAS, Attestation} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry} from "@eas/contracts/ISchemaRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";
import {IAgentIdentityLinker} from "../src/IAgentIdentityLinker.sol";
import {IdentityLinkResolver} from "../src/IdentityLinkResolver.sol";

/// @notice Fork-based integration tests. Run with:
///     forge test --match-path test/AgentIdentityLinker.integration.t.sol \
///         --fork-url $BASE_SEPOLIA_RPC -vv
///
/// These tests are auto-skipped when the chain id is not Base Sepolia (84532),
/// so the default `forge test` run does not require RPC connectivity.
contract AgentIdentityLinkerIntegration is Test {
    // Base Sepolia
    address internal constant EAS_ADDR = 0x4200000000000000000000000000000000000021;
    address internal constant SCHEMA_REGISTRY_ADDR = 0x4200000000000000000000000000000000000020;
    address internal constant IDENTITY_REGISTRY_TESTNET =
        0x8004A818BFB912233c491871b3d84c89A494BD9e;

    AgentIdentityLinker internal linker;
    IdentityLinkResolver internal resolver;

    address internal owner = makeAddr("integration-owner");
    address internal stranger = makeAddr("integration-stranger");

    uint256 internal constant LOCAL_AGENT_ID = 8_004_001;
    uint256 internal constant REMOTE_AGENT_ID = 1;
    uint256 internal constant REMOTE_CHAIN_ID = 11_155_111; // Ethereum Sepolia
    address internal constant REMOTE_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    modifier onlyOnBaseSepolia() {
        if (block.chainid != 84_532) {
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 84_532) {
            return;
        }

        // Deploy resolver + linker against the live EAS / SchemaRegistry.
        uint256 nonce = vm.getNonce(address(this));
        address predictedLinker = vm.computeCreateAddress(address(this), nonce + 1);

        resolver = new IdentityLinkResolver(
            IEAS(EAS_ADDR), predictedLinker, IDENTITY_REGISTRY_TESTNET
        );
        linker = new AgentIdentityLinker(
            IEAS(EAS_ADDR),
            ISchemaRegistry(SCHEMA_REGISTRY_ADDR),
            IDENTITY_REGISTRY_TESTNET,
            address(resolver)
        );
        require(address(linker) == predictedLinker, "addr mismatch");

        // Mint an agent NFT to `owner` directly via storage manipulation —
        // the live ERC-8004 registry on testnet uses standard ERC-721 storage,
        // so we can use vm.store to assign ownership for test purposes.
        // The mapping `_owners` lives at slot 2 of OZ ERC721Upgradeable
        // (after initializable + name/symbol slots may differ). Instead we
        // call the public mint via cheatcode prank if available; otherwise
        // we use deal + low-level storage.
        // Safer: prank as the registry owner and call any mint function the
        // registry exposes. ERC-8004 registries expose `register(...)` which
        // mints to msg.sender. Since the exact API may evolve, fall back to
        // storage write of the owner mapping.

        // OZ v5 ERC721 stores _owners at slot 2 in non-upgradeable. The
        // upgradeable variant uses a namespaced storage slot. We assume the
        // upgradeable layout used by ERC-8004:
        //  ERC721StorageLocation =
        //   keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC721")) - 1))
        //   & ~bytes32(uint256(0xff))
        bytes32 baseSlot = 0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d875f7c2785d8e58e5f3c92a52d;
        // _owners is the first mapping in the struct (slot offset 2).
        bytes32 ownersSlot = bytes32(uint256(baseSlot) + 2);
        bytes32 entrySlot = keccak256(abi.encode(LOCAL_AGENT_ID, ownersSlot));
        vm.store(IDENTITY_REGISTRY_TESTNET, entrySlot, bytes32(uint256(uint160(owner))));
    }

    function test_Integration_FullLinkFlow_BaseSepolia() public onlyOnBaseSepolia {
        // Sanity: storage mock above gives `owner` ownership.
        require(
            IERC721(IDENTITY_REGISTRY_TESTNET).ownerOf(LOCAL_AGENT_ID) == owner,
            "ownership mock failed"
        );

        IAgentIdentityLinker.LinkParams memory p = IAgentIdentityLinker.LinkParams({
            localAgentId: LOCAL_AGENT_ID,
            remoteChainId: REMOTE_CHAIN_ID,
            remoteRegistryAddress: REMOTE_REGISTRY,
            remoteAgentId: REMOTE_AGENT_ID,
            expirationTime: 0,
            refUID: bytes32(0)
        });

        vm.prank(owner);
        bytes32 uid = linker.createLink(p);
        assertTrue(uid != bytes32(0));
        assertTrue(linker.isLinked(LOCAL_AGENT_ID));

        Attestation memory att = IEAS(EAS_ADDR).getAttestation(uid);
        assertEq(att.recipient, owner);
        assertEq(att.attester, address(linker));
    }

    function test_Integration_RevokeFlow_BaseSepolia() public onlyOnBaseSepolia {
        IAgentIdentityLinker.LinkParams memory p = IAgentIdentityLinker.LinkParams({
            localAgentId: LOCAL_AGENT_ID,
            remoteChainId: REMOTE_CHAIN_ID,
            remoteRegistryAddress: REMOTE_REGISTRY,
            remoteAgentId: REMOTE_AGENT_ID,
            expirationTime: 0,
            refUID: bytes32(0)
        });

        vm.prank(owner);
        bytes32 uid = linker.createLink(p);
        vm.prank(owner);
        linker.revokeLink(uid);

        assertFalse(linker.isLinked(LOCAL_AGENT_ID));
        Attestation memory att = IEAS(EAS_ADDR).getAttestation(uid);
        assertTrue(att.revocationTime != 0);
    }

    function test_Integration_ResolverRejectsNonOwner_BaseSepolia()
        public
        onlyOnBaseSepolia
    {
        IAgentIdentityLinker.LinkParams memory p = IAgentIdentityLinker.LinkParams({
            localAgentId: LOCAL_AGENT_ID,
            remoteChainId: REMOTE_CHAIN_ID,
            remoteRegistryAddress: REMOTE_REGISTRY,
            remoteAgentId: REMOTE_AGENT_ID,
            expirationTime: 0,
            refUID: bytes32(0)
        });

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentIdentityLinker.NotAgentOwner.selector, LOCAL_AGENT_ID, stranger
            )
        );
        linker.createLink(p);
    }
}
