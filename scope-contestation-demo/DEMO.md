# scope-contestation over the recovery `asset_set` (worked example)

The [recovery escrow](../contracts) proves a rescue is **faithful** (`valid ∧ match ∧ delivery`) but binds
the *declared* `asset_set` — it cannot prove the set was **complete**. An agent can honestly miss an asset,
emit a clean receipt, settle, nullify, and still leave a coordinate behind (E-capture).
[`scope-contestation`](https://github.com/damonzwicker/scope-contestation) (Damon Zwicker, CC0) is the
orthogonal **contestability axis**: commit the observed `asset_set` bound to the job's OCP/8281 commitment,
and anyone can **nominate** a *missed* asset — proving on-chain (sorted-Merkle non-inclusion) it's absent.
The registry adjudicates nothing; its single guarantee is that **no omission is structurally invisible.**

This wires it onto a real recovery job.

## The job
Bound to the live Sepolia recovery job's `artifact_hash` = `0xee601a25…0989bc0b` — the **same OCP layer-0
commitment** the WYRIWE receipt uses (compose by reference, no new dependency).
- **Declared / observed `asset_set`:** `gobross.eth` · `PixelGoblin #4417` · `ENScribe #88` · `Vortex LP #12`
- **Still in the compromised wallet, NOT observed:** `PixelGoblin #903`

## Live on Sepolia
| step | result |
|---|---|
| `ScopeContestationRegistry` | [`0xB4012790…E723F`](https://sepolia.etherscan.io/address/0xB4012790CC5A9f237Cb570C5e5150912df3E723F) |
| `commitScope` (asset_set root ↦ artifact_hash) | [`0x6e1d8300…`](https://sepolia.etherscan.io/tx/0x6e1d83001505e24c47a2da6c1d2369f8a749c37ef13e46e01aac16122f61dd59) · scopeId `0x892152fd…` |
| `nominate(PixelGoblin #903)` — the **missed** asset | [`0x5ff29228…`](https://sepolia.etherscan.io/tx/0x5ff29228226c0f5870544edceaba111478cbc9553b5854b137f165119ca50d84) ✅ omission permanent + nominable |
| `nominate(PixelGoblin #4417)` — a **declared** asset | reverts `coordinate is in scope` — **soundness** |

So "did the rescue actually get everything?" is now an on-chain, permissionless, recomputable question
against the real job — and a *declared* asset cannot be faked as an omission.

## Reproduce
```bash
pip install pycryptodome
python3 recovery_scope_demo.py     # prints the scope root + the non-inclusion proof for the missed asset
# then: forge create the registry, cast send commitScope, cast send nominate(<missed>, <proof>)
```
`scope_ref.py` is vendored from [damonzwicker/scope-contestation](https://github.com/damonzwicker/scope-contestation) (CC0) — same logic as the on-chain verifier; forge 10/10 confirmed there ([PR #1](https://github.com/damonzwicker/scope-contestation/pull/1)).
