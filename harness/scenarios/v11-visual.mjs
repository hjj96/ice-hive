// v1.1 package B (visual readability) regression + capture scenario.
//   node harness/run.mjs --file dist/artifact.html --scenario harness/scenarios/v11-visual.mjs --mobile [--landscape] [--phase P] [--cls C]
// Phases (--phase, default 'check'):
//   check   numeric regression, no screenshots: telegraph underlays follow their source meshes, the brute lane stops at
//           the deck edge, beacon state 0 is cold blue, the queen tint lands on DIR.q.uid, marine animation fields stay
//           bounded, the bug program stays shared, one extra program at most
//   perf    draw calls over 60 rendered frames in a 700-bug horde ('med'), distinct GL programs used, __dbg.bench
//   pool    lit swarm pool (flashlight / flame on a packed crowd) -> 1 shot; crop it with harness/tools/hue.py
//   horde   portrait horde in the flashlight with the squad bunched -> 1 shot (marine colours + magenta share)
//   tele    brutes, spitters, boomers and a console 4.2x queen next to beacon 0 -> 1 shot
//   states  cryo nova on ~300 bugs, a napalm burn, corpses and stains -> 1 shot
//   desk    desktop 'high' (bloom) close shot of the squad, one bot downed -> 1 shot
// Phases that work on a v1.0 build too (pool, horde, perf) only use the public __dbg API.

