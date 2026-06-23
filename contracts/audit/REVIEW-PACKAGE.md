# BIP340.sol — independent review package

**One-link entry point for a reviewer.** Everything needed for a fast, well-scoped pass on the single
crypto-critical file in the recovery-escrow stack.

## TL;DR
- **Review target:** `src/BIP340.sol` — on-chain BIP-340 (secp256k1 Schnorr) verification (~120 lines).
- **Effort:** small + bounded — `ecrecover`-trick for `sG = R + eP`, an even-Y point lift via the `modexp`
  precompile, and the domain-check surface. No external deps, no assembly beyond the precompile call.
- **Why:** it's the `valid` leg of an owner-bound escrow's release gate. A false-accept undermines the
  whole "verify trusting no one" design.
- **Status:** 25/25 foundry tests green incl. all 15 official BIP-340 vectors; deployed + run end-to-end
  on Sepolia. We're not asking you to find missing tests — we're asking for human crypto eyes on the math.
- **Author:** `BIP340.sol` written by **@babyblueviper1**, who is explicitly *not* self-reviewing — hence
  this independent request.

## Assurance tiers (labeled straight)
We don't oversell where this stands.

**Interim corroboration — ✅ DONE (two independent legs).** This establishes the *evidence base is genuine*
and the *implementation reproduces its documented behaviour* — it does NOT audit the math. See
[`CROSS-CHECK.md`](./CROSS-CHECK.md) (reproduce: [`crosscheck/`](./crosscheck/)):
- **Reference cross-check** — the wired vectors are the genuine `bitcoin/bips` set with correct labels;
  off-chain and on-chain inputs are byte-identical (`sha256(preimage)` both sides, no drift).
- **On-EVM reproduction** — the *compiled* `BIP340.sol` / `BIP340Verifier.sol` reproduce every BIP-340
  assertion in a real EVM (live `ecrecover` + `modexp`), 34/34, zero false-accepts.
- Independently re-derived by **@damonzwicker** (third party to the author); separately reproduced on-EVM
  by **@babyblueviper1** under py-evm (31/31). Both labeled **reproduction, not review**.

**The open gate — the human crypto review (sourcing now).** A **cred-based public-good review** by a
best-matched independent reviewer (the on-chain-Schnorr / `ecrecover`-trick crowd — crysol/verklegarden,
a Chronicle-Schnorr reviewer, Witnet's EC folks) of the math the vectors *can't* establish: the
`ecrecover`-trick soundness, the even-Y lift, and **domain-check completeness**.

**Tier 2 — formal (the real mainnet gate).** A **grant-funded** spot audit (ENS ecosystem / EF ESP — it's
an ENS recovery tool). Required **before any mainnet value flows**, not before.

`BIP340.sol` stays flagged **pre-mainnet-audit** until Tier 2 lands. The interim legs + a cred-based review
strengthen confidence; they do not lift that flag.

## What to review
| | file | role |
|---|---|---|
| **primary** | [`src/BIP340.sol`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/src/BIP340.sol) | the secp256k1 Schnorr verifier — **the file** |
| supporting | [`src/BIP340Verifier.sol`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/src/BIP340Verifier.sol) | decodes `receiptProof`, pins issuer, extracts artifact_hash from the signed preimage |
| context | [`src/RecoveryEscrow.sol`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/src/RecoveryEscrow.sol) | how `verify()` is consumed (out of review scope) |

## Read first
- **Reviewer brief** (scope · the ecrecover-trick algebra · full domain-check checklist · known limitation ·
  recommended hardening): [`audit/BIP340-review-brief.md`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/audit/BIP340-review-brief.md)

## Evidence already in place
- **Official BIP-340 vectors:** [`test/BIP340Vectors.t.sol`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/test/BIP340Vectors.t.sol) — all 15 verification vectors from `bitcoin/bips` `test-vectors.csv` (32-byte-message set) pass, incl. every invalid case (not-on-curve pubkey, odd-Y R, negated message/s, infinite `sG−eP`, `rx` not a curve x, sig fields ≥ field/order, pubkey ≥ field size).
- **Unit tests:** [`test/BIP340.t.sol`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/test/BIP340.t.sol) (real noble-curves vector + tamper cases), [`test/BIP340Verifier.t.sol`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/test/BIP340Verifier.t.sol) (real SDK-signed receipt).
- **Live on Sepolia** ([`deployments.md`](https://github.com/TMerlini/hack-ens-recovery/blob/wyriwe-receipt/contracts/deployments.md)):
  - BIP340Verifier [`0x7c99c52E…3b70`](https://sepolia.etherscan.io/address/0x7c99c52Ed86EcedD65e60482243aa882a50F3b70) · RecoveryEscrow [`0x71D8E5a2…4f59`](https://sepolia.etherscan.io/address/0x71D8E5a2AD591EEf8541527DFfD705BC69134f59)
  - deployed verifier ran a real agent-signed receipt → `(valid, match) = (true, true)`
  - full fee-release [release tx](https://sepolia.etherscan.io/tx/0x2684908b3093590b31b6ced0d151d8b2589e6992890696b34eeb62b8412393b2) (block 11125260); replay reverts (nullifier).

## Reproduce locally
```bash
git clone https://github.com/TMerlini/hack-ens-recovery && cd hack-ens-recovery
git checkout wyriwe-receipt
cd contracts
forge install foundry-rs/forge-std
forge test            # 25/25 green
forge test --match-path test/BIP340Vectors.t.sol -vvv   # the official vectors
```

## What we're asking you to confirm
1. The `ecrecover`-trick mapping is sound: `ecrecover(h=−s·px, v=27, r=px, s_ec=−e·px) == address(R)` for `R = s·G − e·P`.
2. The challenge hash matches BIP-340 (`e = sha256(tag‖tag‖rx‖px‖m) mod n`, tag = `sha256("BIP0340/challenge")`).
3. The even-Y lift (`y = (x³+7)^((p+1)/4) mod p`, parity flip) and the curve-membership check are correct.
4. The domain checks are complete (`px,s ∈ (0,n)`, `rx ∈ (0,p)`, `e≠0`, infinity/`address(0)` handling).
5. No false-accept path exists; no unexpected revert (the function must return `false`, not revert, on bad input).
6. (supporting) `BIP340Verifier`'s preimage byte-scan for `artifact_hash` can't be steered given the signed, issuer-pinned bytes.

The brief expands each of these. Known, documented limitation: x-only keys with `x ∈ [n, p)` (~2⁻¹²⁸ of keys)
can't be used as the ecrecover `r` → pin a normal key. Please confirm acceptable.

## Logistics
- **Repo access:** public — `https://github.com/TMerlini/hack-ens-recovery` (PR [#1](https://github.com/TMerlini/hack-ens-recovery/pull/1)).
- **Engagement:** Tier 1 is a cred-based public-good review (not a paid bounty) — a fast, citeable pass on
  ~120 lines, with a reference cross-check you'd likely run anyway. Tier 2 (formal, grant-funded) comes only
  when mainnet value is on the horizon; happy to co-write the ENS/EF-ESP grant then.
- **Contact:** GitHub [@babyblueviper1](https://github.com/babyblueviper1) (author) · [@TMerlini](https://github.com/TMerlini) (escrow/integration). Comment on PR #1 or reach out directly.
