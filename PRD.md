# PRD: EAS-Based Identity Linker

## 1. Project Summary

A smart contract system that lets ERC-8004 agent owners prove cross-chain identity linkage using Ethereum Attestation Service (EAS) attestations with on-chain ownership verification. An agent registered as `agentId=42` on Ethereum and `agentId=17` on Base creates paired EAS attestations on each chain; a resolver contract verifies NFT ownership at attestation time; an indexed registry contract maintains O(1) lookup mappings so any contract can call `isLinked(agentId)` to check cross-chain identity without trusting off-chain intermediaries. Deploys on Base and Ethereum mainnet.

## 2. Problem Context

ERC-8004's Identity Registry is a per-chain singleton with incrementing `tokenId`. An agent gets `agentId=42` on Ethereum and `agentId=17` on Base — two unrelated NFTs with no on-chain link (Limitation (a): Identity fragmentation — P0). The only cross-chain hook is the `registrations[]` array in the off-chain Agent Registration File — self-asserted JSON, no signature, no on-chain verification (Limitation (e): Agent Card centralization risk — P1).

Existing ecosystem tools (8004scan, 8k4 API, Agent Arena) aggregate this JSON off-chain. Verity Protocol already anchors Brier Skill Scores as EAS attestations on Base, proving the EAS pattern works for 8004-adjacent data. This project extends that pattern to cross-chain identity linking with three properties the current `registrations[]` array lacks:

1. **On-chain verifiability** — a resolver calls `ownerOf(agentId)` at attestation time, proving the attester controls the NFT.
2. **On-chain queryability** — any contract can call `isLinked()` for O(1) lookups without parsing off-chain JSON.
3. **Revocability** — stale links (NFT transferred, chain abandoned) can be revoked, unlike permanent off-chain JSON.

## 3. Technical Specification

### 3a. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Agent Owner (Off-Chain)                    │
│                                                                 │
│  1. Owns agentId=42 on Ethereum, agentId=17 on Base             │
│  2. Calls AgentIdentityLinker.createLink() on Chain A            │
│     → resolver verifies ownerOf(42) on Ethereum                 │
│     → EAS attestation created, UID stored in linker registry    │
│  3. Takes uidA, calls AgentIdentityLinker.createLink() on        │
│     Chain B with refUID=uidA                                    │
│     → resolver verifies ownerOf(17) on Base                     │
│     → EAS attestation created, UID stored in linker registry    │
│  4. Calls completePairing(uidA, uidB) on Chain A to record      │
│     the reverse reference (optional but recommended)            │
└───────────┬─────────────────────────────────────┬───────────────┘
            │                                     │
            ▼                                     ▼
