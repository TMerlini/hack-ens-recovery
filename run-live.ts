/**
 * run-live.ts — drive a recorded incident end-to-end through the verifiable recovery-escrow flow.
 *
 * The five locked steps, one command:
 *   1. commitPreAction   build the UNSIGNED kind-30078 commit (binds output_address + the rescue spec)
 *   2. sign              BIP-340 schnorr-sign the event id with the agent key (the key the verifier pins)
 *   3. publishCommit     relay-anchor (+ OTS if `ots` is installed) — commit-before-outcome, best-effort
 *   4. openJob           fund the escrow for this artifact_hash if no job exists yet
 *   5. release           buildReceiptProof → escrow.release(artifact_hash, proof)
 *
 * Owner-binding (output_address in the preimage + on-chain delivery check), replay (nullifier), and the
 * signature/issuer leg (BIP340Verifier) are all enforced on-chain — nothing here is trusted.
 *
 * SAFETY: DRY_RUN defaults to TRUE. A dry run does steps 1–3, then *statically* checks the verifier
 * (valid ∧ artifact_hash_matches) + the on-chain delivery (ownerOf == output_address) and reports
 * whether release WOULD succeed — without broadcasting. Set DRY_RUN=false to actually openJob + release.
 *
 *   bun run run-live.ts
 *
 * env:
 *   RPC_URL              JSON-RPC endpoint (testnet for the demo)
 *   ESCROW_ADDRESS       deployed RecoveryEscrow (from script/Deploy.s.sol)
 *   AGENT_PRIVKEY        32-byte hex — the agent's BIP-340 key; its x-only pubkey is what the verifier pins
 *   CALLER_KEY           funded EVM key that opens the job + submits release (release is permissionless)
 *   AGENT_FEE_RECIPIENT  EVM address paid the fee on release (default: the CALLER address)
 *   JOB_ID               salt; auto-generated if unset
 *   COMPROMISED_ADDRESS  target_wallet (or derived from COMPROMISED_KEY if that's set instead)
 *   NEW_WALLET           output_address — the ONLY destination assets may go
 *   ENS_LABEL            label of the rescued .eth name (token_id = keccak256(label))
 *   BASE_REGISTRAR       ERC-721 holding the name (default ENS mainnet BaseRegistrar)
 *   ENS_REGISTRY         ENS registry (default mainnet)
 *   FEE_ETH              escrow fee (default 0.01)
 *   EXPIRY_SECONDS       refund window from now (default 86400)
 *   DRY_RUN              "false" to broadcast; anything else = dry run (default)
 */
import { ethers } from "ethers";
import { schnorr } from "@noble/curves/secp256k1";
import { commitPreAction, buildReceiptProof, publishCommit, type RecoveryArtifact } from "./receipt";

