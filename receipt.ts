/**
 * WYRIWE recovery receipt (kind 30078) — the verifiable layer over the rescue.
 *
 * Single trust anchor: artifact_hash + the commit event come from @trustless-ai/agent-sdk, NOT a local
 * copy — so the agent's hash and the escrow's expect_artifact_hash are byte-identical by construction.
 * Commit-before-outcome: committed before the bundle is broadcast; result_ref (settled tx) is the
 * outcome leg, kept OUT of the artifact preimage.
 *
 * Spec (locked w/ babyblueviper1): https://gist.github.com/TMerlini/98b7dbeb221024b617b36c7e3b79e695
 */
import {
  artifactHash as sdkArtifactHash,
  buildCommitEvent,
  normalizeSpec as sdkNormalizeSpec,
  publishCommit as sdkPublishCommit,
  packReceiptProof as sdkPackReceiptProof,
  relayPublish,
  PROOF_KIND,
  type PublishResult,
} from "@trustless-ai/agent-sdk";
import { AbiCoder, getBytes } from "ethers";

export const JUDGMENT_TYPE = "recovery_receipt";
export const SCHEMA = "trustless-ai.commit.v0";

export interface RecoveryArtifact {
  job_id: string;          // salt → identical specs stay distinct (don't collide under the nullifier)
  target_wallet: string;   // the compromised wallet
  output_address: string;  // owner-specified destination — the only place assets may go
  asset_set: { ens_name: string; token_id: string; base_registrar: string; registry: string };
}

/**
 * Normalize the spec so caller + escrow hash IDENTICAL input. Delegates to the SDK's `normalizeSpec`
 * — the single anti-drift point (recursively lowercases EVM-address-shaped strings, leaves
 * case-significant fields like ens_name/token_id/job_id untouched). The escrow calls the SAME SDK
 * function, so `artifact_hash` is byte-identical on both sides by construction. (SDK's canonical()
 * sorts keys recursively, so field order here is irrelevant.)
 */
export function normalizeSpec(a: RecoveryArtifact): RecoveryArtifact {
  return sdkNormalizeSpec(a);
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

/** Public Nostr relays for the commit-publication leg. Override with NOSTR_RELAYS (comma-separated). */
const DEFAULT_RELAYS = (process.env.NOSTR_RELAYS ?? "wss://relay.damus.io,wss://nos.lol,wss://relay.primal.net")
  .split(",").map((s) => s.trim()).filter(Boolean);

/**
 * publishCommit — anchor the SIGNED kind-30078 commit to public sources: relay-publish (third-party
 * copies + published_at) + OTS-to-Bitcoin (PoW precedence). Thin wrapper over the SDK's
 * `publishCommit()` (injected I/O, NEVER signs): default `relayPublish` for the relay leg; the OTS leg
 * is injected because it needs the `ots` calendar I/O (not bundled). Pass `otsStamp` to enable it —
 * recompute later with `ots verify -d <event_id>`.
 *
 * The event must already be signed by your own key mgmt (`commitPreAction` returns it UNSIGNED — sign
 * it, set `receipt.event.sig`, then publish). Verification stays the SDK's `verifyFullFlow` (gate:
 * valid && artifact_hash_matches && anchored); the escrow ALSO checks on-chain delivery + nullifies.
 */
export async function publishCommit(
  receipt: RecoveryReceipt,
  opts: { relays?: string[]; otsStamp?: (eventId: string) => Promise<unknown> } = {},
): Promise<PublishResult> {
  if (!receipt.event) {
    throw new Error("publishCommit: receipt has no commit event — run commitPreAction with AGENT_PUBKEY first.");
  }
  if (!receipt.event.sig) {
    throw new Error("publishCommit: event is unsigned — sign the kind-30078 event with your own key mgmt before publishing (the SDK never signs).");
  }
  return sdkPublishCommit({
    event: receipt.event,
    relays: opts.relays ?? DEFAULT_RELAYS,
    publishToRelay: relayPublish,
    otsStamp: opts.otsStamp,
    requireSig: true,
  });
}

const SECP256K1_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2Fn;
// artifact_hash marker as it appears in the serialized (escaped) content: \"artifact_hash\":\"
const ARTIFACT_MARKER = Buffer.from('\\"artifact_hash\\":\\"', "utf8");

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  base %= mod;
  let r = 1n;
  while (exp > 0n) {
    if (exp & 1n) r = (r * base) % mod;
    base = (base * base) % mod;
    exp >>= 1n;
  }
  return r;
}

/** even-Y lift of x on secp256k1: y = √(x³+7) mod p (p ≡ 3 mod 4), chosen even (BIP-340). */
function liftXEvenY(rx: string): string {
  const x = BigInt(rx);
  const y2 = (modPow(x, 3n, SECP256K1_P) + 7n) % SECP256K1_P;
  let y = modPow(y2, (SECP256K1_P + 1n) / 4n, SECP256K1_P);
  if ((y * y) % SECP256K1_P !== y2) throw new Error("liftXEvenY: rx is not a valid curve x-coordinate");
  if (y & 1n) y = SECP256K1_P - y;
  return "0x" + y.toString(16).padStart(64, "0");
}

/**
 * buildReceiptProof — pack the SIGNED kind-30078 commit into the `receiptProof` bytes that
 * `RecoveryEscrow.release(expectArtifactHash, receiptProof)` forwards to `BIP340Verifier.verify()`.
 *
 * Layout: `abi.encode(px, rx, s, ry, contentOffset, preimage)`, byte-identical to what the on-chain
 * verifier decodes (same anti-drift discipline as `normalizeSpec`). The SDK's `packReceiptProof()` supplies
 * `(px, rx, s, preimage)`; this wrapper adds two witnesses the verifier CHECKS (never trusts) so it can
 * skip expensive on-chain work — per Max Wickham's 2026-07 review (see BIP340.sol / BIP340Verifier.sol):
 *   - `ry`            : even-Y coord of R lifted from `rx`. Contract verifies `ry² ≡ rx³+7 (mod p)` instead
 *                       of computing the sqrt via the `modexp` precompile every call (gas).
 *   - `contentOffset` : exact index of the `artifact_hash` marker in the preimage. Contract checks the
 *                       marker sits there instead of scanning for a first match (parsing-ambiguity fix).
 *
 * The event must be signed (the contract checks the BIP-340 sig over `sha256(preimage)`); `commitPreAction`
 * returns it UNSIGNED. Release flow: commitPreAction → sign → publishCommit → buildReceiptProof → escrow.release.
 */
export function buildReceiptProof(receipt: RecoveryReceipt): string {
  if (!receipt.event) {
    throw new Error("buildReceiptProof: receipt has no commit event — run commitPreAction with AGENT_PUBKEY first.");
  }
  if (!receipt.event.sig) {
    throw new Error("buildReceiptProof: event is unsigned — sign the kind-30078 event before packing (the contract verifies the signature).");
  }
  const coder = AbiCoder.defaultAbiCoder();
  const [px, rx, s, preimage] =
    coder.decode(["bytes32", "bytes32", "bytes32", "bytes"], sdkPackReceiptProof(receipt.event));
  const ry = liftXEvenY(rx);
  const contentOffset = Buffer.from(getBytes(preimage)).indexOf(ARTIFACT_MARKER);
  if (contentOffset < 0) throw new Error("buildReceiptProof: artifact_hash marker not found in the signed preimage");
  return coder.encode(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "bytes"],
    [px, rx, s, ry, contentOffset, preimage],
  );
}
