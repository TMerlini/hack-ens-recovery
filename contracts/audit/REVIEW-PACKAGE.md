# BIP340.sol — independent review package

**One-link entry point for a reviewer.** Everything needed for a fast, well-scoped pass on the single
crypto-critical file in the recovery-escrow stack.

## TL;DR
- **Review target:** `src/BIP340.sol` — on-chain BIP-340 (secp256k1 Schnorr) verification (~120 lines).
- **Effort:** small + bounded — `ecrecover`-trick for `sG = R + eP`, an even-Y point lift via the `modexp`
  precompile, and the domain-check surface. No external deps, no assembly beyond the precompile call.
- **Why:** it's the `valid` leg of an owner-bound escrow's release gate. A false-accept undermines the
  whole "verify trusting no one" design. This review is the **last gate before mainnet**.
- **Status:** 25/25 foundry tests green incl. all 15 official BIP-340 vectors; deployed + run end-to-end
  on Sepolia. We're not asking you to find missing tests — we're asking for human crypto eyes on the math.
- **Author:** `BIP340.sol` written by **@babyblueviper1**, who is explicitly *not* self-reviewing — hence
  this independent request. Bounty available (terms below).

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
  - BIP340Verifier [`0x681DfB46…67195`](https://sepolia.etherscan.io/address/0x681DfB46b744519a321dE187339386d6E8f67195) · RecoveryEscrow [`0x03e2a9Ec…fdb15`](https://sepolia.etherscan.io/address/0x03e2a9Ec424eF063ee78212A17aC9D25F26fdb15)
  - deployed verifier ran a real agent-signed receipt → `(valid, match) = (true, true)`
  - full fee-release [release tx](https://sepolia.etherscan.io/tx/0xed8974c7e842044cc81a7b5083a85a752aace38452b4352d4753028c54594c48) (block 11118096); replay reverts (nullifier).

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
- **Bounty:** available — amount/terms TBD with the reviewer (it's ~120 lines; we're after a tight, fast pass).
- **Contact:** GitHub [@babyblueviper1](https://github.com/babyblueviper1) (author) · [@TMerlini](https://github.com/TMerlini) (escrow/integration). Comment on PR #1 or reach out directly.
