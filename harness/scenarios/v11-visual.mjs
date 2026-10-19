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
//           (or: --phase states --quality high --down 1 on the desktop viewport, both in one frame)
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
        // glare budget: a marine inside a charging ring drops it to alpha 0.55 with no inner sweep
        const b = DIR.beacons[b0], sv = [b.state, M.map((m) => [m.x, m.z])], away = () => { for (const m of M) { m.x = b.x + 30; m.z = b.z; } };
        if (!u.uSweep || !X.beaconFx[b0].ind.material.fragmentShader.includes('uSweep')) fails.push('beacon ring has no uSweep knob');
        b.state = 1; away(); P.x = b.x; P.z = b.z; F.renderFx(0, t);
        out.beaconInside = { alpha: u.uAlpha.value, sweep: u.uSweep ? u.uSweep.value : null };
        away(); F.renderFx(0, t);
        out.beaconOutside = { alpha: u.uAlpha.value, sweep: u.uSweep ? u.uSweep.value : null };
        b.state = sv[0]; M.forEach((m, k) => { [m.x, m.z] = sv[1][k]; }); F.renderFx(0, t);
        if (out.beaconInside.alpha !== 0.55 || out.beaconInside.sweep !== 0 || out.beaconOutside.alpha !== 1 || out.beaconOutside.sweep !== 1) fails.push('beacon glare budget wrong ' + JSON.stringify([out.beaconInside, out.beaconOutside]));
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
      // the squad walks into the beacon while the sim runs: put it back to 'go here' (state 0) with everyone outside
      b.state = 0; b.progress = 0; DIR.active = -1;
      for (const m of M) { const ok = F.walkable(px + (m.i - 1.5) * 1.2, pz); m.x = m.px = ok ? px + (m.i - 1.5) * 1.2 : px; m.z = m.pz = pz; }
      const es = L.edgeSpot(px, pz, 3, 14);
      if (es) {
        F.teleLane(es.x, es.z, es.dx, es.dz, 12, 2.3, 30, 1);
        for (let k = 1; k <= 3; k++) { const i = F.spawnBug(X.RUN, es.x + es.dx * k * 1.2, es.z + es.dz * k * 1.2, 0); if (i >= 0) B.spd[i] = 0.01; }
      }
      L.teleAt = [px, pz];
      return { beacon: bk, at: [+px.toFixed(1), +pz.toFixed(1)], queen: q, lane: es };
    },
    // right before the capture: squad (and camera) back at the staging spot, then on the lit deck in front of the
    // player a swelling boomer's countdown (half full) and a spitter's acid mark, emitted exactly as simBugs does
    teleMarks() {
      window.__dbg.tp(L.teleAt[0], L.teleAt[1]);
      const P = M[0], ax = P.ax || 0, az = P.az || 1, spots = [];
      for (const [d, sd] of [[3.5, 1.6], [4.5, -1.8], [2.5, 2.5], [5, 0]]) { const x = P.x + ax * d - az * sd, z = P.z + az * d + ax * sd; if (F.walkable(x, z)) spots.push([x, z]); }
      if (spots[0]) { const [x, z] = spots[0], i = F.spawnBug(X.BOOM, x, z, 0); if (i >= 0) B.spd[i] = 0.01; F.teleFill(x, z, 3.1, 1.0, 0.2, 0.1, 0.8); F.teleRing(x, z, 3.1, 1.0, 0.35, 0.2, 0.8); }
      if (spots[1]) { const [x, z] = spots[1]; F.teleRing(x, z, 1.5, 0.75, 1.0, 0.15, 1.45); F.teleFill(x, z, 1.5, 0.5, 0.85, 0.08, 1.45); }
      for (const e of TELE) if (e.on && e.kind !== 1 && e.t === 0) e.t = e.life * 0.5;
      return spots.length;
    },
    // glare capture: no bugs (nobody fires), the player's flashlight pool on the deck, and in it one of each warning:
    // a red ring, a boomer countdown (fill + rim), an acid mark (ring + fill) and a brute lane, held at fixed intensity
    stageGlare() {
      for (let i = 0; i < B.n; i++) if (!B.dead[i]) F.killBug(i, -1);
      for (const n of X.NAP) n.on = false;
      for (const e of TELE) e.on = false;
      const P = M[0], ax = P.ax || 0, az = P.az || 1, at = (d, sd) => [P.x + ax * d - az * sd, P.z + az * d + ax * sd];
      const ok = (q) => F.walkable(q[0], q[1]);
      const pl = [];
      let q = at(3.2, -1.6); if (ok(q)) { F.teleRing(q[0], q[1], 1.4, 1.0, 0.18, 0.1, 10, 1.4, false); pl.push('ring:red'); }
      q = at(3.4, 1.7); if (ok(q)) { F.teleFill(q[0], q[1], 1.6, 1.0, 0.2, 0.1, 10); F.teleRing(q[0], q[1], 1.6, 1.0, 0.35, 0.2, 10, 1.6, false); pl.push('boomer'); }
      q = at(6, -1.2); if (ok(q)) { F.teleRing(q[0], q[1], 1.5, 0.75, 1.0, 0.15, 10, 1.5, false); F.teleFill(q[0], q[1], 1.5, 0.5, 0.85, 0.08, 10); pl.push('acid'); }
      q = at(5.6, 2.4); if (ok(q)) { F.teleLane(q[0], q[1], ax, az, 4, 1.6, 0.8, 30); pl.push('lane'); }
      for (const e of TELE) if (e.on) { e.raw = [e.r, e.g, e.b]; e.t = e.kind === 1 ? 1 : e.kind === 2 ? 6 : 2; }
      return pl;
    },
    // B's telegraph treatment on / off (off = no underlays, the colours as passed: the v1.0 look)
    glareMode(on) {
      for (const [, u] of X.teleUnders) u.visible = on;
      for (const e of TELE) if (e.on && e.raw) { if (on) { const m = Math.max(...e.raw); [e.r, e.g, e.b] = e.raw.map((c) => m * Math.pow(c / m, 2.2)); } else [e.r, e.g, e.b] = e.raw; }
    },
    teleInfo() {
      let qi = -1; for (let i = 0; i < B.n; i++) if (!B.dead[i] && B.uid[i] === DIR.q.uid) qi = i;
      const b = DIR.beacons.find(b => b.state === 0) || DIR.beacons[0];
      const lanes = TELE.filter(e => e.on && e.kind === 1).map(e => ({ len: e.len, start: L.ndc(e.x, e.y, e.z), end: L.ndc(e.x + e.dx * e.len, e.y1, e.z + e.dz * e.len) }));
      return { rings: X.teleRingMesh.count, fills: X.teleFillMesh.count, lanes, under: X.teleUnders.map(([, u]) => u.count),
        beacon: { state: b.state, ndc: L.ndc(b.x, 0, b.z) }, queen: qi >= 0 ? { ndc: L.ndc(B.x[qi], F.groundY(B.x[qi], B.z[qi]) + 1, B.z[qi]), st: B.st[qi], flash: +B.fl[qi].toFixed(2), burn: +B.burn[qi].toFixed(2) } : null,
        player: L.ndc(M[0].x, M[0].mesh.position.y + 1, M[0].z) };
    },
    // states capture: a frozen crowd (cryo nova) next to a napalm burn (orange glands), corpses and stains on the deck
    stageStates() {
      const P = M[0];
      window.__dbg.tp(LV.start.x, LV.start.z);
      // a ring of bugs right around the squad (the nova freezes them), a second cluster in the napalm pool, and
      // corpses / stains from a kill front between them
      const ring = (cx, cz, r0, r1, n) => { let k = 0; for (let t = 0; t < n * 4 && k < n; t++) { const a = F.rnd() * TAU, r = r0 + F.rnd() * (r1 - r0), x = cx + Math.cos(a) * r, z = cz + Math.sin(a) * r; if (F.walkable(x, z) && F.spawnBug(X.RUN, x, z, 0) >= 0) k++; } return k; };
      ring(P.x, P.z, 2.5, 6, 160);
      const nx = P.x + X.FWD_X * 8, nz = P.z + X.FWD_Z * 8;
      ring(P.x + X.RIGHT_X * 7, P.z + X.RIGHT_Z * 7, 0, 3, 40);
      for (let i = 0, k = 0; i < B.n && k < 40; i++) if (!B.dead[i] && (B.x[i] - P.x - X.RIGHT_X * 7) ** 2 + (B.z[i] - P.z - X.RIGHT_Z * 7) ** 2 < 9) { F.killBug(i, 0); k++; }
      ring(nx, nz, 0, 3.5, 70);
      for (let i = 0; i < B.n; i++) if (!B.dead[i]) { B.spd[i] = 0.01; B.cd[i] = 99; B.hp[i] = B.hpMax[i] = 1e4; }
      window.__dbg.fast(0.05);   // one sim step puts the new bugs into the spatial grid the nova queries
      P.abCd = 0; F.useAbility(P, P.x, P.z);
      const n = X.NAP[0];
      n.on = true; n.x = nx; n.z = nz; n.r = 4; n.t = 5; n.own = 1;
      for (let i = 0; i < B.n; i++) if (!B.dead[i] && (B.x[i] - nx) ** 2 + (B.z[i] - nz) ** 2 < 16) { B.burn[i] = 5; B.frz[i] = 0; B.chill[i] = 0; }
      F.fxNapalmBurst(nx, nz, 4);
      // ~0.6 s later: the nova's hit flash has faded and its burst particles have aged (a software-rendered frame
      // takes too long for real time to do this), the frozen ring is not burning
      for (let i = 0; i < B.n; i++) if (!B.dead[i]) { B.fl[i] = 0; if (B.frz[i] > 0) B.burn[i] = 0; }
      for (let k = 0; k < 6; k++) F.renderFx(0.1, X.renderTime + k * 0.1);
      window.__dbg.timeScale(0.05);
      return L.statesInfo();
    },
    statesInfo() { let alive = 0, frozen = 0, burning = 0, flash = 0; for (let i = 0; i < B.n; i++) if (!B.dead[i]) { alive++; if (B.frz[i] > 0) frozen++; if (B.burn[i] > 0) burning++; if (B.fl[i] > 0.05) flash++; } return { alive, frozen, burning, flash, corpses: X.corpseMeshes.map(c => c.mesh.count), decals: X.decFill, simTime: +X.simTime.toFixed(2) }; },
    // desktop capture: squad close-up on 'high' (bloom), one squadmate downed, a few bugs around
    stageDesk() {
      window.__dbg.tp(LV.start.x - 4, LV.start.z - 4);
      window.__dbg.spawn(40);
      window.__dbg.fast(1.0);
      const m = M[2]; if (m) { m.downed = true; m.revive = 0.3; m.hp = 0; }
      return L.marineInfo();
    },
    // screen points (CSS px) to sample in the next canvas grab: frozen / burning bugs at mid-body, corpses on the deck,
    // the queen, and each marine's torso (tagged by class)
    pts() {
      const cv = document.querySelector('#stage canvas'), W = cv.clientWidth, H = cv.clientHeight, out = [];
      const add = (tag, x, y, z) => { const v = new THREE.Vector3(x, y, z).project(X.camera); if (Math.abs(v.x) < 0.97 && Math.abs(v.y) < 0.97 && v.z < 1) out.push([tag, (v.x + 1) / 2 * W, (1 - v.y) / 2 * H]); };
      for (let i = 0; i < B.n; i++) {
        if (B.dead[i]) continue;
        const y = F.groundY(B.x[i], B.z[i]) + B.y[i] + 0.3 * B.sc[i];
        if (DIR.q.uid && B.uid[i] === DIR.q.uid) add('queen', B.x[i], y + 0.3, B.z[i]);
        else if (B.frz[i] > 0) add('frozen', B.x[i], y, B.z[i]);
        else if (B.burn[i] > 0) add('burning', B.x[i], y, B.z[i]);
        else add('bug', B.x[i], y, B.z[i]);
      }
      for (const C of X.corpseMeshes) { const a = C.mesh.instanceMatrix.array; for (let k = 0; k < C.mesh.count; k++) add('corpse', a[k * 16 + 12], a[k * 16 + 13] + 0.05, a[k * 16 + 14]); }
      for (const m of M) add('marine:' + m.cls, m.x, m.mesh.position.y + 1.15 * m.mesh.scale.y, m.z);
      // telegraphs: rings on 0.8..1.0 of their current radius, fills over their disc, lanes along the centre line
      for (const e of TELE) {
        if (!e.on) continue;
        const u = e.t / e.life, sm = u * u * (3 - 2 * u), col = e.g > e.r ? 'acid' : 'red';
        if (e.kind === 0) { const r = e.r0 + (e.r1 - e.r0) * sm; for (let a = 0; a < 16; a++) for (const f of [0.8, 0.9, 1.0]) add('ring:' + col, e.x + Math.cos(a / 16 * TAU) * r * f, e.y + 0.05, e.z + Math.sin(a / 16 * TAU) * r * f); }
        else if (e.kind === 2) { const r = e.r0 * (0.12 + 0.88 * u); for (let a = 0; a < 12; a++) for (const f of [0.3, 0.6, 0.9]) add('fill:' + col, e.x + Math.cos(a / 12 * TAU) * r * f, e.y + 0.05, e.z + Math.sin(a / 12 * TAU) * r * f); }
        else for (let d = 0.5; d < e.len; d += 0.5) add('lane', e.x + e.dx * d, e.y + (e.y1 - e.y) * d / e.len + 0.06, e.z + e.dz * d);
      }
      return out;
    },
    marineInfo() { return M.map(m => ({ cls: m.cls, downed: m.downed, scale: m.mesh.scale.x, rx: +m.mesh.rotation.x.toFixed(2), rz: +m.mesh.rotation.z.toFixed(2), rim: [X.MARINE_RIM[m.i].r, X.MARINE_RIM[m.i].g, X.MARINE_RIM[m.i].b].map(v => +v.toFixed(3)), ndc: L.ndc(m.x, m.mesh.position.y + 1, m.z) })); },
  };
  window.__vx = L;
  return true;
}

