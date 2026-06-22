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

## Open decisions — what's still missing

**1. The receipt-validity leg (`IReceiptVerifier`) — the real open call, needs Fede.**
The escrow can't itself check a BIP-340 schnorr signature over a Nostr event for free. Three implementations, decreasing trustlessness:
- **A) On-chain BIP-340 verification** of the kind-30078 event signature → fully trustless, no oracle (purest fit for "nothing is a trusted oracle"; gas-heavy, needs a vetted secp256k1/BIP-340 Solidity lib).
- **B) Attestor EIP-712** — `/verify-proof` co-signs `valid + match`, contract checks ECDSA → cheap, but re-introduces trust in Fede's verifier key. Viable v1 *with* a roadmap to A.
- **C) Optimistic challenge window** — release after a delay unless someone submits a fraud proof → trust-minimized, adds latency + a challenge path.
The contract is built so this is a drop-in: only the verifier changes.

**2. `artifact_hash` representation mismatch.**
`expectArtifactHash` is a **SHA-256 over canonical JSON** from `agent-sdk` (`artifactHash(normalizeSpec(spec))`) — *not* `keccak256(abi.encode(...))`. The contract therefore treats it as an **opaque bytes32 commitment** (checks equality + delivery + nullifier; does not recompute). If we want the chain to *recompute* the binding, the SDK needs a parallel keccak/abi-encoded artifact id. Confirm with Fede which is canonical for on-chain use.

**3. Delivery check scope.**
v1 checks a single **ERC-721** `ownerOf(tokenId)` (matches `rescue.ts` — unwrapped `.eth` 2LD on the BaseRegistrar + `setOwner` on the registry). Still to decide:
- **Wrapped names** (ENS NameWrapper, ERC-1155) — different ownership check.
- **Multi-asset rescues** (`asset_set` can be funds + several NFTs) — v1 is one token; do we loop the set, or one job per asset?
- **ERC-20 / native funds** delivery (balance deltas are racy — needs thought).

**4. Fee lifecycle gaps.**
Has `openJob`/`release`/`refund(after expiry)`. Not yet: partial fees / fee splits, a protocol fee, dispute arbitration beyond the expiry refund, or cancel-before-commit. Confirm the commercial shape.

**5. committed_at / precedence is intentionally off-chain.**
The commit-before-outcome ordering (OTS / Bitcoin PoW via `ots verify -d`) is evidence on `/ledger`, not enforced in the contract. If we ever want on-chain precedence we'd anchor `committed_at` here too — currently out of scope by design.

**6. Not done yet:** deploy script (`script/`), testnet deployment + address, gas profiling of option A, and wiring `release()` into the agent flow (`receipt.ts` → sign → `publishCommit` → escrow `release`).
