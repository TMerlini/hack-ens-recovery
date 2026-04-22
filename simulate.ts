/**
 * Dry-run simulation only — no transactions submitted.
 * Useful to verify the bundle will succeed before running rescue.ts.
 */

import { ethers } from "ethers";

const COMPROMISED_KEY = process.env.COMPROMISED_KEY ?? "";
const THROWAWAY_KEY   = process.env.THROWAWAY_KEY   ?? "";
const NEW_WALLET      = process.env.NEW_WALLET       ?? "";
const ENS_LABEL       = process.env.ENS_LABEL        ?? "";
const FUND_AMOUNT     = process.env.FUND_AMOUNT      ?? "0.006";

if (!COMPROMISED_KEY || !THROWAWAY_KEY || !NEW_WALLET || !ENS_LABEL) {
  console.error("Missing required env vars.");
  process.exit(1);
}

const BASE_REGISTRAR = "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85";
const ENS_REGISTRY   = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e";

const provider    = new ethers.JsonRpcProvider("https://1rpc.io/eth");
const throwaway   = new ethers.Wallet(THROWAWAY_KEY, provider);
const compromised = new ethers.Wallet(COMPROMISED_KEY, provider);

const tokenId = BigInt(ethers.keccak256(ethers.toUtf8Bytes(ENS_LABEL)));
const node    = ethers.namehash(`${ENS_LABEL}.eth`);

const feeData = await provider.getFeeData();
const maxFee  = (feeData.maxFeePerGas ?? ethers.parseUnits("30", "gwei")) * 5n;
const maxPrio = ethers.parseUnits("10", "gwei");

const [tNonce, cNonce, block] = await Promise.all([
  provider.getTransactionCount(throwaway.address),
  provider.getTransactionCount(compromised.address),
  provider.getBlockNumber(),
]);

const tx1 = await throwaway.signTransaction({
  to: compromised.address, value: ethers.parseEther(FUND_AMOUNT),
  nonce: tNonce, gasLimit: 21000n,
  maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPrio, chainId: 1, type: 2,
});
const tx2 = await compromised.signTransaction({
  to: BASE_REGISTRAR,
  data: new ethers.Interface(["function transferFrom(address,address,uint256)"])
    .encodeFunctionData("transferFrom", [compromised.address, NEW_WALLET, tokenId]),
  nonce: cNonce, gasLimit: 120000n,
  maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPrio, chainId: 1, type: 2,
});
const tx3 = await compromised.signTransaction({
  to: ENS_REGISTRY,
  data: new ethers.Interface(["function setOwner(bytes32,address)"])
    .encodeFunctionData("setOwner", [node, NEW_WALLET]),
  nonce: cNonce + 1, gasLimit: 60000n,
  maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPrio, chainId: 1, type: 2,
});

const body = JSON.stringify({
  jsonrpc: "2.0", id: 1, method: "eth_callBundle",
  params: [{ txs: [tx1, tx2, tx3], blockNumber: "0x" + block.toString(16), stateBlockNumber: "latest" }],
});
const sig = await throwaway.signMessage(ethers.id(body));
const res = await fetch("https://relay.flashbots.net", {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Flashbots-Signature": `${throwaway.address}:${sig}` },
  body,
});
const json = await res.json() as any;

if (json.error) {
  console.error("Simulation FAILED:", JSON.stringify(json.error, null, 2));
  process.exit(1);
}

console.log(`Simulation OK — block ${block}`);
console.log(`Total gas: ${json.result.totalGasUsed} | Gas price: ${ethers.formatUnits(json.result.bundleGasPrice, "gwei")} gwei`);
for (const r of json.result.results) {
  const status = r.error ? `❌ ${r.error}` : "✅";
  console.log(`  → ${r.toAddress}: ${r.gasUsed} gas ${status}`);
}
