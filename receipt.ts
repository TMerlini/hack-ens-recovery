/**
 * WYRIWE recovery receipt (kind 30078) — the verifiable layer over the rescue.
 *
 * Single trust anchor: artifact_hash + the commit event come from @onchain-ai/agent-sdk, NOT a local
 * copy — so the agent's hash and the escrow's expect_artifact_hash are byte-identical by construction.
 * Commit-before-outcome: committed before the bundle is broadcast; result_ref (settled tx) is the
 * outcome leg, kept OUT of the artifact preimage.
 *
 * Spec (locked w/ babyblueviper1): https://gist.github.com/TMerlini/98b7dbeb221024b617b36c7e3b79e695
 */
import { artifactHash as sdkArtifactHash, buildCommitEvent, PROOF_KIND } from "@onchain-ai/agent-sdk";

export const JUDGMENT_TYPE = "recovery_receipt";
export const SCHEMA = "onchain-ai.commit.v0";

export interface RecoveryArtifact {
  job_id: string;          // salt → identical specs stay distinct (don't collide under the nullifier)
  target_wallet: string;   // the compromised wallet
  output_address: string;  // owner-specified destination — the only place assets may go
  asset_set: { ens_name: string; token_id: string; base_registrar: string; registry: string };
}

/**
 * Normalize the spec so caller + escrow hash IDENTICAL input. The SDK's canonical() sorts keys
 * (recursive) and is case-sensitive on purpose, so we only lowercase the case-significant address
 * fields here. (Interim — switch to the SDK's `normalizeSpec` convention the moment it ships.)
 */
export function normalizeSpec(a: RecoveryArtifact) {
  return {
    job_id: a.job_id,
    target_wallet: a.target_wallet.toLowerCase(),
    output_address: a.output_address.toLowerCase(),
    asset_set: {
      ens_name: a.asset_set.ens_name,
      token_id: a.asset_set.token_id,
      base_registrar: a.asset_set.base_registrar.toLowerCase(),
      registry: a.asset_set.registry.toLowerCase(),
    },
  };
}

/** artifact_hash via the SDK over the normalized spec — the same value the escrow holds as expect_artifact_hash. */
export function artifactHash(a: RecoveryArtifact): string {
  return sdkArtifactHash(normalizeSpec(a));
}

export interface RecoveryReceipt {
  kind: number;
  artifact_hash: string;
  output_address: string;
  committed_at: number;    // pre-action (precedes outcome)
  event?: Record<string, unknown>; // the (unsigned) kind-30078 commit from the SDK
  entry?: string;          // event id; read back via GET /ledger/{entry}/commitment once published
  result_ref?: string;     // outcome leg (attached on land; NOT in artifact_hash); read via /ledger/{entry}/outcome
}

/**
 * Pre-action commit: build the kind-30078 commit via the SDK BEFORE the bundle is broadcast.
 * Requires AGENT_PUBKEY (x-only hex of the signer). Signing + relay-publish + OTS anchoring are
 * `publishCommit()`'s job (SDK follow-up) — the SDK never touches a private key.
 */
export async function commitPreAction(a: RecoveryArtifact): Promise<RecoveryReceipt> {
  const spec = normalizeSpec(a);
  const pubkey = process.env.AGENT_PUBKEY ?? "";
  if (!pubkey) {
    // No signer configured → still produce the deterministic owner-binding (hash only).
    return { kind: PROOF_KIND, artifact_hash: sdkArtifactHash(spec), output_address: spec.output_address, committed_at: Math.floor(Date.now() / 1000) };
  }
  const { event, id, artifact_hash } = buildCommitEvent({ spec, pubkey, judgmentType: JUDGMENT_TYPE, schema: SCHEMA });
  return { kind: event.kind as number, artifact_hash, output_address: spec.output_address, committed_at: event.created_at as number, event, entry: id };
}

/** Attach the settled outcome. result_ref stays OUT of artifact_hash (commit-before-outcome). */
export function finalize(receipt: RecoveryReceipt, result_ref: string): RecoveryReceipt {
  return { ...receipt, result_ref };
}

/**
 * publishCommit — sign + relay-publish + OTS-anchor the commit event. Stub until the SDK ships its
 * `publishCommit()` (relay + OTS) helper; until then `commitPreAction` returns the built event ready
 * to publish. Verification is the SDK's `verifyFullFlow` (gate: valid && artifact_hash_matches &&
 * anchored; the escrow ALSO checks on-chain delivery + nullifies the artifact).
 */
export async function publishCommit(_receipt: RecoveryReceipt): Promise<never> {
  throw new Error("publishCommit: pending @onchain-ai/agent-sdk relay+OTS helper. See gist 98b7dbeb.");
}
