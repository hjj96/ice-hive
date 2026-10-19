// ================================================================
//  COACH — the five-step first-run tutorial «Учебная высадка» (v1.1, package C)
// ================================================================
// tickCoach(dt) runs every fixed tick just before tickDirector (never in the bench); coachBegin(opts) runs in
// startMission after showScreen('playing') and returns true when it took over the mission start (no «Высадка»
// banner); coachHoldFire(m) lets the bots leave the practice groups to the player (botThink, 06-marines.js).
// Each step completes on the action OR on its timeout, never a fail state. While steps 1-4 run, DIR.calm asks the
// director for no trickle, no hordes and a frozen pressure clock (package A honours it); the first beacon of a
// coached run starts a smaller horde (DIR.beaconHordeMul, consumed and reset by the director).
// Store keys: 'tut' (1 = the coach was seen), 'sticks' (seconds of thumb-stick use, read by the HUD).
const COACH_MAX = [7, 12, 9, 8, 1e9];
const CO = {
  on: false, step: -1, t: 0, x0: 0, z0: 0, fire: 0, mode: '',
  // the coach's own practice groups (runners only, half HP), climbing over the railing at a steady rate
  qe: new Int32Array(2), qn: new Int32Array(2), qr: new Float32Array(2), qa: new Float32Array(2), qc: 0,
  // revive line: once per run, for the first three runs of a profile
  revArm: false, revT: 0, revText: '',
};
function coachText(k) {
  const md = IN.mode;
  if (k === 0) return md === 'touch' ? 'Левый палец — бег' : md === 'gamepad' ? 'Левый стик — бег' : 'WASD — бег';
  if (k === 1) return md === 'touch' ? 'Правый палец — прицел, огонь сам' : md === 'gamepad' ? 'Правый стик — прицел и огонь' : 'Мышь — прицел, ЛКМ — огонь';
  if (k === 2) return M[0].C.abShort + ' — по толпе' + (md === 'mouse' ? ' (Q)' : md === 'gamepad' ? ' (LB)' : '');
  if (k === 3) return 'Рывок — из окружения' + (md === 'mouse' ? ' (пробел)' : md === 'gamepad' ? ' (A)' : '');
  return 'Маяк — встаньте в кольцо';
}

// ---------- DOM: the card fills the stage-0 #coach slot; the ghost thumb lives in #touchUI (touch only) ----------
const coachEl = $('coach');
coachEl.innerHTML = '<span class="co-n"></span><span class="co-t"></span><button class="co-skip" type="button">Пропустить</button>';
const coN = coachEl.children[0], coT = coachEl.children[1], coSkip = coachEl.children[2];
const ghostEl = document.createElement('div');
ghostEl.id = 'ghost';
$('touchUI').appendChild(ghostEl);
let coGhostDirty = false;
// «Пропустить» fires on the finger lifting (onTap), so it works while the other thumb rests on the move stick
onTap(coSkip, () => { if (!CO.on) return; sfx('click'); haptic('select'); coachEnd(true); });
// pause menu: replay the coach on the current class
const pTutBtn = document.createElement('button');
pTutBtn.className = 'btn btn-ghost'; pTutBtn.id = 'pTut'; pTutBtn.textContent = 'Обучение';
$('pQuality').after(pTutBtn);
onTap(pTutBtn, () => startMission(GS.cls, { coach: true }));

