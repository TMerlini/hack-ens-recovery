# RecoveryEscrow (contracts)

On-chain escrow for the [Recovery Agent — Verifiable Escrow Flow](https://gist.github.com/TMerlini/98b7dbeb221024b617b36c7e3b79e695) (v1 design LOCKED w/ Fede, 2026-06-22).

The escrow is *the only thing that moves the fee*. It releases iff **all three** locked conditions hold — **never on `valid` alone** (the footgun the spec calls out):

| # | condition | who checks it | where |
|---|---|---|---|
| 1 | `valid` — receipt is a genuine BIP-340-signed invinoveritas proof | `IReceiptVerifier` | off-chain leg, surfaced on-chain |
| 2 | `artifactHashMatches` — receipt's `artifact_hash` == job's `expectArtifactHash` | `IReceiptVerifier` | off-chain leg, surfaced on-chain |
| 3 | **delivery** — `ownerOf(tokenId) == output_address` | `RecoveryEscrow` itself | **on-chain, trustless** |

On release it **nullifies** `expectArtifactHash` (mark-spent) so a replayed receipt can't be claimed twice. Owner-binding is structural (`output_address` is inside `expectArtifactHash`, computed off-chain by the SDK) **and** re-checked on-chain at delivery.

## Layout
- `src/RecoveryEscrow.sol` — escrow: `openJob` (fund) · `release` (permissionless, gated) · `refund` (requester, after expiry) · nullifier.
- `src/IReceiptVerifier.sol` — the `valid` + artifact-match seam (**the one open decision**, see below).
- `test/RecoveryEscrow.t.sol` — 10 tests incl. `test_release_neverOnValidAlone` (the headline invariant), replay/nullifier, refund.

## Build / test
```bash
forge install foundry-rs/forge-std   # restores lib/ (gitignored)
forge test -vv
```

## Design decisions

**Resolved with Fede (babyblueviper1), 2026-06-22:**

1. **Verifier leg → A (on-chain BIP-340). Fede owns the impl.** `BIP340Verifier` does schnorr verify via the `ecrecover` trick (~3k gas, native precompile — no bespoke secp256k1 lib), recomputes the kind-30078 event id via the sha256 precompile, and checks `content.artifact_hash == expectArtifactHash`. An SDK helper packs `receiptProof` byte-aligned with off-chain `verifyFullFlow()`. **B (attestor EIP-712) rejected** — it makes the verifier key the release authority, re-introducing the trust this model deletes. **Fallback C (optimistic)** invokes the A verifier on its challenge path, so no trusted key in any case. Drops straight into the `IReceiptVerifier` seam.
2. **`artifact_hash` → single SHA-256 canonical-JSON, opaque bytes32. No parallel keccak id.** A second canonicalization (TS sha256-over-JSON vs Solidity keccak-over-abi) would re-create the cross-language drift we removed by sharing `artifactHash(normalizeSpec(spec))`. The chain stays trustless without recomputing the spec: owner-binding via the on-chain delivery check, replay via the nullifier, and the A-path verify recomputes the *event id* (sha256) — keccak never needed.
3. **Delivery scope → v1 single ERC-721** (`ownerOf(tokenId)`, matches `rescue.ts`). Wrapped names (NameWrapper/1155) and multi-asset sets are **separate jobs**, not a loop — one job ↔ one nullifier is cleaner. (`asset_set` is already inside `expectArtifactHash`, so the receipt commits to the full set regardless.)
5. **Precedence stays off-chain.** commit-before-outcome ordering lives on `/ledger` via OTS→Bitcoin (`ots verify -d <event_id>`); pulling it on-chain buys nothing the relay+OTS record doesn't already give recomputably.

**Remaining:**

4. **Fee shape (commercial, ours).** Have `openJob`/`release`/`refund(after expiry)`. Not yet: fee splits, protocol fee, richer dispute path, cancel-before-commit. Nothing verifier-side blocks it.
6. **To build:** Fede's `BIP340Verifier` (impl A) + SDK calldata helper; then our side: deploy script (`script/`), testnet deploy + address, and wiring `release()` into the agent flow (`receipt.ts` → sign → `publishCommit` → `release`).