┌───────────────────────────┐   ┌───────────────────────────────┐
│     Ethereum Mainnet      │   │         Base Mainnet           │
│                           │   │                                │
│  EAS (0xA120...Ce587)     │   │  EAS (0x4200...0021)           │
│  SchemaRegistry           │   │  SchemaRegistry                │
│         │                 │   │         │                      │
│         ▼                 │   │         ▼                      │
│  IdentityLinkResolver    │   │  IdentityLinkResolver          │
│  ├─ onAttest(): calls     │   │  ├─ onAttest(): calls          │
│  │  IdentityRegistry      │   │  │  IdentityRegistry           │
│  │  .ownerOf(agentId)     │   │  │  .ownerOf(agentId)          │
│  └─ onRevoke(): allows    │   │  └─ onRevoke(): allows         │
│                           │   │                                │
│  AgentIdentityLinker      │   │  AgentIdentityLinker           │
│  ├─ createLink()          │   │  ├─ createLink()               │
│  ├─ completePairing()     │   │  ├─ completePairing()          │
│  ├─ revokeLink()          │   │  ├─ revokeLink()               │
│  ├─ isLinked()            │   │  ├─ isLinked()                 │
│  ├─ getLinks()            │   │  ├─ getLinks()                 │
│  └─ getLinkByChain()      │   │  └─ getLinkByChain()           │
│                           │   │                                │
│  IdentityRegistry         │   │  IdentityRegistry              │
│  (0x8004A169...9a432)     │   │  (0x8004A169...9a432)          │
└───────────────────────────┘   └───────────────────────────────┘
```

**On-chain components (per chain):**

- **`IdentityLinkResolver.sol`** — EAS `SchemaResolver` subclass (~60 LOC). Called by EAS when an attestation is created under the identity link schema. Verifies that `msg.sender` (via EAS relay) is the owner of the claimed `agentId` on the local Identity Registry. Also called on revocation (always allows revocation by the original attester).

- **`AgentIdentityLinker.sol`** — The main contract. Orchestrates attestation creation via EAS, maintains indexed mappings for O(1) lookups, and exposes the public query interface (`isLinked()`, `getLinks()`, `getLinkByChain()`). Not upgradeable. Owned only for schema registration (one-time setup), then ownership is renounced.

**Off-chain components:**
- None. The entire flow is on-chain transactions. No keeper, no relayer, no indexer required.

**External dependencies:**
- EAS contracts (per chain)
- ERC-8004 Identity Registry (per chain)

### 3b. Smart Contract Interfaces

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAgentIdentityLinker
/// @notice Creates and manages EAS attestations that link ERC-8004 agent
///         identities across chains. Each link is a paired attestation:
///         one on the source chain, one on the destination chain.
interface IAgentIdentityLinker {

    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────

    /// @notice Parameters for creating an identity link attestation.
    /// @param localAgentId The agent's tokenId in the local Identity Registry.
    /// @param remoteChainId The chain ID where the agent has another registration.
    /// @param remoteRegistryAddress The Identity Registry address on the remote chain.
    /// @param remoteAgentId The agent's tokenId in the remote Identity Registry.
    /// @param expirationTime Unix timestamp when this link expires (0 = no expiry).
    /// @param refUID UID of the paired attestation on the remote chain (bytes32(0)
    ///        if this is the first attestation in the pair).
    struct LinkParams {
        uint256 localAgentId;
        uint256 remoteChainId;
        address remoteRegistryAddress;
        uint256 remoteAgentId;
        uint64 expirationTime;
        bytes32 refUID;
    }

    /// @notice Stored record of an identity link.
    /// @param attestationUID The EAS attestation UID for this link.
    /// @param localAgentId Agent's tokenId on this chain.
    /// @param remoteChainId Chain ID of the linked registration.
    /// @param remoteRegistryAddress Identity Registry on the remote chain.
    /// @param remoteAgentId Agent's tokenId on the remote chain.
    /// @param pairedAttestationUID The UID of the paired attestation on the
    ///        remote chain (bytes32(0) if pairing is incomplete).
    /// @param owner The address that created the link (verified NFT owner
    ///        at attestation time).
    /// @param createdAt Block timestamp when the link was created.
    /// @param revoked Whether this link has been revoked.
    struct LinkRecord {
        bytes32 attestationUID;
        uint256 localAgentId;
        uint256 remoteChainId;
        address remoteRegistryAddress;
        uint256 remoteAgentId;
        bytes32 pairedAttestationUID;
        address owner;
        uint64 createdAt;
        bool revoked;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a new identity link attestation is created.
    event LinkCreated(
        bytes32 indexed attestationUID,
        uint256 indexed localAgentId,
        uint256 indexed remoteChainId,
        address remoteRegistryAddress,
        uint256 remoteAgentId,
        address owner
    );

    /// @notice Emitted when a link is paired with its remote counterpart.
    event LinkPaired(
        bytes32 indexed localUID,
        bytes32 indexed remoteUID
    );

    /// @notice Emitted when a link is revoked.
    event LinkRevoked(
        bytes32 indexed attestationUID,
        uint256 indexed localAgentId,
        address revokedBy
    );

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Caller is not the owner of the local agentId.
    error NotAgentOwner(uint256 agentId, address caller);

    /// @notice The remote chain ID is zero or equals the local chain ID.
    error InvalidRemoteChain(uint256 remoteChainId);

    /// @notice The remote registry address is the zero address.
    error InvalidRemoteRegistry();

    /// @notice A link already exists between these two agent registrations.
    error LinkAlreadyExists(uint256 localAgentId, uint256 remoteChainId,
        address remoteRegistry, uint256 remoteAgentId);

    /// @notice The attestation UID does not correspond to a known link.
    error LinkNotFound(bytes32 attestationUID);

    /// @notice Caller is not authorized to revoke this link.
    error NotLinkOwner(bytes32 attestationUID, address caller);

    /// @notice The link has already been revoked.
    error LinkAlreadyRevoked(bytes32 attestationUID);

    /// @notice The paired UID does not match the expected link.
    error PairingMismatch(bytes32 localUID, bytes32 remoteUID);

    /// @notice The link is already paired.
    error AlreadyPaired(bytes32 attestationUID);

    /// @notice The EAS schema has not been initialized.
    error SchemaNotInitialized();

    // ──────────────────────────────────────────────
    //  Write functions
    // ──────────────────────────────────────────────

    /// @notice Create an identity link attestation on this chain.
    ///         The caller must own `localAgentId` in the local Identity Registry.
    ///         The resolver verifies ownership at attestation time.
    ///         If `refUID` is non-zero, it is set as the EAS refUID,
    ///         creating a reference to the paired attestation on the
    ///         remote chain.
    /// @param params The link parameters.
    /// @return attestationUID The UID of the created EAS attestation.
    function createLink(
        LinkParams calldata params
    ) external returns (bytes32 attestationUID);

    /// @notice Record the paired attestation UID from the remote chain.
    ///         This completes the bidirectional link on this chain's side.
    ///         Can only be called by the original link creator.
    ///         Does NOT verify the remote UID on-chain (no cross-chain read);
    ///         the trust derives from the same owner creating both attestations
    ///         with resolver-verified ownership on each chain.
    /// @param localUID The attestation UID on this chain.
    /// @param remoteUID The attestation UID on the remote chain.
    function completePairing(
        bytes32 localUID,
        bytes32 remoteUID
    ) external;

    /// @notice Revoke an identity link. Revokes the EAS attestation and
    ///         marks the link record as revoked in the linker's storage.
    ///         Can only be called by the address that created the link.
    /// @param attestationUID The UID of the attestation to revoke.
    function revokeLink(bytes32 attestationUID) external;

    // ──────────────────────────────────────────────
    //  Read functions
    // ──────────────────────────────────────────────

    /// @notice Check if an agent has any active (non-revoked, non-expired)
    ///         identity links on this chain.
    /// @param localAgentId The agent's tokenId on this chain.
    /// @return linked True if at least one active link exists.
    function isLinked(uint256 localAgentId) external view returns (bool linked);

    /// @notice Get all link records for an agent on this chain.
    ///         Includes revoked links (check `revoked` field).
    /// @param localAgentId The agent's tokenId on this chain.
    /// @return records Array of link records.
    function getLinks(
        uint256 localAgentId
    ) external view returns (LinkRecord[] memory records);

    /// @notice Get the link record for a specific agent-to-chain pair.
    ///         Reverts if no link exists for this pair.
    /// @param localAgentId The agent's tokenId on this chain.
    /// @param remoteChainId The target chain ID.
    /// @param remoteRegistryAddress The Identity Registry on the target chain.
    /// @param remoteAgentId The agent's tokenId on the target chain.
    /// @return record The link record.
    function getLinkByRemote(
        uint256 localAgentId,
        uint256 remoteChainId,
        address remoteRegistryAddress,
        uint256 remoteAgentId
    ) external view returns (LinkRecord memory record);

    /// @notice Get the EAS schema UID used by this linker.
    /// @return schemaUID The schema UID.
    function getSchemaUID() external view returns (bytes32 schemaUID);

    /// @notice Get the address of the Identity Registry on this chain.
    /// @return registry The Identity Registry address.
    function getIdentityRegistry() external view returns (address registry);

    /// @notice Get the address of the EAS contract on this chain.
    /// @return eas The EAS contract address.
    function getEAS() external view returns (address eas);
}
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Attestation} from "@eas/contracts/IEAS.sol";

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
```