// Canvas-only colour statistics without a screenshot: after the game's own rAF callback has rendered (same task, so
// the drawing buffer is still valid), read the WebGL canvas back and count the hue.py 'magenta/pink' share in a crop
// given in CSS px. Works on any build (no internals needed).
function installGrab() {
  if (window.__grab) return;
  const raf = window.requestAnimationFrame.bind(window);
  window.__grab = { want: null, res: null, detail: false, cells: new Array(48).fill(0), samples: [] };
  window.requestAnimationFrame = (cb) => raf((ts) => {
    cb(ts);
    const g = window.__grab;
    if (!g.want) return;
    const cv = document.querySelector('#stage canvas'), gl = cv.getContext('webgl2');
    const k = cv.width / cv.clientWidth, [x0, y0, x1, y1] = g.want.map((v) => Math.round(v * k)), w = x1 - x0, hh = y1 - y0;
    const px = new Uint8Array(w * hh * 4);
    gl.readPixels(x0, cv.height - y1, w, hh, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let n = 0, lit = 0, mag = 0;
    for (let i = 0; i < px.length; i += 4) {
      const r = px[i] / 255, gg = px[i + 1] / 255, b = px[i + 2] / 255, mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), d = mx - mn;
      n++;
      if (mx <= 0.22) continue;
      lit++;
      if (!d || d / mx <= 0.35) continue;
      let hu = mx === r ? (gg - b) / d : mx === gg ? 2 + (b - r) / d : 4 + (r - gg) / d;
      hu = ((hu / 6) % 1 + 1) % 1 * 360;
      if (hu >= 285 && hu <= 352) { mag++; if (g.detail) { const q = i / 4, cx = Math.floor((q % w) / w * 8), cy = 5 - Math.floor(Math.floor(q / w) / hh * 6); g.cells[cy * 8 + cx]++; if (g.samples.length < 12 && Math.random() < 0.01) g.samples.push([px[i], px[i + 1], px[i + 2]]); } }
    }
    g.res = { px: n, bright: +(lit / n).toFixed(3), magentaPink: +(mag / n).toFixed(4) };
    if (g.dump) {
      // the same crop as a PNG (canvas readback, no page screenshot): rows flipped, alpha forced opaque
      const c2 = document.createElement('canvas'); c2.width = w; c2.height = hh;
      const x2 = c2.getContext('2d'), im = x2.createImageData(w, hh);
      for (let y = 0; y < hh; y++) for (let x = 0; x < w * 4; x++) im.data[y * w * 4 + x] = (x & 3) === 3 ? 255 : px[(hh - 1 - y) * w * 4 + x];
      x2.putImageData(im, 0, 0); g.res.png = c2.toDataURL('image/png'); g.dump = false;
    }
    if (g.pts) {
      // per tag: mean colour of 5x5 device-px windows at the points, the hue of that mean, and the share of windows
      // whose own mean is blue-dominant / warm (hue 10..60, sat > .35) / magenta-pink (hue 285..352, sat > .35)
      const hsv = (r, gg, b) => { const mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), d = mx - mn; let hu = !d ? 0 : mx === r ? (gg - b) / d : mx === gg ? 2 + (b - r) / d : 4 + (r - gg) / d; hu = ((hu / 6) % 1 + 1) % 1 * 360; return [hu, mx ? d / mx : 0, mx]; };
      const full = new Uint8Array(cv.width * cv.height * 4); gl.readPixels(0, 0, cv.width, cv.height, gl.RGBA, gl.UNSIGNED_BYTE, full);
      const acc = {};
      for (const [tag, x, y] of g.pts) {
        const px0 = Math.round(x * k), py0 = cv.height - 1 - Math.round(y * k);
        let r = 0, gg = 0, b = 0, c = 0;
        for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) { const xx = px0 + dx, yy = py0 + dy; if (xx < 0 || yy < 0 || xx >= cv.width || yy >= cv.height) continue; const o = (yy * cv.width + xx) * 4; r += full[o]; gg += full[o + 1]; b += full[o + 2]; c++; }
        if (!c) continue;
        r /= c * 255; gg /= c * 255; b /= c * 255;
        const [hu, sa] = hsv(r, gg, b), A = acc[tag] || (acc[tag] = { n: 0, r: 0, g: 0, b: 0, blue: 0, warm: 0, pink: 0, list: [] });
        A.list.push([Math.max(r, gg, b), r, gg, b]);
        A.n++; A.r += r; A.g += gg; A.b += b;
        if (b > r && b >= gg * 0.9) A.blue++;
        if (sa > 0.35 && hu >= 10 && hu <= 60) A.warm++;
        if (sa > 0.35 && hu >= 285 && hu <= 352) A.pink++;
      }
      g.res.tags = {};
      for (const [tag, A] of Object.entries(acc)) { const r = A.r / A.n, gg = A.g / A.n, b = A.b / A.n, [hu, sa, v] = hsv(r, gg, b); g.res.tags[tag] = { n: A.n, rgb: [r, gg, b].map((u) => +u.toFixed(3)), hue: Math.round(hu), sat: +sa.toFixed(2), val: +v.toFixed(2), blue: +(A.blue / A.n).toFixed(2), warm: +(A.warm / A.n).toFixed(2), pink: +(A.pink / A.n).toFixed(2) };
        // the brightest quarter of the windows (a washed-out warning shows up here as high value, low saturation)
        const top = A.list.sort((p, q) => q[0] - p[0]).slice(0, Math.max(1, A.list.length >> 2)), tr = top.reduce((s2, q) => s2 + q[1], 0) / top.length, tg = top.reduce((s2, q) => s2 + q[2], 0) / top.length, tb = top.reduce((s2, q) => s2 + q[3], 0) / top.length, th = hsv(tr, tg, tb);
        g.res.tags[tag].top = { hue: Math.round(th[0]), sat: +th[1].toFixed(2), val: +th[2].toFixed(2), white: top.filter((q) => Math.min(q[1], q[2], q[3]) > 0.8).length }; }
      g.pts = null;
    }
    if (g.detail) { g.res.cells = g.cells.join(','); g.res.samples = g.samples; g.cells = new Array(48).fill(0); g.samples = []; }
    g.want = null;
  });
}

