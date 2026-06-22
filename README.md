# ENS Recovery from Compromised Wallet

A Flashbots atomic bundle tool to rescue an ENS domain (`.eth`) from a wallet controlled by a sweeper bot — without losing the domain to the attacker.

> **Recompute / verify (one rule):** every rescue emits a WYRIWE receipt (kind `30078`) binding the rescue to its owner-specified destination. Anyone can re-derive the binding from public data — `bun run recompute.ts <job_id> <target_wallet> <output_address> <ens_label> [artifact_hash]` — and verify the full receipt via [@onchain-ai/agent-sdk] / invinoveritas `/verify-proof`. The claim is checkable without trusting the agent or us. See [Verifiable receipt](#verifiable-receipt-wyriwe).

## The Attack

A **sweeper bot** is malware that monitors a compromised wallet's incoming transactions. The moment any ETH lands in the wallet, it instantly submits a sweep transaction with a high gas price, draining the ETH before you can do anything with it.

This makes normal recovery impossible: you can't fund the wallet to pay gas for the ENS transfer, because the funds get swept before your transfer tx executes.

## The Solution: Flashbots Atomic Bundle

[Flashbots](https://docs.flashbots.net/flashbots-auction/overview) lets you submit a **bundle** of transactions that are guaranteed to execute atomically in the same block, in order, or not at all. The bundle bypasses the public mempool entirely — the sweeper bot never sees it.

**Bundle structure:**

```
TX1  [throwaway wallet]   → fund compromised wallet (gas money)
TX2  [compromised wallet] → BaseRegistrar.transferFrom(compromised, newWallet, tokenId)
TX3  [compromised wallet] → ENSRegistry.setOwner(namehash, newWallet)
```

All three execute in one block. The sweeper can only react in the next block — by then the ENS is already in your new wallet.

## Requirements

- [Bun](https://bun.sh) (or Node.js with ethers v6)
- A **throwaway wallet** with ~0.01 ETH (for gas funding + fees). This wallet signs the Flashbots bundle header — it does not need to be your main wallet.
- The **private key** of the compromised wallet
- A **new safe wallet** address (destination)

## Setup

```bash
bun install
cp .env.example .env
# Fill in your values
```

## Configuration

Edit `.env`:

```
COMPROMISED_KEY=0x...       # private key of the hacked wallet
THROWAWAY_KEY=0x...         # private key of a fresh throwaway wallet (fund it with ~0.01 ETH first)
NEW_WALLET=0x...            # destination address (your safe wallet)
ENS_LABEL=yourname          # just the label, e.g. "dinamic" for dinamic.eth
FUND_AMOUNT=0.006           # ETH to send from throwaway → compromised (covers gas for TX2+TX3)
```

## Run

```bash
bun run rescue.ts
```

The script will:
1. Simulate the bundle on Flashbots — confirms all 3 TXs will succeed before submitting
2. Submit to **Flashbots relay**, **beaverbuild**, and **Titan builder** for 100 consecutive blocks (~20 min)
3. Poll every 15s and exit as soon as the transfer confirms

## How it works in detail

### ENS has two ownership layers

| Layer | Contract | What it controls |
|---|---|---|
| Registrant | `BaseRegistrar` (ERC-721) | Who owns the registration (renewal, transfer) |
| Controller | `ENS Registry` | Who can set records (resolver, TTL, subdomains) |

TX2 transfers the BaseRegistrar NFT. TX3 updates the Registry controller. Both must happen or the recovery is incomplete.

### Why the sweeper can't react

The bundle is submitted privately to block builders. It never appears in the public mempool. The sweeper only sees the ETH arrive at the compromised wallet at the moment TX1 is confirmed — which is the same block TX2 and TX3 also confirm. There's no gap to exploit.

### Why we submit to multiple builders

No single relay/builder builds 100% of Ethereum blocks. By submitting to Flashbots (covers beaverbuild, ~40% of blocks) and Titan (~20%), the bundle reaches 60%+ of block builders. With 100 target blocks, the statistical probability of not landing is negligible.

## Contract addresses (Ethereum mainnet)

| Contract | Address |
|---|---|
| BaseRegistrar | `0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85` |
| ENS Registry | `0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e` |
| NameWrapper | `0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401` |

> **Note:** This tool works for **unwrapped** ENS names (BaseRegistrar owner = your wallet). If your name is wrapped in NameWrapper, the NFT owner is the NameWrapper contract — use a different approach.

## After the ENS transfer — don't stop there

If the compromised wallet was also the **owner of your resolver contract**, you need a second bundle to fix it. The `setSigner()` and `transferOwnership()` functions on the resolver can only be called by the contract owner — same sweeper problem.

**Second bundle (resolver fix):**

```
TX1  [throwaway wallet]   → fund compromised wallet
TX2  [compromised wallet] → OffchainResolver.setSigner(newGatewaySigningKey)
TX3  [compromised wallet] → OffchainResolver.transferOwnership(newSafeWallet)
```

Same throwaway, same approach. Budget another ~0.005 ETH on the throwaway. Then update your gateway's `GATEWAY_PRIVATE_KEY` and `ADMIN_WALLETS` env vars to the new keys.

## Real incident (2026-04-22)

`dinamic.eth` was running on a custom CCIP Read stack ([ens-dynamic-kit](https://github.com/Echo-Merlini/ens-dynamic-kit)). The deployer wallet was used as both the ENS name owner, the resolver contract owner, and the gateway signing key — a single key controlling everything. When it was compromised by a sweeper bot, the attacker had full access to all three layers.

**Timeline:**

1. Wallet compromise discovered — MetaMask sending ETH to an unknown address (actually just a normal gas fee, but triggered the investigation)
2. Confirmed sweeper: any ETH sent to the wallet was drained within seconds
3. Flashbots bundle built and submitted for 15 blocks → no inclusion (Flashbots alone covers ~40% of blocks)
4. Resubmitted for 50 blocks → still no inclusion
5. Expanded to Flashbots + beaverbuild + Titan for 100 blocks → **landed, ENS transferred**
6. Sweeper ran at compromised wallet nonce 38 — the ENS was already gone (transferred at nonces 36–37, sweeper got nothing useful)
7. Second Flashbots bundle: `setSigner` + `transferOwnership` on resolver contract → landed in seconds on first attempt
8. Gateway restarted with new isolated signing key, `ADMIN_WALLETS` updated, done

**Root causes found during recovery:**

- Gateway signing key = deployer wallet (single key controlling everything — never do this)
- CIDv1 contenthash encoding bug in the gateway: `0xe5 0x01` + UTF-8 text instead of `0xe3 0x01` + raw binary CID bytes — caused eth.limo to 500 before the incident was even noticed
- DB persistence on Coolify image-based deployments: every redeploy wipes SQLite — requires manual `docker cp` backup/restore

**What the sweeper got:** Nothing of value. The ENS name, resolver ownership, and all records were recovered. The compromised wallet itself is now empty and abandoned.

## Verifiable receipt (WYRIWE)

Every run emits a **WYRIWE receipt** (Nostr kind `30078`) so the rescue is *provable*, not just claimed — and **owner-bound by construction**.

**Commit-before-outcome.** Before the bundle is broadcast, `rescue.ts` commits an `artifact_hash`:

    artifact_hash = H(job_id, target_wallet, output_address, asset_set)

Because `output_address` is inside the hash, the receipt is **non-portable** — it can only describe *this* rescue, to *this* destination. The settled transfer tx is attached afterward as `result_ref`, kept **out** of the preimage (preserving the commit-before-outcome ordering). `job_id` salts it so identical rescues stay distinct.

**The commit is the event — no central endpoint.** The kind-30078 event *is* the commitment; `agent-sdk`'s zero-dep scripts publish it to Nostr relays + OTS-anchor it (Bitcoin PoW precedence). Nothing routes through any service. It's read back via the mirrors `GET /ledger/{entry}/commitment` and `/ledger/{entry}/outcome` (so `verifyFullFlow()` and the ledger agree).

**Anyone can verify, trusting no one:**
- `bun run recompute.ts <job_id> <target_wallet> <output_address> <ens_label> [artifact_hash]` re-derives the binding from public data, offline.
- Full validity (signature, invinoveritas issuance, Bitcoin-OTS precedence) via invinoveritas `/verify-proof` + [@onchain-ai/agent-sdk](https://github.com/onchain-ai)'s `verifyFullFlow()`.

**Escrow gate (for the paid a2a service) — never `valid` alone:** release on `valid === true` **AND** `checks.artifact_hash_matches === true` **AND** on-chain delivery (the asset actually landed at `output_address`); the escrow nullifies the `artifact_hash` on release so a receipt can't be replayed.

Reference flow + locked spec: https://gist.github.com/TMerlini/98b7dbeb221024b617b36c7e3b79e695

---

**Use responsibly. You need to own the compromised private key to use this.**
