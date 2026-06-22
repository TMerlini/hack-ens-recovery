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
// There is NO central commit endpoint — the commit is the kind-30078 event itself, published to
// relays + OTS-anchored by agent-sdk's zero-dep scripts (nothing routes through a service).
// Read mirrors so verifyFullFlow() and the ledger agree (base defaults to api.babyblueviper.com):
//   GET {LEDGER_URL}/ledger/{entry}/commitment   ·   GET {LEDGER_URL}/ledger/{entry}/outcome

export interface RecoveryArtifact {
  job_id: string;          // salt → identical specs stay distinct (don't collide under the nullifier)
  target_wallet: string;   // the compromised wallet
  output_address: string;  // owner-specified destination — the only place assets may go
  asset_set: { ens_name: string; token_id: string; base_registrar: string; registry: string };
}

/** The kind-30078 commitment event. This event IS the commit — there is no central POST.
 *  agent-sdk's zero-dep scripts publish it to Nostr relays + OTS-anchor it (Bitcoin PoW precedence). */
export interface CommitEvent {
  kind: number;            // 30078
  created_at: number;      // pre-action
  tags: string[][];        // [["artifact_hash", …], ["output_address", …]]
  content: string;
}

export interface RecoveryReceipt {
  kind: number;
  artifact_hash: string;   // = H(job_id, target_wallet, output_address, asset_set) — owner-bound by construction
  output_address: string;
  committed_at: number;    // pre-action (precedes outcome)
  event?: CommitEvent;     // the built commit, pre-publish
  entry?: string;          // published event id; read back via GET /ledger/{entry}/commitment
  result_ref?: string;     // outcome leg (attached on land; NOT in artifact_hash); read via /ledger/{entry}/outcome
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

/** Build the kind-30078 commitment event. This event IS the commit (no central POST). */
export function buildCommit(a: RecoveryArtifact): { event: CommitEvent; artifact_hash: string } {
  const artifact_hash = artifactHash(a);
  const event: CommitEvent = {
    kind: RECEIPT_KIND,
    created_at: Math.floor(Date.now() / 1000),
    tags: [
      ["artifact_hash", artifact_hash],
      ["output_address", a.output_address.toLowerCase()],
    ],
    content: JSON.stringify({ artifact_hash, output_address: a.output_address.toLowerCase() }),
  };
  return { event, artifact_hash };
}

/**
 * Pre-action commit: build the kind-30078 event and publish it BEFORE the bundle is broadcast.
 * The event itself is the commitment — agent-sdk's zero-dep scripts relay-publish + OTS-anchor it
 * (Bitcoin PoW precedence). Nothing routes through a central service. Read back via
 * GET /ledger/{entry}/commitment.
 */
export async function commitPreAction(a: RecoveryArtifact): Promise<RecoveryReceipt> {
  const { event, artifact_hash } = buildCommit(a);
  const receipt: RecoveryReceipt = {
    kind: RECEIPT_KIND,
    artifact_hash,
    output_address: a.output_address.toLowerCase(),
    committed_at: event.created_at,
    event,
  };
  // ── publish via @onchain-ai/agent-sdk (zero-dep: sign → relay-publish → OTS anchor) ──
  // const { publishCommit } = await import("@onchain-ai/agent-sdk");
  // receipt.entry = await publishCommit(event);   // returns the published event id (the ledger entry)
  // Until agent-sdk lands, `receipt.event` carries the built commit, ready to publish.
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
