# BIP340.sol — reviewer brief

Independent review request for the crypto-critical file in the recovery-escrow stack. Everything else
(escrow logic, off-chain SDK) is in scope only as context.

## Scope
- **`src/BIP340.sol`** — on-chain BIP-340 (secp256k1 Schnorr) signature verification via the `ecrecover`
  trick + the `modexp` precompile. **This is the file that guards funds — the priority.**
- **`src/BIP340Verifier.sol`** — supporting: decodes `receiptProof`, runs `BIP340.verify`, pins the
  issuer key, extracts `artifact_hash` from the signed preimage.
- Out of scope: `RecoveryEscrow.sol` (escrow logic, separately unit-tested), `@onchain-ai/agent-sdk`.

## Why it matters
`BIP340.verify` is the `valid` leg of the escrow release gate (release = `valid ∧ artifactHashMatches ∧
on-chain delivery ∧ unspent`). A false-positive here — accepting an invalid signature, or a signature
under a key other than the pinned agent — undermines the "verify trusting no one" guarantee at exactly
the point a skeptic reads the code. Hence the independent pass before mainnet value flows.

## The construction (what's being asserted)
BIP-340 verify: `R = s·G − e·P`, with `e = int(tagged_hash("BIP0340/challenge", rx‖px‖m)) mod n`; accept
iff `R` has even Y and `R.x == rx`.

ecrecover trick: `ecrecover(h, v=27, r=px, s_ec)` recovers `Q = px⁻¹·(s_ec·P − h·G)` (with `P` = the
even-Y point at x=`px`). Setting `s_ec = −e·px mod n`, `h = −s·px mod n` ⇒ `Q = s·G − e·P = R`. So
`ecrecover(...) == address(R)`; the code independently derives `address(R)` from `rx` (lift to the
even-Y point) and compares. Equality ⟺ valid.

## Review checklist (the risk surface)
1. **Mapping algebra** — confirm the `s_ec`/`h` substitution yields `R`; `v=27` ⇒ `P` is the even-Y point
   (BIP-340 x-only keys are even-Y by definition).
2. **Challenge** — `CHALLENGE_TAG_HASH == sha256("BIP0340/challenge")`; `e = sha256(tag‖tag‖rx‖px‖m) mod n`;
   `e == 0` rejected.
3. **Even-Y lift** — `y² = x³+7 mod p`; `ry = y2^((p+1)/4) mod p` (valid since `p ≡ 3 mod 4`); reject if
   `ry² ≠ y2` (rx not a curve x-coord); parity-flip to even Y.
4. **Domain checks** — `px∈(0,n)`, `s∈(0,n)`, `rx∈(0,p)`, `e≠0`, `ep≠0`, `sp∈(0,n)`, `recovered≠0`.
5. **Address vs point equality** — relies on keccak collision resistance (~2⁻¹⁶⁰); standard, but confirm.
6. **Documented limitation** — x-only keys with `x∈[n,p)` (~2⁻¹²⁸ of keys) can't be used as the ecrecover
   `r` → pin a normal key. `rx` is unconstrained (keccak input only). Confirm acceptable for the issuer pin.
7. **modexp precompile (0x05)** — input encoding (3×32-byte lengths + base/exp/mod), `staticcall` failure
   handling.
8. **No reverts on malformed input** — returns `false`; matches the off-chain verifier. Confirm no path
   reverts unexpectedly (DoS surface on `release`).

## BIP340Verifier.sol checklist
- `receiptProof = abi.encode(px, rx, s, preimage)`; `id = sha256(preimage)` is the signed message;
  `preimage` = NIP-01 `[0,pubkey,created_at,kind,tags,content]`.
- `valid = sigOk ∧ (px == issuerPubkeyX) ∧ schemaMarker present`.
- `artifact_hash` byte-scan: first occurrence of `\"artifact_hash\":\"` + 64 hex. Note it operates over
  **signed, issuer-pinned** bytes (an attacker can't inject without the issuer key), but confirm a
  first-occurrence scan can't be steered by issuer-side content shape; consider a stricter parse if the
  content schema grows.

## Test coverage present (24/24 green)
- `BIP340.t.sol` (7): real noble-curves vector verifies; wrong msg / wrong pubkey / tampered r / tampered
  s / zero inputs / `s ≥ n` all rejected.
- `BIP340Verifier.t.sol` (6): real SDK-signed receipt — valid+match, wrong-expect, wrong-issuer-pin,
  tampered preimage, malformed (no revert), zero-issuer ctor.
- **Live (Sepolia):** deployed verifier `verify(real receipt)` → `(valid,match)=(true,true)`; full
  fee-release demo, release tx in block 11118096; replay reverts (nullifier). See `../deployments.md`.

## Recommended hardening (suggested additions)
1. **Official BIP-340 test vectors** — wire the BIP's `test-vectors.csv` as on-chain assertions, especially
   the *invalid* cases (y not a square, `x ≥ p`, `s ≥ n`, malleability). Highest-value addition.
2. **Fuzz** — random sk/msg: `sign → verify` true; single-bit flip → false.
3. **Diff** against a reference ecrecover-Schnorr implementation.
4. **Gas** — confirm ~7.5k/verify holds under worst-case `preimage` length in `BIP340Verifier`.

## Suggested reviewer
Independent Solidity/crypto auditor familiar with secp256k1 / `ecrecover` tricks (ideally the kind of eyes
that review `@noble/curves`-class code).
