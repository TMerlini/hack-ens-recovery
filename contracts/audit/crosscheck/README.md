# crosscheck/ — independent reproduction scripts

Backing scripts for [`../CROSS-CHECK.md`](../CROSS-CHECK.md). Two passes, both exit 0 on success.

| file | purpose |
|---|---|
| `pass1_reference_crosscheck.py` | reference cross-check vs `bitcoin/bips`: all upstream vectors through `reference.py`, byte-diff of the 15 wired vectors, anti-drift on the integration receipt |
| `Harness.sol` | exposes the `internal` `BIP340.verify` externally (same call shape as `test/BIP340.t.sol`) |
| `compile.js` | compiles `BIP340` + `BIP340Verifier` + `Harness` with solc-js → `artifacts.json` |
| `run_evm.py` | deploys to py-evm and replays all 14 BIP-340 forge functions (34 assertions) on a real EVM |

## Run

```bash
# Pass 1 — reference cross-check (pulls reference.py + test-vectors.csv from bitcoin/bips)
python3 pass1_reference_crosscheck.py

# Pass 2 — on-EVM reproduction
npm install solc@0.8.28
node compile.js
pip install web3 py-evm eth-tester
python3 run_evm.py
```

`reference.py`, `test-vectors.csv` (fetched by Pass 1) and `artifacts.json` (written by `compile.js`)
are byproducts and can be git-ignored.

Note: Pass 2 uses solc-js + py-evm rather than `forge` so it runs without the Foundry toolchain;
the equivalent canonical path is `forge test --match-path 'test/BIP340*.t.sol'`.
