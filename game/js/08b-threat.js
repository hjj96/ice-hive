// ================================================================
//  THREAT — tiers, hive pressure and the Матка (v1.1, package A)
// ================================================================
// The tier table (DIFF / TH / setTier) lives in 01-core.js and the rules that read it sit where they act (director,
// sim, marines). This file holds the Матка — the boss of the lift hold — plus the pressure / boss HUD states and the
// debug helpers. Everything here works on fixed fields: no allocations per tick or per frame.

// private Матка state (DIR.q is the shared view: B reads uid, D reads spawned / alive / done)
const QSTATE = { warn: -1, edge: -1, i: -1, x: 0, z: 0, hpFrac: 1, brood: 0, volley: 0, ram: 0, mcd: 0, armed: false, enr: false };

// a rim edge of the lift on its far side (z − lift.z < −4), else any rim edge, else the edge nearest to the lift
function queenEdge() {
  const L = LV.lift, r2 = (L.r + 1.5) * (L.r + 1.5);
  let back = 0, rim = 0, near = 0, nd = 1e9;
  for (let e = 0; e < LV.edgeN; e++) {
    const dx = LV.edgeX[e] - L.x, dz = LV.edgeZ[e] - L.z, d2 = dx * dx + dz * dz;
    if (d2 < nd) { nd = d2; near = e; }
    if (d2 < r2) { rim++; if (dz < -4) back++; }
  }
  if (!rim) return near;
  let k = ((back || rim) * rnd()) | 0;
  for (let e = 0; e < LV.edgeN; e++) {
    const dx = LV.edgeX[e] - L.x, dz = LV.edgeZ[e] - L.z;
    if (dx * dx + dz * dz < r2 && (!back || dz < -4) && k-- === 0) return e;
  }
  return near;
}
// 2 s of red warning ring where she will climb over the rim
function queenWarn() {
  QSTATE.edge = queenEdge(); QSTATE.warn = 2;
  if (!simOnly) teleRing(LV.edgeX[QSTATE.edge], LV.edgeZ[QSTATE.edge], 3, 1.0, 0.12, 0.08, 2.0);
}
function queenSpawn() {
  const q = DIR.q, e = QSTATE.edge >= 0 ? QSTATE.edge : queenEdge();
  const i = spawnBug(BRUTE, LV.edgeX[e], LV.edgeZ[e], 1, LV.edgeNX[e], LV.edgeNZ[e], 3);
  if (i < 0) { QSTATE.warn = 0.5; return; }   // bug arrays full (debug floods only): try again shortly
  // a brute instance scaled up: 0 extra draw calls (package B tints her by uid)
  B.hp[i] = B.hpMax[i] = TH.qHp * DIR.hpMul; B.r[i] = 1.5; B.sc[i] = 4.2; B.spd[i] = TH.qSpd;
  q.uid = B.uid[i]; q.spawned = true; q.alive = true; q.done = false; q.t0 = GS.time; q.killT = 0;
  QSTATE.warn = -1; QSTATE.i = i; QSTATE.x = B.x[i]; QSTATE.z = B.z[i]; QSTATE.hpFrac = 1;
  QSTATE.brood = 4; QSTATE.volley = 3; QSTATE.ram = 6; QSTATE.mcd = 0; QSTATE.armed = false; QSTATE.enr = false;
  if (!simOnly) {
    banner('Матка', 'Поднимается из бездны — лифт не уйдёт, пока она жива', false);
    sfx('siren'); sfx('queen'); addShake(0.4); haptic('heavy');
  }
}
// called from the hold branch of tickDirector every tick
function queenTick(dt) {
  const q = DIR.q;
  if (!q.spawned) {
    if (QSTATE.warn < 0) { if (DIR.liftDur - DIR.liftT >= TH.qAt) queenWarn(); }
    else if ((QSTATE.warn -= dt) <= 0) queenSpawn();
    return;
  }
  if (!q.alive) return;
  let qi = -1;
  for (let i = 0; i < B.n; i++) if (B.uid[i] === q.uid) { qi = i; break; }
  if (qi < 0 || B.dead[qi]) { q.alive = false; q.done = true; q.killT = GS.time - q.t0; QSTATE.i = -1; QSTATE.hpFrac = 0; return; }
  QSTATE.i = qi; QSTATE.x = B.x[qi]; QSTATE.z = B.z[qi]; QSTATE.hpFrac = clamp(B.hp[qi] / B.hpMax[qi], 0, 1);
  // immune to freeze and deep chill (beamTick / the nova / frost blasts skip her too)
  B.frz[qi] = 0; if (B.chill[qi] > 0.5) B.chill[qi] = 0.5;
  // enrage once below half health: faster, angrier, and the hive answers her call
  if (!QSTATE.enr && B.hp[qi] < B.hpMax[qi] * 0.5) {
    QSTATE.enr = true; B.spd[qi] = TH.qSpd * 1.35;
    startHorde(Math.round(TH.qHorde * hordeScale()), 'Матка в ярости', '', 50);
  }
  const en = QSTATE.enr;
  if (QSTATE.mcd > 0) QSTATE.mcd -= dt;
  // brood: runners burst from her body (only while the swarm cap has room)
  QSTATE.brood -= dt;
  if (QSTATE.brood <= 0) {
    QSTATE.brood = TH.qBroodT * (en ? 0.7 : 1);
    for (let k = 0; k < TH.qBroodN && capLeft() > 0; k++) spawnBug(RUN, B.x[qi], B.z[qi], 2);
  }
  // acid volley: one glob per standing marine within 18 m, aimed 0.8 s ahead with ±1.2 m spread
  QSTATE.volley -= dt;
  if (QSTATE.volley <= 0) {
    QSTATE.volley = TH.qVolleyT * (en ? 0.75 : 1);
    for (let k = 0; k < M.length; k++) {
      const m = M[k];
      if (m.downed || (m.x - QSTATE.x) * (m.x - QSTATE.x) + (m.z - QSTATE.z) * (m.z - QSTATE.z) > 324) continue;
      const ax = m.x + m.vx * 0.8 + rr(-1.2, 1.2), az = m.z + m.vz * 0.8 + rr(-1.2, 1.2);
      launchGlob(QSTATE.x, QSTATE.z, ax, az);
      if (!simOnly) { teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, 0.95); teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, 0.95); }
    }
  }
  // ram: the brute AI does the wind-up (red lane) and the charge; her own TH.qRamT clock decides when it may start
  QSTATE.ram -= dt;
  const st = B.st[qi];
  if (st === S_WIND) { QSTATE.ram = TH.qRamT * (en ? 0.75 : 1); QSTATE.armed = false; }
  else if (st === S_MOVE) {
    if (QSTATE.ram > 0) { if (B.cd[qi] < 0.5) B.cd[qi] = 0.5; }
    else if (!QSTATE.armed) { QSTATE.armed = true; B.cd[qi] = 0; }
  }
}
// killBug on her uid (05-sim.js)
function queenKilled(x, z) {
  const q = DIR.q;
  q.alive = false; q.done = true; q.killT = GS.time - q.t0; QSTATE.i = -1; QSTATE.hpFrac = 0;
  queueBoom(x, z, 8, 300, 0, 'frag');
  dropMedkit(x + 1, z); dropMedkit(x - 1, z);
  if (!simOnly) {
    hsCd = 0; hitStop(0.2, 0.15);   // her death always gets its hit-stop
    flashLight(x, 3, z, 0x9a48ff, 900, 1.2);
    banner('Матка убита', 'Лифт свободен', true);
    haptic('success');
  }
}
// __dbg.skip() in the hold: she dies (or never comes) before the lift is released
function queenSkip() {
  const q = DIR.q;
  if (q.alive) for (let i = 0; i < B.n; i++) if (B.uid[i] === q.uid && !B.dead[i]) { killBug(i, -1); break; }
  q.alive = false; q.spawned = true; q.done = true; QSTATE.warn = -1;
}
function queenHpFrac() { return DIR.q.alive ? QSTATE.hpFrac : 0; }