// ---------- hooks ----------
function coachActive() { return CO.on; }
function coachHoldFire(m) { return CO.on && CO.step <= 3 && !m.isPlayer && crowd[m.i] < 2; }
function coachBegin(opts) {
  CO.on = false; CO.step = -1; CO.qc = 0; CO.revT = 0;
  // raw profile (package D writes it); read per mission, after the iOS bridge restored the saved keys
  const prof = store.get('profile', null);
  const runs = prof && typeof prof === 'object' ? +prof.runs || 0 : 0;
  CO.revArm = runs < 3;
  hudMissionStart();
  const first = opts.coach === undefined && !store.get('tut', 0) && !(GS.best || store.get('best', null)) && !runs;
  if (opts.coach !== true && !first) { coachShow(); return false; }
  CO.on = true;
  DIR.beaconHordeMul = 0.65;
  coachStep(0);
  return true;
}
function coachSeen() { if (!store.get('tut', 0)) store.set('tut', 1); }
function coachEnd(seen) {
  CO.on = false; CO.step = -1; CO.qc = 0;
  DIR.calm = false;
  if (seen) coachSeen();
  coachShow();
}
// practice group: n runners from one stretch of railing dmin..dmax away (skipped if no edge qualifies)
function coachGroup(P, dmin, dmax, n, rate) {
  let e = pickEdge(P.x, P.z, dmin, dmax);
  if (e < 0) e = pickEdge(P.x, P.z, dmin * 0.6, dmax + 8);
  if (e < 0 || CO.qc >= 2) return;
  const q = CO.qc++;
  CO.qe[q] = e; CO.qn[q] = n; CO.qr[q] = rate; CO.qa[q] = 0;
}
function coachSpawned(i) { if (i >= 0) { B.hp[i] *= 0.5; B.hpMax[i] *= 0.5; } }
function coachStep(k) {
  const P = M[0];
  CO.step = k; CO.t = 0; CO.x0 = P.x; CO.z0 = P.z; CO.fire = 0;
  DIR.calm = k <= 3;
  if (k === 1) coachGroup(P, 9, 16, 10, 5);
  else if (k === 2) { coachGroup(P, 8, 13, 18, 30); P.abCd = 0; }
  else if (k === 3) {
    for (let a = 0; a < 8; a++) {
      const x = P.x + Math.cos(a * TAU / 8) * 4.2, z = P.z + Math.sin(a * TAU / 8) * 4.2;
      if (walkable(x, z) && capLeft() > 0) coachSpawned(spawnBug(RUN, x, z, 2));
    }
    P.dashCd = 0;
  }
  coachShow();
}
function coachQueue(dt) {
  for (let q = 0; q < CO.qc; q++) {
    CO.qa[q] += CO.qr[q] * dt;
    while (CO.qa[q] >= 1 && CO.qn[q] > 0) {
      CO.qa[q] -= 1; CO.qn[q]--;
      if (capLeft() <= 0) continue;
      const e = edgeNear(CO.qe[q], 6);
      coachSpawned(spawnBug(RUN, LV.edgeX[e], LV.edgeZ[e], 1, LV.edgeNX[e], LV.edgeNZ[e], 1.8 + rnd() * 2.2));
    }
    if (CO.qn[q] <= 0) {   // drop the finished slot (swap the last one in)
      const l = --CO.qc;
      CO.qe[q] = CO.qe[l]; CO.qn[q] = CO.qn[l]; CO.qr[q] = CO.qr[l]; CO.qa[q] = CO.qa[l]; q--;
    }
  }
}
function tickCoach(dt) {
  if (GS.attract) return;
  // revive line: the first time a squadmate goes down in this run
  if (CO.revT > 0) CO.revT -= dt;
  if (CO.revArm) for (let k = 1; k < M.length; k++) if (M[k].downed) { CO.revArm = false; CO.revT = 6; CO.revText = M[k].name + ' ранен — встаньте рядом, чтобы поднять'; break; }
  if (!CO.on) return;
  coachQueue(dt);
  const P = M[0], s = CO.step;
  CO.t += dt;
  if (P.firing) CO.fire += dt;
  if (IN.mode !== CO.mode) coachShow();
  // walking onto a beacon ends the coach early: the player found the objective on their own
  if (s <= 3 && DIR.active >= 0) { coachEnd(true); return; }
  let ok = false;
  if (s === 0) ok = Math.hypot(P.x - CO.x0, P.z - CO.z0) >= 3;
  else if (s === 1) ok = CO.fire >= 1.2 && CO.t > 2.5;
  else if (s === 2) ok = P.abCd > 0.5;
  else if (s === 3) ok = P.dashT > 0;
  else ok = DIR.active >= 0;
  if (!ok && CO.t <= COACH_MAX[s]) return;
  haptic('select');
  if (ok) sfx('click');
  if (s >= 3) coachSeen();   // seen enough: never forced again
  if (s >= 4) coachEnd(true); else coachStep(s + 1);
}

