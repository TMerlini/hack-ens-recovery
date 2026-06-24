# `count` open question — option (b) reference backing

For the `IScopeContestation` `commitScope` open question (Damon, 2026-06-24).
This is a reference-impl backing for **(b)** — *drop `count` from the normative
signature, bind cardinality into `scopeRoot`* — not a redeploy of the canonical
contract. The group's call stands; this just shows (b) is sound and cheap.

## What (b) changes
- **`scopeRoot` binds cardinality:** `scopeRoot = keccak256(abi.encode(merkleRoot, count))`.
- **`commitScope` drops `count`:** `commitScope(commitmentHash, scopeRoot)` — scheme-agnostic.
- **`count` rides in the proof** and is validated at `nominate`: recompute `merkleRoot`
  from the boundary membership path(s), then require `keccak256(abi.encode(merkleRoot, count)) == scopeRoot`.
  A wrong `count` perturbs Merkle orientation → different root → binding check fails.

## Proven in the reference (`recovery_scope_demo_b.py`, real recovery asset_set)
```
merkle_root (a) = 0x07918473…7b0dc860
scope_root  (b) = 0xd80e7f63…e234ee43   = keccak(merkleRoot, count)
[1] missed coordinate NOMINABLE under (b) : OK
[2] declared coordinate un-nominable      : OK   (soundness preserved)
[3] wrong count (±1) REJECTED             : OK   (binding is load-bearing)
[4] truncation attack (understate N vs prefix) REJECTED : OK
```

### The binding is the whole point (Fede, 2026-06-24)
Cardinality has only **one** safe home: bound to the commitment. Carrying `count` in the
opaque proof *alone* is NOT sound — a prover understates `N` and proves non-inclusion against
a proper **prefix** (truncation) of the committed set. So removing the normative field requires
the guarantee to move *up* to a normative line, not disappear with it:

> A conforming scheme MUST non-malleably bind the scope's cardinality to its commitment (e.g.
> committed within `scopeRoot`), such that `verifyAbsence` cannot be satisfied against a proper
> prefix (truncation) of the committed set. Cardinality carried only within an opaque proof that
> is not itself bound to the commitment does NOT satisfy this requirement.

Test [4] is exactly that attack against this reference impl — rejected, because
`bind(root(prefix), N-1) != committed bind(root(full), N)`.
Reference logic in `scope_ref.py`: `bind_count`, `scope_root_b`, `verify_non_inclusion_b`.

## Contract delta (sketch — ~small)
```solidity
// commitScope: count leaves the signature; scopeRoot is now the bound root
function commitScope(bytes32 commitmentHash, bytes32 scopeRoot) external returns (bytes32 scopeId) {
    scopeId = keccak256(abi.encode(commitmentHash, scopeRoot, msg.sender));
    // store { commitmentHash, scopeRoot, committer }   // no `count` field
    emit ScopeCommitted(scopeId, commitmentHash, scopeRoot, msg.sender);
}

// nominate / _verifyNonInclusion: take `count` from the proof, recompute merkleRoot
// from the membership climbs, then bind-check against the committed scopeRoot:
require(keccak256(abi.encode(merkleRootFromProof, proof.count)) == s.scopeRoot, "bad root/count");
```

## The one cost, named
Declared cardinality is no longer readable from the commit event alone — it becomes
known/verifiable at the first nomination (the proof reveals `count`, bound to the root).
If eager readability is wanted, the **reference impl** MAY emit `count` as a *non-normative*
hint in its own event; the normative interface stays clean. That keeps (b)'s scheme-agnostic
win without losing the forensic "agent claimed N" signal.
