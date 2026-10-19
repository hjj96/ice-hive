// v1.1 package E regression: seeded stations («Станции»).
//   node harness/run.mjs --file dist/v11-e.html --scenario harness/scenarios/v11-stations.mjs [--phase gen,mem,render,ui]
// Phases (comma list; default gen,mem,render,ui):
//   gen     first-ever station is seed 0; seed 0 reproduces the hand-made layout exactly (walk / height hashes,
//           vertex count) after rebuilds; the in-page generator validates 40 seeds
//   mem     30 rebuilds on the title with frames between: GPU geometries / textures / programs stay flat; rebuild ms
//   render  start-view draw calls and triangles on seeds 0-4 (generated <= hand-made + 4 calls, level triangles <= hand-made)
//   ui      «↻» on the title, drop banner, report header, «Ещё раз» keeps the station, «Новая станция», reload keeps
//           the seed; never a rebuild while playing
//   ios     (--www --fake-ios --prefs '{"ledulei.seed":"37"}') boot restores the seed from Preferences; a new
//           station is mirrored back into Preferences
//   auto    autopilot full missions (--seeds 0,1,2,3,4 --cls assault --maxmin 14): every seed won, stuck 0, nobody off the grid
//   shots   single frames (--shot start|overview|title|end|lift, comma list): generated start view, overview of
//           seeds --seeds, title with the chip, end screen with «Новая станция», lift approach
export default async (page, h) => {
  const { log, fail, sleep } = h;
  const ev = (f, a) => page.evaluate(f, a);
  const D = (name, ...a) => ev(([n, args]) => window.__dbg[n](...args), [name, a]);
  const expect = (cond, msg) => { if (cond) log('[ok]', msg); else fail(msg); };
  const phases = String(h.args.phase || 'gen,mem,render,ui').split(',');
  const cls = h.args.cls || 'assault';
  const frames = (n = 2) => ev((k) => new Promise((r) => { const f = () => (--k <= 0 ? r() : requestAnimationFrame(f)); requestAnimationFrame(f); }), n);
  const waitIdle = async () => { for (let k = 0; k < 100; k++) { if (!(await D('station')).busy) return; await sleep(100); } fail('station rebuild never finished'); };
  const tap = async (sel) => {
    const v = await ev((s) => { const el = document.querySelector(s); if (!el) return null; const r = el.getBoundingClientRect(); return { w: r.width, x: r.x + r.width / 2, y: r.y + r.height / 2 }; }, sel);
    if (!v || !v.w) { fail('cannot tap ' + sel + ' (not visible)'); return; }
    if (h.mobile) await h.touch.tap(v.x, v.y); else await page.mouse.click(v.x, v.y);
    await sleep(200);
  };
  const text = (sel) => ev((s) => { const el = document.querySelector(s); return el ? el.textContent : null; }, sel);
  // finish the current mission with a win through the debug skips (simulation only)
  const winNow = async () => {
    for (let k = 0; k < 40; k++) {
      const s = await D('state');
      if (s.screen === 'won' || s.screen === 'lost') return s.screen;
      await D('skip'); await D('fast', 1);
    }
    return (await D('state')).screen;
  };
  const noRebuildWhilePlaying = async (tag) => {
    const st = await D('station');
    expect(st.refused === 0 && st.log.every((e) => e.screen !== 'playing'), `${tag}: no rebuild ever ran while playing (${st.log.length} rebuilds, screens ${[...new Set(st.log.map((e) => e.screen))].join('/')}, refused ${st.refused})`);
  };

  if (phases.includes('gen')) {
    const st = await D('station');
    const s0 = await D('state');
    expect(st.seed === 0 && s0.station === 'Кельвин-9' && st.log.length === 0, `first-ever start: seed ${st.seed} «${s0.station}», boot rebuilds ${st.log.length}`);
    const h0 = await D('levelHash');
    const a = await D('level', 7);
    const h7 = await D('levelHash');
    await D('level', 123);
    const b = await D('level', 0);
    const h0b = await D('levelHash');
    log('[gen] seed 7', JSON.stringify({ name: a.name, ms: a.ms, lift: a.lift, start: a.start }), 'hash', JSON.stringify(h7));
    expect(h7.walk !== h0.walk && a.name === 'Сектор И-1', `seed 7 is a different station «${a.name}»`);
    expect(h0b.walk === h0.walk && h0b.hgt === h0.hgt && h0b.verts === h0.verts && h0b.edges === h0.edges && b.name === 'Кельвин-9',
      `seed 0 after rebuilds reproduces the hand-made layout: walk ${h0.walk}/${h0b.walk}, hgt ${h0.hgt}/${h0b.hgt}, verts ${h0.verts}/${h0b.verts}, edges ${h0.edges}/${h0b.edges}`);
    const gens = await ev(() => { const out = []; for (let s = 1; s <= 40; s++) out.push(window.__dbg.gen(s)); return out; });
    const bad = gens.filter((g) => !g || !g.ok);
    const tours = gens.filter(Boolean).map((g) => g.tour).sort((x, y) => x - y);
    expect(!bad.length, `in-page generator: ${40 - bad.length}/40 seeds valid, tour p50 ${tours[20]} (range ${tours[0]}-${tours[tours.length - 1]})`);
  }

  if (phases.includes('mem')) {
    // each rebuild and one frame run in one call with the live loop frozen (the attract scene cannot create
    // first-use effect geometries in between), and the frame is the overview camera, so every level mesh is in view
    // and uploaded (a frustum-culled mesh is never uploaded, which would make the count depend on the layout)
    const step = (seed) => ev((s) => { const r = window.__dbg.level(s); window.__dbg.snap(true); return { ms: r.ms, ...window.__dbg.gpu() }; }, seed);
    const g0 = await step(0);
    const rows = [], ms = [];
    for (let k = 1; k <= 30; k++) {
      const r = await step(k % 3 ? 200 + k : 0);
      ms.push(r.ms);
      if (k % 10 === 0) rows.push({ k, geo: r.geo, tex: r.tex, progs: r.progs });
    }
    ms.sort((x, y) => x - y);
    log('[mem] start', JSON.stringify(g0), 'after', JSON.stringify(rows));
    expect(rows.every((r) => r.geo === g0.geo && r.tex === g0.tex && r.progs === g0.progs),
      `30 rebuilds: geometries ${g0.geo} -> ${rows.map((r) => r.geo).join('/')}, textures ${g0.tex} -> ${rows.map((r) => r.tex).join('/')}, programs ${g0.progs} -> ${rows.map((r) => r.progs).join('/')}`);
    log('[rebuild ms]', JSON.stringify({ n: ms.length, min: ms[0], p50: ms[Math.floor(ms.length / 2)], p90: ms[Math.floor(ms.length * 0.9)], max: ms[ms.length - 1] }));
    expect(ms[Math.floor(ms.length / 2)] <= 250 && ms[ms.length - 1] <= 450, `rebuild p50 ${ms[Math.floor(ms.length / 2)]} ms (<= 250), max ${ms[ms.length - 1]} ms (<= 450)`);
  }

  if (phases.includes('render')) {
    const seeds = [0, 1, 2, 3, 4];
    const res = [];
    for (const s of seeds) {
      await D('level', s, cls);
      await sleep(900);
      const one = await D('snap');   // one hand-drawn start-view frame, loop frozen
      const hs = await D('levelHash');
      res.push({ seed: s, draw: one.draw, tris: one.tris, levelTris: Math.round(hs.verts / 3) });
      await ev(() => { window.__dbg.state(); });
    }
    log('[render]', JSON.stringify(res));
    // v1.0 «Кельвин-9» measured the same way (1280x720, high, one frame 0.9 s after the drop): 55 calls, 40158
    // start-view triangles, 39323 level triangles
    const V10 = { draw: 55, tris: 40158, levelTris: 39323 };
    const h0 = res[0];
    expect(h0.draw <= V10.draw && h0.levelTris <= V10.levelTris, `seed 0: ${h0.draw} calls, ${h0.levelTris} level triangles (v1.0 ${V10.draw}, ${V10.levelTris})`);
    for (const r of res.slice(1)) {
      expect(r.draw <= h0.draw + 4, `seed ${r.seed}: start-view draw calls ${r.draw} <= hand-made ${h0.draw} + 4`);
      expect(r.tris <= V10.tris && r.levelTris <= V10.levelTris, `seed ${r.seed}: start-view triangles ${r.tris}, level triangles ${r.levelTris} <= v1.0 hand-made ${V10.tris} / ${V10.levelTris} (this build's seed 0: ${h0.tris} / ${h0.levelTris})`);
    }
    await D('level', 0);
  }

  if (phases.includes('ui')) {
    await D('level', 0);
    await sleep(300);
    expect((await text('#tStName')) === 'Станция Кельвин-9 · −94 °C', 'title meta: ' + (await text('#tStName')));
    // «↻» on the title
    await tap('#tStNew');
    await waitIdle();
    let st = await D('station');
    const s1 = st.seed;
    expect(s1 !== 0 && st.saved === s1 && st.log[st.log.length - 1].screen === 'title', `«↻»: new station ${s1} «${st.name}», saved ${st.saved}`);
    expect((await text('#tStName')) === 'Станция ' + st.name + ' · −94 °C', 'title meta after «↻»: ' + (await text('#tStName')));
    // a mission on it: drop banner names the station
    await D('start', cls);
    await sleep(300);
    const sub = await text('#bnS');
    expect((await D('state')).station === st.name && sub === st.name + ' · запустите три маяка', 'drop banner: ' + sub);
    expect(await winNow() === 'won', 'mission won through skips');
    await sleep(300);
    expect((await text('#eTag')) === 'Отчёт миссии · ' + st.name, 'report header: ' + (await text('#eTag')));
    const vis = await ev(() => { const b = document.getElementById('eNew'); const r = b.getBoundingClientRect(); return !b.hidden && r.width > 0; });
    expect(vis, '«Новая станция» is visible on the end screen');
    // «Ещё раз» keeps the station
    const n0 = (await D('station')).log.length;
    await tap('#eAgain');
    await sleep(300);
    st = await D('station');
    expect((await D('state')).screen === 'playing' && st.seed === s1 && st.log.length === n0, `«Ещё раз»: same station ${st.seed}, rebuilds ${n0} -> ${st.log.length}`);
    expect(await winNow() === 'won', 'second mission won');
    await sleep(300);
    // «Новая станция»: fresh seed, mission starts on it
    await tap('#eNew');
    await waitIdle();
    await sleep(300);
    st = await D('station');
    const s2 = st.seed;
    const s = await D('state');
    expect(s.screen === 'playing' && s2 !== s1 && st.saved === s2 && s.station === st.name && st.log[st.log.length - 1].screen === 'won',
      `«Новая станция»: ${s1} -> ${s2} «${st.name}», screen ${s.screen}, rebuilt on '${st.log[st.log.length - 1].screen}'`);
    await noRebuildWhilePlaying('ui');
    // a mission start while playing must not rebuild (the request is refused, the current station stays)
    await ev(() => window.__dbg.start('pyro', { seed: 999 }));
    st = await D('station');
    expect(st.seed === s2 && st.refused === 1, `start while playing: rebuild refused (seed ${st.seed}, refused ${st.refused})`);
    // reload: the saved seed comes back behind the loading screen
    await page.reload({ waitUntil: 'load' });
    await sleep(2500);
    st = await D('station');
    expect(st.seed === s2 && (await D('state')).station === st.name && st.log.length === 1 && st.log[0].screen === 'title' && (await text('#tStName')).includes(st.name),
      `reload: station ${st.seed} «${st.name}» restored at boot (${st.log.length} rebuild on '${st.log[0] && st.log[0].screen}')`);
    if (h.native && h.args['fake-ios']) {
      const p = await h.native.prefs();
      expect(p['ledulei.seed'] === JSON.stringify(s2), 'iOS Preferences mirror ledulei.seed = ' + p['ledulei.seed']);
    }
  }

  if (phases.includes('ios')) {
    const want = Number(h.args.seed || 37);
    let st = await D('station');
    expect(st.seed === want && st.log.length === 1, `boot restored seed ${want} from Preferences: station ${st.seed} «${st.name}»`);
    await D('newStation');
    st = await D('station');
    const p = await h.native.prefs();
    expect(p['ledulei.seed'] === JSON.stringify(st.seed) && st.seed !== want, `new station ${st.seed} mirrored to Preferences: ${p['ledulei.seed']}`);
  }

  if (phases.includes('auto')) {
    const seeds = String(h.args.seeds || '0,1,2,3,4').split(',').map(Number);
    const maxMin = +(h.args.maxmin || 14);
    const out = [];
    for (const seed of seeds) {
      await D('level', seed, cls);
      let r;
      for (let k = 0; k < maxMin; k++) { r = await D('run', 60); if (r.screen !== 'paused' && r.screen !== 'playing') break; }
      out.push({ seed, ...r });
      log('[auto]', seed, cls, JSON.stringify(r));
      expect(r.screen === 'won' && r.stuck === 0 && r.off === 0, `seed ${seed}: ${r.screen} at ${r.t} s, downs ${r.downs}, stuck ${r.stuck}, off-grid samples ${r.off}`);
      await D('level', 0);
    }
    await noRebuildWhilePlaying('auto');
  }

  if (phases.includes('shots')) {
    const want = String(h.args.shot || 'start,overview,title,end,lift').split(',');
    const seeds = String(h.args.seeds || '3,11').split(',').map(Number);
    if (want.includes('title')) {
      await D('level', seeds[0]);
      await sleep(1500);
      log('[snap]', JSON.stringify(await D('snap')));
      await h.shot('title-chip');
    }
    if (want.includes('start')) {
      await D('level', seeds[0], cls);
      await sleep(1500);
      log('[snap]', JSON.stringify(await D('snap')));
      await h.shot('start-seed' + seeds[0]);
    }
    if (want.includes('lift')) {
      await D('level', seeds[0], cls);
      await sleep(300);
      const L = (await D('level', seeds[0], cls)).lift;
      await D('tp', L.x, L.z + L.r + 6);
      await sleep(1200);
      log('[snap]', JSON.stringify(await D('snap')));
      await h.shot('lift-seed' + seeds[0]);
    }
    if (want.includes('overview')) for (const s of seeds) {
      await D('level', s, cls);
      await sleep(600);
      await ev(() => { for (const id of ['hud', 'plates', 'marker', 'touchUI', 'banner', 'toasts']) { const e = document.getElementById(id); if (e) e.style.visibility = 'hidden'; } });
      log('[snap overview]', s, JSON.stringify(await D('snap', true)));
      await h.shot('overview-seed' + s);
      await ev(() => { for (const id of ['hud', 'plates', 'marker', 'touchUI', 'banner', 'toasts']) { const e = document.getElementById(id); if (e) e.style.visibility = ''; } });
    }
    if (want.includes('end')) {
      await D('level', seeds[0], cls);
      await winNow();
      await sleep(600);
      await h.shot('end-new-station');
    }
  }
};