// ---------- HUD: 0 calm · 1 the hive wakes (amber) · 2 the swarm converges (red) · 3 the Матка lives ----------
function threatState() {
  if (GS.attract) return 0;
  if (DIR.stage === 'hold') return DIR.q.alive ? 3 : 0;
  if (!((DIR.stage === 'beacons' && DIR.active < 0) || DIR.stage === 'toLift')) return 0;
  return DIR.press >= TH.grace ? 2 : DIR.press >= TH.grace - 10 ? 1 : 0;
}
const THUD = { st: 0, heart: -9, box: null };
function updateThreatHUD() {
  const s = threatState();
  // heartbeat while the swarm converges (game time: silent in pause)
  if (s === 2 && GS.screen === 'playing' && Math.abs(GS.time - THUD.heart) >= 1.2) { THUD.heart = GS.time; sfx('heart'); }
  if (s === THUD.st) return;
  THUD.st = s;
  const box = THUD.box || (THUD.box = document.querySelector('.obj-box'));
  box.classList.toggle('press1', s === 1);
  box.classList.toggle('press2', s === 2);
  box.classList.toggle('boss', s === 3);
  UI.marker.classList.toggle('urge', s === 2);
  markHudLayout();
}

// ---------- debug helpers (merged into window.__dbg by 12-main.js) ----------
window.__dbgExt = Object.assign(window.__dbgExt || {}, {
  // switch the live tier (0 Новобранец · 1 Ветеран · 2 Кошмар); missions started later pick their own via tierPrepare
  diff(i) { if (i != null) setTier(+i); return TH.id; },
  // the Матка climbs up right now (lift hold only); returns her uid or 0
  queen() { if (DIR.stage !== 'hold' || DIR.q.spawned) return 0; QSTATE.edge = -1; queenSpawn(); return DIR.q.uid; },
  press() { return { press: +DIR.press.toFixed(2), idleMul: +DIR.idleMul.toFixed(3), afkT: +GS.afkT.toFixed(2), state: threatState() }; },
});
