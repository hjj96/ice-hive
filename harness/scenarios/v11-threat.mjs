// v1.1 package A regression: tiers, one-shot fodder, hive pressure + AFK clock, the Матка and the lift lock.
//   npm run build:artifact && node harness/run.mjs --scenario harness/scenarios/v11-threat.mjs --quiet
//   (also runs on the www bundle: --www). Simulation is driven with __dbg.fast; no screenshots unless --shots.
export default async (page, h) => {
  const { log, fail, sleep } = h;
  const ev = (f, a) => page.evaluate(f, a);
  const expect = (cond, msg) => { if (cond) log('[ok]', msg); else fail(msg); };
  const T = () => ev(() => window.__dbg.threat());
  // the HUD (DOM) updates on rendered frames only, and SwiftShader frames can take seconds: wait until the objective
  // text has caught up with the simulation (the real-time loop runs at timeScale 0.05 here, so it barely ticks)
  const frame = async () => {
    for (let k = 0; k < 60; k++) {
      if (await ev(() => document.getElementById('hObj').textContent === window.__dbg.state().objective)) return;
      await sleep(200);
    }
  };
  const hud = async () => {
    await frame(); await sleep(50);
    return ev(() => {
      const box = document.querySelector('.obj-box'), mk = document.getElementById('marker');
      return { cls: ['press1', 'press2', 'boss'].filter((c) => box.classList.contains(c)).join(','), urge: mk.classList.contains('urge'), text: document.getElementById('hObj').textContent, bar: document.getElementById('hObjBar').classList.contains('on') };
    });
  };
  const has = await ev(() => !!(window.__dbg && ['diff', 'queen', 'press', 'threat'].every((k) => typeof window.__dbg[k] === 'function')));
  expect(has, '__dbg exposes diff / queen / press / threat');
  if (!has) return;
  await ev(() => window.__dbg.timeScale(0.05));

  // ---- 1. tiers + one-shot fodder: 200 runners at the drop and after ~2 min stay ≤ 16.8 HP on every tier
  for (const [i, id] of [[0, 'rec'], [1, 'vet'], [2, 'nm']]) {
    const st = await ev((i) => window.__dbg.start('assault', { tier: i, coach: false, seed: 0 }), i);
    expect(st.tier === id && st.screen === 'playing', `start tier ${i} -> ${st.tier}`);
    const r = await ev(() => {
      const d = window.__dbg; d.god(true);
      d.spawn(200, 'runner'); const a = d.threat().runnerHpMax;
      d.fast(110); d.spawn(200, 'runner'); const b = d.threat();
      d.god(false);
      return { a, b: b.runnerHpMax, n: b.runners, t: d.state().time };
    });
    expect(r.a <= 16.8 && r.b <= 16.8 && r.a >= 13.2, `${id}: runner max HP at 0 s ${r.a}, at ${Math.round(r.t)} s ${r.b} (${r.n} runners alive)`);
  }
  expect((await ev(() => window.__dbg.diff(0))) === 'rec' && (await ev(() => window.__dbg.diff())) === 'rec', 'diff(0) switches the live tier');

  // ---- 2. hive pressure on Ветеран: amber at 15 s, red at 25 s, brutes on the stall clock, a beacon clears it
  await ev(() => { const d = window.__dbg; d.start('assault', { tier: 1, coach: false, seed: 0 }); d.god(true); });
  let t = await ev(() => { window.__dbg.fast(14); return window.__dbg.threat(); });
  await frame();
  let u = await hud();
  expect(t.state === 0 && !u.cls, `14 s idle: calm (press ${t.press}, hud '${u.cls}')`);
  t = await ev(() => { window.__dbg.fast(1.5); return window.__dbg.threat(); });
  u = await hud();
  expect(t.state === 1 && u.cls === 'press1' && u.text === 'Улей просыпается — к маяку' && u.bar, `15.5 s: amber press1 «${u.text}» (press ${t.press})`);
  t = await ev(() => { window.__dbg.fast(10); return window.__dbg.threat(); });
  u = await hud();
  expect(t.state === 2 && u.cls === 'press2' && u.urge && u.text === 'Рой стягивается — к маяку!', `25.5 s: red press2 + marker urge «${u.text}» (press ${t.press}, idleMul ${t.idleMul})`);
  if (h.args.shots) await h.shot('pressure');
  // AFK clock: counting with no input, reset by a key
  expect(t.afkT > 12, `AFK clock counts with no input: ${t.afkT} s`);
  await page.keyboard.down('KeyW');
  const afk = await ev(() => { window.__dbg.fast(0.1); return window.__dbg.threat().afkT; });
  await page.keyboard.up('KeyW');
  expect(afk === 0, 'AFK clock resets on a move key: ' + afk);
  // pause: no ticks, no pressure jump
  await page.keyboard.press('Escape'); await sleep(150);
  const p0 = await T(); await sleep(1500); const p1 = await T();
  const scr = (await h.stats()).screen;
  await page.keyboard.press('Escape'); await sleep(150);
  expect(scr === 'paused' && p0.press === p1.press, `paused 1.5 s: press ${p0.press} -> ${p1.press}`);
  // stall clock: brutes join while the squad loiters (TH.stall = 60 s on Ветеран)
  const brute = await ev(() => { const d = window.__dbg; for (let k = 0; k < 60; k++) { d.fast(1); const s = d.threat(); if (s.brutes > 0) return d.state().time; } return -1; });
  expect(brute > 0, `stall clock: first brute alive at ${brute} s without any objective progress`);
  // a beacon starts: the state clears at once
  t = await T();
  await ev(([x, z]) => { const d = window.__dbg; d.tp(x + 2.4, z); d.fast(0.3); }, t.beacon);
  t = await T();
  u = await hud();
  expect(t.state === 0 && !u.cls && !u.urge, `beacon started: pressure state cleared («${u.text}», press ${t.press})`);
  await ev(() => window.__dbg.god(false));

  // ---- 3. the Матка: boss HUD, the lift waits for her, the lift leaves ~4.6 s after she dies
  await ev(() => { const d = window.__dbg; d.start('assault', { tier: 1, coach: false, seed: 0 }); d.god(true); for (let k = 0; k < 4; k++) d.skip(); });
  const uid = await ev(() => window.__dbg.queen(1e6));
  t = await T();
  expect(uid > 0 && t.stage === 'hold' && t.queen.alive && t.queen.hpMax === 1e6, `queen() in the hold: uid ${uid}, hp ${t.queen.hp}`);
  await ev(() => window.__dbg.fast(3));
  u = await hud();
  expect(u.cls === 'boss' && u.text === 'Убейте Матку · лифт ждёт', `boss HUD «${u.text}» (${u.cls})`);
  if (h.args.shots) await h.shot('queen');
  t = await ev(() => { window.__dbg.fast(105); return window.__dbg.threat(); });
  const obj = (await h.stats()).objective;
  expect(t.stage === 'hold' && t.liftT > 0 && t.liftT <= 0.011 && obj === 'Лифт заблокирован — Матка жива', `lift timer out, she lives: stage ${t.stage}, liftT ${t.liftT}, «${obj}»`);
  const dt = await ev(() => {
    const d = window.__dbg; d.skip();
    const t0 = d.state().time;
    for (let k = 0; k < 200 && d.state().screen === 'playing'; k++) d.fast(0.05);
    return { s: d.state().screen, dt: +(d.state().time - t0).toFixed(2), q: d.threat().queen };
  });
  expect(dt.s === 'won' && dt.dt >= 4.4 && dt.dt <= 5.0 && dt.q.done && !dt.q.alive, `she dies -> won ${dt.dt} s later (${dt.s})`);

  // ---- 4. cryo: she never freezes (beam + nova), chill stays ≤ 0.5
  await ev(() => { const d = window.__dbg; d.start('cryo', { tier: 1, coach: false, seed: 0 }); d.god(true); d.auto(true); for (let k = 0; k < 4; k++) d.skip(); d.queen(1e6); });
  const fr = await ev(() => {
    const d = window.__dbg; let frz = 0, chill = 0, n = 0;
    for (let k = 0; k < 60; k++) { d.fast(0.25); const q = d.threat().queen; if (q.alive) { n++; frz = Math.max(frz, q.frz); chill = Math.max(chill, q.chill); } }
    const q = d.threat().queen; d.auto(false); d.god(false);
    return { frz, chill, n, hp: q.hp };
  });
  expect(fr.n > 50 && fr.frz === 0 && fr.chill <= 0.5 && fr.hp < 1e6, `cryo vs the Матка: max frz ${fr.frz}, max chill ${fr.chill} over ${fr.n} samples, she took ${1e6 - fr.hp} damage`);

  // ---- 4b. (calibration build only, harness/calib/mkcalib.mjs) the lift pulse: a brute beside her takes it, she does not
  if (await ev(() => !!window.__int)) {
    const pr = await ev(() => {
      const d = window.__dbg, I = window.__int, B = I.B;
      d.start('assault', { tier: 1, coach: false, seed: 0 }); d.god(true); for (let k = 0; k < 4; k++) d.skip(); d.queen(1e6); d.fast(3);
      I.TUR.on = false;
      let qi = -1; for (let i = 0; i < B.n; i++) if (B.uid[i] === I.DIR.q.uid) qi = i;
      const bi = I.spawnBug(2, B.x[qi] + 1.5, B.z[qi], 0);
      // only this pulse: no other blasts, shots or fire land on her during the check
      I.BOOMS.length = 0; B.burn.fill(0); I.rebuildHash();
      const q0 = B.hp[qi], b0 = B.hp[bi];
      I.queueBoom(B.x[qi], B.z[qi], 10.6, 48 * I.DIR.hpMul, -1, 'pulse');
      I.processBooms();
      return { q0, q1: B.hp[qi], b0, b1: B.dead[bi] ? 0 : B.hp[bi], frz: B.frz[qi] };
    });
    expect(pr.q1 === pr.q0 && pr.b1 < pr.b0, `lift pulse: Матка HP ${pr.q0} -> ${pr.q1}, brute beside her ${Math.round(pr.b0)} -> ${Math.round(pr.b1)}`);
    await ev(() => window.__dbg.god(false));
  }

  // ---- 5. skip() still wins every tier (the native scenario relies on it), and the sfx recipe plays
  for (const i of [0, 2]) {
    const w = await ev((i) => {
      const d = window.__dbg; d.start('gunner', { tier: i, coach: false, seed: 0 }); d.god(true);
      for (let k = 0; k < 16 && d.state().screen === 'playing'; k++) { d.skip(); d.fast(0.2); }
      d.god(false); return d.state().screen;
    }, i);
    expect(w === 'won', `tier ${i}: mission won via skip() -> ${w}`);
  }
  const sx = await ev(() => window.__dbg.sfxAll());
  expect(!sx.bad.length, `sfxAll incl. 'queen': ${sx.played} played, bad: ${sx.bad.join(', ') || 'none'}`);
  await ev(() => { window.__dbg.diff(1); window.__dbg.timeScale(1); });
};
