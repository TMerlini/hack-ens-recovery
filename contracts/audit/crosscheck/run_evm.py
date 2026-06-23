#!/usr/bin/env python3
"""
Pass 2 - on-EVM reproduction of BIP340.sol / BIP340Verifier.sol.
Drop location: contracts/audit/crosscheck/  (repo paths resolved relative to this file).

Compiles the actual contracts (via compile.js -> artifacts.json) and executes them in a real
EVM (py-evm, through eth-tester / web3.py), exercising the live ecrecover (0x01) and modexp
(0x05) precompiles. Faithfully mirrors all 14 forge test functions across the three BIP-340 test
files (34 individual assertions). The other 11 of the suite's 25 functions are escrow/deploy and
are out of scope here.

Prereqs:
  npm install solc@0.8.28 && node compile.js     # writes artifacts.json
  pip install web3 py-evm eth-tester
Exit code 0 iff all assertions pass.
"""
import json, os, re
from web3 import Web3, EthereumTesterProvider

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.normpath(os.path.join(HERE, "..", "..", "test"))
with open(os.path.join(HERE, "artifacts.json")) as f:
    ART = json.load(f)

w3 = Web3(EthereumTesterProvider())
acct = w3.eth.accounts[0]

def deploy(name, *cargs):
    c = w3.eth.contract(abi=ART[name]["abi"], bytecode=ART[name]["bytecode"])
    rc = w3.eth.wait_for_transaction_receipt(c.constructor(*cargs).transact({"from": acct}))
    return w3.eth.contract(address=rc.contractAddress, abi=ART[name]["abi"])

def b32(h): return bytes.fromhex(h.replace("0x", ""))
def x1(b):  return (int.from_bytes(b, "big") ^ 1).to_bytes(32, "big")

R = {"ok": 0, "fail": 0, "fails": []}
def chk(name, got, exp):
    good = got == exp
    R["ok" if good else "fail"] += 1
    if not good: R["fails"].append(name)
    print(f"  [{'PASS' if good else 'FAIL'}] {name}: got={got} expected={exp}")

# ---- 1) BIP340Vectors.t.sol: 15 official vectors (via Harness) -------------------------------
print("== BIP340Vectors.t.sol :: test_officialBIP340Vectors ==")
H = deploy("Harness")
with open(os.path.join(TEST, "BIP340Vectors.t.sol")) as f:
    sol = f.read()
n = 0
for px, m, rx, s, e in re.findall(
        r"_v\(\s*0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),"
        r"\s*0x([0-9A-Fa-f]+),\s*(true|false)\)", sol):
    chk(f"vec{n}", H.functions.verify(b32(px), b32(rx), b32(s), b32(m)).call(), e == "true"); n += 1

# ---- 2) BIP340.t.sol: 7 functions / 9 assertions (via Harness) -------------------------------
print("== BIP340.t.sol :: unit + tamper ==")
with open(os.path.join(TEST, "BIP340.t.sol")) as f:
    u = f.read()
cst = lambda nm: b32(re.search(nm + r"\s*=\s*0x([0-9a-fA-F]+)", u).group(1))
PX, RX, S, M = cst("PX"), cst("RX"), cst("S"), cst("M")
N = H.functions.N().call()
chk("test_validSignature",          H.functions.verify(PX, RX, S, M).call(),                 True)
chk("test_wrongMessage",            H.functions.verify(PX, RX, S, x1(M)).call(),              False)
chk("test_wrongPubkey",             H.functions.verify(x1(PX), RX, S, M).call(),              False)
chk("test_tamperedS",               H.functions.verify(PX, RX, x1(S), M).call(),              False)
chk("test_tamperedR",               H.functions.verify(PX, x1(RX), S, M).call(),              False)
chk("test_zeroInputs[px=0]",        H.functions.verify(b"\x00"*32, RX, S, M).call(),          False)
chk("test_zeroInputs[s=0]",         H.functions.verify(PX, RX, b"\x00"*32, M).call(),         False)
chk("test_zeroInputs[rx=0]",        H.functions.verify(PX, b"\x00"*32, S, M).call(),          False)
chk("test_sAboveOrderRejected",     H.functions.verify(PX, RX, N.to_bytes(32,"big"), M).call(), False)

# ---- 3) BIP340Verifier.t.sol: 6 functions / 10 assertions ------------------------------------
print("== BIP340Verifier.t.sol :: integration (real SDK-signed receipt) ==")
with open(os.path.join(TEST, "BIP340Verifier.t.sol")) as f:
    v = f.read()
ISSUER   = b32(re.search(r"ISSUER\s*=\s*0x([0-9a-fA-F]+)", v).group(1))
ARTIFACT = b32(re.search(r"ARTIFACT\s*=\s*0x([0-9a-fA-F]+)", v).group(1))
PROOF    = bytes.fromhex(re.search(r'PROOF\s*=\s*hex"([0-9a-fA-F]+)"', v, re.S).group(1))

V = deploy("BIP340Verifier", ISSUER)
valid, matches = V.functions.verify(ARTIFACT, PROOF).call()
chk("validReceipt_matchingHash[valid]",   valid,   True)
chk("validReceipt_matchingHash[matches]", matches, True)
valid, matches = V.functions.verify(x1(ARTIFACT), PROOF).call()
chk("validReceipt_wrongExpectHash[valid]",   valid,   True)
chk("validReceipt_wrongExpectHash[matches]", matches, False)
Vother = deploy("BIP340Verifier", x1(ISSUER))
valid, matches = Vother.functions.verify(ARTIFACT, PROOF).call()
chk("wrongIssuerPin_invalid[valid]",   valid,   False)
chk("wrongIssuerPin_invalid[matches]", matches, True)   # hash still parses, independent of pin
bad = bytearray(PROOF); bad[-8] ^= 1
valid, _ = V.functions.verify(ARTIFACT, bytes(bad)).call()
chk("tamperedProof_invalid[valid]", valid, False)
valid, matches = V.functions.verify(ARTIFACT, bytes.fromhex("deadbeef")).call()
chk("malformedProof_noRevert[valid]",   valid,   False)
chk("malformedProof_noRevert[matches]", matches, False)
reverted = False
try:
    deploy("BIP340Verifier", b"\x00"*32)
except Exception:
    reverted = True
chk("constructorRejectsZeroIssuer[revert]", reverted, True)

print(f"\n==== EVM RESULT: {R['ok']} passed / {R['fail']} failed "
      f"(14 forge functions across the 3 BIP-340 files; 34 assertions) ====")
print("BIP340.sol + BIP340Verifier.sol reproduce every assertion on a real EVM."
      if not R["fails"] else f"FAILURES: {R['fails']}")
import sys; sys.exit(0 if not R["fails"] else 1)
