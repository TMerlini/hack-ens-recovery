/**
 * recompute — re-derive the receipt's artifact_hash from PUBLIC data, with zero trust.
 * This is the org "recompute/verify step": anyone can run it and check a recovery receipt
 * without trusting the agent, the ledger, or us.
 *
 *   bun run recompute.ts <job_id> <target_wallet> <output_address> <ens_label> [expected_artifact_hash]
 *
 * Re-derives artifact_hash = H(job_id, target_wallet, output_address, asset_set). If you pass the
 * receipt's artifact_hash as the last arg, it asserts they match. (Full receipt validity —
 * signature + invinoveritas issuance + Bitcoin-OTS precedence — is checked via @onchain-ai/agent-sdk /
 * invinoveritas /verify-proof; this script proves the *binding* leg offline.)
 */
import { artifactHash } from "./receipt";

const BASE_REGISTRAR = "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85";
const ENS_REGISTRY = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e";

const [job_id, target_wallet, output_address, ens_label, expected] = process.argv.slice(2);
if (!job_id || !target_wallet || !output_address || !ens_label) {
  console.error("usage: bun run recompute.ts <job_id> <target_wallet> <output_address> <ens_label> [expected_artifact_hash]");
  process.exit(1);
}

const { ethers } = await import("ethers");
const ens_name = `${ens_label}.eth`;
const token_id = BigInt(ethers.keccak256(ethers.toUtf8Bytes(ens_label))).toString();

const hash = artifactHash({
  job_id, target_wallet, output_address,
  asset_set: { ens_name, token_id, base_registrar: BASE_REGISTRAR, registry: ENS_REGISTRY },
});

console.log("ens_name      :", ens_name);
console.log("token_id      :", token_id);
console.log("artifact_hash :", hash);

if (expected) {
  const ok = hash.toLowerCase() === expected.toLowerCase();
  console.log(ok ? "\n✅ MATCH — receipt is bound to exactly this rescue spec." : "\n❌ MISMATCH — receipt does not bind this spec.");
  process.exit(ok ? 0 : 1);
}
