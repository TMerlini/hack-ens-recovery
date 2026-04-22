# ENS Recovery from Compromised Wallet

A Flashbots atomic bundle tool to rescue an ENS domain (`.eth`) from a wallet controlled by a sweeper bot — without losing the domain to the attacker.

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

## Real recovery (2026-04-22)

This tool was built and used to recover `dinamic.eth` after the deployer wallet was compromised. The bundle landed on the first attempt after expanding to multiple builders. The sweeper ran at nonce 38 (after the ENS had already transferred at nonces 36–37).

---

**Use responsibly. You need to own the compromised private key to use this.**
