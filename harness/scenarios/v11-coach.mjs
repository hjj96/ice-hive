// v1.1 package C regression: the first-run coach «Учебная высадка».
// Run on a fresh profile with --mobile (portrait; add --landscape for the step-3 shot), optionally --www --fake-ios
// (haptics + the 'tut' key through the native bridge). Options: --noshot (no screenshots).
//   node harness/run.mjs --file dist/artifact.html --mobile --scenario harness/scenarios/v11-coach.mjs
// Checks:
//   1. the title «В бой» on a fresh profile starts the coach (no «Высадка» banner, card + ghost thumb shown)
//   2. idle novice: step changes at ~7 / 19 / 28 / 36 s (±3 s); DIR.calm on in steps 1-4, off from step 5;
//      DIR.beaconHordeMul = 0.65 until the first beacon; store 'tut' = 1 afterwards; the beacon reached
//   3. a second start from the title path has no coach; __dbg.start(cls) never coaches, {coach: true} does
//   4. autopilot pass: the coach ends when the beacon is active
//   5. «Пропустить» works while a thumb rests on the move stick
//   6. the revive line shows once when a squadmate first goes down (profile runs < 3)
export default async (page, h) => {
  const ev = (f, a) => page.evaluate(f, a);
  const D = 'window.__dbg';
  const tut = () => ev(() => window.__dbg.tut());
  const shots = !h.args.noshot;
  const fail = (m) => h.fail(m);
  const near = (v, want, tol) => Math.abs(v - want) <= tol;

  // a level-up opened by a real-time frame stops __dbg.fast: take the first card
  const unblock = async () => { for (let k = 0; k < 10 && (await ev(() => window.__dbg.state().screen)) === 'levelup'; k++) { await h.sleep(800); await h.keys.press('Digit1'); await h.sleep(200); } };
  await ev(() => window.__dbg.setQuality('low'));
  // 1. fresh profile → the title button starts the coached first mission
  const fresh = await ev(() => ({ tut: localStorage.getItem('ledulei.tut'), best: localStorage.getItem('ledulei.best'), profile: localStorage.getItem('ledulei.profile') }));
  h.log('[fresh profile]', JSON.stringify(fresh));
  const go = await ev(() => { const r = document.getElementById('btnGo').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
  if (h.mobile) await h.touch.tap(go.x, go.y); else await page.mouse.click(go.x, go.y);
  // the ghost thumb is placed on the next rendered frame (SwiftShader frames can be slow on a loaded box)
  for (let k = 0; h.mobile && k < 30 && !(await ev(() => /on/.test(document.getElementById('ghost').className))); k++) await h.sleep(200);
  const c0 = await ev(() => {
    const el = document.getElementById('coach'), r = el.getBoundingClientRect(), o = document.querySelector('.obj-box').getBoundingClientRect();
    return { tut: window.__dbg.tut(), screen: window.__dbg.state().screen, hidden: el.hidden, text: el.innerText.replace(/\n/g, ' | '), rect: [r.left, r.top, r.right, r.bottom].map(Math.round),
      obj: [o.left, o.top, o.right, o.bottom].map(Math.round), ghost: document.getElementById('ghost').className, banner: document.getElementById('banner').className, vw: innerWidth, hint: document.getElementById('hHint').textContent };
  });
  h.log('[coach start]', JSON.stringify(c0));
  if (!c0.tut.on || c0.tut.step !== 0) fail('the first mission from the title did not start the coach');
  if (/show/.test(c0.banner)) fail('the «Высадка» banner showed on a coached start');
  if (c0.hidden) fail('the coach card is hidden');
  if (c0.rect[1] < c0.obj[3]) fail('the coach card overlaps the objective box');
  if (c0.rect[2] - c0.rect[0] > c0.vw * 0.92 + 1) fail('the coach card is wider than 92vw');
  if (!c0.tut.calm) fail('DIR.calm is off in step 1');
  if (c0.tut.beaconHordeMul !== 0.65) fail('DIR.beaconHordeMul is not 0.65 on a coached run');
  if (h.mobile && !/on/.test(c0.ghost)) fail('no ghost thumb on step 1 (touch)');
  if (c0.hint) fail('the control hint shows during the coach: ' + c0.hint);
  if (shots && !h.landscape) { await ev(() => window.__dbg.timeScale(0.05)); await h.shot('coach-step1'); await ev(() => window.__dbg.timeScale(1)); await unblock(); }

  // 2. idle novice: only timeouts advance the coach
  const log = [];
  let last = -9, calmBad = 0, mulBad = 0, shot3 = false;
  for (let k = 0; k < 220; k++) {
    const t = await ev(() => { window.__dbg.fast(0.25); return window.__dbg.tut(); });
    if (t.step !== last) { log.push({ step: t.step, time: t.time, calm: t.calm, mul: t.beaconHordeMul, hordes: t.hordes }); last = t.step; }
    if (t.on && (t.step <= 3) !== t.calm) calmBad++;
    if (t.active < 0 && t.beaconHordeMul !== 0.65) mulBad++;
    if (t.step === 2 && !shot3 && shots && h.landscape) {
      shot3 = true;
      // the world nearly stops for the capture (real-time frames would otherwise run on and may open a level-up)
      await ev(() => { window.__dbg.fast(1.5); window.__dbg.timeScale(0.05); });
      await h.sleep(600);
      await h.shot('coach-step3');
      await ev(() => window.__dbg.timeScale(1));
      await unblock();
    }
    if (t.step === 4) break;
  }
  h.log('[idle novice steps]', JSON.stringify(log));
  const want = [0, 7, 19, 28, 36];
  for (let s = 1; s <= 4; s++) {
    const e = log.find((x) => x.step === s);
    if (!e) fail('idle novice never reached step ' + (s + 1));
    else if (!near(e.time, want[s], 3)) fail('step ' + (s + 1) + ' started at ' + e.time + ' s (want ' + want[s] + ' ± 3)');
  }
  if (calmBad) fail('DIR.calm wrong on ' + calmBad + ' samples');
  const s5 = await tut();
  if (s5.calm) fail('DIR.calm still on in step 5');
  if (s5.tut !== 1) fail("store 'tut' not set after step 4");
  const mk = await ev(() => document.getElementById('marker').className);
  h.log('[step 5]', JSON.stringify(s5), 'marker class', mk);
  // walk to the beacon with the autopilot (stands in for a player following the marker)
  await ev(() => window.__dbg.auto(true));
  let reach = null;
  for (let k = 0; k < 120; k++) {
    const t = await ev(() => { const r = window.__dbg.tut(); window.__dbg.fast(0.25); return [r, window.__dbg.tut()]; });
    if (t[1].active >= 0 || !t[1].on) { reach = { before: t[0], after: t[1] }; break; }
  }
  h.log('[beacon reached]', JSON.stringify(reach));
  if (!reach) fail('the beacon was not reached');
  else {
    if (reach.after.on) fail('the coach still runs with the beacon active');
    if (reach.before.beaconHordeMul !== 0.65) fail('beaconHordeMul changed before the first beacon');
    // (0 hordes before the first beacon needs package A's DIR.calm gating: checked after the merge)
    h.log('[hordes before the first beacon]', reach.before.hordes, '(gated by package A; expected 0 after the merge)');
  }
  if (mulBad) fail('beaconHordeMul not 0.65 on ' + mulBad + ' samples before the beacon');
  await ev(() => window.__dbg.auto(false));

  // 3. second start from the title path (opts.coach undefined) has no coach; __dbg.start rules
  const c2 = await ev(() => { window.__dbg.start('cryo', { coach: undefined }); return window.__dbg.tut(); });
  h.log('[2nd run]', JSON.stringify(c2));
  if (c2.on) fail('the coach ran again on the second start');
  const c3 = await ev(() => { window.__dbg.start('assault'); const a = window.__dbg.tut(); window.__dbg.start('assault', { coach: true }); return [a, window.__dbg.tut()]; });
  h.log('[dbg.start]', JSON.stringify(c3));
  if (c3[0].on) fail('__dbg.start(cls) coached');
  if (!c3[1].on) fail('__dbg.start(cls, {coach: true}) did not coach');

  // 4. autopilot from the start: actions complete the steps, the coach ends when the beacon is active
  await ev(() => { window.__dbg.start('pyro', { coach: true }); window.__dbg.auto(true); });
  const logB = []; last = -9;
  let endB = null;
  for (let k = 0; k < 240; k++) {
    const t = await ev(() => { window.__dbg.fast(0.25); return window.__dbg.tut(); });
    if (t.step !== last) { logB.push({ step: t.step, time: t.time, active: t.active }); last = t.step; }
    if (!t.on) { endB = t; break; }
  }
  await ev(() => window.__dbg.auto(false));
  h.log('[autopilot steps]', JSON.stringify(logB));
  if (!endB) fail('autopilot: the coach never ended');
  else if (endB.active < 0) fail('autopilot: the coach ended without an active beacon');

  // 5. «Пропустить» while a thumb rests on the move stick (touch only)
  if (h.mobile) {
    await ev(() => window.__dbg.start('gunner', { coach: true }));
    await h.sleep(600);
    const sk = await ev(() => { const r = document.querySelector('#coach .co-skip').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
    const L = { x: Math.round(h.width * 0.2), y: Math.round(h.height * 0.75), id: 1 };
    await h.touch.start([L]);
    await h.touch.move([{ ...L, x: L.x + 30 }]);
    await h.sleep(250);
    const S = { x: Math.round(sk.x), y: Math.round(sk.y), id: 2 };
    await h.touch.start([{ ...L, x: L.x + 30 }, S]);
    await h.sleep(120);
    await h.touch.set([S], 'touchEnd');   // CDP: touchEnd releases only the listed point — the thumb stays down
    await h.sleep(250);
    const st = await ev(() => ({ tut: window.__dbg.tut(), hidden: document.getElementById('coach').hidden, thumbDown: document.getElementById('stickL').classList.contains('on') }));
    await h.touch.end();
    h.log('[skip with a thumb on the stick]', JSON.stringify(st));
    if (!st.thumbDown) fail('test setup: the move-stick thumb was not down during the tap');
    if (st.tut.on || !st.hidden) fail('«Пропустить» did not work while a thumb rested on the move stick');
    if (st.tut.calm) fail('DIR.calm left on after skip');
  }

  // 6. revive line (raw profile runs < 3): once per run when a squadmate first goes down
  await ev(() => window.__dbg.start('assault'));
  await h.sleep(300);
  const rv = await ev(() => { window.__dbg.fast(8); window.__dbg.god(true); window.__dbg.hurt(2, 0); window.__dbg.fast(0.2); return window.__dbg.tut(); });
  await h.sleep(500);
  const rvText = await ev(() => document.getElementById('hHint').textContent);
  const rv2 = await ev(() => { window.__dbg.fast(7); window.__dbg.hurt(1, 0); window.__dbg.fast(0.2); const t = window.__dbg.tut(); window.__dbg.god(false); return t; });
  h.log('[revive line]', JSON.stringify({ t: rv.revT, text: rvText, second: rv2.revT }));
  if (!(rv.revT > 5)) fail('the revive line did not start');
  if (!/ранен — встаньте рядом, чтобы поднять/.test(rvText)) fail('the revive line is not in the hint: ' + rvText);
  if (rv2.revT > 0) fail('the revive line showed twice in one run');

  // iOS shell: haptics per step and the 'tut' key mirrored into native Preferences
  if (h.native && (await ev(() => !!window.__fakeNative))) {
    const calls = await h.native.calls(), prefs = await h.native.prefs();
    const sel = calls.filter((c) => c.plugin === 'Haptics' || /haptic/i.test(c.method)).length;
    h.log('[native]', 'haptic calls', sel, '| prefs tut', prefs['ledulei.tut'], '| sticks', prefs['ledulei.sticks']);
    if (prefs['ledulei.tut'] !== '1') fail("native Preferences lack 'ledulei.tut' = 1");
    if (!sel) fail('no haptic calls during the coach');
  }
  h.log('[stats]', JSON.stringify(await h.stats()));
};