### 3c. Data Structures and Storage Layout

**EAS Schema Definition:**

```
uint256 localAgentId,uint256 remoteChainId,address remoteRegistryAddress,uint256 remoteAgentId
```

Schema properties:
- **Resolver:** `IdentityLinkResolver` contract address
- **Revocable:** `true`

The schema is registered once per chain via `ISchemaRegistry.register()`. The returned `schemaUID` is stored as an immutable in `AgentIdentityLinker`.

**EAS Attestation Data Encoding:**

```solidity
abi.encode(
    uint256 localAgentId,
    uint256 remoteChainId,
    address remoteRegistryAddress,
    uint256 remoteAgentId
)
```

EAS `AttestationRequestData` fields:
- `recipient`: `address(0)` (the attestation is about the agent, not a recipient)
- `expirationTime`: passed from `LinkParams.expirationTime` (0 = no expiry)
- `revocable`: `true`
- `refUID`: passed from `LinkParams.refUID` (bytes32(0) for first in pair)
- `data`: ABI-encoded schema data above
- `value`: `0` (no ETH sent to resolver)

**AgentIdentityLinker Storage:**

```solidity
/// @dev EAS contract address (immutable, set in constructor).
IEAS public immutable eas;

/// @dev Identity Registry address on this chain (immutable).
address public immutable identityRegistry;

/// @dev Schema UID (immutable, set in constructor after registration).
bytes32 public immutable schemaUID;

/// @dev Attestation UID → LinkRecord.
mapping(bytes32 => LinkRecord) internal _links;

/// @dev localAgentId → array of attestation UIDs.
mapping(uint256 => bytes32[]) internal _agentLinks;

/// @dev Deduplication: keccak256(localAgentId, remoteChainId,
///      remoteRegistryAddress, remoteAgentId) → attestation UID.
///      Prevents duplicate links for the same agent pair.
///      Cleared on revocation to allow re-linking.
mapping(bytes32 => bytes32) internal _linkKeys;
```

**IdentityLinkResolver Storage:**

```solidity
/// @dev The AgentIdentityLinker address (immutable). Only attestations
///      created through the linker are accepted.
address public immutable linker;

/// @dev The ERC-8004 Identity Registry on this chain (immutable).
address public immutable identityRegistry;
```

### 3d. External Dependencies

