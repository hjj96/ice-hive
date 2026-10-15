#!/usr/bin/env node
// «Ледяной Улей» v2.0 — renders the web game's procedural WebAudio sounds (game/js/09-audio.js) to files.
//
//   node ios-native/tools/render-audio.mjs
//
// Every recipe of sfx() (the names __dbg.sfxAll() plays) runs through the game's own tone() / noiseHit() code in an
// OfflineAudioContext inside headless Chromium; the continuous beds of audioInit() (wind, swarm chitter, rumble,
// flamethrower, cryo hiss, minigun whine) are rendered as seamless loops. Deterministic (seeded noise + Math.random).
// Output: ios-native/App/Resources/Sounds/*.wav (44.1 kHz mono 16-bit, peak-normalised to -1 dBFS) and
//         ios-native/App/Resources/Sounds/sounds-manifest.json (name -> files, loop, base gain, …).
import fs from 'node:fs';
import path from 'node:path';
import { openGamePage, TOOLS, RES, ROOT, b64 } from './lib/gamepage.mjs';

const OUTDIR = path.join(RES, 'Sounds');
const SR = 44100, PEAK = Math.pow(10, -1 / 20);   // -1 dBFS
const VARIANTS = { pulse: 3, mg: 3, squish: 3, kill: 3 };

// ---------------------------------------------------------------- recipe metadata from the game source
const audioSrc = fs.readFileSync(path.join(ROOT, 'game', 'js', '09-audio.js'), 'utf8');
const mainSrc = fs.readFileSync(path.join(ROOT, 'game', 'js', '12-main.js'), 'utf8');
const NAMES = JSON.parse(mainSrc.match(/sfxAll\(\)[\s\S]*?const names = (\[[^\]]*\])/)[1].replace(/'/g, '"'));
const SFX_GAP = Function('return ' + audioSrc.match(/const SFX_GAP = (\{[^}]*\})/)[1])();
// a recipe is distance-attenuated when its case uses the `v` factor (v = clamp(1.1 - d / 34, 0.08, 1))
const CASES = {};
{
  const sw = audioSrc.slice(audioSrc.indexOf('switch (name)'));
  const re = /case '(\w+)':([\s\S]*?)(?=\n\s*case '|\n\s*\}\n\})/g;
  let m;
  while ((m = re.exec(sw))) CASES[m[1]] = m[2];
}
const attenuated = (n) => /\*\s*v\b|\bv\s*\)/.test(CASES[n] || '');

// ---------------------------------------------------------------- helpers
function f32(s) { const b = b64(s); return new Float32Array(b.buffer, b.byteOffset, b.byteLength / 4); }
function peakOf(a) { let p = 0; for (let i = 0; i < a.length; i++) { const v = Math.abs(a[i]); if (v > p) p = v; } return p; }
function trim(a, floor = 1e-4) {
  const p = peakOf(a); let end = a.length;
  while (end > 1 && Math.abs(a[end - 1]) < p * floor) end--;
  const out = a.slice(0, Math.min(a.length, end + Math.round(SR * 0.01)));
  const f = Math.min(out.length, Math.round(SR * 0.005));   // 5 ms tail fade
  for (let i = 0; i < f; i++) out[out.length - 1 - i] *= i / f;
  return out;
}
function wav(samples, gain) {
  const n = samples.length, buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) buf.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(samples[i] * gain * 32767))), 44 + i * 2);
  return buf;
}
const db = (x) => +(20 * Math.log10(Math.max(1e-9, x))).toFixed(2);
// seamless loop: take [warm, warm + L) and cross-fade its head with the audio that follows it (equal power)
function seamless(a, warm, L, X) {
  const w = Math.round(warm * SR), n = Math.round(L * SR), x = Math.round(X * SR), out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = a[w + i];
  for (let i = 0; i < x; i++) {
    const t = i / x, fi = Math.sin(t * Math.PI / 2), fo = Math.cos(t * Math.PI / 2);
    out[i] = a[w + i] * fi + a[w + n + i] * fo;
  }
  return out;
}

