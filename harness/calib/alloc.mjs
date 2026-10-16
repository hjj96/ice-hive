// Allocation sample over 10 s of real-time play (DevTools sampling heap profiler via CDP), dev only.
//   node harness/run.mjs --file dist/v11-a.html --scenario harness/calib/alloc.mjs [--phase hold|press] [--seconds 10]
// phase hold: the lift hold with the Матка alive (queenTick, the boss HUD); phase press: loitering on the start pad
// at full hive pressure with the AFK hunt on (the hunt test in simBugs, the pressure HUD). Prints the allocating
// functions (bytes sampled, including objects already collected) and fails if any of the v1.1 threat code allocates.
export default async (page, h) => {
  const phase = h.args.phase || 'hold', secs = +(h.args.seconds || 10);
  const ev = (f, a) => page.evaluate(f, a);
  await ev((phase) => {
    const d = window.__dbg;
    d.setQuality('med');
    d.start('assault', { tier: 1, coach: false, seed: 0 }); d.god(true);
    if (phase === 'hold') { for (let k = 0; k < 4; k++) d.skip(); d.queen(1e6); d.fast(4); }
    else d.fast(60);
  }, phase);
  await h.sleep(1500);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('HeapProfiler.enable');
  await cdp.send('HeapProfiler.collectGarbage');
  await cdp.send('HeapProfiler.startSampling', { samplingInterval: 256, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
  await h.sleep(secs * 1000);
  const { profile } = await cdp.send('HeapProfiler.stopSampling');
  const st = await ev(() => ({ ...window.__dbg.threat(), fps: window.__dbg.state().fps, screen: window.__dbg.state().screen }));
  const self = {};
  const walk = (n) => { const f = n.callFrame.functionName || '(anon)'; self[f] = (self[f] || 0) + n.selfSize; for (const c of n.children) walk(c); };
  walk(profile.head);
  const top = Object.entries(self).sort((a, b) => b[1] - a[1]).slice(0, 25).map(([f, b]) => f + ' ' + Math.round(b / 1024) + 'K');
  h.log('[alloc]', phase, 'state', JSON.stringify({ stage: st.stage, state: st.state, press: st.press, idleMul: st.idleMul, afkT: st.afkT, queen: st.queen.alive, fps: st.fps, screen: st.screen }));
  h.log('[alloc] top self allocators over', secs, 's:', top.join(' | '));
  const mine = ['queenTick', 'queenEdge', 'queenWarn', 'simBugs', 'updateThreatHUD', 'threatState', 'objectiveProgress', 'processBooms', 'killBug', 'tickDirector', 'tickMarines', 'beamTick', 'hurtMarine'];
  const bad = mine.filter((f) => (self[f] || 0) > 0).map((f) => f + ' ' + self[f] + ' B');
  h.log('[alloc] v1.1 threat functions with sampled allocations:', bad.length ? bad.join(', ') : 'none');
  if (phase === 'hold' && (!st.queen.alive || st.stage !== 'hold')) h.fail('the Матка was not alive in the hold during the sample');
  if (phase === 'press' && st.state !== 2) h.fail('pressure was not at state 2 during the sample');
  const strict = ['queenTick', 'queenEdge', 'updateThreatHUD', 'threatState', 'objectiveProgress', 'simBugs'];
  const hard = strict.filter((f) => (self[f] || 0) > 0);
  if (hard.length) h.fail('allocations in ' + hard.join(', '));
};
