# BIP-340 verifier — independent cross-check

**Status:** both interim (Tier-1) corroboration legs complete and independently re-derived.
**Scope:** `src/BIP340.sol` + `src/BIP340Verifier.sol` (the crypto-critical surface). The escrow
contracts and the *review of the verifier's mathematics* are out of scope here (see below).
**Re-derivation by:** @damonzwicker — independent third party to the author (@babyblueviper1).
**Date:** 2026-06-22.
**Reproduce:** scripts in [`crosscheck/`](./crosscheck/) (both exit 0 on success).

This document records two passes run against the `wyriwe-receipt` branch:

1. a **reference cross-check** — proving the test corpus is the genuine upstream vector set with
   correct labels, and that off-chain and on-chain inputs are byte-identical (no drift); and
2. an **on-EVM reproduction** — proving the compiled contracts themselves reproduce every assertion
   on a real EVM, through the live `ecrecover` (`0x01`) and `modexp` (`0x05`) precompiles that the
   `ecrecover`-trick depends on.

Neither pass is a substitute for the human crypto review requested in `REVIEW-PACKAGE.md`. They
establish that the *evidence base is genuine* and the *implementation reproduces its documented
behaviour* — they do **not** audit the `ecrecover`-trick algebra, the even-Y lift, or domain-check
completeness. That remains the open gate.

---

## Pass 1 — reference cross-check (vs `bitcoin/bips`)

**Goal:** confirm the vectors wired into `test/BIP340Vectors.t.sol` are the real official BIP-340
vectors (not hand-tweaked), that their pass/fail labels are correct under the canonical reference
verifier, and that the integration receipt's off-chain signer and on-chain `verify()` read identical
bytes.

### Results
- **All upstream vectors (currently 19) produce their documented result** when run through the
  spec's own `reference.py` — every `TRUE` verifies, every `FALSE` rejects.
- The **15** vectors wired in `BIP340Vectors.t.sol` are **byte-identical** to CSV rows 0–14 — every
  field (`px`, `m`, `rx`, `s`, `expected`) diffed, 15/15 identical.
- The **15-vs-19 gap is correct and documented, not an omission**: `BIP340.verify` takes a `bytes32`
  message (the NIP-01 event id), so the four variable-length-message vectors (15–18, added 2022-12)
  are genuinely out of scope. The test file states this explicitly.
- **Anti-drift / off-chain == on-chain.** `BIP340Verifier.sol` computes the signed message as
  `id = sha256(preimage)` (confirmed by source), so the off-chain and on-chain message derivation are
  the same by construction. Decoding the `PROOF` constant in `BIP340Verifier.t.sol` as
  `abi.encode(px, rx, s, preimage)`:
  - `preimage` is the NIP-01 serialization `[0, "<pubkey>", <created_at>, 30078, [], "<content>"]`;
  - `M = sha256(preimage) = 5ecd5cd6559b505a58429d66169077734558ff36c9264f07384cc015ff30f84c`;
  - the Schnorr signature `(rx, s)` verifies **TRUE** over `M` under the pinned issuer key, checked
    against `reference.py` (i.e. independently of the contract);
  - the `artifact_hash` embedded in the signed `content` extracts to exactly the `ARTIFACT` the
    escrow checks (`567f91ee…9896d9`), and `px` equals the pinned `ISSUER`.

### Reproduce
```bash
cd contracts/audit/crosscheck
python3 pass1_reference_crosscheck.py     # pulls reference.py + test-vectors.csv from bitcoin/bips
```

---

## Pass 2 — on-EVM reproduction of the contracts

**Goal:** confirm the *actual compiled contracts* (not the reference verifier) reproduce every
assertion when executed in a real EVM, including the `ecrecover` and `modexp` precompiles.

**Toolchain note.** Foundry's release binaries were unreachable in the environment used
(`release-assets.githubusercontent.com` host-blocked), so this was run **without `forge`**: the
contracts were compiled with **solc 0.8.28** (solc-js) and executed in **py-evm** via `eth-tester` /
`web3.py`. Same EVM semantics and precompiles — different harness. A reviewer with Foundry gets the
equivalent via `forge test --match-path 'test/BIP340*.t.sol'`.

`BIP340.verify` is an `internal` library function, so a one-line `Harness` exposes it externally with
the exact call shape used by `BIP340.t.sol::_verify` (the library code inlines into the harness —
identical to what the suite exercises).

### Results — 34/34 assertions, zero false-accepts

This reproduces **all 14 of the suite's 25 forge test functions that exercise the BIP-340 surface**
(`BIP340.t.sol` 7 + `BIP340Vectors.t.sol` 1 + `BIP340Verifier.t.sol` 6 = 14 functions, 34 individual
assertions). The remaining 11 functions are escrow (10) + deploy (1) and are **not** re-run here.

| group | functions / assertions | result |
|---|---|---|
| Official BIP-340 vectors (`BIP340Vectors.t.sol`) | 1 / 15 | all valid verify, all invalid reject |
| Unit + tamper (`BIP340.t.sol`) | 7 / 9 | wrong msg/pubkey/s/r, zero `px`/`s`/`rx`, `s≥N` all rejected; valid verifies |
| Integration on real SDK-signed receipt (`BIP340Verifier.t.sol`) | 6 / 10 | see below |

Integration detail:
- genuine receipt → `(valid, match) = (true, true)`
- wrong expect-hash → `valid=true`, `match=false`
- wrong issuer pin → `valid=false` (and `match=true` — hash parse is independent of the pin)
- one-byte-tampered preimage → `valid=false`
- malformed proof (`0xdeadbeef`) → `(false, false)`, **no revert**
- zero-issuer constructor → reverts (`"issuer pubkey required"`)

### Reproduce
```bash
cd contracts/audit/crosscheck
npm install solc@0.8.28 && node compile.js      # writes artifacts.json
pip install web3 py-evm eth-tester
python3 run_evm.py                               # -> 34 passed / 0 failed
```

---

## What is confirmed vs. what remains

**Confirmed (independently):**
- the wired vectors are the genuine upstream set with correct labels;
- the verifier's on-chain and off-chain inputs are byte-identical — message derivation is
  `sha256(preimage)` on both sides (no canonicalization drift);
- the compiled `BIP340.sol` / `BIP340Verifier.sol` reproduce every assertion across the 14 BIP-340
  forge functions on a real EVM, with no false-accept and no unexpected revert.

**Not done here (still the open gate — for the named crypto reviewer):**
- the verifier's mathematics — `ecrecover`-trick soundness, the even-Y point lift, and
  **domain-check completeness** (the property a fixed vector suite cannot fully establish);
- whether `BIP340Verifier`'s `artifact_hash` byte-scan can be **steered** by attacker-influenced
  content (only verified here on one benign, issuer-signed receipt; `REVIEW-PACKAGE.md` item 6);
- the escrow tests (`RecoveryEscrow.t.sol`) were not re-run in this pass;
- the documented limitation (x-only keys with `x ∈ [n, p)`, ~2⁻¹²⁸ of keys, unusable as the
  `ecrecover` `r`) is noted, not assessed.

The live Sepolia deployment and fee-release run are recorded in `deployments.md` and are **not**
independently re-checked in this document.

**Bottom line:** the interim assurance legs are complete — the evidence base is genuine and the
implementation reproduces it on-EVM. The remaining mainnet gate is the cred-based crypto review of
the ~120 lines, exactly as scoped in `REVIEW-PACKAGE.md`.