| Dependency | Address / Version | Interface Used | Trust Assumption |
|---|---|---|---|
| EAS (Ethereum mainnet) | `0xA1207F3BBa224E2c9c3c6D5aF63D0eb1582Ce587` | `IEAS.attest()`, `IEAS.revoke()`, `IEAS.getAttestation()`, `IEAS.isAttestationValid()` | EAS contract is audited and immutable. Attestation storage is trustless. |
| EAS (Base mainnet) | `0x4200000000000000000000000000000000000021` | Same as above. | Same. Base predeploy — immutable. |
| EAS (Ethereum Sepolia) | `0xC2679fBD37d54388Ce493F1DB75320D236e1815e` | Same. Used in tests. | Same. |
| EAS (Base Sepolia) | `0x4200000000000000000000000000000000000021` | Same. Used in tests. | Same. |
| SchemaRegistry (Ethereum mainnet) | `0xA7b39296258348C78294F95B872b282326A97BDF` | `ISchemaRegistry.register()` | One-time schema registration. Immutable after creation. |
| SchemaRegistry (Base mainnet) | `0x4200000000000000000000000000000000000020` | Same. | Same. |
| SchemaRegistry (Ethereum Sepolia) | `0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0` | Same. Used in tests. | Same. |
| SchemaRegistry (Base Sepolia) | `0x4200000000000000000000000000000000000020` | Same. Used in tests. | Same. |
| ERC-8004 Identity Registry (all mainnets) | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `ownerOf(uint256)` (ERC-721), `isAuthorizedOrOwner(address, uint256)` | Deployed and verified. Ownership data is authoritative. |
| ERC-8004 Identity Registry (all testnets) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | Same. | Same. |
| OpenZeppelin Contracts | v5.3.0 | `Ownable` (for one-time schema init, then renounced) | Audited, widely used. |
| EAS Contracts (Solidity interfaces) | `@ethereum-attestation-service/eas-contracts` latest stable | `SchemaResolver` base contract, `IEAS`, `ISchemaRegistry`, `Attestation` struct | Published npm/Foundry package. |

### 3e. Security Considerations

**S1. Resolver ownership verification bypass.**
Risk: An attacker creates an attestation claiming `agentId=42` without owning it.
Mitigation: The `IdentityLinkResolver.onAttest()` decodes `localAgentId` from the attestation data and calls `identityRegistry.ownerOf(localAgentId)`. If the return value does not match the attester address (passed by EAS as `attestation.attester`), the resolver returns `false`, rejecting the attestation. The resolver also requires `attestation.attester == linker`, ensuring attestations can only be created through the `AgentIdentityLinker` contract, which in turn verifies `msg.sender` is the NFT owner before calling EAS.

**S2. Front-running `createLink()`.**
Risk: An attacker sees a `createLink()` transaction in the mempool and front-runs with their own, claiming the same `(localAgentId, remoteChainId, remoteRegistry, remoteAgentId)` pair.
Mitigation: The resolver checks `ownerOf(localAgentId)` — the attacker cannot pass this check unless they own the NFT. Additionally, `createLink()` verifies `msg.sender` is the NFT owner before calling EAS, so front-running with a different sender fails.

**S3. Stale links after NFT transfer.**
Risk: An agent owner creates a link, then transfers the NFT to a new owner. The link attestation remains valid, falsely claiming the old owner's cross-chain identity.
Mitigation: Links are revocable. The original creator can call `revokeLink()`. However, a transferred-to owner cannot revoke links they didn't create. Consumers should check `expirationTime` and use short-lived links (6–12 months) for sensitive applications. A future v2 could add a `revokeAsCurrentOwner()` function that checks current `ownerOf()`.

**S4. Duplicate link prevention.**
Risk: An agent creates multiple links for the same `(localAgentId, remoteChainId, remoteRegistry, remoteAgentId)` tuple, inflating link counts or confusing consumers.
Mitigation: The `_linkKeys` mapping stores `keccak256(localAgentId, remoteChainId, remoteRegistryAddress, remoteAgentId) → attestationUID`. `createLink()` reverts with `LinkAlreadyExists` if a non-revoked link already exists for this key. On revocation, the key is cleared, allowing re-linking.

**S5. Resolver reentrancy.**
Risk: The resolver calls `ownerOf()` on the Identity Registry, which could theoretically be a malicious contract.
Mitigation: The Identity Registry addresses are immutable and set at construction — they point to the canonical ERC-8004 deployments. The `ownerOf()` call is a `view` function with no state-changing side effects. The resolver runs inside EAS's `attest()` transaction, and EAS itself enforces the resolver's return value before storing the attestation.

**S6. Cross-chain pairing without verification.**
Risk: `completePairing()` accepts a `remoteUID` without verifying it exists on the remote chain. An attacker could pair with a fabricated UID.
Mitigation: This is a deliberate design choice — cross-chain verification would require a messaging layer, which this project avoids. The trust model is: the same address that owns both NFTs (verified by resolvers on each chain) creates both attestations and pairs them. A fabricated `remoteUID` provides no benefit to an attacker because the link's value comes from the resolver-verified ownership on each chain, not from the pairing itself. Consumers that need stronger guarantees should verify the `remoteUID` via off-chain indexing or a future cross-chain read integration.

**S7. EAS attestation data tampering.**
Risk: The attestation data could be malformed or encode unexpected values.
Mitigation: `AgentIdentityLinker.createLink()` constructs the attestation data itself from validated `LinkParams` — the caller does not provide raw encoded data. The resolver decodes and re-validates the data. Mismatched encoding would cause `abi.decode` to revert.

