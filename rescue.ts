/**
 * ENS Recovery — Flashbots Atomic Bundle
 * Rescues an ENS .eth domain from a sweeper-bot-compromised wallet.
 *
 * Configure via .env (see .env.example), then: bun run rescue.ts
 */

import { ethers } from "ethers";

// ─── Config ──────────────────────────────────────────────────────────────────
const COMPROMISED_KEY = process.env.COMPROMISED_KEY ?? "";
const THROWAWAY_KEY   = process.env.THROWAWAY_KEY   ?? "";
const NEW_WALLET      = process.env.NEW_WALLET       ?? "";
const ENS_LABEL       = process.env.ENS_LABEL        ?? "";
const FUND_AMOUNT     = process.env.FUND_AMOUNT      ?? "0.006";

if (!COMPROMISED_KEY || !THROWAWAY_KEY || !NEW_WALLET || !ENS_LABEL) {
  console.error("Missing required env vars. Copy .env.example → .env and fill in values.");
  process.exit(1);
}

// ─── Constants ───────────────────────────────────────────────────────────────
const BASE_REGISTRAR = "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85";
const ENS_REGISTRY   = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e";

// Builders/relays that accept eth_sendBundle
const BUILDERS = [
  { url: "https://relay.flashbots.net",  sign: true  },
  { url: "https://rpc.beaverbuild.org/", sign: false },
  { url: "https://rpc.titanbuilder.xyz", sign: true  },
];

const BLOCKS = 100; // target this many consecutive blocks (~20 min)

// ─── Setup ───────────────────────────────────────────────────────────────────
const provider    = new ethers.JsonRpcProvider("https://1rpc.io/eth");
const throwaway   = new ethers.Wallet(THROWAWAY_KEY, provider);
const compromised = new ethers.Wallet(COMPROMISED_KEY, provider);

const ensName  = `${ENS_LABEL}.eth`;
const tokenId  = BigInt(ethers.keccak256(ethers.toUtf8Bytes(ENS_LABEL)));
const node     = ethers.namehash(ensName);

const registrarIface = new ethers.Interface([
  "function transferFrom(address from, address to, uint256 tokenId)",
  "function ownerOf(uint256 tokenId) view returns (address)",
]);
const registryIface = new ethers.Interface([
  "function setOwner(bytes32 node, address owner)",
]);

// ─── Helpers ─────────────────────────────────────────────────────────────────
async function getOwner(): Promise<string> {
  const result = await provider.call({
    to: BASE_REGISTRAR,
    data: registrarIface.encodeFunctionData("ownerOf", [tokenId]),
  });
  return registrarIface.decodeFunctionResult("ownerOf", result)[0] as string;
}

async function submitBundle(
  txs: string[],
  targetBlock: number,
  { url, sign }: { url: string; sign: boolean }
): Promise<boolean> {
  const blockHex = "0x" + targetBlock.toString(16);
  const body = JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "eth_sendBundle",
    params: [{ txs, blockNumber: blockHex }],
  });
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (sign) {
    const sig = await throwaway.signMessage(ethers.id(body));
    headers["X-Flashbots-Signature"] = `${throwaway.address}:${sig}`;
  }
  try {
    const res = await fetch(url, { method: "POST", headers, body });
    const json = await res.json() as any;
    return !!json.result?.bundleHash || (!json.error && !!json.id);
  } catch {
    return false;
  }
}

