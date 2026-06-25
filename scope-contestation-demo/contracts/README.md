# Scope Contestation — Solidity reference (Layer 1 `verifyAbsence` leg)

Solidity port of the Python reference (`../scope_ref.py`, option **(b)**), wired into the
**Layer 2 `contest()` flow** so the two layers run end-to-end. This is the leg
[JimmyShi22](https://gist.github.com/JimmyShi22/8ef5b25f928bea5e34df3f03fea03d67) handed
back: *"the verifyAbsence leg is the natural seam for your Layer 1 work."*

## Contracts
| File | Role |
|---|---|
| `IScopeContestation.sol` | **Layer 1** abstract interface (the standard; merkle is one impl) |
| `ScopeContestation.sol` | sorted-Merkle non-inclusion reference — ports `verify_non_inclusion_b` |
| `IScopeClassifier.sol` | **Layer 2** interface — verbatim from Jimmy's gist |
| `MajorityClassifier.sol` | `categorical/majority` reference classifier (for the e2e test) |
| `Layer2PreCheck.sol` | orchestrator: runs `contest()` in the fixed guard order |
| `ScopeTypes.sol` | `NIProof`, `Vote` |

## The scheme (Guarantee 4 — truncation resistance)
```
leaf(c)   = keccak256(0x00 ‖ c)          node(l,r) = keccak256(0x01 ‖ l ‖ r)
scopeRoot = bind(root, N) = keccak256(abi.encode(root, N))     odd node promoted
```
`count` (N) is **not** on the interface — it is bound into `scopeRoot` and rides inside
the proof, validated at verify-time. Understate N → recompute a different root →
`bind` mismatch → reject. So a committer can't declare a small scope, then prove a
*declared* coordinate "absent" against a truncated prefix.

## The seam
`Layer2PreCheck.contest()` derives `coordinateHash = keccak256(nominatedCoordinate)`
**once** and passes the same 32 bytes to **both** `verifyAbsence` (Layer 1 guard) and
`classify` (Layer 2) — so the cross-layer "same coordinate" invariant is structural,
not just a written rule. All guards are `require()` — they revert, never encoded in the
returned `separated` bool.

## Run
```bash
forge test -vv      # 5 tests
```
- `materialAbsentX_separates` — full contest() path: an absent X flips the verdict → material
- `verifyAbsence_truncationAttack_rejected` — Guarantee 4: understated-N prefix proof rejected
- `makeNI_declaredCoordinate_hasNoProof` — soundness: no proof exists for a declared coord
- `nonMaterialAbsentX_notSeparated` — absent X that doesn't change the verdict → not material
- `isolationViolation_reverts` — a pair differing on more than X is rejected

Mirrors `../recovery_scope_demo_b.py` tests `[1]`–`[4]`.