**S8. Griefing via mass attestation.**
Risk: An attacker with many agent NFTs creates thousands of link attestations, bloating the `_agentLinks` array.
Mitigation: Each `createLink()` requires the caller to own the local `agentId` (verified by both the linker and the resolver). An attacker can only create links for agents they own. The `_linkKeys` deduplication prevents duplicate links for the same pair. The `_agentLinks` array grows linearly with the number of *distinct* remote registrations an agent links to — bounded by the number of chains, which is small.

### 3f. Gas Analysis

Gas estimates for Base mainnet (L2 execution + L1 data posting). Ethereum mainnet will be ~2–5x more expensive for execution but identical for contract logic.

| Operation | Estimated Gas (L2 execution) | Breakdown |
|---|---|---|
| `createLink()` | ~180,000–220,000 | Ownership check via `ownerOf()` (~5K) + dedup key check (~5K) + EAS `attest()` (~120K incl. resolver callback) + storage writes for `_links`, `_agentLinks`, `_linkKeys` (~50K–70K) |
| `completePairing()` | ~35,000–45,000 | Storage read for link record (~5K) + ownership check (~3K) + storage write for `pairedAttestationUID` (~20K) + event (~5K) |
| `revokeLink()` | ~80,000–100,000 | Storage read (~5K) + EAS `revoke()` (~50K) + storage update for `revoked` flag (~5K) + clear `_linkKeys` (~5K) + event (~5K) |
| `isLinked()` | ~8,000–15,000 | Read `_agentLinks` array length (~3K) + iterate and check revoked/expired status (~5K per entry, typically 1–3 entries) |
| `getLinks()` | ~10,000–30,000 | Read and copy array (~10K base + ~5K per entry). View function, no on-chain gas cost when called off-chain. |
| `getLinkByRemote()` | ~8,000–12,000 | Compute dedup key (~1K) + storage read (~5K) + read link record (~3K) |

**Economic viability:**

- On Base mainnet at ~0.01 gwei L2 fee: `createLink()` costs ~$0.002–0.005. Paired attestation (both chains on Base-like L2s): < $0.01 total.
- On Ethereum mainnet at 30 gwei: `createLink()` costs ~$0.15–0.25. Acceptable as a one-time identity setup cost.
- The full flow (create on chain A + create on chain B + completePairing on chain A) costs < $0.30 total for two L2 chains, or ~$0.50 with one L1 chain. This is a one-time cost per cross-chain link, amortized over the lifetime of the agent's operation.

## 4. Implementation Guide

### Step 1: Initialize Foundry project

Create the Foundry project structure and install dependencies.

**Files to create:**
- `foundry.toml`
- `src/` directory
- `test/` directory
- `script/` directory

**Commands:**
```bash
cd ai-on-chain-projects/eas-identity-linker
forge init --no-git --no-commit .
forge install OpenZeppelin/openzeppelin-contracts@v5.3.0 --no-git --no-commit
forge install ethereum-attestation-service/eas-contracts --no-git --no-commit
```

**Configure `foundry.toml`:**
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.28"
optimizer = true
optimizer_runs = 10000
via_ir = false
evm_version = "cancun"

remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "@eas/contracts/=lib/eas-contracts/contracts/",
]

[profile.default.fuzz]
runs = 1000
max_test_rejects = 100000

