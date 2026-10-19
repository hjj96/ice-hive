// ================================================================
//  STATIONS — seeded station layouts (v1.1, package E)
//  Seed 0 is the hand-made «Кельвин-9» (the first-ever mission and the coach); any other seed is a generated
//  «Сектор Д-17». store 'seed' holds the station for the next mission; «Ещё раз» keeps it. The layout is
//  rebuilt in place (04-level.js rebuildLevel) only at boot behind #sLoad, on a menu tap behind the
//  «Стыковка…» cover, or in startMission before the world reset — never while a mission is running.
// ================================================================
// stationBoot() runs once in boot() before the first resetWorld; stationPrepare(opts) runs in startMission
// (opts.seed) before resetWorld; stationLabel() is the station name shown in banners, the title and the report.
let STATION = { seed: 0, name: 'Кельвин-9' };
const ST_LOG = [];                // the last rebuilds: { seed, ms, screen } (tests check none ran mid-mission)
let stBusy = false, stRefused = 0;
function stationName(seed) { return seed ? 'Сектор ' + 'АБВГДЕЖИКЛМН'[seed % 12] + '-' + (1 + (seed >> 4) % 99) : 'Кельвин-9'; }
function stationLabel() { return STATION.name; }
function stationSeedOf(v) { v = Math.floor(+v); return v > 0 && v < 0x40000000 ? v : 0; }
function stationSaved() { return stationSeedOf(store.get('seed', 0)); }
// the only path to a rebuild; refused mid-mission (the caller keeps the current station)
function stationBuild(seed) {
  if (GS.screen === 'playing') { stRefused++; return -1; }
  const ms = rebuildLevel(stationSeedOf(seed));
  STATION.seed = levelSeed; STATION.name = stationName(levelSeed);
  ST_LOG.push({ seed: levelSeed, ms: +ms.toFixed(1), screen: GS.screen });
  if (ST_LOG.length > 64) ST_LOG.shift();
  store.set('seed', STATION.seed);
  stationUI();
  return ms;
}
function stationUI() {
  $('tStName').textContent = 'Станция ' + STATION.name + ' · −94 °C';
  $('eTag').textContent = 'Отчёт миссии · ' + STATION.name;
}
// a fresh station: paint the «Стыковка…» cover, wait two frames so it is on screen, rebuild, resolve with the seed
function newStation() {
  if (stBusy) return Promise.resolve(STATION.seed);
  stBusy = true;
  let seed = STATION.seed;
  while (seed === STATION.seed) seed = 1 + Math.floor(Math.random() * 0xfffff);
  const cover = $('stDock');
  cover.lastChild.textContent = stationName(seed);
  cover.hidden = false;
  return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => {
    try { stationBuild(seed); } finally { stBusy = false; cover.hidden = true; }
    resolve(STATION.seed);
  })));
}
function stationBoot() {
  const cover = document.createElement('div');
  cover.id = 'stDock'; cover.hidden = true;
  cover.innerHTML = '<div class="sd-m">Стыковка…</div><div class="sd-s"></div>';
  document.body.appendChild(cover);
  // title «↻»: another station for the attract scene and the next sortie
  onTap($('tStNew'), () => {
    if (GS.screen !== 'title' || stBusy) return;
    audioInit(); sfx('click');
    newStation().then(() => { if (GS.screen === 'title') resetWorld(GS.cls, true); });
  });
  // end screen «Новая станция»: a fresh station, same class (D places and styles the button)
  const bNew = $('eNew');
  bNew.hidden = false;
  onTap(bNew, () => {
    if ((GS.screen !== 'won' && GS.screen !== 'lost') || stBusy) return;
    sfx('click');
    newStation().then(() => { if (GS.screen === 'won' || GS.screen === 'lost') startMission(GS.cls); });
  });
  // the saved station (the boot loading screen is still up, so the rebuild is hidden)
  const s = stationSaved();
  if (s !== STATION.seed) stationBuild(s);
  stationUI();
}
function stationPrepare(opts) {
  const want = opts && opts.seed != null ? stationSeedOf(opts.seed) : stationSaved();
  if (want !== STATION.seed) stationBuild(want);
}

