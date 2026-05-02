# EAS-Based Identity Linker

A smart contract system that enables ERC-8004 agent owners to prove cross-chain identity linkage using Ethereum Attestation Service (EAS) attestations. Agent owners create paired attestations on each chain where they hold an agent NFT; a resolver contract verifies NFT ownership at attestation time; an indexed registry contract provides O(1) on-chain lookups via `isLinked()`. Supports revocable links, duplicate prevention, and bidirectional pairing. Deploys on Base and Ethereum mainnet.

**Status:** Implemented — 49 tests passing (38 unit, 4 fuzz × 1000 runs each, 4 resolver, 3 fork-only integration scaffolds).

## Layout

- `src/AgentIdentityLinker.sol` — main contract (link CRUD + indexed lookups)
- `src/IdentityLinkResolver.sol` — EAS schema resolver verifying ERC-721 ownership
- `src/IAgentIdentityLinker.sol`, `src/IIdentityLinkResolver.sol` — interfaces
- `test/` — unit, fuzz, fork-based integration tests
- `script/Deploy.s.sol`, `script/VerifyDeployment.s.sol` — deployment + verification

## Build & test

```bash
forge build
forge test
forge test --gas-report
```

Integration tests auto-skip unless run against Base Sepolia:

```bash
forge test --match-path test/AgentIdentityLinker.integration.t.sol \
    --fork-url $BASE_SEPOLIA_RPC -vv
```

## Deploy

```bash
DEPLOYER_KEY=0x... forge script script/Deploy.s.sol \
    --rpc-url $BASE_SEPOLIA_RPC --broadcast
```

The deploy script picks canonical EAS / SchemaRegistry / ERC-8004 addresses for chain ids 1, 8453, 11155111, 84532. Provide `EAS_ADDRESS`, `SCHEMA_REGISTRY_ADDRESS`, `IDENTITY_REGISTRY_ADDRESS` env vars to override.

See [PRD.md](PRD.md) for the full specification.
