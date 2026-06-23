# Deployments

## Sepolia (chainId 11155111) — 2026-06-23 · `trustless-ai.commit.v0`

Current deployment, under the **trustless-ai** scope + schema (`@trustless-ai/agent-sdk@0.2.0`, schema `trustless-ai.commit.v0`; verifier `SCHEMA_MARKER = "trustless-ai.commit"`).

| contract | address |
|---|---|
| `BIP340Verifier` | [`0x7c99c52Ed86EcedD65e60482243aa882a50F3b70`](https://sepolia.etherscan.io/address/0x7c99c52Ed86EcedD65e60482243aa882a50F3b70) |
| `RecoveryEscrow` | [`0x71D8E5a2AD591EEf8541527DFfD705BC69134f59`](https://sepolia.etherscan.io/address/0x71D8E5a2AD591EEf8541527DFfD705BC69134f59) |

- **Pinned issuer** (agent x-only pubkey): `0xa0de083ca870991bcc5adb1a836abc3480aa83aa4a13773ed3d1877f1ce77ca1` — throwaway demo key.
- **Deployer**: `0xFf9a176577Fb42b6bc9c19fd05a241e8fCd0ca14`.

### Full fee-release demo (end-to-end, on-chain, new schema)
Complete gate — `valid ∧ artifactHashMatches ∧ delivery` — with a real agent-signed receipt (`trustless-ai.commit.v0`) and a live fee payout:
- `DemoERC721` (settable-owner stand-in for the BaseRegistrar): `0x4EFeBb735eB06419D3890382737455e23AaB4DF5` (tokenId `keccak256("gobross")` minted to `output_address`).
- `openJob` tx: [`0x804e8d56…a579`](https://sepolia.etherscan.io/tx/0x804e8d564b098df48c794a1ba6e24dc94eda436a59028ba6da90c5e0cb6da579) (0.001 ETH escrowed)
- `release` tx: [`0x2684908b…93b2`](https://sepolia.etherscan.io/tx/0x2684908b3093590b31b6ced0d151d8b2589e6992890696b34eeb62b8412393b2) — block 11125260; **fee → agent, `artifact_hash` nullified.**
- Verified: agent payout balance `0 → 0.001 ETH`; replay reverts (nullifier). Run via `bun run run-live.ts`.

### Superseded — 2026-06-22 · `onchain-ai.commit.v0` (pre-rename)
The original deployment under the old scope/schema. Left intact (still valid for old-prefix receipts), superseded by the rename:
- `BIP340Verifier` `0x681DfB46b744519a321dE187339386d6E8f67195` · `RecoveryEscrow` `0x03e2a9Ec424eF063ee78212A17aC9D25F26fdb15` · demo release tx `0xed8974c7…94c48` (block 11118096).

- ⚠️ `BIP340.sol` pending independent audit before mainnet value.
