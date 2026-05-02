# EAS-Based Identity Linker

A smart contract system that enables ERC-8004 agent owners to prove cross-chain identity linkage using Ethereum Attestation Service (EAS) attestations. Agent owners create paired attestations on each chain where they hold an agent NFT; a resolver contract verifies NFT ownership at attestation time; an indexed registry contract provides O(1) on-chain lookups via `isLinked()`. Supports revocable links, duplicate prevention, and bidirectional pairing. Deploys on Base and Ethereum mainnet.

**Status:** Not Started

See [PRD.md](PRD.md) for full specification.
