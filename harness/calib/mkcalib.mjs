// Calibration build (dev only, never shipped): copies a built artifact and exposes the game internals as
// window.__int, plus a switch that turns drawing off (window.__noDraw = true) so balance runs only simulate.
//   node scripts/build-artifact.mjs --out dist/v11-a.html && node harness/calib/mkcalib.mjs dist/v11-a.html dist/v11-a-calib.html
// The live game is untouched: this only appends to a copy, right before the module's closing </script>.
import fs from 'node:fs';
import path from 'node:path';

const [inArg, outArg] = process.argv.slice(2);
if (!inArg || !outArg) { console.error('usage: node harness/calib/mkcalib.mjs <built.html> <out-calib.html>'); process.exit(2); }
let src = fs.readFileSync(path.resolve(inArg), 'utf8');
// measurement hooks (calibration copy only): damage taken and downs by source (bug type 0..3, 4 = Матка, -1 = other)
function rep(a, b) { const n = src.split(a).length - 1; if (n !== 1) { console.error('[mkcalib] anchor x' + n + ': ' + a.slice(0, 80)); process.exit(1); } src = src.replace(a, b); }
rep('  if (m.isPlayer) GS.lastHit = src;\n', '  if (m.isPlayer) GS.lastHit = src;\n  m.lastSrc = src; if (window.__hurt) window.__hurt[src + 1] += dmg;\n');
rep('  if (m.isPlayer) { GS.downs++; GS.downBy = GS.lastHit; }\n', '  if (m.isPlayer) { GS.downs++; GS.downBy = GS.lastHit; }\n  if (window.__downBy) window.__downBy[(m.lastSrc ?? -1) + 1]++;\n');
const end = src.lastIndexOf('</script>');
if (end < 0 || !src.includes('window.__dbg = {')) { console.error('[mkcalib] not a built game artifact: ' + inArg); process.exit(1); }
const inj = `
// ---- calibration hooks (harness/calib/mkcalib.mjs) ----
window.__int = {
  M, B, DIR, GS, LV, BT, DIFF, CLASSES, UPG, QSTATE, IN, TUR, typeAlive, crowd,
  tick, rollUpgrades, applyUpgrade, queryCircle, spawnBug, killBug, hitBug, hurtMarine, startHorde, queueBoom, processBooms, rebuildHash, BOOMS, showScreen, setTier,
  onLift, standingIn, nextBeacon, capLeft, hordeScale, threatState, updateThreatHUD, objectiveProgress, objectiveText,
  get TH() { return TH; }, get simCap() { return simCap; }, get simTime() { return simTime; },
  get autoPlayer() { return autoPlayer; }, set autoPlayer(v) { autoPlayer = v; },
  get godMode() { return godMode; }, set godMode(v) { godMode = v; },
};
{ const r0 = renderer.render.bind(renderer); renderer.render = function (s, c) { if (window.__noDraw) return; return r0(s, c); }; }
`;
const out = src.slice(0, end) + inj + src.slice(end);
fs.mkdirSync(path.dirname(path.resolve(outArg)), { recursive: true });
fs.writeFileSync(path.resolve(outArg), out);
console.log('[mkcalib] wrote', outArg, Buffer.byteLength(out), 'bytes');