[fmt]
line_length = 100
tab_width = 4
bracket_spacing = false
int_types = "long"
multiline_func_header = "params_first"
quote_style = "double"
number_underscore = "thousands"
```

**Verification:** `forge build` succeeds with no warnings.

### Step 2: Implement IdentityLinkResolver

**File:** `src/IdentityLinkResolver.sol`

Implement the EAS schema resolver:
- Inherits `SchemaResolver` from `@eas/contracts/resolver/SchemaResolver.sol`
- Constructor takes `IEAS _eas`, `address _linker`, `address _identityRegistry`
- `onAttest(Attestation calldata attestation, uint256)`:
  1. Verify `attestation.attester == linker` — revert with `UnauthorizedAttester` if not
  2. Decode `(uint256 localAgentId, , , )` from `attestation.data`
  3. Call `IERC721(identityRegistry).ownerOf(localAgentId)`
  4. Verify owner matches the actual agent owner (passed as the `recipient` field or derived — see implementation note below)
  5. Return `true` if valid
- `onRevoke(Attestation calldata, uint256)`: always returns `true` (revocation is controlled by the linker)
- `isPayable()`: returns `false`

**Implementation note on ownership verification:** The resolver needs to verify that the person who initiated `createLink()` owns the local agent NFT. Since EAS sets `attestation.attester` to `msg.sender` of the `attest()` call (which is the `AgentIdentityLinker` contract, not the end user), the linker must pass the actual owner address in the attestation. The cleanest approach: use `attestation.recipient` to carry the original caller address. The resolver then checks `ownerOf(localAgentId) == attestation.recipient`.

**Verification:** `forge build` succeeds.

### Step 3: Implement AgentIdentityLinker

**File:** `src/AgentIdentityLinker.sol`

Implement the main contract:
- Constructor takes `IEAS _eas`, `ISchemaRegistry _schemaRegistry`, `address _identityRegistry`, `address _resolver`
- In the constructor: register the EAS schema via `_schemaRegistry.register(schemaString, ISchemaResolver(_resolver), true)` and store the returned `schemaUID` as immutable
- `createLink(LinkParams calldata params)`:
  1. Verify `msg.sender == IERC721(identityRegistry).ownerOf(params.localAgentId)` — revert `NotAgentOwner`
  2. Verify `params.remoteChainId != 0 && params.remoteChainId != block.chainid` — revert `InvalidRemoteChain`
  3. Verify `params.remoteRegistryAddress != address(0)` — revert `InvalidRemoteRegistry`
  4. Compute dedup key, check `_linkKeys[key] == bytes32(0)` or the existing link is revoked — revert `LinkAlreadyExists`
  5. Encode attestation data: `abi.encode(params.localAgentId, params.remoteChainId, params.remoteRegistryAddress, params.remoteAgentId)`
  6. Call `eas.attest(AttestationRequest({schema: schemaUID, data: AttestationRequestData({recipient: msg.sender, expirationTime: params.expirationTime, revocable: true, refUID: params.refUID, data: encodedData, value: 0})}))`
  7. Store `LinkRecord` in `_links[uid]`
  8. Append `uid` to `_agentLinks[params.localAgentId]`
  9. Store `_linkKeys[key] = uid`
  10. Emit `LinkCreated`
- `completePairing(bytes32 localUID, bytes32 remoteUID)`:
  1. Load `_links[localUID]`, verify it exists and is not revoked
  2. Verify `msg.sender == _links[localUID].owner` — revert `NotLinkOwner`
  3. Verify `_links[localUID].pairedAttestationUID == bytes32(0)` — revert `AlreadyPaired`
  4. Store `_links[localUID].pairedAttestationUID = remoteUID`
  5. Emit `LinkPaired`
- `revokeLink(bytes32 attestationUID)`:
  1. Load `_links[attestationUID]`, verify exists
  2. Verify `msg.sender == _links[attestationUID].owner` — revert `NotLinkOwner`
  3. Verify `!_links[attestationUID].revoked` — revert `LinkAlreadyRevoked`
  4. Call `eas.revoke(RevocationRequest({schema: schemaUID, data: RevocationRequestData({uid: attestationUID, value: 0})}))`
  5. Set `_links[attestationUID].revoked = true`
  6. Clear `_linkKeys[dedupKey]`
  7. Emit `LinkRevoked`
- `isLinked(uint256 localAgentId)`: iterate `_agentLinks[localAgentId]`, return `true` if any entry is non-revoked and non-expired (check `expirationTime == 0 || expirationTime > block.timestamp` via EAS `isAttestationValid()`)
- `getLinks(uint256 localAgentId)`: return full `LinkRecord[]` for the agent
- `getLinkByRemote(...)`: compute dedup key, load from `_linkKeys` and `_links`
- Getter functions: `getSchemaUID()`, `getIdentityRegistry()`, `getEAS()`

**Verification:** `forge build` succeeds.

### Step 4: Implement test mocks

**File:** `test/mocks/MockIdentityRegistry.sol`

A minimal ERC-721 mock that simulates the ERC-8004 Identity Registry:
- `mint(address to, uint256 agentId)` — mints an agent NFT
- `ownerOf(uint256 agentId)` — standard ERC-721
- `transferFrom(address from, address to, uint256 agentId)` — standard ERC-721
- `isAuthorizedOrOwner(address spender, uint256 agentId)` — returns true if owner or approved

**File:** `test/mocks/MockEAS.sol`

Do NOT mock EAS. Use the real EAS contracts in a forked environment (Step 7) and deploy fresh EAS + SchemaRegistry instances for unit tests using the actual EAS contract code from the installed dependency.

**Verification:** `forge build` succeeds.

### Step 5: Implement unit tests

**File:** `test/IdentityLinkResolver.t.sol`

Deploy fresh EAS, SchemaRegistry, MockIdentityRegistry, IdentityLinkResolver, and AgentIdentityLinker in `setUp()`.

| Test Function | Scenario |
|---|---|
| `test_OnAttest_ValidOwner_ReturnsTrue` | Attester owns the agentId, attestation succeeds |
| `test_OnAttest_NotOwner_Reverts` | Attester does not own agentId, attestation rejected |
| `test_OnAttest_UnauthorizedAttester_Reverts` | Direct EAS attest (not via linker) is rejected |
| `test_OnAttest_InvalidData_Reverts` | Malformed attestation data |
| `test_OnRevoke_AlwaysReturnsTrue` | Revocation always allowed |

**File:** `test/AgentIdentityLinker.t.sol`

**createLink tests:**

| Test Function | Scenario |
|---|---|
| `test_CreateLink_ValidOwner_CreatesAttestation` | Happy path: owner creates link, attestation UID returned, events emitted |
| `test_CreateLink_NotOwner_Reverts` | Non-owner calls createLink |
| `test_CreateLink_ZeroRemoteChainId_Reverts` | `remoteChainId = 0` |
| `test_CreateLink_SameChainId_Reverts` | `remoteChainId == block.chainid` |
| `test_CreateLink_ZeroRemoteRegistry_Reverts` | `remoteRegistryAddress = address(0)` |
| `test_CreateLink_DuplicateLink_Reverts` | Same agent pair linked twice without revoking |
| `test_CreateLink_AfterRevocation_Succeeds` | Revoke then re-link same pair |
| `test_CreateLink_WithRefUID_SetsReference` | Second attestation references first via refUID |
| `test_CreateLink_WithExpiration_SetsExpiry` | Non-zero expirationTime stored correctly |
| `test_CreateLink_StorageConsistency` | Verify `_links`, `_agentLinks`, `_linkKeys` all populated correctly |
| `test_CreateLink_EmitsLinkCreated` | Event fields match input params |

**completePairing tests:**

| Test Function | Scenario |
|---|---|
| `test_CompletePairing_ValidOwner_SetsPairedUID` | Happy path |
| `test_CompletePairing_NotOwner_Reverts` | Non-creator calls completePairing |
| `test_CompletePairing_AlreadyPaired_Reverts` | Call completePairing twice |
| `test_CompletePairing_RevokedLink_Reverts` | Pair a revoked link |
| `test_CompletePairing_NonexistentUID_Reverts` | Random UID |
| `test_CompletePairing_EmitsLinkPaired` | Event fields correct |

**revokeLink tests:**

| Test Function | Scenario |
|---|---|
| `test_RevokeLink_ValidOwner_RevokesAttestation` | Happy path: EAS attestation revoked, storage updated |
| `test_RevokeLink_NotOwner_Reverts` | Non-creator calls revokeLink |
| `test_RevokeLink_AlreadyRevoked_Reverts` | Double revocation |
| `test_RevokeLink_NonexistentUID_Reverts` | Random UID |
| `test_RevokeLink_ClearsDedupKey` | After revocation, same pair can be re-linked |
| `test_RevokeLink_EmitsLinkRevoked` | Event fields correct |

**Read function tests:**

| Test Function | Scenario |
|---|---|
| `test_IsLinked_ActiveLink_ReturnsTrue` | Agent with one active link |
| `test_IsLinked_NoLinks_ReturnsFalse` | Agent with no links |
| `test_IsLinked_AllRevoked_ReturnsFalse` | Agent with only revoked links |
| `test_IsLinked_ExpiredLink_ReturnsFalse` | Agent with only expired link |
| `test_IsLinked_MixedLinks_ReturnsTrue` | One revoked, one active |
| `test_GetLinks_ReturnsAllIncludingRevoked` | Verify revoked links included |
| `test_GetLinks_EmptyAgent_ReturnsEmpty` | Agent with no links |
| `test_GetLinkByRemote_ExistingLink_ReturnsRecord` | Happy path |
| `test_GetLinkByRemote_NoLink_Reverts` | No link for this pair |
| `test_GetSchemaUID_ReturnsNonZero` | Schema was registered |
| `test_GetIdentityRegistry_ReturnsCorrectAddress` | Constructor param stored |
| `test_GetEAS_ReturnsCorrectAddress` | Constructor param stored |

**NFT transfer scenario tests:**

| Test Function | Scenario |
|---|---|
| `test_CreateLink_AfterTransfer_NewOwnerCanLink` | Transfer NFT, new owner creates fresh link |
| `test_RevokeLink_AfterTransfer_OriginalCreatorCanRevoke` | Original creator can still revoke their link after NFT transfer |
| `test_CreateLink_AfterTransfer_OldOwnerCannotLink` | Old owner cannot create new links for transferred agent |

**Verification:** `forge test -vv` — all tests pass. `forge test --gas-report` — `createLink` < 230,000 gas.

### Step 6: Implement fuzz tests

**File:** `test/AgentIdentityLinker.fuzz.t.sol`

| Test Function | Invariant |
|---|---|
| `testFuzz_CreateLink_AlwaysVerifiesOwnership(uint256 agentId, uint256 remoteChainId, address remoteRegistry, uint256 remoteAgentId)` | For any valid inputs, `createLink` only succeeds when `msg.sender == ownerOf(agentId)`. Bound: `remoteChainId > 0 && remoteChainId != block.chainid`, `remoteRegistry != address(0)`. |
| `testFuzz_CreateLink_NoDuplicates(uint256 agentId, uint256 remoteChainId, address remoteRegistry, uint256 remoteAgentId)` | After a successful `createLink`, a second call with the same params reverts with `LinkAlreadyExists`. |
| `testFuzz_RevokeAndRelink_AlwaysSucceeds(uint256 agentId, uint256 remoteChainId, address remoteRegistry, uint256 remoteAgentId)` | After `createLink` + `revokeLink`, a second `createLink` with the same params succeeds. |
| `testFuzz_IsLinked_ConsistentWithGetLinks(uint256 agentId)` | `isLinked(agentId)` returns `true` iff `getLinks(agentId)` contains at least one non-revoked, non-expired entry. |

**Verification:** `forge test --match-path test/AgentIdentityLinker.fuzz.t.sol -vv` — 1,000 fuzz runs pass.

### Step 7: Implement deployment script

**File:** `script/Deploy.s.sol`

A Forge script that deploys the full system:
1. Deploy `IdentityLinkResolver` with constructor args: EAS address (chain-specific), linker address (precomputed via CREATE2), Identity Registry address (chain-specific)
2. Deploy `AgentIdentityLinker` with constructor args: EAS address, SchemaRegistry address, Identity Registry address, resolver address. The constructor registers the schema.
3. Log all deployed addresses, schema UID, and domain info.

Use CREATE2 via Safe Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`) for deterministic addresses across chains.

