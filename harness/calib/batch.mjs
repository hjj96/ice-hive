// Runs calibration missions (harness/calib/run.mjs) in parallel and appends their '[R]' lines to a JSONL file.
//   node harness/calib/batch.mjs <configs.json> <out.jsonl> [parallel=2]
//   node harness/calib/batch.mjs --tiers 0,1,2 --n 4 [--mode auto] [--maxs 600] [--th '{"trickle":1.25}'] [--tag t]
//                                [--classes assault,pyro,cryo,gunner] [--par 2] [--file dist/v11-a-calib.html] --out out.jsonl
// A config is { tag, cls, tier, mode, maxs, th, q, seed }. --n = runs per class and tier.
// The box is shared: keep parallel ≤ 2 (each run is one headless Chromium).
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const argv = process.argv.slice(2);
const flags = {}, pos = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) { const k = argv[i].slice(2); flags[k] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true; }
  else pos.push(argv[i]);
}
let cfgs, outPath, par;
if (pos.length >= 2) {
  cfgs = JSON.parse(fs.readFileSync(pos[0], 'utf8')); outPath = pos[1]; par = +(pos[2] || 2);
} else {
  if (!flags.out) { console.error('usage: batch.mjs <configs.json> <out.jsonl> [par] | --tiers 0,1,2 --n 4 --out out.jsonl'); process.exit(2); }
  outPath = flags.out; par = +(flags.par || 2);
  const tiers = String(flags.tiers ?? '1').split(',').map(Number);
  const classes = String(flags.classes || 'assault,pyro,cryo,gunner').split(',');
  const n = +(flags.n || 1);
  cfgs = [];
  for (let r = 0; r < n; r++) for (const tier of tiers) for (const cls of classes) {
    cfgs.push({ tag: flags.tag ? flags.tag + '-' + ['rec', 'vet', 'nm'][tier] : undefined, cls, tier, mode: flags.mode || 'auto', maxs: flags.maxs ? +flags.maxs : undefined, th: flags.th ? JSON.parse(flags.th) : undefined, seed: flags.seed != null ? +flags.seed : undefined });
  }
}
const FILE = flags.file || process.env.CALIB || 'dist/v11-a-calib.html';
if (!fs.existsSync(path.resolve(ROOT, FILE))) { console.error('[batch] no ' + FILE + ' — build it with harness/calib/mkcalib.mjs'); process.exit(2); }
let next = 0, running = 0;
const t0 = Date.now();
function runOne(c) {
  return new Promise((res) => {
    const args = ['harness/run.mjs', '--file', FILE, '--scenario', 'harness/calib/run.mjs', '--width', '320', '--height', '180',
      '--out', 'harness/out/calib/x', '--cls', c.cls || 'assault', '--tier', String(c.tier ?? 1), '--mode', c.mode || 'auto', '--q', c.q || 'med'];
    if (c.maxs) args.push('--maxs', String(c.maxs));
    if (c.tag) args.push('--tag', c.tag);
    if (c.seed != null) args.push('--seed', String(c.seed));
    if (c.th && Object.keys(c.th).length) args.push('--th', JSON.stringify(c.th));
    const p = spawn('timeout', ['900', 'node', ...args], { cwd: ROOT });
    let buf = '';
    p.stdout.on('data', (d) => (buf += d)); p.stderr.on('data', (d) => (buf += d));
    p.on('close', () => {
      const lines = buf.split('\n').filter((l) => l.startsWith('[R]'));
      if (!lines.length) fs.appendFileSync(outPath, JSON.stringify({ tag: c.tag, cls: c.cls, tierIx: c.tier, mode: c.mode, error: buf.slice(-600) }) + '\n');
      for (const l of lines) fs.appendFileSync(outPath, l.slice(4) + '\n');
      res();
    });
  });
}
await new Promise((done) => {
  const pump = () => {
    if (next >= cfgs.length && running === 0) return done();
    while (running < par && next < cfgs.length) {
      const c = cfgs[next++]; running++;
      runOne(c).then(() => { running--; process.stdout.write('.'); pump(); });
    }
  };
  pump();
});
console.log('\n[batch] done', cfgs.length, 'runs in', Math.round((Date.now() - t0) / 1000), 's ->', outPath);
