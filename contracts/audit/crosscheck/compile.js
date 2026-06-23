// Compile BIP340 + BIP340Verifier + Harness with solc-js (no binary download).
// Run from contracts/audit/crosscheck/ after: npm install solc@0.8.28
const fs = require('fs'), path = require('path'), solc = require('solc');
const HERE = __dirname, SRC = path.resolve(HERE, '..', '..', 'src');
const files = {
  'BIP340.sol':           path.join(SRC, 'BIP340.sol'),
  'IReceiptVerifier.sol': path.join(SRC, 'IReceiptVerifier.sol'),
  'BIP340Verifier.sol':   path.join(SRC, 'BIP340Verifier.sol'),
  'Harness.sol':          path.join(HERE, 'Harness.sol'),
};
const sources = {};
for (const [n, p] of Object.entries(files)) sources[n] = { content: fs.readFileSync(p, 'utf8') };
function findImports(p) {
  const base = path.basename(p);
  if (sources[base]) return { contents: sources[base].content };
  for (const dir of [SRC, HERE]) {
    const fp = path.join(dir, base);
    if (fs.existsSync(fp)) return { contents: fs.readFileSync(fp, 'utf8') };
  }
  return { error: 'not found: ' + p };
}
const input = { language: 'Solidity', sources, settings: {
  optimizer: { enabled: true, runs: 200 },
  outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } } } };
const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
const errs = (out.errors || []).filter(e => e.severity === 'error');
if (errs.length) { errs.forEach(e => console.error(e.formattedMessage)); process.exit(1); }
const art = {};
for (const f of Object.keys(out.contracts))
  for (const c of Object.keys(out.contracts[f]))
    art[c] = { abi: out.contracts[f][c].abi, bytecode: out.contracts[f][c].evm.bytecode.object };
fs.writeFileSync(path.join(HERE, 'artifacts.json'), JSON.stringify(art));
console.log('compiled (solc ' + solc.version() + '):', Object.keys(art).join(', '));
