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
- `src/IReceiptVerifier.sol` — the `valid` + artifact-match seam.
- `src/BIP340.sol` — on-chain BIP-340 (secp256k1 Schnorr) verify via the `ecrecover` trick (~7.5k gas, native precompiles only). **Crypto-critical — get an independent review before mainnet value flows through it.**
- `src/BIP340Verifier.sol` — `IReceiptVerifier` impl A: decodes `receiptProof = abi.encode(px,rx,s,preimage)`, checks the sig over `sha256(preimage)`, pins the issuer key, extracts `artifact_hash` from the *signed* preimage.
- `script/Deploy.s.sol` — `BIP340Verifier(issuer) → RecoveryEscrow(verifier)`.
- `test/` — **24 tests green**: escrow (10, incl. `test_release_neverOnValidAlone`), BIP340 (7, real noble vector), BIP340Verifier (6, real SDK-signed receipt), Deploy wiring (1).

## Build / test
```bash
forge install foundry-rs/forge-std   # restores lib/ (gitignored)
forge test -vv
```

## Deploy
```bash
# .env: PRIVATE_KEY, RPC_URL, ISSUER_PUBKEY (x-only, 32-byte — default = the agent's AGENT_PUBKEY)
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
```

## Release flow (agent side)
The agent never gets a key past the SDK; the escrow enforces. End to end:
```
commitPreAction(artifact)         // build UNSIGNED kind-30078 (binds output_address + spec)
  → sign(event)                   // your own key mgmt; the SDK never signs
  → publishCommit(receipt)        // relay + OTS anchor (commit-before-outcome)
  → run the rescue (rescue.ts)    // flashbots bundle → output_address
  → buildReceiptProof(receipt)    // packReceiptProof(signedEvent) — byte-identical to what the contract hashes
  → escrow.release(receipt.artifact_hash, proof)   // permissionless; gated on valid ∧ match ∧ on-chain delivery
```
`../run-live.ts` automates all five against a deployment: `bun run run-live.ts`. It self-checks the
issuer pin, signs with the agent key, and runs a **static preflight** (verifier `valid`∧`match` +
`ownerOf==output_address`) reporting whether release would succeed. **DRY_RUN defaults to true** — set
`DRY_RUN=false` to actually openJob + release.

## Design decisions

**Resolved with Fede (babyblueviper1), 2026-06-22:**

1. **Verifier leg → A (on-chain BIP-340). ✅ SHIPPED** (`BIP340Verifier`, by Fede, [#2](https://github.com/TMerlini/hack-ens-recovery/pull/2)). Schnorr verify via the `ecrecover` trick (~7.5k gas, native precompiles — no bespoke secp256k1 lib), recomputes the kind-30078 event id via the sha256 precompile, checks `content.artifact_hash == expectArtifactHash`. The SDK's `packReceiptProof()` packs `receiptProof` byte-aligned with off-chain `verifyFullFlow()`. **B (attestor EIP-712) rejected** — it makes the verifier key the release authority, re-introducing the trust this model deletes. **Fallback C (optimistic)** invokes the A verifier on its challenge path, so no trusted key in any case.
2. **`artifact_hash` → single SHA-256 canonical-JSON, opaque bytes32. No parallel keccak id.** A second canonicalization (TS sha256-over-JSON vs Solidity keccak-over-abi) would re-create the cross-language drift we removed by sharing `artifactHash(normalizeSpec(spec))`. The chain stays trustless without recomputing the spec: owner-binding via the on-chain delivery check, replay via the nullifier, and the A-path verify recomputes the *event id* (sha256) — keccak never needed.
3. **Delivery scope → v1 single ERC-721** (`ownerOf(tokenId)`, matches `rescue.ts`). Wrapped names (NameWrapper/1155) and multi-asset sets are **separate jobs**, not a loop — one job ↔ one nullifier is cleaner. (`asset_set` is already inside `expectArtifactHash`, so the receipt commits to the full set regardless.)
5. **Precedence stays off-chain.** commit-before-outcome ordering lives on `/ledger` via OTS→Bitcoin (`ots verify -d <event_id>`); pulling it on-chain buys nothing the relay+OTS record doesn't already give recomputably.

**Remaining:**

4. **Fee shape (commercial, ours).** Have `openJob`/`release`/`refund(after expiry)`. Not yet: fee splits, protocol fee, richer dispute path, cancel-before-commit. Nothing verifier-side blocks it.
7. **`issuerPubkeyX` → the recovery agent's x-only key** (`AGENT_PUBKEY`/`buildCommitEvent`), confirmed w/ Fede. The agent signs its own commit; invinoveritas does not re-issue or co-sign — pinning their key would re-insert a trusted issuer in the path. So `valid ⟺ signed by the accountable recovery agent`, the semantic that makes commit-before-outcome precedence meaningful. Owner-binding stays on the delivery check + nullifier (key-independent).
6. **Done:** `BIP340Verifier` (impl A) + SDK `packReceiptProof()` + deploy script + agent-side `buildReceiptProof()` wiring + issuer policy. **Left:** **independent audit of `BIP340.sol`**, testnet deploy + address, end-to-end run on a live receipt.

**Future (post-v1, not a v1 change):** a single pinned key binds one escrow to one agent. For multiple recovery agents against one escrow, generalize to either (a) an issuer **allowlist** in the verifier, or (b) an **ERC-8004 Validation-Registry** lookup instead of the hardcoded pin.
