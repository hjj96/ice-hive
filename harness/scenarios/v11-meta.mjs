// v1.1 package D regression: profile, score, ranks, medals, tier selector, mission report, saves, layout.
//
//   node harness/run.mjs --mobile --scenario harness/scenarios/v11-meta.mjs [--shots]
//   iOS Preferences mirror + relaunch (WebKit purged localStorage, Preferences restores it):
//   node harness/run.mjs --www --fake-ios --scenario harness/scenarios/v11-meta.mjs --quick
//
// --shots takes the six single frames (title fresh / returning / 568x320, report win / loss / landscape).
// --quick skips the long autopilot win (a skip() win instead) and the layout sweep.
export default async (page, h) => {
  const { log, fail, sleep } = h;
  const ev = (f, a) => page.evaluate(f, a);
  const expect = (cond, msg) => { if (cond) log('[ok]', msg); else fail(msg); };
  const SHOTS = !!h.args.shots, QUICK = !!h.args.quick, FAKE = !!h.args['fake-ios'];
  const W0 = h.width, H0 = h.height;
  const prof = () => ev(() => window.__dbg.profile());
  const meta = (gs, dir) => ev(([g, d]) => window.__dbg.meta(g, d), [gs || null, dir || null]);
  const screen = async () => (await h.stats()).screen;
  const report = () => ev(() => document.getElementById('eBox').innerText.replace(/\s*\n\s*/g, ' | '));
  const size = async (w, hh) => { await page.setViewportSize({ width: w, height: hh }); await sleep(350); };
  const tap = async (sel) => {
    const r = await ev((s) => { const el = document.querySelector(s); if (!el) return null; const b = el.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2, w: b.width }; }, sel);
    if (!r || !r.w) { fail('cannot tap ' + sel); return; }
    if (h.mobile) await h.touch.tap(r.x, r.y); else await page.mouse.click(r.x, r.y);
    await sleep(300);
  };
  const reboot = async () => {
    await page.reload({ waitUntil: 'load' });
    for (let i = 0; i < 240; i++) { const ok = await ev(() => !!(window.__dbg && window.__dbg.state && document.getElementById('sLoad').style.display === 'none')).catch(() => false); if (ok) break; await sleep(250); }
    await sleep(300);
  };
  const SIZES = [[390, 844], [844, 390], [568, 320]];
  const titleFit = () => ev(() => {
    const s = document.getElementById('sTitle'), go = document.getElementById('btnGo').getBoundingClientRect();
    const segs = [...document.querySelectorAll('#tTier .tt-b')].map((b) => b.getBoundingClientRect());
    // in-flow blocks of the title must not overlap (absolute chips from other packages are excluded)
    const kids = [...document.querySelector('.t-wrap').children].filter((c) => c.getBoundingClientRect().height > 0).map((c) => [c.id || c.className, c.getBoundingClientRect()]);
    let overlap = '';
    for (let i = 1; i < kids.length; i++) if (kids[i][1].top < kids[i - 1][1].bottom - 0.5) overlap += kids[i - 1][0] + '/' + kids[i][0] + ' ';
    return { scroll: s.scrollHeight - s.clientHeight, go: Math.round(go.bottom), vh: innerHeight, segH: Math.min(...segs.map((b) => b.height)), segW: Math.min(...segs.map((b) => b.width)), overlap };
  });
  const endFit = () => ev(() => {
    const s = document.getElementById('sEnd'), r = (id) => document.getElementById(id).getBoundingClientRect();
    const a = r('eAgain'), n = r('eNew'), m = r('eMenu');
    const cut = [...document.querySelectorAll('.r-strip span')].filter((x) => x.scrollWidth > x.clientWidth + 1).map((x) => x.textContent);
    return { scroll: s.scrollHeight - s.clientHeight, again: [Math.round(a.top), Math.round(a.bottom)], nw: [Math.round(n.top), Math.round(n.bottom)], menu: Math.round(m.bottom), vh: innerHeight, vw: innerWidth, cut: cut.join(',') };
  });
  const checkEnd = async (tag) => {
    // package E un-hides «Новая станция»; until it lands the layout is checked with the button shown
    await ev(() => { document.getElementById('eNew').hidden = false; });
    for (const [w, hh] of QUICK ? [] : SIZES) {
      await size(w, hh);
      const f = await endFit();
      expect(f.again[0] >= 0 && f.again[1] <= f.vh && f.nw[0] >= 0 && f.nw[1] <= f.vh && f.menu <= f.vh && !f.cut,
        `${tag} ${w}x${hh}: «Ещё раз» ${f.again} and «Новая станция» ${f.nw} above the fold (vh ${f.vh}, scroll ${f.scroll}${f.cut ? ', strip cut: ' + f.cut : ''})`);
    }
    await size(W0, H0);
  };
  const runUntilEnd = async (perStep, max) => {
    for (let k = 0; k < max; k++) { const st = await ev((n) => window.__dbg.fast(n), perStep); if (st.screen !== 'playing') return st; }
    return h.stats();
  };
  // crush the squad: the player stands still while waves pile in (bots revive, so it takes a while)
  const crush = async () => ev(() => {
    window.__dbg.auto(false);
    let s = 'playing';
    for (let i = 0; i < 60 && s === 'playing'; i++) { window.__dbg.spawn(160, 'runner'); window.__dbg.spawn(30, 'brute'); window.__dbg.spawn(30, 'boomer'); s = window.__dbg.fast(4).screen; }
    return window.__dbg.state();
  });

  await ev(() => window.__dbg.setQuality('low'));
  // package E un-hides «Новая станция» (and wires it); until it lands the button is shown here so the layout and
  // the primary-button rule can be checked
  const showNew = () => ev(() => { document.getElementById('eNew').hidden = false; });
  await showNew();

  // ---------- 1. fresh profile: Новобранец by default, the title fits
  let m = await meta();
  let p = await prof();
  expect(p.runs === 0 && m.effective === 0 && m.pick === null, 'fresh profile: runs 0, default tier Новобранец ' + JSON.stringify(m));
  for (const [w, hh] of SIZES) {
    await size(w, hh);
    const f = await titleFit();
    expect(f.scroll <= 0 && f.go <= f.vh && f.segH >= 44 && !f.overlap, `title fresh ${w}x${hh}: ${JSON.stringify(f)}`);
  }
  await size(W0, H0);
  const tierOn = await ev(() => [...document.querySelectorAll('#tTier .tt-b')].findIndex((b) => b.classList.contains('on')));
  expect(tierOn === 0, 'selector shows Новобранец on a fresh profile (' + tierOn + ')');
  if (SHOTS) await h.shot('title-fresh');

  // ---------- 2. first run: autopilot win on Новобранец
  await ev(() => { window.__dbg.start('assault'); window.__dbg.auto(true); });
  expect((await h.stats()).tier === 'rec', 'first mission runs on Новобранец');
  // nothing on the title / end / tier DOM changes while a mission runs (no per-frame report work)
  await ev(() => { window.__metaMut = 0; const o = new MutationObserver((l) => { window.__metaMut += l.length; }); for (const id of ['sTitle', 'eBox', 'sPause']) o.observe(document.getElementById(id), { subtree: true, childList: true, attributes: true, characterData: true }); window.__metaObs = o; });
  await sleep(1500);
  const mut = await ev(() => { window.__metaObs.disconnect(); return window.__metaMut; });
  expect(mut === 0, 'no title / report DOM mutations during play (' + mut + ')');
  let st;
  if (QUICK) {
    await ev(() => window.__dbg.god(true));
    for (let i = 0; i < 30 && ['playing', 'levelup'].includes(await screen()); i++) await ev(() => { window.__dbg.skip(); window.__dbg.fast(0.5); });
    await ev(() => window.__dbg.god(false));
    st = await h.stats();
  } else st = await runUntilEnd(10, 90);
  await sleep(500);
  expect(st.screen === 'won', 'autopilot run ended: ' + st.screen + ' at ' + st.time + ' s');
  p = await prof();
  const rep1 = await report();
  log('[report win]', rep1);
  const score1 = +((rep1.match(/ОЧКИ \| ([\d\s ]+)/) || [])[1] || '').replace(/[\s ]/g, '');
  const a = p.cls.assault;
  expect(p.runs === 1 && p.wins === 1 && a.runs === 1 && a.wins === 1, 'profile after the win: runs 1, wins 1');
  expect(score1 > 0 && a.xp === Math.round(score1 / 10) && a.best === score1 && p.earned === score1, `xp = round(score/10): score ${score1}, xp ${a.xp}`);
  expect(a.ev[0] === 1 && a.ev[1] === 0 && a.ev[2] === 0, 'medal Новобранец set: ev ' + JSON.stringify(a.ev));
  expect(/ОЧКИ/.test(rep1) && /Ваши убийства/.test(rep1) && /Маяки 3\/3/.test(rep1) && /Эвакуация \| \+1 500/.test(rep1) && /×0,8/.test(rep1), 'report: ОЧКИ, breakdown and «×0,8»');
  expect(/МАТКА/.test(rep1) && /Новая нашивка: Штурмовик · Новобранец/i.test(rep1) && /Дальше — «Ветеран»/.test(rep1), 'report: МАТКА on the strip, the new medal and the promotion line');
  const prim = await ev(() => ({ again: document.getElementById('eAgain').classList.contains('btn-go'), nw: document.getElementById('eNew').classList.contains('btn-go') }));
  expect(prim.nw && !prim.again, 'win: «Новая станция» is the primary button');
  await checkEnd('win');
  if (SHOTS) { await h.shot('report-win'); await size(844, 390); await h.shot('report-land'); await size(W0, H0); }
  const raw1 = await ev(() => localStorage.getItem('ledulei.profile'));
  log('[profile bytes]', raw1.length);
  if (FAKE) {
    const pr = await h.native.prefs();
    expect(pr['ledulei.profile'] === raw1, 'profile mirrored to iOS Preferences (' + (pr['ledulei.profile'] || '').length + ' bytes)');
  }

  // ---------- 3. after the first evacuation the default is Ветеран; two early losses, tips, «дольше прошлой попытки»
  st = await ev(() => window.__dbg.start('assault'));
  expect(st.tier === 'vet', 'next start without opts runs Ветеран (' + st.tier + ')');
  await meta({ downBy: 2 });   // package A sets downBy on the player's down; forced here
  st = await crush();
  await sleep(400);
  let rep = await report();
  log('[report loss 1]', st.screen, st.time, rep);
  expect(st.screen === 'lost' && /Громила: красная полоса/.test(rep) && /Ветеран · ×1,0 очков/.test(rep), 'loss 1: brute tip and the tier line');
  expect(!/дольше прошлой попытки/.test(rep), 'loss 1: no «дольше» line (the previous run was a win)');
  const prim2 = await ev(() => document.getElementById('eAgain').classList.contains('btn-go'));
  expect(prim2, 'loss: «Ещё раз» is the primary button');
  await tap('#eAgain');
  st = await h.stats();
  expect(st.screen === 'playing' && st.tier === 'vet', '«Ещё раз» restarts on the same tier');
  // the first loss lasted t1 s; this one: autopilot (invulnerable) until 20 s past it, then crushed
  const t1 = (await prof()).cls.assault.lastT;
  await ev((t) => { window.__dbg.auto(true); window.__dbg.god(true); while (window.__dbg.state().time < t + 20 && window.__dbg.state().screen === 'playing') window.__dbg.fast(5); window.__dbg.god(false); }, t1);
  await meta({ downBy: 4 });   // SRC_QUEEN
  st = await crush();
  await sleep(400);
  rep = await report();
  log('[report loss 2]', st.screen, st.time, 'beacons', st.beacons, rep);
  expect(/Матка: уходите с полосы тарана/.test(rep), 'loss 2: queen tip (SRC_QUEEN)');
  expect(/Продержались на \d+:\d\d дольше прошлой попытки/.test(rep), 'loss 2: «дольше прошлой попытки» (' + t1 + ' s before)');
  const early = st.beacons < 2;
  if (early) expect(/Попробуйте «Новобранец»/i.test(rep), 'two early losses on Ветеран: the «Попробуйте «Новобранец»» chip');
  else log('[note] loss 2 reached beacon ' + st.beacons + ': chip not expected');
  await checkEnd('loss');
  if (SHOTS) await h.shot('report-loss');
  if (early) {
    await tap('#eRepB .r-chip');
    st = await h.stats();
    m = await meta();
    expect(st.screen === 'playing' && st.tier === 'rec' && m.pick === 0 && (await prof()).recTip === 1, 'chip: diff = 0 and a restart on Новобранец');
  } else await ev(() => window.__dbg.start('assault'));
  // pressure at the down wins over the damage source
  await meta({ downBy: 1 }, { press: 99, idleMul: 2 });
  st = await crush();
  await sleep(300);
  rep = await report();
  expect(/улей стягивает рой/.test(rep) && !/Попробуйте/i.test(rep), 'pressure tip; the chip is one-time');

  // ---------- 4. pause heading
  await ev(() => window.__dbg.start('pyro', { tier: 2 }));
  await page.keyboard.press('Escape');
  await sleep(300);
  const ph = await ev(() => document.querySelector('#sPause h2').textContent);
  expect(ph === 'Пауза· Кошмар', 'pause heading «Пауза · Кошмар»: ' + JSON.stringify(ph));
  await page.keyboard.press('Escape');
  await sleep(200);

  // ---------- 5. tier selector: one tap, persists across a reload; returning title
  await ev(() => document.getElementById('pQuit').click());   // surrender → report
  await sleep(300);
  await tap('#eMenu');
  expect((await screen()) === 'title', 'back on the title');
  await tap('#tTier .tt-b:nth-child(3)');
  m = await meta();
  expect(m.pick === 2 && (await ev(() => localStorage.getItem('ledulei.diff'))) === '2', 'tapped Кошмар: store diff = 2');
  await reboot();
  m = await meta();
  const on2 = await ev(() => [...document.querySelectorAll('#tTier .tt-b')].findIndex((b) => b.classList.contains('on')));
  expect(m.pick === 2 && m.effective === 2 && on2 === 2, 'the choice survives a reload ' + JSON.stringify(m));
  const line = await ev(() => ({ best: document.getElementById('tBest').textContent, chips: [...document.querySelectorAll('.cc-rk')].map((c) => c.textContent), pips: document.querySelectorAll('.cc-ev i.on').length, premise: getComputedStyle(document.querySelector('.t-premise')).display }));
  expect(/^(Штурмовик|Огнемётчик|Криотехник|Пулемётчик) · \S.* · рекорд [\d ]+$/.test(line.best) && line.chips.length >= 2 && line.pips >= 1 && line.premise === 'none', 'returning title: ' + JSON.stringify(line));
  for (const [w, hh] of SIZES) {
    await size(w, hh);
    const f = await titleFit();
    expect(f.scroll <= 0 && f.go <= f.vh && f.segH >= 44 && !f.overlap, `title returning ${w}x${hh}: ${JSON.stringify(f)}`);
    if (SHOTS && w === 568) await h.shot('title-568');
  }
  await size(W0, H0);
  if (SHOTS) await h.shot('title-return');
  st = await ev(() => window.__dbg.start('cryo'));
  expect(st.tier === 'nm', 'a start without opts uses the stored choice (' + st.tier + ')');

  // ---------- 6. iOS: relaunch with purged localStorage, Preferences restores the profile and the choice
  if (FAKE) {
    const pr = await h.native.prefs();
    const saved = { 'ledulei.profile': pr['ledulei.profile'], 'ledulei.diff': pr['ledulei.diff'] };
    await page.addInitScript((s) => { try { localStorage.clear(); } catch (e) { /* none */ } if (window.__fakeNative) Object.assign(window.__fakeNative.prefs, s); }, saved);
    await reboot();
    const back = await ev(() => ({ prof: localStorage.getItem('ledulei.profile'), runs: window.__dbg.profile().runs, pick: window.__dbg.meta().pick }));
    expect(back.prof === saved['ledulei.profile'] && back.runs === (await prof()).runs && back.pick === 2, 'relaunch: Preferences restored the profile (' + back.runs + ' runs) and the tier choice');
  }

  // ---------- 7. 20 runs: the profile stays small
  const sz = await ev(() => {
    const cls = ['assault', 'pyro', 'cryo', 'gunner'];
    for (let i = 0; i < 20; i++) { window.__dbg.start(cls[i % 4], { tier: i % 3 }); window.__dbg.fast(1); document.getElementById('pQuit').click(); }
    return { bytes: localStorage.getItem('ledulei.profile').length, runs: window.__dbg.profile().runs };
  });
  expect(sz.bytes <= 4096, `profile after ${sz.runs} runs: ${sz.bytes} bytes (≤ 4 KB)`);

  // ---------- 8. corrupt and legacy saves
  if (!FAKE) {
    const cases = [['{bad', 0], ['{"v":1,"runs":"x"}', 0], [JSON.stringify('x'.repeat(50 * 1024)), 0], ['{"v":1,"runs":3,"wins":1,"cls":{"pyro":{"xp":-5,"ev":[1,"y",0]}}}', 3]];
    for (const [val, runs] of cases) {
      await ev((v) => { localStorage.setItem('ledulei.profile', v); localStorage.removeItem('ledulei.diff'); localStorage.removeItem('ledulei.best'); }, val);
      await reboot();
      const q = await prof();
      expect(q.runs === runs && q.cls.pyro.xp === 0 && (await screen()) === 'title', `save ${val.slice(0, 40)}${val.length > 40 ? '…(' + val.length + ')' : ''} → boots, runs ${q.runs}`);
    }
    await ev(() => { localStorage.removeItem('ledulei.profile'); localStorage.setItem('ledulei.best', '{"kills":812,"win":431}'); });
    await reboot();
    m = await meta(); p = await prof();
    expect(p.runs === 1 && p.wins === 1 && m.effective === 1, 'legacy best with a win → runs 1, wins 1, default Ветеран');
    expect((await ev(() => window.__dbg.start('assault'))).tier === 'vet', 'legacy veteran starts on Ветеран');
    await ev(() => { localStorage.removeItem('ledulei.profile'); localStorage.setItem('ledulei.best', '{"kills":300,"win":0}'); });
    await reboot();
    m = await meta(); p = await prof();
    expect(p.runs === 1 && p.wins === 0 && m.effective === 0, 'legacy best without a win → default Новобранец');
  }
};
