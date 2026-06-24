"""
Independent reference implementation of the Scope Contestation core.

This mirrors, line-for-line in logic, the on-chain verifier in
src/ScopeContestationRegistry.sol. Its job is to prove the load-bearing
cryptographic claim is SOUND and COMPLETE:

  - SOUND:    you CANNOT prove non-inclusion of a coordinate that WAS declared.
  - COMPLETE: you CAN prove non-inclusion of any coordinate that was NOT declared.

Tree: position-aware binary Merkle tree over a SORTED coordinate list.
  leaf(c)        = keccak( 0x00 || c )           (domain-separated)
  node(l, r)     = keccak( 0x01 || l || r )
  odd node at a level is PROMOTED (carried up unchanged).

Orientation and promotion are derived by the verifier from PUBLIC (index, count)
only -- never from prover-supplied flags. The prover supplies sibling hashes.
"""

from Crypto.Hash import keccak

def k256(b: bytes) -> bytes:
    h = keccak.new(digest_bits=256); h.update(b); return h.digest()

def leaf_hash(coord: bytes) -> bytes:
    assert len(coord) == 32
    return k256(b"\x00" + coord)

def node_hash(l: bytes, r: bytes) -> bytes:
    return k256(b"\x01" + l + r)

# ---- tree construction (committer side) ----
def build_layers(coords_sorted):
    level = [leaf_hash(c) for c in coords_sorted]
    layers = [level]
    while len(level) > 1:
        nxt = []
        for i in range(0, len(level), 2):
            if i + 1 < len(level):
                nxt.append(node_hash(level[i], level[i + 1]))
            else:
                nxt.append(level[i])           # promote odd
        level = nxt
        layers.append(level)
    return layers

def root_of(coords_sorted):
    return build_layers(coords_sorted)[-1][0]

def membership_siblings(coords_sorted, idx):
    """Sibling hashes from leaf->root for leaf at idx. Promotion consumes none."""
    layers = build_layers(coords_sorted)
    sibs = []
    pos = idx
    for lvl in range(len(layers) - 1):
        level = layers[lvl]
        size = len(level)
        if pos % 2 == 1:
            sibs.append(level[pos - 1])        # left sibling
        else:
            if pos + 1 < size:
                sibs.append(level[pos + 1])    # right sibling
            # else promoted: no sibling
        pos //= 2
    return sibs

# ---- verification (on-chain side: derives orientation from idx,count only) ----
def verify_membership(leaf, idx, count, sibs, root) -> bool:
    h = leaf
    pos = idx
    size = count
    k = 0
    while size > 1:
        if pos % 2 == 1:
            if k >= len(sibs): return False
            h = node_hash(sibs[k], h); k += 1
        else:
            if pos + 1 < size:
                if k >= len(sibs): return False
                h = node_hash(h, sibs[k]); k += 1
            # else: promoted, consume no sibling
        pos //= 2
        size = (size + 1) // 2
    return k == len(sibs) and h == root

# ---- non-inclusion proof ----
# case 0 = interior (lo,hi adjacent straddle c)
# case 1 = below-min   (c < leaf[0])
# case 2 = above-max   (c > leaf[count-1])
def verify_non_inclusion(c, root, count, proof) -> bool:
    case = proof["case"]
    if case == 1:  # below min
        lo = proof["loCoord"]
        return c < lo and verify_membership(leaf_hash(lo), 0, count, proof["sibsLo"], root)
    if case == 2:  # above max
        hi = proof["hiCoord"]
        return c > hi and verify_membership(leaf_hash(hi), count - 1, count, proof["sibsHi"], root)
    # interior
    lo = proof["loCoord"]; hi = proof["hiCoord"]
    idxLo = proof["idxLo"]
    if not (idxLo + 1 == proof["idxHi"]): return False
    if not (lo < c < hi): return False
    if not verify_membership(leaf_hash(lo), idxLo, count, proof["sibsLo"], root): return False
    if not verify_membership(leaf_hash(hi), idxLo + 1, count, proof["sibsHi"], root): return False
    return True