// ---------------------------------------------------------------- render
fs.mkdirSync(OUTDIR, { recursive: true });
for (const f of fs.readdirSync(OUTDIR)) if (f.endsWith('.wav')) fs.rmSync(path.join(OUTDIR, f));
const { browser, page } = await openGamePage([path.join(TOOLS, 'lib', 'inpage-audio.js')]);
const manifest = {
  version: 1,
  generator: 'ios-native/tools/render-audio.mjs (game/js/09-audio.js rendered with OfflineAudioContext in headless Chromium)',
  format: 'WAV, 44.1 kHz, mono, 16-bit PCM, each file peak-normalised to -1 dBFS',
  playback: 'volume = baseGain * (distance factor if attenuated) * master. baseGain restores the web level of the recipe (files are normalised). attenuated: v = clamp(1.1 - d / 34, 0.08, 1) with d = distance (m) from the player marine. minInterval: the web SFX_GAP — drop a new play of the same sound inside this window. variants: pick one at random per play.',
  master: { volume: 'default 0.8 (settings cycle 1 / 0.8 / 0.6 / 0.4 / 0.2, mute)', compressor: { thresholdDb: -14, ratio: 6, attack: 0.003, release: 0.25, note: 'the web master bus: DynamicsCompressor after the master gain (use AVAudioUnitEffect kAudioUnitSubType_DynamicsProcessor or a limiter)' } },
  sounds: {},
  loops: {},
};
let total = 0;
const report = [];
for (const name of NAMES) {
  const nv = VARIANTS[name] || 1, files = [];
  let basePeak = 0, dur = 0;
  for (let k = 0; k < nv; k++) {
    let a = f32(await page.evaluate(({ name, k }) => window.__A.oneShot(name, 6, k + 1), { name, k }));
    if (a.some(Number.isNaN)) throw new Error(name + ': NaN samples');
    a = trim(a);
    const p = peakOf(a);
    if (p <= 0) throw new Error(name + ': silent');
    basePeak = Math.max(basePeak, p);
    const file = nv > 1 ? `${name}_${k + 1}.wav` : `${name}.wav`;
    const g = PEAK / p, buf = wav(a, g);
    fs.writeFileSync(path.join(OUTDIR, file), buf);
    total += buf.length; files.push(file); dur = Math.max(dur, a.length / SR);
    report.push(`${file.padEnd(18)} ${(a.length / SR).toFixed(2)} s  web peak ${db(p)} dBFS`);
  }
  manifest.sounds[name] = {
    files, loop: false, baseGain: +(basePeak / PEAK).toFixed(4), webPeakDb: db(basePeak), duration: +dur.toFixed(3),
    attenuated: attenuated(name), ...(SFX_GAP[name] !== undefined ? { minInterval: SFX_GAP[name] } : {}),
    ...(name === 'combo' ? { pitch: 'rate = 1.06 ^ min(24, floor(combo / 5)) (the web recipe raises the base 520 Hz with the combo counter)' } : {}),
  };
}
const LOOPS = {
  wind: { L: 100 / 7, X: 0.6, level: 'constant 0.085 (the cold wind bed, always on while the context runs)' },
  chitter: { L: 2, X: 0.05, level: 'web gain = min(1, bugsNearCamera / 500) * 0.16 (x0.4 on the title screen), smoothed 0.3 s; baseGain is for the maximum' },
  rumble: { L: 2, X: 0.05, level: 'web gain = min(1, bugsNearCamera / 500) * 0.35 (x0.4 on the title screen), smoothed 0.4 s; baseGain is for the maximum' },
  flame: { L: 2, X: 0.05, level: 'pyro firing: 0.3 * clamp(1.1 - d / 30, 0.1, 1) * (player 1 / bot 0.6), smoothed 0.06 s; baseGain is for 0.3' },
  cryo: { L: 2, X: 0.05, level: 'cryo beam on: 0.12 * clamp(1.1 - d / 30, 0.1, 1) * (player 1 / bot 0.6), smoothed 0.06 s; baseGain is for 0.12' },
  spin: { L: 2, X: 0.05, level: 'minigun barrel whine: gain spin² * 0.05 * near (near = clamp(1.1 - d / 30, 0.1, 1) * (player 1 / bot 0.55)); rendered at full spin (330 / 165 Hz): playback rate = (70 + 260 * spin) / 330, smoothed 0.1 s; baseGain is for spin = 1' },
};
for (const [kind, { L, X, level }] of Object.entries(LOOPS)) {
  const warm = 1;
  const a = f32(await page.evaluate(({ kind, dur }) => window.__A.loop(kind, dur, 1), { kind, dur: warm + L + X + 0.1 }));
  const s = seamless(a, warm, L, X), p = peakOf(s);
  const file = `loop_${kind}.wav`, buf = wav(s, PEAK / p);
  fs.writeFileSync(path.join(OUTDIR, file), buf);
  total += buf.length;
  // seam check: the jump from the last sample back to the first vs the typical sample-to-sample step
  let step = 0; for (let i = 1; i < s.length; i++) step += Math.abs(s[i] - s[i - 1]);
  const seam = Math.abs(s[0] - s[s.length - 1]) / (step / (s.length - 1));
  manifest.loops[kind] = { files: [file], loop: true, baseGain: +(p / PEAK).toFixed(4), webPeakDb: db(p), duration: +L.toFixed(4), level };
  report.push(`${file.padEnd(18)} ${L.toFixed(2)} s loop  web peak ${db(p)} dBFS  seam ${seam.toFixed(2)}x avg step`);
}
await browser.close();
fs.writeFileSync(path.join(OUTDIR, 'sounds-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(report.join('\n'));
console.log(`${NAMES.length} sounds + ${Object.keys(LOOPS).length} loops, ${(total / 1048576).toFixed(2)} MB`);