export default async (page, h) => {
  const phase = h.args.phase || 'check';
  const cls = h.args.cls || (phase === 'pool' ? 'pyro' : 'assault');
  const ev = (fn, arg) => page.evaluate(fn, arg);
  const lvl = async () => { for (let k = 0; k < 6 && (await h.stats()).screen === 'levelup'; k++) { await page.keyboard.press('Digit1'); await h.sleep(300); } };
  const info = async (tag) => { const s = await h.stats(); h.log('[' + tag + ']', JSON.stringify({ alive: s.bugsAlive, dc: s.drawCalls, q: s.quality, screen: s.screen })); return s; };
  const W = h.width, H = h.height;
  // CSS-pixel captures (same as the design lens' scen-pool / scen-vx), so hue.py crops are in CSS px at any dpr
  let sn = 0;
  h.shot = async (name) => { const p = `${h.args.out || 'harness/out/v11-visual'}-${String(++sn).padStart(2, '0')}-${name}.png`; await page.screenshot({ path: p, timeout: 240000, scale: 'css' }); h.log('[shot]', p); return p; };
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
    // 60 rendered gameplay frames; a level-up popping in the middle voids the sample (dismiss it and measure again)
    let dc = [];
    for (let k = 0; k < 4; k++) {
      dc = await ev(() => new Promise((res) => {
        const v = []; let n = 0;
        const f = () => { const s = window.__dbg.state(); if (s.screen !== 'playing') { res(null); return; } v.push(s.drawCalls); if (++n < 60) requestAnimationFrame(f); else res(v); };
        requestAnimationFrame(f);
      }));
      if (dc) break;
      await lvl(); await h.sleep(300);
    }
    await release();
    if (!dc) { h.fail('perf: no 60 uninterrupted gameplay frames'); return; }
    const s = await info('perf-horde');
    const progs = await ev(() => window.__progs.size);
    const mx = Math.max(...dc), mean = dc.reduce((a, b) => a + b, 0) / dc.length;
    h.log('[perf] alive', s.bugsAlive, '| drawCalls max', mx, 'mean', mean.toFixed(1), 'min', Math.min(...dc), '| GL programs used', progs,
      hasVx ? '| renderer.info.programs ' + (await ev(() => window.__vx.programs())) : '');
    // __dbg.bench is CPU-only and noisy on a shared box: report the per-field minimum over benchN runs
    const runs = [];
    for (let k = 0; k < (+h.args.benchN || 2); k++) runs.push(await ev(() => window.__dbg.bench([500, 1500, 3000])));
    const keys = ['msPerTick', 'denseMsPerTick', 'combatMsPerTick', 'renderPrepMs'];
    h.log('[bench-min of ' + runs.length + ']', JSON.stringify(runs[0].map((r, c) => Object.fromEntries([['count', r.count], ...keys.map((k) => [k, Math.min(...runs.map((x) => x[c][k]))])]))));
    return;
  }

  // --seed S: seeded Math.random and simulated (not wall-clock) time, so two builds get the same scene
  const seed = +h.args.seed || 0;
  if (seed) await ev((sd) => { let a = sd >>> 0; Math.random = () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }, seed);
  const live = async (ms) => { if (seed) await ev((t) => window.__dbg.fast(t), ms / 1000); else { await ev(() => window.__dbg.timeScale(1)); await h.sleep(ms); } await ev(() => window.__dbg.timeScale(0.05)); };

  // --grab N: N canvas-only measurements (no screenshot) instead of the single capture; --crop x0,y0,x1,y1 in CSS px
  const grabN = +h.args.grab || 0;
  const defCrop = phase === 'pool' ? (W > H ? [250, 40, 650, 330] : [20, 280, 370, 560]) : [0, 230, 390, 640];
  const crop = h.args.crop ? String(h.args.crop).split(',').map(Number) : defCrop;
  const finish = async (name) => {
    if (!grabN) { await h.shot(name); await info(name); return; }
    await ev(installGrab);
    if (h.args.detail) await ev(() => { window.__grab.detail = true; });
    if (h.args.attrib && hasVx) {
      if (h.args.pts) await ev(() => { window.__grabPts = true; });
      // attribution: magenta share with one group of scene objects hidden at a time (same frame state, timeScale 0.05)
      const groups = String(h.args.groups || 'none,bugs,corpses,decals,particles,beams,telegraphs,marines,splash,pl0').split(','), acc = {};
      for (let rep = 0; rep < +h.args.attrib; rep++) for (const gname of groups) {
        await ev(([g, c]) => {
          const X = window.__dbg.vx(), hide = [];
          if (g === 'bugs') hide.push(...X.bugMeshes);
          if (g === 'corpses') hide.push(...X.corpseMeshes.map((o) => o.mesh));
          if (g === 'decals') hide.push(X.decals);
          if (g === 'particles') hide.push(X.PA.points, X.PN.points);
          if (g === 'beams') hide.push(X.laserMesh, X.trMesh);
          if (g === 'telegraphs') hide.push(X.teleRingMesh, X.teleFillMesh, X.teleLaneMesh, X.splashMesh, ...X.teleUnders.map((u) => u[1]), ...X.beaconFx.map((f) => f.ind));
          if (g === 'marines') hide.push(...X.M.map((m) => m.mesh));
          if (g === 'splash') hide.push(X.splashMesh);
          if (g === 'pl0') { const l = X.plights[0].light; Object.defineProperty(l, 'intensity', { configurable: true, get: () => 0, set: () => {} }); window.__unpl = () => { delete l.intensity; l.intensity = 0; }; }
          window.__hidden = hide; for (const o of hide) o.visible = false;
          window.__grab.res = null; window.__grab.want = c; if (window.__vx && window.__grabPts) window.__grab.pts = window.__vx.pts();
        }, [gname, crop]);
        for (let t = 0; t < 100 && !(await ev(() => window.__grab.res)); t++) await h.sleep(50);
        const r = await ev(() => { for (const o of window.__hidden) o.visible = true; if (window.__unpl) { window.__unpl(); window.__unpl = null; } return window.__grab.res; });
        (acc[gname] = acc[gname] || []).push(r.magentaPink);
        if (r.tags) h.log('[attrib tags hide ' + gname + ']', JSON.stringify(Object.fromEntries(Object.entries(r.tags).filter(([k]) => /^(ring|fill|lane|queen|bug)/.test(k)).map(([k, v]) => [k, { rgb: v.rgb, hue: v.hue, sat: v.sat, top: v.top }]))));
        if (h.args.detail) h.log('[detail ' + gname + ']', r.cells, JSON.stringify(r.samples));
      }
      for (const g of groups) h.log('[attrib hide ' + g + '] mean', (acc[g].reduce((a, b) => a + b, 0) / acc[g].length).toFixed(4), JSON.stringify(acc[g]));
      return;
    }
    const res = [];
    for (let k = 0; k < grabN; k++) {
      if (k) { await live(250); await lvl(); await h.sleep(200); }
      await ev(([c, p, d]) => { window.__grab.res = null; window.__grab.want = c; window.__grab.dump = d; if (p && window.__vx) window.__grab.pts = window.__vx.pts(); }, [crop, !!h.args.pts, !!h.args.dump && k === grabN - 1]);
      for (let t = 0; t < 100 && !(await ev(() => window.__grab.res)); t++) await h.sleep(50);
      res.push(await ev(() => window.__grab.res));
    }
    const m = res.map((r) => r.magentaPink);
    for (const r of res) if (r.tags) { h.log('[tags ' + name + ']', JSON.stringify(r.tags)); delete r.tags; }
    for (const r of res) if (r.png) { const fs = await import('node:fs'); fs.writeFileSync(String(h.args.dump), Buffer.from(r.png.split(',')[1], 'base64')); h.log('[dump]', h.args.dump); delete r.png; }
    h.log('[grab ' + name + ' crop ' + crop.join(',') + ']', JSON.stringify(res), '| mean magentaPink', (m.reduce((a, b) => a + b, 0) / m.length).toFixed(4));
    await info(name);
  };

  if (phase === 'pool') {
    // same staging as the design lens' scen-pool.mjs 'pool' capture: the swarm closes in, aim held up-left
    await ev(([c, sd]) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); if (sd) d.timeScale(0.05); }, [cls, seed]);
    await h.sleep(1000);
    await ev(() => { const d = window.__dbg; d.tp(30, -8); d.fast(0.5); d.timeScale(0.05); });
    await h.sleep(1200);
    await ev(() => { const d = window.__dbg; d.spawn(650); d.fast(1.6); });
    await aimStick(-40, -34);
    await live(1600);
    await lvl();
    await h.sleep(1200);
    await finish('pool');
    await release();
    return;
  }

  if (phase === 'horde') {
    // same staging as the design lens' scen-vx.mjs 'horde' capture (700-bug horde in the flashlight)
    await ev(([c, sd]) => { const d = window.__dbg; d.start(c); d.setQuality('med'); d.god(true); if (sd) d.timeScale(0.05); }, [cls, seed]);
    await h.sleep(1200);
    await ev(() => { const d = window.__dbg; d.fast(8.5); d.timeScale(0.05); });
    await h.sleep(1500);
    await ev(() => { const d = window.__dbg; d.tp(30, -8); d.fast(0.4); });
    await h.sleep(1500);
    await ev(() => window.__dbg.horde(700));
    await aimStick(-40, -30);
    await ev(() => window.__dbg.fast(4));
    await live(1800);
    await lvl();
    await h.sleep(1500);
    await finish('horde');
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
    h.log('[tele-marks]', await ev(() => window.__vx.teleMarks()));
    await h.sleep(1000);
    h.log('[tele-state]', JSON.stringify(await ev(() => window.__vx.teleInfo())));
    await finish('tele');
    return;
  }

  if (phase === 'glare') {
    await ev(([c, q]) => { const d = window.__dbg; d.start(c); d.setQuality(q); d.god(true); }, [cls, h.args.quality || 'med']);
    await h.sleep(800);
    await ev(() => { const d = window.__dbg; d.tp(30, -8); d.timeScale(0.05); });
    await h.sleep(600);
    h.log('[glare-stage]', JSON.stringify(await ev(() => window.__vx.stageGlare())));
    await h.sleep(600);
    await ev(installGrab);
    const crop = [0, 0, W, H];
    for (const mode of ['off', 'on', 'off', 'on']) {
      await ev(([m, c]) => { window.__vx.glareMode(m === 'on'); window.__grab.res = null; window.__grab.want = c; window.__grab.pts = window.__vx.pts(); }, [mode, crop]);
      for (let t = 0; t < 100 && !(await ev(() => window.__grab.res)); t++) await h.sleep(50);
      const r = await ev(() => window.__grab.res);
      h.log('[glare ' + mode + ']', JSON.stringify(Object.fromEntries(Object.entries(r.tags || {}).filter(([k]) => /^(ring|fill|lane)/.test(k)).map(([k, v]) => [k, { rgb: v.rgb, hue: v.hue, sat: v.sat, top: v.top }]))));
    }
    if (h.args.dump) {
      await ev((c) => { window.__vx.glareMode(true); window.__grab.res = null; window.__grab.want = c; window.__grab.dump = true; }, [Math.round(W * 0.1), Math.round(H * 0.2), Math.round(W * 0.9), Math.round(H * 0.75)]);
      for (let t = 0; t < 100 && !(await ev(() => window.__grab.res)); t++) await h.sleep(50);
      const r = await ev(() => window.__grab.res); const fs = await import('node:fs'); fs.writeFileSync(String(h.args.dump), Buffer.from(r.png.split(',')[1], 'base64')); h.log('[dump]', h.args.dump);
    }
    return;
  }

  if (phase === 'states') {
    // --quality high --down 1 on the desktop viewport doubles as the 'desk' capture (bloom, downed squadmate, scale)
    await ev((q) => { const d = window.__dbg; d.start('cryo'); d.setQuality(q); d.god(true); }, h.args.quality || 'med');
    await h.sleep(800);
    const r = await ev((dn) => { const r = window.__vx.stageStates(); if (dn) { const m = window.__dbg.vx().M[2]; m.downed = true; m.revive = 0.3; m.hp = 0; } return r; }, !!h.args.down);
    h.log('[states-stage]', JSON.stringify(r));
    await h.sleep(900);
    h.log('[states-state]', JSON.stringify(await ev(() => window.__vx.statesInfo())));
    if (h.args.down) h.log('[desk-state]', JSON.stringify(await ev(() => window.__vx.marineInfo())));
    await finish('states');
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
