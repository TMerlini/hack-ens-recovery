#!/usr/bin/env python3
"""
Pass 1 - reference cross-check for the BIP-340 verifier.
Drop location: contracts/audit/crosscheck/  (all repo paths resolved relative to this file).

Confirms, independently of the contract:
  (a) every upstream bitcoin/bips BIP-340 vector produces its documented result under the
      spec's own reference.py;
  (b) the 15 vectors wired in test/BIP340Vectors.t.sol are byte-identical to the upstream
      32-byte-message rows (0-14);
  (c) anti-drift: the integration receipt in test/BIP340Verifier.t.sol is a genuine BIP-340
      signature over sha256(preimage) under the pinned issuer key, and the committed
      artifact_hash equals the expected ARTIFACT. (BIP340Verifier.sol computes the message as
      id = sha256(preimage), so off-chain and on-chain operate on identical bytes.)

Requires: internet (pulls reference.py + test-vectors.csv from bitcoin/bips). No other deps.
Exit code 0 iff all checks pass.
"""
import csv, hashlib, os, re, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.normpath(os.path.join(HERE, "..", "..", "test"))
BIPS = "https://raw.githubusercontent.com/bitcoin/bips/master/bip-0340/"

def fetch(name):
    p = os.path.join(HERE, name)
    if not os.path.exists(p):
        urllib.request.urlretrieve(BIPS + name, p)
    return p

fetch("reference.py"); fetch("test-vectors.csv")
sys.path.insert(0, HERE)
from reference import schnorr_verify   # BIP-340 spec reference implementation

def hx(s): return bytes.fromhex(s) if s else b""
fails = []

# (a) every upstream vector through the reference verifier
with open(os.path.join(HERE, "test-vectors.csv")) as f:
    rows = list(csv.DictReader(f))
a_ok = 0
for r in rows:
    exp = r["verification result"].strip().upper() == "TRUE"
    try: got = schnorr_verify(hx(r["message"]), hx(r["public key"]), hx(r["signature"]))
    except Exception: got = False
    if got == exp: a_ok += 1
    else: fails.append(f"upstream vec {r['index']}")
print(f"(a) reference verifier vs upstream csv : {a_ok}/{len(rows)} match documented result")

# (b) wired vectors byte-identical to upstream rows 0-14
with open(os.path.join(TEST, "BIP340Vectors.t.sol")) as f:
    sol = f.read()
wired = [(px.lower(), m.lower(), rx.lower(), s.lower(), e == "true")
         for px, m, rx, s, e in re.findall(
             r"_v\(\s*0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),"
             r"\s*0x([0-9A-Fa-f]+),\s*(true|false)\)", sol)]
upstream = []
for r in rows:
    if int(r["index"]) > 14: continue
    sig = r["signature"].lower()
    upstream.append((r["public key"].lower(), r["message"].lower(), sig[:64], sig[64:],
                     r["verification result"].strip().upper() == "TRUE"))
b_ok = sum(1 for w, u in zip(wired, upstream) if w == u)
if b_ok != len(upstream) or len(wired) != 15:
    fails.append("wired-vs-upstream diff")
print(f"(b) wired vectors vs upstream rows 0-14: {b_ok}/{len(upstream)} byte-identical "
      f"(wired count={len(wired)})")

# (c) anti-drift on the integration receipt
with open(os.path.join(TEST, "BIP340Verifier.t.sol")) as f:
    v = f.read()
ISSUER   = re.search(r"ISSUER\s*=\s*0x([0-9a-fA-F]+)", v).group(1).lower()
ARTIFACT = re.search(r"ARTIFACT\s*=\s*0x([0-9a-fA-F]+)", v).group(1).lower()
PROOF = bytes.fromhex(re.search(r'PROOF\s*=\s*hex"([0-9a-fA-F]+)"', v, re.S).group(1))
px, rx, s = PROOF[0:32], PROOF[32:64], PROOF[64:96]
off = int.from_bytes(PROOF[96:128], "big")
ln  = int.from_bytes(PROOF[off:off + 32], "big")
preimage = PROOF[off + 32: off + 32 + ln]
M = hashlib.sha256(preimage).digest()                    # == contract's id = sha256(preimage)
sig_ok = schnorr_verify(M, px, rx + s)
issuer_ok = px.hex() == ISSUER
dec = preimage.decode()
tail = dec[dec.find("artifact_hash"):]
ah_m = re.search(r"([0-9a-fA-F]{64})", tail)
ah = ah_m.group(1).lower() if ah_m else None
drift_ok = sig_ok and issuer_ok and (ah == ARTIFACT)
if not drift_ok: fails.append("anti-drift")
print(f"(c) anti-drift integration receipt    : sig_valid={sig_ok} issuer_pinned={issuer_ok} "
      f"artifact_hash_matches={ah == ARTIFACT}")
print(f"    M = sha256(preimage) = {M.hex()}")

print("\nPASS 1:", "OK — all checks passed." if not fails else f"FAILED: {fails}")
sys.exit(0 if not fails else 1)
