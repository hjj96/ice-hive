// Allocation sample (DevTools sampling heap profiler via CDP), dev only.
//   node harness/run.mjs --file dist/v11-a-calib.html --scenario harness/calib/alloc.mjs [--phase hold|press] [--how ticks|frames]
//        [--events off] [--seconds 10]
// phase hold: the lift hold with the Матка alive (queenTick, the boss HUD); phase press: loitering on the start pad
// at full hive pressure with the AFK hunt on (the hunt test in simBugs, the pressure HUD).
// how ticks (default, needs the calibration build): after a warm-up, the simulation runs 10 s of fixed ticks inside the
//   sample and the threat HUD functions run once per tick — the steady state of optimised code.
// how frames: 10 s of the real-time loop. On SwiftShader (~15 fps) per-frame functions stay in V8's unoptimised tiers
//   for a long time, and those box every double they load (a few hundred bytes in a 10 s sample): that is the JIT
//   warming up, not an allocation in the code — compare with the same phase on the v1.0 build.
// Prints the allocating functions (bytes sampled, including objects already collected) and fails if the v1.1 threat
// code allocates on its per-tick path (see the strict list below). On the v1.0 build (a copy with window.__int =
// { M, B, DIR, GS, LV, tick }) the same phases give the baseline for simBugs & co.
export default async (page, h) => {
  const phase = h.args.phase || 'hold', secs = +(h.args.seconds || 10), how = h.args.how || 'ticks';
  const ev = (f, a) => page.evaluate(f, a);
  const calib = await ev(() => !!window.__int);
  if (how === 'ticks' && !calib) { h.fail('--how ticks needs the calibration build (harness/calib/mkcalib.mjs)'); return; }
  await ev((phase) => {
    const d = window.__dbg;
    d.setQuality('med');
    d.start('assault', { tier: 1, coach: false, seed: 0 }); d.god(true);
    if (phase === 'hold') { for (let k = 0; k < 4; k++) d.skip(); if (d.queen) d.queen(1e6); d.fast(4); }
    else d.fast(60);
  }, phase);
  const noEv = h.args.events === 'off';
  const loop = (s) => ev(([s, phase, noEv]) => {
    const d = window.__dbg, I = window.__int;
    const n = Math.round(s * 60);
    for (let k = 0; k < n; k++) {
      d.fast(1 / 60);
      if (I.threatState) { I.updateThreatHUD(); I.threatState(); I.objectiveProgress(); I.objectiveText(); }
      if (phase === 'press') { I.GS.afkT = 60; I.DIR.press = Math.max(I.DIR.press || 0, 60); }   // keep the hunt and state 2 on
      // --events off: no volley / brood events during the sample, i.e. only her per-tick path (a volley allocates two
      // telegraph objects via the shared teleRing/teleFill helpers plus the sfx nodes, exactly like a spitter's shot)
      if (phase === 'hold' && noEv && I.QSTATE) { I.QSTATE.volley = 99; I.QSTATE.brood = 99; }
    }
  }, [s, phase, noEv]);
  if (how === 'ticks') await loop(20);   // warm-up: every function involved is optimised before the sample
  else await h.sleep(1500);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('HeapProfiler.enable');
  await cdp.send('HeapProfiler.collectGarbage');
  await cdp.send('HeapProfiler.startSampling', { samplingInterval: 256, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
  if (how === 'ticks') await loop(secs);
  else {
    // the real-time loop: pick level-up cards so the sample stays in play
    for (let t = 0; t < secs * 1000; t += 500) { await h.sleep(500); if ((await h.stats()).screen === 'levelup') await page.keyboard.press('Digit1'); }
  }
  const { profile } = await cdp.send('HeapProfiler.stopSampling');
  // (the v1.0 build has no threat(): the same phases there are the baseline for simBugs & co.)
  const st = await ev(() => ({ queen: {}, ...(window.__dbg.threat ? window.__dbg.threat() : {}), fps: window.__dbg.state().fps, screen: window.__dbg.state().screen }));
  const base = !(await ev(() => !!window.__dbg.threat));
  const self = {};
  const walk = (n) => { const f = n.callFrame.functionName || '(anon)'; self[f] = (self[f] || 0) + n.selfSize; for (const c of n.children) walk(c); };
  walk(profile.head);
  const top = Object.entries(self).sort((a, b) => b[1] - a[1]).slice(0, 20).map(([f, b]) => f + ' ' + Math.round(b / 1024) + 'K');
  h.log('[alloc]', phase, how, 'state', JSON.stringify({ stage: st.stage, state: st.state, press: st.press, idleMul: st.idleMul, afkT: st.afkT, queen: st.queen.alive, fps: st.fps, screen: st.screen }));
  h.log('[alloc] top self allocators over', secs, 's:', top.join(' | '));
  const mine = ['queenTick', 'queenEdge', 'queenWarn', 'simBugs', 'updateThreatHUD', 'threatState', 'objectiveProgress', 'objectiveText', 'processBooms', 'killBug', 'tickDirector', 'tickMarines', 'beamTick', 'hurtMarine'];
  const bad = mine.filter((f) => (self[f] || 0) > 0).map((f) => f + ' ' + self[f] + ' B');
  h.log('[alloc] v1.1 threat functions with sampled allocations:', bad.length ? bad.join(', ') : 'none');
  if (base) return;
  if (phase === 'hold' && (!st.queen.alive || st.stage !== 'hold')) h.fail('the Матка was not alive in the hold during the sample');
  if (phase === 'press' && st.state !== 2) h.fail('pressure was not at state 2 during the sample');
  if (how === 'ticks') {
    // simBugs allocates in v1.0 already (more than here: the same phases sample 24 MB / 7 MB there vs ~7 MB / ~2 MB
    // here), so the hunt test is judged by the code (two typed-array reads and a few compares) and that comparison;
    // objectiveProgress boxes its double return value for the unoptimised harness loop that calls it (v1.0 does too);
    // updateThreatHUD allocates only for the 1.2 s heartbeat sfx (press) and queenTick only on volley / brood events
    // (run with --events off to see her per-tick path)
    const strict = ['queenTick', 'queenEdge', 'threatState'].concat(phase === 'hold' ? ['updateThreatHUD'] : []);
    const hard = strict.filter((f) => (self[f] || 0) > 0);
    if (hard.length) h.fail('allocations in ' + hard.join(', '));
  }
};
