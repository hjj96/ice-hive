// ================================================================
//  Appended to the game's module scope by tools/render-audio.mjs.
//  Renders the game's procedural WebAudio recipes (09-audio.js: sfx(), tone(), noiseHit(), the audioInit() loop
//  graphs) offline. Deterministic: the 2 s white-noise buffer and every Math.random() call use seeded generators.
// ================================================================
{
  const SR = 44100;
  const RANDOM = Math.random;
  function b64f(f32) {
    const u8 = new Uint8Array(f32.buffer, f32.byteOffset, f32.byteLength);
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }
  // like audioInit(): master gain (no compressor — the native mixer applies its own limiter) + the noise buffer
  function setup(ctx, seed) {
    AU.ctx = ctx;
    AU.master = ctx.createGain(); AU.master.gain.value = 1; AU.master.connect(ctx.destination);
    const R = mulberry32(7), len = SR * 2, buf = ctx.createBuffer(1, len, SR), d = buf.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = R() * 2 - 1;
    AU.noise = buf;
    AU.muted = false;
    AU.last = Object.create(null);
    Math.random = mulberry32(1000 + seed);
  }
  async function render(ctx) {
    try { const buf = await ctx.startRendering(); return b64f(buf.getChannelData(0)); }
    finally { Math.random = RANDOM; }
  }
  // one sfx() call at full volume (no distance attenuation), from t = 0
  async function oneShot(name, dur, seed, combo = 0) {
    const ctx = new OfflineAudioContext(1, Math.ceil(dur * SR), SR);
    setup(ctx, seed);
    GS.combo = combo;
    AU.last[name] = -1;
    try { sfx(name); } catch (e) { Math.random = RANDOM; throw e; }
    return render(ctx);
  }
  // the continuous beds of audioInit(), each at its maximum in-game level (see the manifest for the ranges)
  async function loop(kind, dur, seed) {
    const ctx = new OfflineAudioContext(1, Math.ceil(dur * SR), SR);
    setup(ctx, seed);
    const out = AU.master;
    if (kind === 'wind') {
      const src = loopNoise(), lp = ctx.createBiquadFilter(), g = ctx.createGain(), lfo = ctx.createOscillator(), lg = ctx.createGain();
      lp.type = 'lowpass'; lp.frequency.value = 420; lp.Q.value = 0.8;
      lfo.frequency.value = 0.07; lg.gain.value = 260; lfo.connect(lg); lg.connect(lp.frequency); lfo.start();
      g.gain.value = 0.085; src.connect(lp); lp.connect(g); g.connect(out);
    } else if (kind === 'chitter') {
      const src = loopNoise(), bp = ctx.createBiquadFilter(), am = ctx.createGain(), amO = ctx.createOscillator(), amG = ctx.createGain(), g = ctx.createGain();
      bp.type = 'bandpass'; bp.frequency.value = 2500; bp.Q.value = 2.5;
      am.gain.value = 0.55; amO.type = 'square'; amO.frequency.value = 27; amG.gain.value = 0.45; amO.connect(amG); amG.connect(am.gain); amO.start();
      g.gain.value = 0.16; src.connect(bp); bp.connect(am); am.connect(g); g.connect(out);
    } else if (kind === 'rumble') {
      const src2 = loopNoise(), lp2 = ctx.createBiquadFilter(), g2 = ctx.createGain();
      lp2.type = 'lowpass'; lp2.frequency.value = 180; g2.gain.value = 0.35; src2.connect(lp2); lp2.connect(g2); g2.connect(out);
    } else if (kind === 'flame') {
      const src = loopNoise(), lp = ctx.createBiquadFilter(), g = ctx.createGain();
      lp.type = 'lowpass'; lp.frequency.value = 1100; lp.Q.value = 1.2; g.gain.value = 0.3;
      src.connect(lp); lp.connect(g); g.connect(out);
    } else if (kind === 'spin') {
      // minigun whine at full spin (spin = 1): saw 70 + 260 = 330 Hz, square 35 + 130 = 165 Hz
      const o = ctx.createOscillator(), o2 = ctx.createOscillator(), f = ctx.createBiquadFilter(), g = ctx.createGain();
      o.type = 'sawtooth'; o.frequency.value = 330; o2.type = 'square'; o2.frequency.value = 165;
      f.type = 'bandpass'; f.frequency.value = 900; f.Q.value = 1.4; g.gain.value = 0.05;
      o.connect(f); o2.connect(f); f.connect(g); g.connect(out); o.start(); o2.start();
    } else if (kind === 'cryo') {
      const src = loopNoise(), bp = ctx.createBiquadFilter(), g = ctx.createGain(), o = ctx.createOscillator(), og = ctx.createGain(), v = ctx.createOscillator(), vg = ctx.createGain();
      bp.type = 'bandpass'; bp.frequency.value = 4200; bp.Q.value = 0.8;
      o.type = 'sine'; o.frequency.value = 1350; v.frequency.value = 7; vg.gain.value = 40; v.connect(vg); vg.connect(o.frequency); o.start(); v.start();
      og.gain.value = 0.18; o.connect(og); og.connect(g);
      g.gain.value = 0.12; src.connect(bp); bp.connect(g); g.connect(out);
    } else throw new Error('unknown loop ' + kind);
    return render(ctx);
  }
  window.__A = { oneShot, loop, SR };
}