// In-page helper library (installed with page.evaluate): staging and numeric checks over the live handles that
// __dbg.vx() returns (package B keeps only that small accessor in the shipped build).
function installLib() {
  const X = window.__dbg.vx(), F = X.fn, { THREE, B, M, DIR, LV, TELE } = X, TAU = Math.PI * 2;
  const L = {
    programs() { return X.renderer.info.programs ? X.renderer.info.programs.length : -1; },
    ndc(x, y, z) { const v = new THREE.Vector3(x, y, z).project(X.camera); return [+v.x.toFixed(2), +v.y.toFixed(2)]; },
    // a console queen before package A lands: a 4.2x brute whose uid is DIR.q.uid
    queen(x, z) {
      const P = M[0];
      if (x === undefined) { x = P.x + X.FWD_X * 6; z = P.z + X.FWD_Z * 6; }
      const i = F.spawnBug(X.BRUTE, x, z, 0);
      if (i < 0) return -1;
      B.sc[i] = 4.2; B.r[i] = 1.5; B.hp[i] = B.hpMax[i] = 1e6; B.cd[i] = 0.5;
      DIR.q.uid = B.uid[i];
      return i;
    },
    // a walkable point at distance [d0, d1] from (x, z) whose straight run to the deck edge is 3..9 m
    edgeSpot(x, z, d0 = 4, d1 = 12) {
      for (let r = d0; r <= d1; r += 1) for (let a = 0; a < 16; a++) {
        const px = x + Math.cos(a / 16 * TAU) * r, pz = z + Math.sin(a / 16 * TAU) * r;
        if (!F.walkable(px, pz)) continue;
        for (let b = 0; b < 8; b++) {
          const dx = Math.cos(b / 8 * TAU), dz = Math.sin(b / 8 * TAU);
          let d = 0; while (d + 0.5 <= 12 && F.walkable(px + dx * (d + 0.5), pz + dz * (d + 0.5))) d += 0.5;
          const c = F.cellOf(px + dx * (d + 0.5), pz + dz * (d + 0.5));
          if (d >= 3 && d <= 9 && c >= 0 && X.walk[c] === 0) return { x: px, z: pz, dx, dz, d };
        }
      }
      return null;
    },
    selfTest() {
      const fails = [], out = {}, t = X.renderTime, P = M[0];
      // 1) underlays follow their source meshes and share their matrices; the brute lane stops at the deck edge
      for (const e of TELE) e.on = false;
      F.teleRing(P.x, P.z, 2, 1, 0.2, 0.1, 1); F.teleFill(P.x + 2, P.z, 2, 0.5, 0.85, 0.08, 1);
      const es = L.edgeSpot(P.x, P.z, 0, 30);
      if (!es) fails.push('no deck-edge spot found near the player');
      else {
        F.teleLane(es.x, es.z, es.dx, es.dz, 12, 2.3, 0.8, 0.9);
        const lane = TELE.find(e => e.on && e.kind === 1);
        out.lane = { want: es.d, got: lane ? lane.len : -1 };
        if (!lane || Math.abs(lane.len - Math.max(es.d, 1)) > 1e-6) fails.push('brute lane does not stop at the deck edge: ' + JSON.stringify(out.lane));
      }
      F.updateTelegraphs(0.001, t);
      out.under = X.teleUnders.map(([tm, u]) => [tm.count, u.count, u.instanceMatrix === tm.instanceMatrix]);
      for (const [tm, u] of X.teleUnders) if (u.count !== tm.count || u.instanceMatrix !== tm.instanceMatrix || !tm.count) fails.push('underlay out of sync ' + JSON.stringify(out.under));
      if (X.teleLaneMesh.material.depthTest !== false || X.teleLaneMesh.renderOrder !== 5) fails.push('lane is not drawn over bodies');
      for (const e of TELE) e.on = false;
      F.updateTelegraphs(0.001, t);
      if (X.teleUnders.some(([, u]) => u.count)) fails.push('underlays left on after the telegraphs ended');
      // 2) glare budget: a splash at the player's feet is clamped to 0.35 per channel
      const n0 = X.splN; F.splashNow(P.x, P.z, 3, 1, 0.9, 0.2);
      if (X.splN > n0) { const c = X.splashMesh.instanceColor.array; out.splash = [c[n0 * 3], c[n0 * 3 + 1], c[n0 * 3 + 2]].map(v => +v.toFixed(3)); if (Math.max(...out.splash) > 0.35 + 1e-6) fails.push('splash near the player not clamped'); X.splN = n0; }
      // 3) beacon state 0 reads cold blue and the top marker follows
      F.renderFx(0, t);
      const b0 = DIR.beacons.findIndex(b => b.state === 0);
      if (b0 >= 0) {
        const u = X.beaconFx[b0].ind.material.uniforms, c = u.uCol.value, tc = X.beaconFx[b0].top.material.color;
        out.beacon0 = { col: [c.r, c.g, c.b].map(v => +v.toFixed(2)), alpha: u.uAlpha.value, top: [tc.r, tc.g, tc.b].map(v => +v.toFixed(2)) };
        if (!(c.b > c.g && c.g > c.r && Math.abs(u.uAlpha.value - 0.6) < 1e-6 && tc.b > tc.r)) fails.push('beacon state 0 is not cold blue ' + JSON.stringify(out.beacon0));
      }
      // 4) the queen tint lands on DIR.q.uid only, and a 4.2x body just off screen is still drawn (no edge popping)
      const qi = L.queen();
      if (qi < 0) fails.push('could not spawn the test queen');
      else {
        const find = () => { const mesh = X.bugMeshes[X.BRUTE], an = mesh.geometry.attributes.iAnim.array; let q = -1, n = 0; for (let k = 0; k < mesh.count; k++) if (an[k * 4 + 3] === -1) { q = k; n++; } return { q, n, mesh }; };
        F.writeBugInstances(t, 0);
        let f = find();
        if (f.q < 0 || f.n !== 1) fails.push('queen tint not found exactly once (' + f.n + ')');
        else { const c = f.mesh.instanceColor.array; out.queenCol = [c[f.q * 3], c[f.q * 3 + 1], c[f.q * 3 + 2]].map(v => +v.toFixed(2)); if (!(out.queenCol[2] > out.queenCol[0] && out.queenCol[0] > out.queenCol[1])) fails.push('queen colour is not violet'); }
        // her centre 1.3 half-widths right of the screen centre (outside the 1.15 margin a small bug gets)
        const o = X.camera.position, dir = new THREE.Vector3(1.3, 0, 0.5).unproject(X.camera).sub(o).normalize();
        const gy = F.groundY(B.x[qi], B.z[qi]) + 0.3 * 4.2, s = (gy - o.y) / dir.y;
        B.x[qi] = o.x + dir.x * s; B.z[qi] = o.z + dir.z * s;
        F.writeBugInstances(t, 0);
        f = find(); out.queenOffscreenDrawn = f.q >= 0;
        if (f.q < 0) fails.push('4.2x queen just off screen is culled (edge popping)');
        B.sc[qi] = 1.0; F.writeBugInstances(t, 0); out.smallOffscreenCulled = find().q < 0;   // control: a small bug there is culled
        if (!out.smallOffscreenCulled) fails.push('control: a 1x bug at 1.3 half-widths should be culled');
        DIR.q.uid = 0; F.killBug(qi, -1);
      }
      // 5) poses: downed lies back, the revive raises it to -0.9, a revived marine stands up in 0.4 s, edge light halves while down
      const m = M[1] || M[0], rim0 = X.MARINE_RIM[m.i].r;
      if (!('leanX' in m && 'leanZ' in m && 'upT' in m && 'visDown' in m)) fails.push('marine pose fields missing');
      m.downed = true; m.revive = 0;
      for (let k = 0; k < 30; k++) F.renderMarines(1, 1 / 60);
      out.downed = { rx: +m.mesh.rotation.x.toFixed(2), rim: +(X.MARINE_RIM[m.i].r / rim0).toFixed(2) };
      if (Math.abs(m.mesh.rotation.x + 1.35) > 0.05 || Math.abs(X.MARINE_RIM[m.i].r / rim0 - 0.5) > 1e-6) fails.push('downed pose / rim wrong ' + JSON.stringify(out.downed));
      m.revive = 1; for (let k = 0; k < 40; k++) F.renderMarines(1, 1 / 60);
      out.reviving = +m.mesh.rotation.x.toFixed(2);
      if (Math.abs(out.reviving + 0.9) > 0.05) fails.push('revive pose does not rise to -0.9: ' + out.reviving);
      m.downed = false; m.revive = 0; m.hurtT = 0; m.dashT = 0;
      F.renderMarines(1, 1 / 60); const first = m.mesh.rotation.x;
      for (let k = 0; k < 30; k++) F.renderMarines(1, 1 / 60);
      out.standUp = { first: +first.toFixed(2), after05s: +m.mesh.rotation.x.toFixed(2), rim: +(X.MARINE_RIM[m.i].r / rim0).toFixed(2) };
      if (first > -0.7 || Math.abs(m.mesh.rotation.x) > 0.15 || Math.abs(X.MARINE_RIM[m.i].r / rim0 - 1) > 1e-6) fails.push('stand-up wrong ' + JSON.stringify(out.standUp));
      // a running, strafing, hurt, firing marine stays within 0.15 rad; a dash leans into the slide
      let worst = 0;
      const sv = [m.vx, m.vz, m.hurtT, m.muzzle, m.firing];
      for (let k = 0; k < 60; k++) {
        m.vx = 5.3 * Math.cos(k); m.vz = 5.3 * Math.sin(k * 1.3); m.hurtT = k % 10 ? 0 : 0.22; m.muzzle = 1; m.firing = true;
        F.renderMarines(1, 1 / 60);
        worst = Math.max(worst, Math.abs(m.mesh.rotation.x), Math.abs(m.mesh.rotation.z), Math.abs(m.gun.rotation.x), Math.abs(m.gun.rotation.y));
      }
      m.dashT = 0.22; for (let k = 0; k < 12; k++) F.renderMarines(1, 1 / 60);
      out.dash = { rx: +m.mesh.rotation.x.toFixed(2), bodyY: +m.body.position.y.toFixed(2) };
      m.dashT = 0;
      [m.vx, m.vz, m.hurtT, m.muzzle, m.firing] = sv;
      out.maxAngle = +worst.toFixed(3);
      if (worst > 0.15 + 1e-6) fails.push('pose angle above 0.15 rad: ' + worst);
      if (out.dash.rx < 0.4) fails.push('dash slide pose missing ' + JSON.stringify(out.dash));
      // 6) programs: the bug material keeps its one shared program; marines use the rim variant; phone scale
      out.bugKey = X.MAT.bug.customProgramCacheKey(); out.marineKey = M[0].mat.customProgramCacheKey();
      if (out.bugKey !== 'bug' || !/r$/.test(out.marineKey)) fails.push('program keys ' + out.bugKey + ' / ' + out.marineKey);
      out.programs = L.programs();
      out.scale = M[0].mesh.scale.x;
      if (Math.abs(out.scale - (X.IS_MOBILE ? 1.3 : 1.12)) > 1e-6) fails.push('marine scale ' + out.scale);
      return { fails, out };
    },
    // tele capture: squad next to an unvisited beacon (outside the ring), a deck-edge lane with bodies on it,
    // brutes / spitters / boomers and the console queen
    stageTele() {
      const bk = DIR.beacons.findIndex(b => b.state === 0), b = DIR.beacons[bk];
      let px = b.x - X.FWD_X * 8, pz = b.z - X.FWD_Z * 8;
      if (!F.walkable(px, pz)) { px = b.x - X.FWD_X * 6 + X.RIGHT_X * 2; pz = b.z - X.FWD_Z * 6 + X.RIGHT_Z * 2; }
      window.__dbg.tp(px, pz);
      window.__dbg.spawn(3, 'brute'); window.__dbg.spawn(8, 'spitter'); window.__dbg.spawn(3, 'boomer'); window.__dbg.spawn(60);
      const q = L.queen(px + X.RIGHT_X * 5 + X.FWD_X * 3, pz + X.RIGHT_Z * 5 + X.FWD_Z * 3);
      window.__dbg.fast(2.0);
      const es = L.edgeSpot(px, pz, 3, 14);
      if (es) {
        F.teleLane(es.x, es.z, es.dx, es.dz, 12, 2.3, 30, 1);
        for (let k = 1; k <= 3; k++) { const i = F.spawnBug(X.RUN, es.x + es.dx * k * 1.2, es.z + es.dz * k * 1.2, 0); if (i >= 0) B.spd[i] = 0.01; }
      }
      return { beacon: bk, at: [+px.toFixed(1), +pz.toFixed(1)], queen: q, lane: es };
    },
    teleInfo() {
      let qi = -1; for (let i = 0; i < B.n; i++) if (!B.dead[i] && B.uid[i] === DIR.q.uid) qi = i;
      const b = DIR.beacons.find(b => b.state === 0) || DIR.beacons[0];
      const lanes = TELE.filter(e => e.on && e.kind === 1).map(e => ({ len: e.len, start: L.ndc(e.x, e.y, e.z), end: L.ndc(e.x + e.dx * e.len, e.y1, e.z + e.dz * e.len) }));
      return { rings: X.teleRingMesh.count, fills: X.teleFillMesh.count, lanes, under: X.teleUnders.map(([, u]) => u.count),
        beacon: { state: b.state, ndc: L.ndc(b.x, 0, b.z) }, queen: qi >= 0 ? { ndc: L.ndc(B.x[qi], F.groundY(B.x[qi], B.z[qi]) + 1, B.z[qi]), st: B.st[qi] } : null,
        player: L.ndc(M[0].x, M[0].mesh.position.y + 1, M[0].z) };
    },
    // states capture: a frozen crowd (cryo nova) next to a napalm burn (orange glands), corpses and stains on the deck
    stageStates() {
      const P = M[0];
      window.__dbg.tp(LV.start.x, LV.start.z);
      window.__dbg.spawn(220);
      window.__dbg.fast(1.2);
      let k = 0; for (let i = 0; i < B.n && k < 40; i++) if (!B.dead[i] && F.rnd() < 0.3) { F.killBug(i, 0); k++; }
      window.__dbg.spawn(160);
      window.__dbg.fast(1.0);
      P.abCd = 0; F.useAbility(P, P.x, P.z);
      const nx = P.x + X.FWD_X * 7, nz = P.z + X.FWD_Z * 7, n = X.NAP[0];
      n.on = true; n.x = nx; n.z = nz; n.r = 4; n.t = 5; n.own = 1;
      for (let i = 0; i < B.n; i++) if (!B.dead[i] && (B.x[i] - nx) ** 2 + (B.z[i] - nz) ** 2 < 16) { B.burn[i] = 5; B.frz[i] = 0; B.chill[i] = 0; }
      F.fxNapalmBurst(nx, nz, 4);
      window.__dbg.timeScale(0.05);
      return L.statesInfo();
    },
    statesInfo() { let alive = 0, frozen = 0, burning = 0; for (let i = 0; i < B.n; i++) if (!B.dead[i]) { alive++; if (B.frz[i] > 0) frozen++; if (B.burn[i] > 0) burning++; } return { alive, frozen, burning, corpses: X.corpseMeshes.map(c => c.mesh.count), decals: X.decFill }; },
    // desktop capture: squad close-up on 'high' (bloom), one squadmate downed, a few bugs around
    stageDesk() {
      window.__dbg.tp(LV.start.x - 4, LV.start.z - 4);
      window.__dbg.spawn(40);
      window.__dbg.fast(1.0);
      const m = M[2]; if (m) { m.downed = true; m.revive = 0.3; m.hp = 0; }
      return L.marineInfo();
    },
    marineInfo() { return M.map(m => ({ cls: m.cls, downed: m.downed, scale: m.mesh.scale.x, rx: +m.mesh.rotation.x.toFixed(2), rz: +m.mesh.rotation.z.toFixed(2), rim: [X.MARINE_RIM[m.i].r, X.MARINE_RIM[m.i].g, X.MARINE_RIM[m.i].b].map(v => +v.toFixed(3)), ndc: L.ndc(m.x, m.mesh.position.y + 1, m.z) })); },
  };
  window.__vx = L;
  return true;
}

