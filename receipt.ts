/**
 * WYRIWE recovery receipt (Nostr kind 30078) — the verifiable layer over the rescue.
 *
 * Commit-before-outcome: the artifact_hash is committed BEFORE the rescue bundle is
 * broadcast (the sweeper-can't-react window is *also* the proof window), then result_ref
 * (the settled tx) is attached once the transfer lands. result_ref is NOT in the artifact
 * preimage — that split is what preserves the commit-before-outcome ordering.
 *
 * Spec (locked w/ babyblueviper1): https://gist.github.com/TMerlini/98b7dbeb221024b617b36c7e3b79e695
 */
import { ethers } from "ethers";

export const RECEIPT_KIND = 30078;
// invinoveritas verify + ledger legs (Fede). Override via LEDGER_URL.
const LEDGER_URL = process.env.LEDGER_URL ?? "https://api.babyblueviper.com";

export interface RecoveryArtifact {
  job_id: string;          // salt → identical specs stay distinct (don't collide under the nullifier)
  target_wallet: string;   // the compromised wallet
  output_address: string;  // owner-specified destination — the only place assets may go
  asset_set: { ens_name: string; token_id: string; base_registrar: string; registry: string };
}

export interface RecoveryReceipt {
  kind: number;
  artifact_hash: string;   // = H(job_id, target_wallet, output_address, asset_set) — owner-bound by construction
  output_address: string;
  committed_at: number;    // pre-action (precedes outcome)
  result_ref?: string;     // settled delivery tx (attached on land; NOT in artifact_hash)
  ledger_ref?: string;     // invinoveritas anchor id (so checks.issued_by_invinoveritas holds)
}

/** Canonical preimage → artifact_hash. Deterministic + re-derivable from public data (see recompute.ts). */
export function artifactHash(a: RecoveryArtifact): string {
  const preimage = JSON.stringify([
    a.job_id,
    a.target_wallet.toLowerCase(),
    a.output_address.toLowerCase(),
    {
      ens_name: a.asset_set.ens_name,
      token_id: a.asset_set.token_id,
      base_registrar: a.asset_set.base_registrar.toLowerCase(),
      registry: a.asset_set.registry.toLowerCase(),
    },
  ]);
  return ethers.sha256(ethers.toUtf8Bytes(preimage));
}

/** Pre-action commit: anchor the artifact_hash BEFORE the bundle is broadcast. */
export async function commitPreAction(a: RecoveryArtifact): Promise<RecoveryReceipt> {
  const receipt: RecoveryReceipt = {
    kind: RECEIPT_KIND,
    artifact_hash: artifactHash(a),
    output_address: a.output_address.toLowerCase(),
    committed_at: Math.floor(Date.now() / 1000),
  };
  // ── INTEGRATION POINT (invinoveritas /ledger, babyblueviper1) ──
  // POST the commitment to get the signed + Bitcoin-OTS-anchored kind-30078 proof event.
  // Exact payload/endpoint per the invinoveritas commitment-proof spec. Best-effort: the
  // local deterministic commitment always stands even if the ledger isn't reachable here.
  try {
    const res = await fetch(`${LEDGER_URL}/ledger/commit`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind: RECEIPT_KIND,
        artifact_hash: receipt.artifact_hash,
        output_address: receipt.output_address,
        committed_at: receipt.committed_at,
      }),
    });
    if (res.ok) {
      const j = (await res.json()) as any;
      receipt.ledger_ref = j.id ?? j.event_id ?? j.ref;
    }
  } catch { /* ledger optional in example/dry mode */ }
  return receipt;
}

/** Attach the settled outcome. result_ref stays OUT of artifact_hash (commit-before-outcome). */
export function finalize(receipt: RecoveryReceipt, result_ref: string): RecoveryReceipt {
  return { ...receipt, result_ref };
}

/**
 * verifyFullFlow — the whole chain, executed. Placeholder until @onchain-ai/agent-sdk ships
 * (Fede's verify + ledger legs). Release gate is NEVER `valid` alone:
 *   valid === true  (= id_integrity ∧ signature_valid ∧ issued_by_invinoveritas ∧ is_proof_event)
 *   AND checks.artifact_hash_matches === true   (receipt artifact == this job's expect_artifact_hash)
 *   AND on-chain delivery (asset_set actually landed at output_address)
 */
export async function verifyFullFlow(_receipt: RecoveryReceipt, _expectArtifactHash: string): Promise<never> {
  throw new Error(
    "verifyFullFlow: wire @onchain-ai/agent-sdk (verify + ledger legs). " +
    "Spec: gist 98b7dbeb. Until then, recompute.ts re-derives artifact_hash from public data.",
  );
}