// ─── Simulate ────────────────────────────────────────────────────────────────
async function simulate(txs: string[], block: number): Promise<void> {
  const body = JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "eth_callBundle",
    params: [{ txs, blockNumber: "0x" + block.toString(16), stateBlockNumber: "latest" }],
  });
  const sig = await throwaway.signMessage(ethers.id(body));
  const res = await fetch("https://relay.flashbots.net", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Flashbots-Signature": `${throwaway.address}:${sig}` },
    body,
  });
  const json = await res.json() as any;
  if (json.error) throw new Error(`Simulation failed: ${JSON.stringify(json.error)}`);
  console.log(`  Simulation OK — total gas: ${json.result.totalGasUsed} | gas price: ${ethers.formatUnits(json.result.bundleGasPrice, "gwei")} gwei`);
  for (const r of json.result.results) {
    console.log(`  TX ${r.toAddress}: ${r.gasUsed} gas${r.error ? ` ❌ ${r.error}` : " ✅"}`);
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────
console.log("═══════════════════════════════════════════");
console.log("  ENS Rescue — Flashbots Atomic Bundle");
console.log("═══════════════════════════════════════════");
console.log(`  Name:        ${ensName}`);
console.log(`  Compromised: ${compromised.address}`);
console.log(`  Throwaway:   ${throwaway.address}`);
console.log(`  Destination: ${NEW_WALLET}`);

// Pre-check
const currentOwner = await getOwner();
console.log(`\n  Current owner: ${currentOwner}`);
if (currentOwner.toLowerCase() === NEW_WALLET.toLowerCase()) {
  console.log("  Already transferred! Nothing to do.");
  process.exit(0);
}
if (currentOwner.toLowerCase() !== compromised.address.toLowerCase()) {
  console.error(`  Owner is ${currentOwner}, not the compromised wallet. Cannot rescue.`);
  process.exit(1);
}

const [tBal, cBal, feeData, tNonce, cNonce, block] = await Promise.all([
  provider.getBalance(throwaway.address),
  provider.getBalance(compromised.address),
  provider.getFeeData(),
  provider.getTransactionCount(throwaway.address),
  provider.getTransactionCount(compromised.address),
  provider.getBlockNumber(),
]);

console.log(`  Throwaway balance: ${ethers.formatEther(tBal)} ETH (nonce ${tNonce})`);
console.log(`  Compromised balance: ${ethers.formatEther(cBal)} ETH (nonce ${cNonce})`);

const maxFee  = (feeData.maxFeePerGas  ?? ethers.parseUnits("30", "gwei")) * 5n;
const maxPrio = ethers.parseUnits("10", "gwei");
console.log(`  Fee: ${ethers.formatUnits(maxFee, "gwei")} gwei max | ${ethers.formatUnits(maxPrio, "gwei")} gwei priority`);

if (tBal < ethers.parseEther(FUND_AMOUNT) + maxFee * 21000n) {
  console.error(`  Throwaway wallet needs at least ${FUND_AMOUNT} ETH + gas. Current: ${ethers.formatEther(tBal)} ETH`);
  process.exit(1);
}

// Sign transactions
const tx1 = await throwaway.signTransaction({
  to: compromised.address, value: ethers.parseEther(FUND_AMOUNT),
  nonce: tNonce, gasLimit: 21000n,
  maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPrio,
  chainId: 1, type: 2,
});
const tx2 = await compromised.signTransaction({
  to: BASE_REGISTRAR,
  data: registrarIface.encodeFunctionData("transferFrom", [compromised.address, NEW_WALLET, tokenId]),
  nonce: cNonce, gasLimit: 120000n,
  maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPrio,
  chainId: 1, type: 2,
});
const tx3 = await compromised.signTransaction({
  to: ENS_REGISTRY,
  data: registryIface.encodeFunctionData("setOwner", [node, NEW_WALLET]),
  nonce: cNonce + 1, gasLimit: 60000n,
  maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPrio,
  chainId: 1, type: 2,
});
const txs = [tx1, tx2, tx3];

// Simulate
console.log("\n  Simulating bundle on Flashbots...");
await simulate(txs, block);

// Submit to all builders for BLOCKS consecutive blocks
console.log(`\n  Submitting to ${BUILDERS.length} builders × ${BLOCKS} blocks...`);
const submitted: Record<string, number> = {};
await Promise.all(BUILDERS.map(async (builder) => {
  let ok = 0;
  for (let i = 1; i <= BLOCKS; i++) {
    if (await submitBundle(txs, block + i, builder)) ok++;
  }
  submitted[builder.url] = ok;
}));
for (const [url, ok] of Object.entries(submitted)) {
  console.log(`  ${ok}/${BLOCKS} — ${url}`);
}

// Poll for confirmation
console.log(`\n  Polling for transfer (blocks ${block + 1}–${block + BLOCKS})...\n`);
const deadline = block + BLOCKS;
while (true) {
  const [owner, current] = await Promise.all([getOwner(), provider.getBlockNumber()]);
  const ts = new Date().toISOString().slice(11, 19);
  if (owner.toLowerCase() === NEW_WALLET.toLowerCase()) {
    console.log(`\n  ✅ SUCCESS at block ${current}!`);
    console.log(`  ${ensName} → ${NEW_WALLET}`);
    break;
  }
  console.log(`  [${ts}] block ${current}/${deadline} | owner: ${owner}`);
  if (current > deadline) {
    console.log("\n  ⚠️  Bundle window expired without inclusion. Rerun the script to resubmit.");
    break;
  }
  await new Promise((r) => setTimeout(r, 15000));
}
