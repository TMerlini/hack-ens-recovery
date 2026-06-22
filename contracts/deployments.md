# Deployments

## Sepolia (chainId 11155111) — 2026-06-22

| contract | address |
|---|---|
| `BIP340Verifier` | [`0x681DfB46b744519a321dE187339386d6E8f67195`](https://sepolia.etherscan.io/address/0x681DfB46b744519a321dE187339386d6E8f67195) |
| `RecoveryEscrow` | [`0x03e2a9Ec424eF063ee78212A17aC9D25F26fdb15`](https://sepolia.etherscan.io/address/0x03e2a9Ec424eF063ee78212A17aC9D25F26fdb15) |

- **Pinned issuer** (agent x-only pubkey): `0xa0de083ca870991bcc5adb1a836abc3480aa83aa4a13773ed3d1877f1ce77ca1` — throwaway demo key.
- **Deployer**: `0xFf9a176577Fb42b6bc9c19fd05a241e8fCd0ca14`.
- **On-chain verified**: `BIP340Verifier.verify(<real agent-signed receipt>)` → `(valid=true, match=true)`; wrong expect-hash → `match=false`. `escrow.verifier()` points at the deployed verifier.
- The delivery leg (`ownerOf == output_address`) is covered by unit tests; a full fee-release run on Sepolia needs a demo ERC-721 minted to `output_address`.
- ⚠️ `BIP340.sol` pending independent audit before mainnet value.
