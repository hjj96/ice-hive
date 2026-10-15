// ================================================================
//  AUDIO — procedural WebAudio, started on the first user gesture
// ================================================================
const AU = { ctx: null, master: null, muted: !!store.get('muted', false), vol: clamp(+store.get('vol', 0.8) || 0.8, 0.1, 1), noise: null, last: Object.create(null), loops: {} };
const SFX_GAP = { thud: 0.12, kill: 0.05, combo: 0.2, shock: 0.3, pulse: 0.045, mg: 0.04, tur: 0.06, squish: 0.035, shatter: 0.05, freeze: 0.08, hurt: 0.22, explode: 0.06, pop: 0.05, acid: 0.1, spit: 0.08, roar: 0.25, swell: 0.15, reload: 0.3, overheat: 0.5 };

function audioResume() {
  // WebKit also leaves contexts 'interrupted' after calls, Siri or app switches: resume anything not running
  if (!AU.ctx || AU.ctx.state === 'running' || document.hidden) return;
  try { const p = AU.ctx.resume(); if (p && p.catch) p.catch(() => {}); } catch (e) { /* resume refused until the next gesture */ }
}
// hidden tab / app in background: the rAF loop (and audioUpdate) stops, so silence the loops and park the context
function audioSuspend() {
  if (!AU.ctx || AU.ctx.state !== 'running') return;
  const t = AU.ctx.currentTime;
  for (const k of ['flame', 'cryo', 'spin', 'chitter', 'rumble']) { const g = AU.loops[k]; if (g) { g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(0, t); } }
  try { const p = AU.ctx.suspend(); if (p && p.catch) p.catch(() => {}); } catch (e) { /* already closed */ }
}
function audioInit() {
  if (AU.ctx) { audioResume(); return; }
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return;
  let ctx;
  try { ctx = new AC(); } catch (e) { return; }
  AU.ctx = ctx;
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = -14; comp.ratio.value = 6; comp.attack.value = 0.003; comp.release.value = 0.25;
  AU.master = ctx.createGain(); AU.master.gain.value = AU.muted ? 0 : AU.vol;
  AU.master.connect(comp); comp.connect(ctx.destination);
  const len = ctx.sampleRate * 2, buf = ctx.createBuffer(1, len, ctx.sampleRate), d = buf.getChannelData(0);
  for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
  AU.noise = buf;
  // cold wind bed
  {
    const src = loopNoise(), lp = ctx.createBiquadFilter(), g = ctx.createGain(), lfo = ctx.createOscillator(), lg = ctx.createGain();
    lp.type = 'lowpass'; lp.frequency.value = 420; lp.Q.value = 0.8;
    lfo.frequency.value = 0.07; lg.gain.value = 260; lfo.connect(lg); lg.connect(lp.frequency); lfo.start();
    g.gain.value = 0.085; src.connect(lp); lp.connect(g); g.connect(AU.master);
  }
  // swarm chitter swell (level follows swarm size near the camera)
  {
    const src = loopNoise(), bp = ctx.createBiquadFilter(), am = ctx.createGain(), amO = ctx.createOscillator(), amG = ctx.createGain(), g = ctx.createGain();
    bp.type = 'bandpass'; bp.frequency.value = 2500; bp.Q.value = 2.5;
    am.gain.value = 0.55; amO.type = 'square'; amO.frequency.value = 27; amG.gain.value = 0.45; amO.connect(amG); amG.connect(am.gain); amO.start();
    g.gain.value = 0; src.connect(bp); bp.connect(am); am.connect(g); g.connect(AU.master);
    const src2 = loopNoise(), lp2 = ctx.createBiquadFilter(), g2 = ctx.createGain();
    lp2.type = 'lowpass'; lp2.frequency.value = 180; g2.gain.value = 0; src2.connect(lp2); lp2.connect(g2); g2.connect(AU.master);
    AU.loops.chitter = g; AU.loops.rumble = g2;
  }
  // flamethrower roar
  {
    const src = loopNoise(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
    lp.type = 'lowpass'; lp.frequency.value = 1100; lp.Q.value = 1.2; g.gain.value = 0;
    src.connect(lp); lp.connect(g); g.connect(AU.master); AU.loops.flame = g;
  }
  // minigun barrel whine (pitch follows spin)
  {
    const o = ctx.createOscillator(), o2 = ctx.createOscillator(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = 'sawtooth'; o.frequency.value = 90; o2.type = 'square'; o2.frequency.value = 45;
    f.type = 'bandpass'; f.frequency.value = 900; f.Q.value = 1.4; g.gain.value = 0;
    o.connect(f); o2.connect(f); f.connect(g); g.connect(AU.master); o.start(); o2.start();
    AU.loops.spin = g; AU.loops.spinO = o; AU.loops.spinO2 = o2;
  }
  // cryo hiss + shimmer
  {
    const src = loopNoise(), bp = ctx.createBiquadFilter(), g = ctx.createGain(), o = ctx.createOscillator(), og = ctx.createGain(), v = ctx.createOscillator(), vg = ctx.createGain();
    bp.type = 'bandpass'; bp.frequency.value = 4200; bp.Q.value = 0.8;
    o.type = 'sine'; o.frequency.value = 1350; v.frequency.value = 7; vg.gain.value = 40; v.connect(vg); vg.connect(o.frequency); o.start(); v.start();
    og.gain.value = 0.18; o.connect(og); og.connect(g);
    g.gain.value = 0; src.connect(bp); bp.connect(g); g.connect(AU.master); AU.loops.cryo = g;
  }
}
function loopNoise() {
  const s = AU.ctx.createBufferSource(); s.buffer = AU.noise; s.loop = true;
  s.start(0, Math.random() * 1.5);
  return s;
}
function setMuted(m) {
  AU.muted = m; store.set('muted', m);
  if (AU.master) AU.master.gain.setTargetAtTime(m ? 0 : AU.vol, AU.ctx.currentTime, 0.05);
}
// master volume: cycles 100 → 80 → 60 → 40 → 20 % (remembered)
function cycleVolume() {
  const steps = [1, 0.8, 0.6, 0.4, 0.2];
  let k = steps.findIndex(v => Math.abs(v - AU.vol) < 0.05);
  AU.vol = steps[(k + 1) % steps.length];
  store.set('vol', AU.vol);
  if (AU.master && !AU.muted) AU.master.gain.setTargetAtTime(AU.vol, AU.ctx.currentTime, 0.05);
  return AU.vol;
}
function tone(type, f0, f1, dur, vol, at = 0, filt = 0) {
  const c = AU.ctx, t = c.currentTime + at, o = c.createOscillator(), g = c.createGain();
  o.type = type; o.frequency.setValueAtTime(f0, t); if (f1 !== f0) o.frequency.exponentialRampToValueAtTime(Math.max(20, f1), t + dur);
  g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(Math.max(0.0002, vol), t + Math.min(0.01, dur * 0.2)); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  let node = o;
  if (filt) { const f = c.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = filt; o.connect(f); node = f; }
  node.connect(g); g.connect(AU.master);
  o.start(t); o.stop(t + dur + 0.02);
}
function noiseHit(ftype, f0, f1, q, dur, vol, at = 0) {
  const c = AU.ctx, t = c.currentTime + at, s = c.createBufferSource(), f = c.createBiquadFilter(), g = c.createGain();
  s.buffer = AU.noise; f.type = ftype; f.Q.value = q;
  f.frequency.setValueAtTime(f0, t); if (f1 !== f0) f.frequency.exponentialRampToValueAtTime(Math.max(30, f1), t + dur);
  g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(Math.max(0.0002, vol), t + Math.min(0.008, dur * 0.2)); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  s.connect(f); f.connect(g); g.connect(AU.master);
  s.start(t, Math.random() * 1.5); s.stop(t + dur + 0.02);
}
function sfx(name, x, z, loud) {
  if (!AU.ctx || AU.muted || simOnly) return;
  const now = AU.ctx.currentTime;
  const gap = SFX_GAP[name];
  if (gap !== undefined) { if (now - (AU.last[name] || 0) < gap) return; AU.last[name] = now; }
  let v = 1;
  if (x !== undefined && M[0]) { const d = Math.hypot(x - M[0].x, z - M[0].z); v = clamp(1.1 - d / 34, 0.08, 1); }
  if (loud === false) v *= 0.5;
  switch (name) {
    case 'pulse': tone('square', 1300, 240, 0.08, 0.07 * v); noiseHit('highpass', 3200, 3200, 0.7, 0.04, 0.06 * v); break;
    case 'mg': noiseHit('bandpass', 1900, 800, 1.1, 0.05, 0.13 * v); tone('triangle', 170, 60, 0.05, 0.1 * v); break;
    case 'tur': tone('square', 1500, 480, 0.04, 0.035 * v); break;
    case 'reload': tone('square', 620, 620, 0.03, 0.05 * v); tone('square', 900, 900, 0.03, 0.05 * v, 0.16); break;
    case 'overheat': noiseHit('highpass', 5000, 2200, 0.6, 0.6, 0.1 * v); tone('sine', 900, 280, 0.4, 0.05 * v); break;
    case 'explode': noiseHit('lowpass', 1700, 90, 0.8, 1.1, 0.6 * v); tone('sine', 95, 32, 0.6, 0.55 * v); noiseHit('highpass', 3000, 1200, 0.7, 0.18, 0.12 * v); tone('sine', 48, 28, 0.9, 0.3 * v, 0.02); break;
    case 'pop': noiseHit('lowpass', 2200, 300, 0.8, 0.3, 0.22 * v); tone('sine', 150, 50, 0.2, 0.2 * v); break;
    case 'squish': noiseHit('bandpass', 700 + Math.random() * 700, 260, 2, 0.08, 0.09 * v); break;
    case 'shatter': noiseHit('highpass', 6000, 3200, 0.8, 0.15, 0.13 * v); tone('sine', 2600, 2300, 0.18, 0.04 * v); tone('sine', 3500, 3300, 0.12, 0.03 * v); break;
    case 'freeze': tone('sine', 1800, 2500, 0.12, 0.035 * v); break;
    case 'hurt': tone('sawtooth', 190, 70, 0.18, 0.12, 0, 900); noiseHit('lowpass', 900, 200, 1, 0.12, 0.16); break;
    case 'down': tone('sawtooth', 320, 70, 0.8, 0.14 * v, 0, 1200); break;
    case 'revive': [523, 659, 784].forEach((f, k) => tone('sine', f, f, 0.16, 0.1 * v, k * 0.08)); break;
    case 'dash': noiseHit('bandpass', 700, 3200, 1.6, 0.22, 0.15 * v); break;
    case 'throw': noiseHit('bandpass', 1300, 400, 2, 0.2, 0.08 * v); tone('square', 1200, 1200, 0.03, 0.03 * v); break;
    case 'napalm': noiseHit('lowpass', 1000, 180, 0.7, 1.0, 0.5 * v); tone('sine', 72, 38, 0.7, 0.4 * v); break;
    case 'shock': tone('sawtooth', 90, 900, 0.25, 0.12 * v, 0, 2400); noiseHit('bandpass', 3000, 900, 1.2, 0.35, 0.16 * v); tone('sine', 60, 40, 0.4, 0.2 * v); break;
    case 'thud': noiseHit('lowpass', 600, 80, 0.9, 0.5, 0.35 * v); tone('sine', 70, 30, 0.45, 0.4 * v); noiseHit('bandpass', 900, 300, 2, 0.25, 0.14 * v, 0.03); break;
    case 'kill': noiseHit('bandpass', 1400 + Math.random() * 900, 500, 2.5, 0.06, 0.07); tone('square', 2100, 1500, 0.035, 0.018); break;
    case 'combo': { const f = 520 * Math.pow(1.06, Math.min(24, (GS.combo / 5) | 0)); tone('triangle', f, f * 1.5, 0.12, 0.06); tone('sine', f * 2, f * 2, 0.1, 0.03, 0.06); break; }
    case 'hordeRoar': noiseHit('lowpass', 260, 900, 0.6, 2.2, 0.3); noiseHit('bandpass', 1800, 3600, 3, 2.0, 0.08, 0.2); tone('sawtooth', 55, 80, 2.0, 0.08, 0, 300); break;
    case 'nova': noiseHit('highpass', 2800, 8000, 0.7, 0.8, 0.25 * v); tone('sine', 2300, 280, 0.7, 0.12 * v); break;
    case 'turret': tone('square', 380, 900, 0.15, 0.06 * v); tone('square', 900, 900, 0.05, 0.05 * v, 0.18); break;
    case 'heal': tone('sine', 660, 990, 0.25, 0.1 * v); break;
    case 'spit': noiseHit('bandpass', 500, 1500, 3, 0.15, 0.1 * v); tone('sine', 300, 620, 0.12, 0.05 * v); break;
    case 'acid': noiseHit('highpass', 2500, 5200, 0.7, 0.5, 0.07 * v); break;
    case 'roar': tone('sawtooth', 75, 42, 0.8, 0.2 * v, 0, 420); noiseHit('lowpass', 520, 180, 1, 0.8, 0.15 * v); break;
    case 'swell': tone('sine', 120, 400, 0.75, 0.12 * v); break;
    case 'siren': {
      const c = AU.ctx, t = c.currentTime, g = c.createGain(), f = c.createBiquadFilter();
      f.type = 'lowpass'; f.frequency.value = 1700;
      g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.16, t + 0.2); g.gain.setValueAtTime(0.16, t + 3.0); g.gain.exponentialRampToValueAtTime(0.0001, t + 3.6);
      for (const det of [0, 7]) {
        const o = c.createOscillator(); o.type = 'sawtooth';
        o.frequency.setValueAtTime(470 + det, t);
        for (let k = 1; k <= 6; k++) o.frequency.linearRampToValueAtTime((k % 2 ? 760 : 470) + det, t + k * 0.6);
        o.connect(f); o.start(t); o.stop(t + 3.7);
      }
      f.connect(g); g.connect(AU.master);
      break;
    }
    case 'beacon': tone('sawtooth', 110, 760, 1.2, 0.07, 0, 1500); tone('square', 220, 220, 0.25, 0.05, 0.05); tone('square', 330, 330, 0.25, 0.05, 0.35); break;
    case 'beaconDone': [440, 554, 659, 880].forEach((f, k) => tone('triangle', f, f, 1.3, 0.07, k * 0.05)); break;
    case 'lift': tone('sawtooth', 48, 130, 4.4, 0.22, 0, 320); noiseHit('lowpass', 300, 600, 0.8, 4.4, 0.25); break;
    case 'levelup': [523, 659, 784, 1046].forEach((f, k) => tone('square', f, f, 0.12, 0.05, k * 0.07)); break;
    case 'click': tone('square', 1800, 1800, 0.025, 0.035); break;
    case 'heart': tone('sine', 64, 44, 0.13, 0.32); tone('sine', 58, 40, 0.15, 0.22, 0.17); break;
    case 'victory': [[523, 659, 784], [587, 740, 880], [659, 830, 988]].forEach((ch, k) => ch.forEach(f => tone('triangle', f, f, 0.9, 0.06, k * 0.35))); break;
    case 'defeat': tone('sawtooth', 220, 55, 2.2, 0.16, 0, 700); tone('sawtooth', 165, 41, 2.4, 0.12, 0.1, 600); break;
  }
}
let audT = 0, heartT = 0;
function loopLevel(idx, P, k) {
  const m = idx >= 0 ? M[idx] : null;
  if (!m || !m.firing || m.downed) return 0;
  return k * clamp(1.1 - Math.hypot(m.x - P.x, m.z - P.z) / 30, 0.1, 1) * (m.isPlayer ? 1 : 0.6);
}
function audioUpdate(dt) {
  if (!AU.ctx) return;
  audT -= dt;
  if (audT > 0) return;
  audT = 0.1;
  const t = AU.ctx.currentTime, P = M[0];
  const live = GS.screen === 'playing' || GS.screen === 'title';
  AU.loops.flame.gain.setTargetAtTime(live ? loopLevel(pyroIdx, P, 0.3) : 0, t, 0.06);
  AU.loops.cryo.gain.setTargetAtTime(live ? loopLevel(cryoIdx, P, 0.12) : 0, t, 0.06);
  // minigun whine follows the barrel spin of the gunner (player or bot)
  const gi = M.findIndex(m => m.cls === 'gunner'), gm = gi >= 0 ? M[gi] : null;
  const spin = live && gm && !gm.downed ? gm.spin : 0;
  const near = gm ? clamp(1.1 - Math.hypot(gm.x - P.x, gm.z - P.z) / 30, 0.1, 1) * (gm.isPlayer ? 1 : 0.55) : 0;
  AU.loops.spin.gain.setTargetAtTime(spin * spin * 0.05 * near, t, 0.08);
  AU.loops.spinO.frequency.setTargetAtTime(70 + spin * 260, t, 0.1);
  AU.loops.spinO2.frequency.setTargetAtTime(35 + spin * 130, t, 0.1);
  const sw = live ? Math.min(1, nearCam / 500) : 0;
  AU.loops.chitter.gain.setTargetAtTime(sw * 0.16 * (GS.screen === 'title' ? 0.4 : 1), t, 0.3);
  AU.loops.rumble.gain.setTargetAtTime(sw * 0.35 * (GS.screen === 'title' ? 0.4 : 1), t, 0.4);
  // heartbeat when the player's armour is low
  heartT -= 0.1;
  if (GS.screen === 'playing' && !P.downed && P.hp < P.maxHp * 0.3 && heartT <= 0) { heartT = 0.55 + 0.5 * P.hp / (P.maxHp * 0.3); sfx('heart'); }
}