// ---------- card + ghost thumb (DOM touched once per step; control rects read once per step, on a rendered frame) ----------
function coachShow() {
  const on = CO.on && CO.step >= 0;
  UI.hud.classList.toggle('coaching', on);
  UI.tAbil.classList.toggle('coach', on && CO.step === 2);
  UI.abil.classList.toggle('coach', on && CO.step === 2);
  UI.tDash.classList.toggle('coach', on && CO.step === 3);
  UI.marker.classList.toggle('coach', on && CO.step === 4);
  if (!on) { coachEl.hidden = true; ghostEl.className = ''; markHudLayout(); return; }
  CO.mode = IN.mode;
  coN.textContent = (CO.step + 1) + '/5';
  coT.textContent = coachText(CO.step);
  coachEl.hidden = false;
  ghostEl.className = '';
  markHudLayout();
}
function coachMarkLayout() { coGhostDirty = true; }
function coachBottom() { if (coachEl.hidden) return 0; const r = coachEl.getBoundingClientRect(); return r.height ? r.bottom : 0; }
// per rendered frame from updateHUD: only places the ghost after a step / layout change
function coachFrame() {
  if (!coGhostDirty) return;
  coGhostDirty = false;
  if (!CO.on || CO.step < 0 || CO.step > 3 || IN.mode !== 'touch') { ghostEl.className = ''; return; }
  const s = CO.step, el = s === 0 ? stickEls.L : s === 1 ? stickEls.R : s === 2 ? UI.tAbil : UI.tDash;
  const r = el.getBoundingClientRect();
  if (!r.width) { ghostEl.className = ''; return; }
  ghostEl.style.transform = 'translate3d(' + Math.round(r.left + r.width / 2) + 'px, ' + Math.round(r.top + r.height / 2) + 'px, 0)';
  ghostEl.className = 'on ' + (s <= 1 ? 'drag' : 'tap');
}
function coachHint() { return CO.revT > 0 ? CO.revText : ''; }

window.__dbgExt = Object.assign(window.__dbgExt || {}, {
  tut() { return { on: CO.on, step: CO.step, t: +CO.t.toFixed(2), calm: DIR.calm, beaconHordeMul: DIR.beaconHordeMul, hordes: DIR.hordes, time: +GS.time.toFixed(1), active: DIR.active, tut: store.get('tut', 0), revT: +CO.revT.toFixed(1) }; },
  cam() { return { zoom: +camZoom.toFixed(4), near: nearCam, want: camZoomWant }; },
  // tests: set a squad member's armour (0 or less downs them)
  // tests: move one marine (and optionally set its aim, radians); plate layout state; updatePlates cost
  place(k = 0, x = 0, z = 0, aim) { const m = M[k | 0]; if (!m) return null; m.x = m.px = x; m.z = m.pz = z; if (aim != null) { m.aim = m.aimVis = +aim; m.ax = Math.sin(m.aim); m.az = Math.cos(m.aim); } if (!k) camTarget.set(x, groundY(x, z), z); return [m.x, m.z]; },
  spots(n = 16, r0 = 8, r1 = 30) { const P = M[0], out = []; for (let t = 0; t < n * 40 && out.length < n; t++) { const a = rnd() * TAU, r = rr(r0, r1), x = P.x + Math.cos(a) * r, z = P.z + Math.sin(a) * r; if (canStand(x, z)) out.push([+x.toFixed(2), +z.toFixed(2)]); } return out; },
  beacons() { return DIR.beacons.map(b => ({ x: b.x, z: b.z, name: b.name })); },
  nextBeacon() { const b = nextBeacon(); return b ? { x: b.x, z: b.z, name: b.name } : null; },
  plates() { return M.map((m, k) => ({ name: m.isPlayer ? 'ВЫ' : m.name, mini: plMini[k], hold: +plHold[k].toFixed(3), x: +plX[k].toFixed(1), y: +plY[k].toFixed(1), off: plOff[k], top: plateTop })); },
  platesBench(n = 10000, move = false) {
    const t0 = performance.now();
    for (let i = 0; i < n; i++) { if (move) for (const m of M) m.mesh.position.x += (i & 1 ? -0.02 : 0.02); updatePlates(); }
    return +((performance.now() - t0) / n * 1000).toFixed(2);   // µs per call
  },
  hurt(k = 1, hp = 20) { const m = M[k | 0]; if (!m) return null; if (hp <= 0) downMarine(m); else { m.hp = Math.min(m.maxHp, hp); m.downed = false; } return { name: m.name, hp: m.hp, downed: m.downed }; },
});
