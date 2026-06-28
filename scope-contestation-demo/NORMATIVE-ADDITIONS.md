# Scope Contestation — normative additions (ship-ready)

*2026-06-28. Fede's first cut with Damon's three precision points folded in. Points 1
and 2 verified at `hack-ens-recovery @ c4100e5`, 13/13 green
(`test_contest_valueCommitment_boundToFullScope`). Point 3 (precedence anchor) verified
against Bitcoin-confirmed ledger entry 38 — OTS digest stamped in block 955810,
merkleroot `0b7c456e…398d0e` independently recomputed off a public explorer.*

---

## Resolved meaning (meaning axis)

A contest MUST be evaluated against the market's actual resolved readings, not against any
coordinate-complete witness set the contester is free to choose. `verifyValueFidelity`
MUST require that the contester's `(sourceId, value)` pairs reproduce the market's actual
resolved readings — fixed **either** by a resolution-time commitment committed before the
outcome was observable (type-2), **or** recomputed from a pre-committed block pin (type-1).
*(Point 1 — the MUST covers both provenance modes; type-1 carries no commitment, it
recomputes.)*

The admissible verdict is therefore **S1 — "X was material to THE resolution" — and only S1.**

The weaker reading S2 ("X was material to some coordinate-complete `a` the contester
chose") is NOT offered as an alternative robustness mode. It is excluded by construction:
"material to some coordinate-complete `a`" does not re-derive to a single answer from
public data, so it cannot satisfy the recomputability MUST. Recomputability forces meaning
to actual-resolution; it is not a configuration the spec toggles. Implementations MUST NOT
expose an S2 / robustness-mode path. This retires the S1/S2 mode distinction for the
meaning axis.

`verifyValueFidelity` is the value-half dual of the coordinate half: `verifyAbsence` and
`verifyScopeComplete` bind *which* coordinates `a` may contain; `verifyValueFidelity` binds
the *values* those coordinates MUST carry. Same bind-then-recompute shape, and `contest()`
MUST enforce in order:

> **verifyAbsence → verifyScopeComplete → verifyValueFidelity → isolation → classify**

### Value-commitment binding *(Point 2)*
The value-fidelity readings set MUST be over **exactly** the Layer 1 cardinality-bound
scope coordinate set — every declared coordinate's value MUST be constrained; none may be
present-in-`a` but absent-from-the-value-check. Otherwise `verifyScopeComplete` forces a
coordinate's *presence* while its *value* stays free, reopening the value half for that
coordinate. The binding inherits from Guarantee 4 transitively: where `verifyScopeComplete`
forces `a` to be exactly the declared id-set and `verifyValueFidelity` requires `a` to
reproduce the committed readings exactly, the two compose to bind the value-commitment leaf
set to the scope — a declared coordinate omitted from the value commitment makes the contest
revert, never slip through. An implementation whose value check is *partial* (constrains
only coordinates that appear in the commitment) MUST add this binding explicitly.

---

## Precedence anchor *(Point 3 — type-2 leg)*

The Pre-outcome MUST (below) is only trustless if precedence is **provable from public
data**, not asserted by the committer. Without an external clock, a type-2 committer can
commit resolution readings *after* observing the outcome and back-date them; the four guards
still pass, because `verifyValueFidelity` checks that `a` reproduces the committed readings,
not *when* they were committed.

So the type-2 `resolution_root` MUST carry an **external-clock anchor** — the same
OpenTimestamps hierarchy defined for the behavioral axis (ERC-8299 Appendix B), inherited by
reference, not redefined. It commits the **signed event_id directly** as the OTS digest
(matching the behavioral axis 1:1: `resolution_root` is bound into a signed event, and that
event's id is stamped — not the bare `keccak256(abi.encode(sortedLeaves))`). The anchor
yields a public upper bound τ_commit (*committed-no-later-than*).

**Strict precedence.** `verifyValueFidelity` MUST verify the anchor proves
**τ_commit < τ_outcome** — a STRICT inequality. `<=` would admit a commitment stamped in the
same block/second as the outcome's observability, exactly the back-dating boundary the anchor
closes. Existence is not precedence; simultaneity is not precedence. τ_outcome MUST itself be
a recomputable public timestamp (e.g. the resolution event's block timestamp), or the check
inherits a trust assumption one level over.

**Tiered, disclosed.** Precedence rests on a hierarchy of clocks — tier-0 Bitcoin PoW
(trust-maximal) > tier-1 relay-attested > tier-2 on-chain committedAt > tier-3 survivor
floor. `verifyValueFidelity` MUST disclose which tier is in force and evaluate the strict
`<` at that tier's timestamp. **Threat-model caveat:** the anchor exists to stop a committer
*motivated to back-date*; against that adversary only tier-0 is signer-independent. Tier-1
(relay-attested) does NOT fully close back-dating — `created_at` is set in the committer's
own event; relays attest receipt, not impossibility of earlier/later stamping. So a type-2
value-fidelity verdict SHOULD require tier-0 for a final verdict and MAY rest on tier-1 only
as an explicitly **provisional** state pending Bitcoin confirmation. *Spec vs. suite:* the
spec is tiered + disclosed; the conformance suite's `anchoring_invariant` PASSES only at
tier-0 (relays can collude). Same hierarchy; the suite certifies at the top of it.

**Frozen-commit.** Once tier-0 confirms, τ_commit is fixed at the Bitcoin block_time. Because
the block is already mined, any outcome settling afterward satisfies the strict `<`
automatically — the commit side is locked and committer-independent.

**Type-1 is exempt.** Type-1 carries no separate commitment: it recomputes each value from
chain state at a pre-committed block pin. The pin's block timestamp *is* the chain's clock
and is fixed before resolution, so precedence is structural (t_pinBlock < t_resolutionBlock),
already provable from chain state. Type-1's precedence is to the EVM clock exactly what
type-2's anchored precedence is to the external OTS clock — same guarantee, one using the
chain as its own timestamp, the other importing one because off-chain readings have none.

*Verified (recomputed, not inherited):* ledger entry 38's signed event_id
(`a42205d7…c663e9`) OTS-stamped in **Bitcoin block 955810** (block_time 1782654639); block
955810's merkleroot `0b7c456e…398d0e` independently recomputed off a public explorer API —
exact match. Full chain: signed event_id → OTS proof → block 955810 → public-explorer
merkleroot, no local node, no trust in the ledger.

---

## Provenance (type-1 / type-2) is orthogonal to the meaning axis

The split is provenance only. It does not change the verdict (S1) or the
`verifyValueFidelity` interface, which MUST NOT fork.

- **type-1 (chain-native):** values recomputable from chain state at a pre-committed block
  pin; no separate commitment carried; `verifyValueFidelity` recomputes from chain and
  requires equality with `a`'s value. (No precedence anchor — structural per Point 3.)
- **type-2 (off-chain):** chain cannot recompute, so `a`'s `(id, value)` pairs are checked
  against a resolution-time commitment `keccak256(abi.encode(sortedLeaves))` committed
  on-chain pre-outcome, carrying the Appendix-B precedence anchor (Point 3).

For type-2 the "source-authenticated inputHash" decomposes into **two composed primitives,
not one**: (1) an **ERC-8281 observation commitment** — commit the digest on-chain
pre-outcome; and (2) **zkTLS / input-provenance** — authenticate that the readings came from
the claimed source. `verifyValueFidelity` covers (1), the commitment side, only.
Source-authentication is the orthogonal zkTLS leg: it answers "are these readings authentic?",
not "does `a` match the committed readings?" Both are required for the full S1 guarantee under
off-chain provenance, and each MUST remain independently recomputable.

---

## Pre-outcome MUST (inherited)

The resolution-time commitment MUST be committed before the outcome is observable. A
post-outcome commitment does not satisfy this — it would only certify a value a committer
fudged after seeing the result. For type-2, precedence is *proven* by the Appendix-B anchor
(Point 3); for type-1 it is structural (the block pin precedes resolution).

---

Related: [[Layer 1 verifyAbsence leg (seam to Jimmy L2)]], [[project_consultation_composition_note]], [[Combined MCP Spec v0.2]].