export default async (page, h) => {
  const phase = h.args.phase || 'check';
  const cls = h.args.cls || (phase === 'pool' ? 'pyro' : 'assault');
  const ev = (fn, arg) => page.evaluate(fn, arg);
  const lvl = async () => { for (let k = 0; k < 6 && (await h.stats()).screen === 'levelup'; k++) { await page.keyboard.press('Digit1'); await h.sleep(300); } };
  const info = async (tag) => { const s = await h.stats(); h.log('[' + tag + ']', JSON.stringify({ alive: s.bugsAlive, dc: s.drawCalls, q: s.quality, screen: s.screen })); return s; };
  const W = h.width, H = h.height;
  const aimStick = async (dx, dy) => {
    if (h.mobile) { const R = { x: W * 0.78, y: H * 0.78, id: 2 }; await h.touch.start([R]); await h.touch.move([{ x: R.x + dx, y: R.y + dy, id: 2 }]); }
    else { await page.mouse.move(W * 0.5 + dx * 4, H * 0.5 + dy * 4); await page.mouse.down(); }
  };
  const release = async () => { if (h.mobile) await h.touch.end(); else await page.mouse.up(); };
  const hasVx = await ev(() => !!(window.__dbg && window.__dbg.vx));
  if (hasVx) await ev(installLib);

  if (phase === 'check') {
    if (!hasVx) { h.fail('__dbg.vx missing (package B debug helpers)'); return; }
    await ev((c) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); }, cls);
    await h.sleep(800);
    const r = await ev(() => window.__vx.selfTest());
    h.log('[vx-check]', JSON.stringify(r));
    for (const f of r.fails) h.fail(f);
    // a few rendered frames with telegraphs + a horde on screen: no errors, draw calls in budget
    await ev(() => { const d = window.__dbg; d.tp(0, 28); d.spawn(4, 'brute'); d.spawn(6, 'spitter'); d.spawn(3, 'boomer'); d.horde(300); d.fast(2.5); });
    await h.sleep(1500);
    const s = await info('check-frame');
    if (h.mobile && s.drawCalls >= 80) h.fail('mobile draw calls ' + s.drawCalls + ' >= 80');
    return;
  }

  if (phase === 'perf') {
    await ev(() => {
      const P = WebGL2RenderingContext.prototype, use = P.useProgram;
      window.__progs = new Set();
      P.useProgram = function (p) { if (p) window.__progs.add(p); return use.call(this, p); };
    });
    await ev((c) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); d.fast(1); d.tp(30, -8); d.horde(700); d.fast(5); }, cls);
    await aimStick(-40, -34);
    await h.sleep(1000);
    await ev(() => window.__dbg.timeScale(0.05));
    await lvl();
    await h.sleep(300);
    const dc = await ev(() => new Promise((res) => {
      const v = []; let n = 0;
      const f = () => { v.push(window.__dbg.state().drawCalls); if (++n < 60) requestAnimationFrame(f); else res(v); };
      requestAnimationFrame(f);
    }));
    await release();
    const s = await info('perf-horde');
    if (s.screen !== 'playing') h.fail('perf: not measuring gameplay frames (screen ' + s.screen + ')');
    const progs = await ev(() => window.__progs.size);
    const mx = Math.max(...dc), mean = dc.reduce((a, b) => a + b, 0) / dc.length;
    h.log('[perf] alive', s.bugsAlive, '| drawCalls max', mx, 'mean', mean.toFixed(1), 'min', Math.min(...dc), '| GL programs used', progs,
      hasVx ? '| renderer.info.programs ' + (await ev(() => window.__vx.programs())) : '');
    for (let k = 0; k < (+h.args.benchN || 2); k++) h.log('[bench]', JSON.stringify(await ev(() => window.__dbg.bench([500, 1500, 3000]))));
    return;
  }

  if (phase === 'pool') {
    // same staging as the design lens' scen-pool.mjs 'pool' capture: the swarm closes in, aim held up-left
    await ev((c) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); }, cls);
    await h.sleep(1000);
    await ev(() => { const d = window.__dbg; d.tp(30, -8); d.fast(0.5); d.timeScale(0.05); });
    await h.sleep(600);
    await ev(() => { const d = window.__dbg; d.timeScale(1); d.spawn(650); d.fast(1.6); });
    await aimStick(-40, -34);
    await ev(() => window.__dbg.timeScale(1));
    await h.sleep(1600);
    await ev(() => window.__dbg.timeScale(0.05));
    await lvl();
    await h.sleep(1200);
    await h.shot('pool');
    await info('pool');
    await release();
    return;
  }

  if (phase === 'horde') {
    // same staging as the design lens' scen-vx.mjs 'horde' capture (portrait, assault, 700-bug horde)
    await ev((c) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); }, cls);
    await h.sleep(1000);
    await ev(() => { const d = window.__dbg; d.fast(8.5); d.tp(30, -8); d.fast(0.4); d.horde(700); });
    await aimStick(-40, -30);
    await ev(() => { window.__dbg.fast(4); window.__dbg.timeScale(1); });
    await h.sleep(1800);
    await ev(() => window.__dbg.timeScale(0.05));
    await lvl();
    await h.sleep(1500);
    await h.shot('horde');
    await info('horde');
    await release();
    return;
  }

  if (!hasVx) { h.fail('phase ' + phase + ' needs __dbg.vx'); return; }

  if (phase === 'tele') {
    await ev((c) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); }, cls);
    await h.sleep(800);
    const r = await ev(() => window.__vx.stageTele());
    h.log('[tele-stage]', JSON.stringify(r));
    await ev(() => window.__dbg.timeScale(0.4));
    await h.sleep(900);
    await ev(() => window.__dbg.timeScale(0.05));
    await lvl();
    await h.sleep(1000);
    h.log('[tele-state]', JSON.stringify(await ev(() => window.__vx.teleInfo())));
    await h.shot('tele');
    await info('tele');
    return;
  }

  if (phase === 'states') {
    await ev(() => { const d = window.__dbg; d.start('cryo'); d.setQuality('med'); d.god(true); });
    await h.sleep(800);
    const r = await ev(() => window.__vx.stageStates());
    h.log('[states-stage]', JSON.stringify(r));
    await h.sleep(900);
    h.log('[states-state]', JSON.stringify(await ev(() => window.__vx.statesInfo())));
    await h.shot('states');
    await info('states');
    return;
  }

  if (phase === 'desk') {
    await ev(() => { const d = window.__dbg; d.start('assault'); d.setQuality('high'); d.god(true); });
    await h.sleep(800);
    const r = await ev(() => window.__vx.stageDesk());
    h.log('[desk-stage]', JSON.stringify(r));
    await h.sleep(1500);
    h.log('[desk-state]', JSON.stringify(await ev(() => window.__vx.marineInfo())));
    await h.shot('desk');
    await info('desk');
  }
};