# ---- prover helper: build a non-inclusion proof for c against a sorted set ----
def make_non_inclusion(coords_sorted, c):
    n = len(coords_sorted)
    root = root_of(coords_sorted)
    if c < coords_sorted[0]:
        return {"case": 1, "loCoord": coords_sorted[0],
                "sibsLo": membership_siblings(coords_sorted, 0)}
    if c > coords_sorted[-1]:
        return {"case": 2, "hiCoord": coords_sorted[-1],
                "sibsHi": membership_siblings(coords_sorted, n - 1)}
    # interior: find idxLo s.t. coords[idxLo] < c < coords[idxLo+1]
    for i in range(n - 1):
        if coords_sorted[i] < c < coords_sorted[i + 1]:
            return {"case": 0, "loCoord": coords_sorted[i], "hiCoord": coords_sorted[i + 1],
                    "idxLo": i, "idxHi": i + 1,
                    "sibsLo": membership_siblings(coords_sorted, i),
                    "sibsHi": membership_siblings(coords_sorted, i + 1)}
    return None  # c is present (or equal to a leaf) -> no proof exists

# ============================================================================
# OPTION (b) — proposal backing for the IScopeContestation `count` open question.
# Bind cardinality INTO the scope root and drop `count` from the normative
# commitScope signature. `count` then rides inside the (opaque) proof and is
# validated against the committed root at nominate-time, so the interface stays
# fully scheme-agnostic while the Merkle-specific cardinality stays inside the
# representation. (T. Merlini — reference backing, not a contract redeploy.)
# ============================================================================

def bind_count(merkle_root: bytes, count: int) -> bytes:
    # Solidity equivalent: keccak256(abi.encode(bytes32 merkleRoot, uint256 count))
    return k256(merkle_root + count.to_bytes(32, "big"))

def scope_root_b(coords_sorted) -> bytes:
    """(b) scope root: the (a) Merkle root with cardinality bound in."""
    return bind_count(root_of(coords_sorted), len(coords_sorted))

def _climb(leaf, idx, count, sibs):
    """Climb the path; RETURN the recomputed Merkle root (or None on sibling mismatch).
    Orientation/promotion derived from (idx, count) only — identical rule to verify_membership."""
    h = leaf; pos = idx; size = count; k = 0
    while size > 1:
        if pos % 2 == 1:
            if k >= len(sibs): return None
            h = node_hash(sibs[k], h); k += 1
        else:
            if pos + 1 < size:
                if k >= len(sibs): return None
                h = node_hash(h, sibs[k]); k += 1
            # else promoted: consume no sibling
        pos //= 2
        size = (size + 1) // 2
    return h if k == len(sibs) else None

def verify_non_inclusion_b(c, committed_scope_root_b, count, proof) -> bool:
    """(b) verifier: `count` is taken from the proof (not the commit). Recompute the
    Merkle root from the boundary membership path(s) and require
    bind_count(merkleRoot, count) == committed scopeRoot. A wrong `count` perturbs
    orientation -> different root -> binding check fails -> sound."""
    case = proof["case"]
    if case == 1:  # below min
        lo = proof["loCoord"]
        if not (c < lo): return False
        r = _climb(leaf_hash(lo), 0, count, proof["sibsLo"])
    elif case == 2:  # above max
        hi = proof["hiCoord"]
        if not (c > hi): return False
        r = _climb(leaf_hash(hi), count - 1, count, proof["sibsHi"])
    else:  # interior straddle
        lo = proof["loCoord"]; hi = proof["hiCoord"]; idxLo = proof["idxLo"]
        if not (idxLo + 1 == proof["idxHi"] and lo < c < hi): return False
        rl = _climb(leaf_hash(lo), idxLo, count, proof["sibsLo"])
        rh = _climb(leaf_hash(hi), idxLo + 1, count, proof["sibsHi"])
        if rl is None or rh is None or rl != rh: return False
        r = rl
    if r is None: return False
    return bind_count(r, count) == committed_scope_root_b
