"""
Worked example: scope-contestation over a real recovery job's asset_set.

Binds the declared observation scope to the LIVE recovery job's artifact_hash
(the OCP/8281 layer-0 commitment the WYRIWE receipt already uses), then proves a
MISSED asset is on-chain-nominable. Uses Damon's reference (scope_ref.py) to
build the sorted-Merkle root + non-inclusion proof — same logic as the contract.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # scope_ref.py is vendored alongside (CC0)
from scope_ref import root_of, make_non_inclusion, k256

def coord(desc):                       # asset coordinate = keccak("asset:" + descriptor)
    return k256(b"asset:" + desc.encode())

# the live recovery job (Sepolia cutover demo) — scope binds to its artifact_hash
COMMITMENT = bytes.fromhex("ee601a25115f2f5461ae1979c1255c1fbb54312acbb6addd1010d4e50989bc0b")

# what the recovery agent DECLARED it observed/rescued from the compromised wallet
declared = ["gobross.eth", "PixelGoblin #4417", "ENScribe #88", "Vortex LP #12"]
# an asset still in the compromised wallet the agent did NOT observe — the omission
missed   = "PixelGoblin #903"

coords = sorted(coord(d) for d in declared)
root   = root_of(coords)
count  = len(coords)
mc     = coord(missed)
p      = make_non_inclusion(coords, mc)
assert p is not None, "missed asset must be genuinely absent"

# pack proof -> contract NonInclusion(uint8 mode,bytes32 lo,bytes32 hi,uint256 idxLo,bytes32[] sibsLo,bytes32[] sibsHi)
Z = b"\x00" * 32
lo = p.get("loCoord", Z); hi = p.get("hiCoord", Z); idxLo = p.get("idxLo", 0)
sibsLo = p.get("sibsLo", []); sibsHi = p.get("sibsHi", [])
def hx(b): return "0x" + b.hex()
def arr(a): return "[" + ",".join(hx(s) for s in a) + "]"
tuple_str = f'({p["case"]},{hx(lo)},{hx(hi)},{idxLo},{arr(sibsLo)},{arr(sibsHi)})'

print("COMMITMENT_HASH=" + hx(COMMITMENT))
print("SCOPE_ROOT=" + hx(root))
print("COUNT=%d" % count)
print("MISSED_DESC=" + missed)
print("MISSED_COORD=" + hx(mc))
print("MISSED_CASE=%d  (0=interior 1=below 2=above)" % p["case"])
print("PROOF_TUPLE=" + tuple_str)
print("PRESENT_COORD=" + hx(coord("PixelGoblin #4417")) + "  (declared — nominate must REVERT)")