const toHex = (u8: Uint8Array) => Buffer.from(u8).toString("hex");
const need = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing env ${k}`);
  return v;
};

const ESCROW_ABI = [
  "function openJob(bytes32 expectArtifactHash, address outputAddress, address asset, uint256 tokenId, address agent, uint64 expiry) payable",
  "function release(bytes32 expectArtifactHash, bytes receiptProof)",
  "function getJob(bytes32) view returns (tuple(address requester, address agent, address outputAddress, address asset, uint256 tokenId, uint256 fee, uint64 expiry, uint8 status))",
  "function verifier() view returns (address)",
  "event Released(bytes32 indexed expectArtifactHash, address indexed agent, uint256 fee, address caller)",
];
const VERIFIER_ABI = [
  "function issuerPubkeyX() view returns (bytes32)",
  "function verify(bytes32 expectArtifactHash, bytes receiptProof) view returns (bool valid, bool artifactHashMatches)",
];
const ERC721_ABI = ["function ownerOf(uint256) view returns (address)"];

const BASE_REGISTRAR = process.env.BASE_REGISTRAR ?? "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85";
const ENS_REGISTRY = process.env.ENS_REGISTRY ?? "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e";
const DRY_RUN = (process.env.DRY_RUN ?? "true").toLowerCase() !== "false";

async function main() {
  const provider = new ethers.JsonRpcProvider(need("RPC_URL"));
  const caller = new ethers.Wallet(need("CALLER_KEY"), provider);
  const escrow = new ethers.Contract(need("ESCROW_ADDRESS"), ESCROW_ABI, caller);
  const verifier = new ethers.Contract(await escrow.verifier(), VERIFIER_ABI, provider);

  const label = need("ENS_LABEL");
  const ensName = `${label}.eth`;
  const tokenId = BigInt(ethers.keccak256(ethers.toUtf8Bytes(label)));
  const outputAddress = ethers.getAddress(need("NEW_WALLET"));
  const targetWallet = process.env.COMPROMISED_ADDRESS
    ? ethers.getAddress(process.env.COMPROMISED_ADDRESS)
    : new ethers.Wallet(need("COMPROMISED_KEY")).address;
  const agentFeeRecipient = ethers.getAddress(process.env.AGENT_FEE_RECIPIENT ?? caller.address);
  const feeWei = ethers.parseEther(process.env.FEE_ETH ?? "0.01");
  const expiry = BigInt(Math.floor(Date.now() / 1000) + Number(process.env.EXPIRY_SECONDS ?? 86400));

  console.log(`\nmode: ${DRY_RUN ? "DRY RUN (no broadcast)" : "⚠️  LIVE (will broadcast)"}`);
  console.log(`escrow   : ${await escrow.getAddress()}`);
  console.log(`verifier : ${await verifier.getAddress()}`);

  // ── agent key: derive the x-only pubkey the commit embeds + the verifier must pin ──
  const priv = need("AGENT_PRIVKEY").replace(/^0x/, "");
  const agentPubX = toHex(schnorr.getPublicKey(priv));
  process.env.AGENT_PUBKEY = agentPubX; // commitPreAction reads this to build a signed-by-agent commit
  const pinned = (await verifier.issuerPubkeyX()).replace(/^0x/, "").toLowerCase();
  console.log(`\nagent x-only pubkey : ${agentPubX}`);
  console.log(`verifier pins       : ${pinned}`);
  if (pinned !== agentPubX.toLowerCase()) {
    throw new Error("issuer mismatch — the verifier pins a different key than AGENT_PRIVKEY. Deploy with ISSUER_PUBKEY = this agent pubkey.");
  }
  console.log("issuer pin matches ✓");

  // ── 1. commit (pre-action, unsigned) ──
  const artifact: RecoveryArtifact = {
    job_id: process.env.JOB_ID || ethers.hexlify(ethers.randomBytes(8)),
    target_wallet: targetWallet,
    output_address: outputAddress,
    asset_set: { ens_name: ensName, token_id: tokenId.toString(), base_registrar: BASE_REGISTRAR, registry: ENS_REGISTRY },
  };
  const receipt = await commitPreAction(artifact);
  const expectHash = receipt.artifact_hash.startsWith("0x") ? receipt.artifact_hash : "0x" + receipt.artifact_hash;
  console.log(`\n[1] commit built — artifact_hash ${expectHash}`);
  if (!receipt.event) throw new Error("no commit event (AGENT_PUBKEY not picked up)");

  // ── 2. sign the event id (BIP-340) ──
  const idBytes = ethers.getBytes(receipt.event.id.startsWith("0x") ? receipt.event.id : "0x" + receipt.event.id);
  const sig = schnorr.sign(idBytes, priv);
  if (!schnorr.verify(sig, idBytes, schnorr.getPublicKey(priv))) throw new Error("local schnorr self-verify failed");
  receipt.event.sig = toHex(sig);
  console.log(`[2] signed — sig ${receipt.event.sig.slice(0, 16)}… (self-verify ✓)`);

  // ── 3. anchor (relay + OTS), best-effort ──
  try {
    const pub = await publishCommit(receipt);
    console.log(`[3] anchored — ${pub.relay_count} relay(s); ots ${pub.ots ? "stamped" : "skipped (no `ots`)"}`);
  } catch (e) {
    console.log(`[3] anchor skipped (${String(e).split("\n")[0]}) — non-blocking; escrow gate is valid∧match∧delivery`);
  }

  // ── proof + preflight (always, even in dry run) ──
  const proof = buildReceiptProof(receipt);
  const [vValid, vMatch] = await verifier.verify(expectHash, proof);
  const onchainOwner = await new ethers.Contract(BASE_REGISTRAR, ERC721_ABI, provider).ownerOf(tokenId);
  const delivered = onchainOwner.toLowerCase() === outputAddress.toLowerCase();
  console.log(`\npreflight (static):`);
  console.log(`  verifier.valid              : ${vValid}`);
  console.log(`  verifier.artifactHashMatches: ${vMatch}`);
  console.log(`  delivery ownerOf==output    : ${delivered}  (owner ${onchainOwner})`);
  const wouldPass = vValid && vMatch && delivered;
  console.log(`  → release would ${wouldPass ? "SUCCEED ✅" : "REVERT ❌"}`);
  if (!delivered) console.log("    (run rescue.ts first so the asset actually sits at output_address)");

  if (DRY_RUN) {
    console.log("\nDRY_RUN — stopping before openJob/release. Set DRY_RUN=false to broadcast.");
    return;
  }
  if (!wouldPass) throw new Error("preflight failed — refusing to broadcast a reverting release.");

  // ── 4. ensure job open ──
  const job = await escrow.getJob(expectHash);
  if (Number(job.status) === 0) {
    console.log(`\n[4] openJob — fee ${ethers.formatEther(feeWei)} ETH, agent ${agentFeeRecipient}`);
    const t = await escrow.openJob(expectHash, outputAddress, BASE_REGISTRAR, tokenId, agentFeeRecipient, expiry, { value: feeWei });
    console.log(`    tx ${t.hash} …`); await t.wait();
  } else {
    console.log(`\n[4] job already open (status ${job.status}) — skipping openJob`);
  }

  // ── 5. release ──
  console.log(`[5] release …`);
  const tx = await escrow.release(expectHash, proof);
  console.log(`    tx ${tx.hash} …`);
  const rc = await tx.wait();
  console.log(`\n✅ released in block ${rc?.blockNumber}. Fee → ${agentFeeRecipient}; artifact_hash nullified.`);
}

main().catch((e) => { console.error("\n✗", e instanceof Error ? e.message : e); process.exit(1); });