**File:** `script/VerifyDeployment.s.sol`

Read-only script:
1. Call `getSchemaUID()`, `getIdentityRegistry()`, `getEAS()` on the linker
2. Call `getSchema(schemaUID)` on the SchemaRegistry to verify schema is registered with correct resolver
3. Log all values for manual verification

**Verification:** `forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_KEY --broadcast` deploys successfully on Base Sepolia. Do **not** deploy to mainnet without explicit operator confirmation.

### Step 8: Integration test against forked chain state

**File:** `test/AgentIdentityLinker.integration.t.sol`

Fork Base Sepolia (`forge test --fork-url $BASE_SEPOLIA_RPC`).

| Test Function | Scenario |
|---|---|
| `test_Integration_FullLinkFlow_BaseSepolia` | Register a new agent on Base Sepolia's Identity Registry fork, deploy resolver + linker against the real EAS, create a link claiming a remote Ethereum Sepolia registration, verify `isLinked()` returns true, verify EAS `getAttestation()` returns correct data. |
| `test_Integration_RevokeFlow_BaseSepolia` | Create a link on fork, revoke it, verify `isLinked()` returns false, verify EAS attestation is revoked. |
| `test_Integration_ResolverRejectsNonOwner_BaseSepolia` | Attempt to create a link for an agent owned by a different address on the forked Identity Registry. Verify revert. |

