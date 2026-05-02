// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ISchemaRegistry, SchemaRecord} from "@eas/contracts/ISchemaRegistry.sol";

import {AgentIdentityLinker} from "../src/AgentIdentityLinker.sol";

/// @notice Read-only verification script. Reads the deployed linker's
///         immutables and the registered schema, prints them for manual
///         inspection.
contract VerifyDeployment is Script {
    function run() external view {
        address linkerAddr = vm.envAddress("LINKER_ADDRESS");
        AgentIdentityLinker linker = AgentIdentityLinker(linkerAddr);

        bytes32 schemaUid = linker.getSchemaUID();
        address registry = linker.getIdentityRegistry();
        address eas = linker.getEAS();

        console2.log("Linker:", linkerAddr);
        console2.log("EAS:", eas);
        console2.log("IdentityRegistry:", registry);
        console2.log("Schema UID:");
        console2.logBytes32(schemaUid);

        address schemaRegistry = vm.envAddress("SCHEMA_REGISTRY_ADDRESS");
        SchemaRecord memory rec = ISchemaRegistry(schemaRegistry).getSchema(schemaUid);
        console2.log("Schema string:", rec.schema);
        console2.log("Schema resolver:", address(rec.resolver));
        console2.log("Schema revocable:", rec.revocable);
    }
}
