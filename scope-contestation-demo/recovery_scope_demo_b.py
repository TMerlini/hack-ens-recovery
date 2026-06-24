"""
OPTION (b) backing for the IScopeContestation `count` open question.

Same real recovery asset_set as recovery_scope_demo.py, but committed under (b):
the scope root BINDS cardinality (scope_root_b = keccak(merkleRoot, count)), so
`count` is dropped from the normative commitScope signature and instead rides in
the proof, validated against the committed root at nominate-time.

Proves the three things the group needs to see before choosing (b):
  1. a genuinely-missed coordinate is still NOMINABLE under (b),
  2. a DECLARED coordinate is still un-nominable (soundness preserved),
  3. a WRONG `count` in the proof is REJECTED (the new binding is load-bearing).
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scope_ref import root_of, make_non_inclusion, k256, scope_root_b, verify_non_inclusion_b

def coord(desc):
    return k256(b"asset:" + desc.encode())

# the same live recovery job as the (a) demo — bound to its artifact_hash
COMMITMENT = bytes.fromhex("ee601a25115f2f5461ae1979c1255c1fbb54312acbb6addd1010d4e50989bc0b")
declared = ["gobross.eth", "PixelGoblin #4417", "ENScribe #88", "Vortex LP #12"]
missed   = "PixelGoblin #903"   # in the compromised wallet, NOT observed

coords = sorted(coord(d) for d in declared)
count  = len(coords)
sr_b   = scope_root_b(coords)                       # (b): cardinality bound into the root
mc     = coord(missed)
p      = make_non_inclusion(coords, mc)             # same prover; count now travels in the proof

# 1. missed coordinate is nominable under (b)
assert p is not None and verify_non_inclusion_b(mc, sr_b, count, p), "missed asset must be nominable under (b)"
# 2. a declared coordinate cannot be nominated (no straddle proof exists)
assert make_non_inclusion(coords, coord("PixelGoblin #4417")) is None, "declared asset must NOT be nominable"
# 3. wrong count is rejected (binding is load-bearing) — try count-1 and count+1
assert not verify_non_inclusion_b(mc, sr_b, count - 1, p), "count-1 must be rejected"
assert not verify_non_inclusion_b(mc, sr_b, count + 1, p), "count+1 must be rejected"

print("COMMITMENT      = 0x" + COMMITMENT.hex())
print("merkle_root (a) = 0x" + root_of(coords).hex())
print("scope_root  (b) = 0x" + sr_b.hex(), " = keccak(merkleRoot, count)")
print("count           = %d  (rides in the proof, not the commit)" % count)
print("[1] missed coordinate NOMINABLE under (b) : OK")
print("[2] declared coordinate un-nominable      : OK")
print("[3] wrong count (±1) REJECTED             : OK")
print("\n(b) is sound + complete in the reference. Cost = bind cardinality into the root;")
print("count leaves the normative signature and is recomputed against the committed root.")