**Verification:** `forge test --match-path test/AgentIdentityLinker.integration.t.sol --fork-url $BASE_SEPOLIA_RPC -vv` — all tests pass.

## 5. Testing Plan

### Unit Tests

**Files:** `test/IdentityLinkResolver.t.sol`, `test/AgentIdentityLinker.t.sol`
**Mock dependencies:** `MockIdentityRegistry.sol` (minimal ERC-721). Real EAS + SchemaRegistry contracts deployed fresh in each test suite's `setUp()`.
**Convention:** `test_FunctionName_Condition_ExpectedResult`
**Coverage target:** Every `external` function in both contracts. Every custom error triggered by at least one test. Every storage mapping verified for consistency.

39 test cases specified across Steps 5.

### Integration Tests

**File:** `test/AgentIdentityLinker.integration.t.sol`
**Fork:** Base Sepolia via `--fork-url`.
**Scenarios:** 3 test cases specified in Step 8.

### Fuzz Tests

**File:** `test/AgentIdentityLinker.fuzz.t.sol`
**Runs:** 1,000 per function.
**Invariants:**
1. `createLink` only succeeds when caller is NFT owner.
2. No duplicate links for the same `(localAgentId, remoteChainId, remoteRegistry, remoteAgentId)` tuple.
3. Revoke-then-relink always succeeds.
4. `isLinked()` is consistent with `getLinks()` for any agent.

4 fuzz test functions specified in Step 6.

## 6. Reference Materials

- **ERC-8004 spec text** — `8004-contracts/erc-8004-contracts/ERC8004SPEC.md` in this repo. Defines Identity Registry interface, `ownerOf()`, and `registrations[]` array.
- **ERC-8004 Identity Registry implementation** — `8004-contracts/erc-8004-contracts/contracts/IdentityRegistryUpgradeable.sol`. Reference for `ownerOf()`, `isAuthorizedOrOwner()`, and the ERC-721 base.
- **ERC-8004 deployed addresses** — `8004-contracts/erc-8004-contracts/scripts/addresses.ts`. Mainnet: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`. Testnet: `0x8004A818BFB912233c491871b3d84c89A494BD9e`.
- **EAS contracts source** — https://github.com/ethereum-attestation-service/eas-contracts. `IEAS.sol`, `ISchemaRegistry.sol`, `SchemaResolver.sol` base contract for custom resolvers.
- **EAS documentation** — https://docs.attest.org/. Schema creation, attestation lifecycle, resolver pattern.
- **EAS deployed addresses** — https://docs.attest.org/docs/quick--start/contracts. Per-chain contract addresses for EAS and SchemaRegistry.
- **EIP-721 spec** — https://eips.ethereum.org/EIPS/eip-721. `ownerOf()` interface used by the resolver.
- **Safe Singleton Factory** — deployed at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` on all EVM chains. Used for deterministic CREATE2 deployment.
