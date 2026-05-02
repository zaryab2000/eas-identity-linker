// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry} from "@eas/contracts/ISchemaRegistry.sol";

import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";
import {IdentityLinkResolver} from "../src/IdentityLinkResolver.sol";

/// @notice Deploy the IdentityLinkResolver and AgentIdentityLinker on the
///         current chain. Reads chain-specific addresses from environment
///         variables (EAS_ADDRESS, SCHEMA_REGISTRY_ADDRESS, IDENTITY_REGISTRY_ADDRESS)
///         or falls back to canonical addresses for known chains.
contract Deploy is Script {
    // Mainnet
    address internal constant EAS_ETH = 0xA1207F3BBa224E2c9c3c6D5aF63D0eb1582Ce587;
    address internal constant SCHEMA_REGISTRY_ETH = 0xA7b39296258348C78294F95B872b282326A97BDF;
    address internal constant EAS_BASE = 0x4200000000000000000000000000000000000021;
    address internal constant SCHEMA_REGISTRY_BASE = 0x4200000000000000000000000000000000000020;

    // Sepolia / Base Sepolia
    address internal constant EAS_ETH_SEPOLIA = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    address internal constant SCHEMA_REGISTRY_ETH_SEPOLIA =
        0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0;

    // ERC-8004
    address internal constant IDENTITY_REGISTRY_MAINNET =
        0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant IDENTITY_REGISTRY_TESTNET =
        0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function run() external {
        (address eas, address schemaRegistry, address identityRegistry) = _resolveAddresses();

        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);
        console2.log("Chain id:", block.chainid);
        console2.log("EAS:", eas);
        console2.log("SchemaRegistry:", schemaRegistry);
        console2.log("IdentityRegistry:", identityRegistry);

        vm.startBroadcast(deployerKey);

        uint256 nonce = vm.getNonce(deployer);
        address predictedLinker = vm.computeCreateAddress(deployer, nonce + 1);
        console2.log("Predicted linker:", predictedLinker);

        IdentityLinkResolver resolver =
            new IdentityLinkResolver(IEAS(eas), predictedLinker, identityRegistry);
        AgentIdentityLinker linker = new AgentIdentityLinker(
            IEAS(eas), ISchemaRegistry(schemaRegistry), identityRegistry, address(resolver)
        );

        vm.stopBroadcast();

        require(address(linker) == predictedLinker, "linker address mismatch");

        console2.log("IdentityLinkResolver:", address(resolver));
        console2.log("AgentIdentityLinker:", address(linker));
        console2.log("Schema UID:");
        console2.logBytes32(linker.schemaUID());
    }

    function _resolveAddresses()
        internal
        view
        returns (address eas, address schemaRegistry, address identityRegistry)
    {
        // Allow overrides via env.
        eas = vm.envOr("EAS_ADDRESS", address(0));
        schemaRegistry = vm.envOr("SCHEMA_REGISTRY_ADDRESS", address(0));
        identityRegistry = vm.envOr("IDENTITY_REGISTRY_ADDRESS", address(0));

        if (eas == address(0) || schemaRegistry == address(0)) {
            uint256 chainId = block.chainid;
            if (chainId == 1) {
                eas = eas == address(0) ? EAS_ETH : eas;
                schemaRegistry =
                    schemaRegistry == address(0) ? SCHEMA_REGISTRY_ETH : schemaRegistry;
                identityRegistry =
                    identityRegistry == address(0) ? IDENTITY_REGISTRY_MAINNET : identityRegistry;
            } else if (chainId == 8_453) {
                eas = eas == address(0) ? EAS_BASE : eas;
                schemaRegistry =
                    schemaRegistry == address(0) ? SCHEMA_REGISTRY_BASE : schemaRegistry;
                identityRegistry =
                    identityRegistry == address(0) ? IDENTITY_REGISTRY_MAINNET : identityRegistry;
            } else if (chainId == 11_155_111) {
                eas = eas == address(0) ? EAS_ETH_SEPOLIA : eas;
                schemaRegistry = schemaRegistry == address(0)
                    ? SCHEMA_REGISTRY_ETH_SEPOLIA
                    : schemaRegistry;
                identityRegistry =
                    identityRegistry == address(0) ? IDENTITY_REGISTRY_TESTNET : identityRegistry;
            } else if (chainId == 84_532) {
                eas = eas == address(0) ? EAS_BASE : eas;
                schemaRegistry =
                    schemaRegistry == address(0) ? SCHEMA_REGISTRY_BASE : schemaRegistry;
                identityRegistry =
                    identityRegistry == address(0) ? IDENTITY_REGISTRY_TESTNET : identityRegistry;
            } else {
                revert("Unsupported chain; provide env addresses");
            }
        }
        require(eas != address(0), "EAS address required");
        require(schemaRegistry != address(0), "SchemaRegistry address required");
        require(identityRegistry != address(0), "IdentityRegistry address required");
    }
}