// ---------- debug helpers (tests) ----------
let stW = null;
function stProbeReset() { stW = { stuck: 0, still: 0, lx: M[0].x, lz: M[0].z, off: 0, downs: 0, was: [0, 0, 0, 0], stageAt: {}, last: '' }; }
function stHash(a) { let h = 0x811c9dc5; for (let i = 0; i < a.length; i++) h = Math.imul(h ^ a[i], 0x01000193); return (h >>> 0).toString(16); }
window.__dbgExt = Object.assign(window.__dbgExt || {}, {
  // rebuild the station from a seed (0 = «Кельвин-9»), then start a mission on it (cls) or refresh the title scene
  level(seed = 0, cls) {
    if (GS.screen !== 'title' && GS.screen !== 'won' && GS.screen !== 'lost') goTitle();
    const ms = stationBuild(seed);
    if (cls) startMission(cls, { coach: false, seed: STATION.seed }); else if (GS.screen === 'title') resetWorld(GS.cls, true);
    stProbeReset();
    return { seed: STATION.seed, name: STATION.name, ms: +ms.toFixed(1), beacons: LV.beacons.map(b => ({ ...b })), lift: { ...LV.lift }, start: { ...LV.start } };
  },
  // generator only (no rebuild): validation numbers for a seed
  gen(seed) { const L = genLevel(seed | 0); return L ? { attempts: L.attempts, ...L.check } : null; },
  // fingerprint of the live layout: walk grid, height field, level vertex count
  levelHash() {
    let verts = 0;
    for (const g of [level, liftDeck]) for (const o of g.children) verts += o.geometry.attributes.position.count;
    return { walk: stHash(walk), hgt: stHash(new Uint8Array(hgt.buffer)), verts, edges: LV.edgeN, seed: levelSeed };
  },
  station() { return { seed: STATION.seed, name: STATION.name, saved: store.get('seed', null), refused: stRefused, log: ST_LOG.slice(), busy: stBusy }; },
  newStation() { return newStation().then(() => this.station()); },
  gpu() { return { geo: renderer.info.memory.geometries, tex: renderer.info.memory.textures, progs: renderer.info.programs.length }; },
  // autopilot for sec simulated seconds (no rendering); between calls the live loop stays frozen
  run(sec = 60) {
    if (GS.screen === 'paused') GS.screen = 'playing';
    if (!stW) stProbeReset();
    const W = stW;
    autoPlayer = true;
    for (let s = 0; s < sec && GS.screen === 'playing'; s++) {
      for (let k = 0; k < 60 && GS.screen === 'playing'; k++) {
        tick(DT);
        while (GS.pendingLevels > 0) { applyUpgrade(rollUpgrades()[0]); GS.pendingLevels--; }
        const st = DIR.stage + (DIR.stage === 'beacons' ? DIR.done + (DIR.active >= 0 ? 'h' : 'w') : '');
        if (st !== W.last) { W.last = st; W.stageAt[st] = Math.round(GS.time); }
        for (let m = 0; m < 4; m++) { const d = M[m].downed ? 1 : 0; if (d && !W.was[m]) W.downs++; W.was[m] = d; }
      }
      const P = M[0];
      // the player not moving 1 m in 10 s while not holding an objective = stuck
      if (!P.downed && Math.hypot(P.x - W.lx, P.z - W.lz) < 1 && DIR.active < 0 && DIR.stage !== 'hold' && DIR.stage !== 'extract') W.still++; else W.still = 0;
      if (W.still >= 10) { W.stuck++; W.still = 0; }
      W.lx = P.x; W.lz = P.z;
      for (const m of M) if (!walkable(m.x, m.z)) W.off++;
    }
    if (GS.screen === 'playing') GS.screen = 'paused';
    return { t: Math.round(GS.time), screen: GS.screen, stage: DIR.stage, done: DIR.done, stuck: W.stuck, off: W.off, downs: W.downs, stageAt: W.stageAt };
  },
});
