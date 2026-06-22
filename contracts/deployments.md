# Deployments

## Sepolia (chainId 11155111) — 2026-06-22

| contract | address |
|---|---|
| `BIP340Verifier` | [`0x681DfB46b744519a321dE187339386d6E8f67195`](https://sepolia.etherscan.io/address/0x681DfB46b744519a321dE187339386d6E8f67195) |
| `RecoveryEscrow` | [`0x03e2a9Ec424eF063ee78212A17aC9D25F26fdb15`](https://sepolia.etherscan.io/address/0x03e2a9Ec424eF063ee78212A17aC9D25F26fdb15) |

- **Pinned issuer** (agent x-only pubkey): `0xa0de083ca870991bcc5adb1a836abc3480aa83aa4a13773ed3d1877f1ce77ca1` — throwaway demo key.
- **Deployer**: `0xFf9a176577Fb42b6bc9c19fd05a241e8fCd0ca14`.
- **On-chain verified**: `BIP340Verifier.verify(<real agent-signed receipt>)` → `(valid=true, match=true)`; wrong expect-hash → `match=false`. `escrow.verifier()` points at the deployed verifier.
### Full fee-release demo (end-to-end, on-chain)
Exercised the complete gate — `valid ∧ artifactHashMatches ∧ delivery` — with a real agent-signed receipt and a live fee payout:
- `DemoERC721` (settable-owner stand-in for the BaseRegistrar): `0x3D6a74F5BFAf8e6D1b621D0c271f492518b8EEaa` (tokenId `keccak256("gobross")` minted to `output_address`).
- `openJob` tx: [`0xe304a0c8…fafe6`](https://sepolia.etherscan.io/tx/0xe304a0c835a11ba65a758fcb6550fe014a66f58461eb1c17a031e62a4c6fafe6) (0.001 ETH escrowed)
- `release` tx: [`0xed8974c7…94c48`](https://sepolia.etherscan.io/tx/0xed8974c7e842044cc81a7b5083a85a752aace38452b4352d4753028c54594c48) — block 11118096; **fee → agent, `artifact_hash` nullified.**
- Verified: agent payout address balance `0 → 0.001 ETH`. Replaying the same receipt now reverts (nullifier).
- Run via `bun run run-live.ts` (commit → BIP-340 sign → relay anchor → openJob → release).

- ⚠️ `BIP340.sol` pending independent audit before mainnet value.
