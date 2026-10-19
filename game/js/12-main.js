// ================================================================
//  MAIN — game flow, camera, fixed-step loop, debug API, boot
// ================================================================
let simOnly = false;     // bench mode: simulation without effects/audio/director
let benchCombat = false; // bench combat pass: kills and effects on, director off
let timeScale = 1;
let dbgGod = false;
const camTarget = new THREE.Vector3(LV.start.x, 0, LV.start.z);
let fps = 60, frameMs = 16.7, last = performance.now(), acc = 0, renderTime = 0;
renderer.info.autoReset = false;

// ---------- fixed simulation step ----------
function tick(dt) {
  simTime += dt;
  compactBugs();
  rebuildHash();
  flowTimer -= dt;
  if (flowTimer <= 0) { flowTimer = 0.25; updateFlows(); }
  processBooms();
  tickMarines(dt);
  simBugs(dt);
  updateProjectiles(dt);
  updateGlobs(dt);
  updateAbilities(dt);
  updateMedkits(dt);
  if (!simOnly && !benchCombat) { tickCoach(dt); tickDirector(dt); }
}

// ---------- game flow ----------
function resetWorld(cls, attract) {
  clearBugs();
  PR.n = 0;
  for (const g of GRN) g.on = false;
  for (const n of NAP) n.on = false;
  for (const k of MED) k.on = false;
  TUR.on = false;
  fxReset();
  GS.attract = attract; autoPlayer = attract; godMode = attract || dbgGod;
  setupSquad(cls);
  resetDirector(attract);
  Object.assign(GS, { time: 0, kills: 0, playerKills: 0, shots: 0, hits: 0, combo: 0, comboT: 0, bestCombo: 0, level: 1, xp: 0, xpNext: xpFor(1), pendingLevels: 0, dmgFlash: 0, flash: 0, hordeFx: 0, upg: {}, newRecord: false, seen: [true, false, false, false], downs: 0, lastHit: -1, downBy: -1, afkT: 0 });
  simTime = 0; flowTimer = 0; acc = 0;
  updateFlows(); rebuildHash();
  camTarget.set(M[0].x, groundY(M[0].x, M[0].z), M[0].z);
  IN.abil = IN.dash = false;
  buildSquadUI();
  if (attract) for (let k = 0; k < 160; k++) { const e = pickEdge(M[0].x, M[0].z, 8, 30); if (e >= 0) spawnBug(RUN, LV.edgeX[e] - LV.edgeNX[e] * 1.5, LV.edgeZ[e] - LV.edgeNZ[e] * 1.5); }
}
// opts (all optional): { tier, seed, coach } — read by tierPrepare (11c), stationPrepare (04b) and coachBegin (11b)
function startMission(cls, opts) {
  opts = opts || {};
  audioInit(); sfx('click');
  GS.cls = CLASSES[cls] ? cls : 'assault';
  store.set('cls', GS.cls);
  tierPrepare(opts);
  stationPrepare(opts);
  resetWorld(GS.cls, false);
  showScreen('playing');
  if (!coachBegin(opts)) banner('Высадка', stationLabel() + ' · запустите три маяка', true);
}
function goTitle() {
  resetWorld(GS.cls, true);
  buildTitle();
  showScreen('title');
}
function endGame(won, surrendered) {
  if (GS.screen === 'won' || GS.screen === 'lost') return;
  const best = GS.best || { kills: 0, win: 0 };
  if (GS.kills > best.kills) { best.kills = GS.kills; GS.newRecord = true; }
  if (won && (!best.win || GS.time < best.win)) best.win = Math.round(GS.time);
  GS.best = best; store.set('best', best);
  showScreen(won ? 'won' : 'lost');
  showEnd(won, surrendered);
  sfx(won ? 'victory' : 'defeat');
  if (!surrendered) haptic(won ? 'success' : 'error');
}
function togglePause() {
  if (GS.screen === 'playing') { showScreen('paused'); openPauseUI(); sfx('click'); }
  else if (GS.screen === 'paused') { showScreen('playing'); sfx('click'); }
}
function openLevelUp() {
  showScreen('levelup');
  renderCards();
  sfx('levelup');
  haptic('success');
}
function pickCard(i) {
  if (GS.screen !== 'levelup' || !offer[i]) return;
  applyUpgrade(offer[i]);
  sfx('click');
  haptic('select');
  GS.pendingLevels--;
  toast(offer[i].name, 'gold');
  if (GS.pendingLevels > 0) renderCards();
  else showScreen('playing');
}

// ---------- camera ----------
// VX-6: phones pull the camera back up to 10 % while the screen is packed (hysteresis 240 / 180 bugs near the
// camera, smoothed, so it never pumps)
let camZoom = 1, camZoomWant = 1;
function updateCamera(rdt, alpha) {
  const P = M[0];
  const px = lerp(P.px, P.x, alpha), pz = lerp(P.pz, P.z, alpha);
  const title = GS.screen === 'title';
  const touch = !title && IN.mode === 'touch', portrait = touch && viewH > viewW;
  const lead = title ? 0 : (IN.mode === 'touch' ? 2.4 : 2.0);
  // on touch the look-at point moves toward screen-down: the player sits higher, the thumbs hide less of the near side.
  // Portrait sits the player in the middle of the free band and leads mostly sideways: the screen is ~23 m wide but
  // ~50 m deep, so the narrow axis is the one worth leading into. Landscape and desktop keep a uniform lead.
  const dn = !touch ? 0 : (portrait ? 3.2 : 3);
  const sr = P.ax * RIGHT_X + P.az * RIGHT_Z, su = P.ax * FWD_X + P.az * FWD_Z;
  const lr = portrait ? 3.4 : lead, lu = portrait ? 1.4 : lead;
  const tx = px + RIGHT_X * sr * lr + FWD_X * su * lu - FWD_X * dn, tz = pz + RIGHT_Z * sr * lr + FWD_Z * su * lu - FWD_Z * dn;
  if (!touch) camZoomWant = 1;
  else if (nearCam > 240) camZoomWant = 1.1;
  else if (nearCam < 180) camZoomWant = 1;
  camZoom += (camZoomWant - camZoom) * damp(1.2, rdt);
  const k = damp(title ? 1.5 : 5, rdt);
  camTarget.x += (tx - camTarget.x) * k; camTarget.z += (tz - camTarget.z) * k;
  // follow the floor height (stairs, sloped catwalks) and the rising lift
  // extraction: the camera pulls back and lags the rise, so the platform visibly climbs out of the dark
  const ex = DIR.stage === 'extract' ? smooth01(DIR.extractT / 4.5) : 0;
  const wantY = groundY(px, pz) + (DIR.stage === 'extract' && onLift(P.x, P.z) ? liftGroup.position.y * 0.55 : 0);
  camTarget.y += (wantY - camTarget.y) * damp(DIR.stage === 'extract' ? 8 : 4, rdt);
  const liftY = camTarget.y;
  const yaw = CAM_YAW + (title ? Math.sin(renderTime * 0.06) * 0.35 : 0);
  const pitch = CAM_PITCH - (title ? 0.08 : 0) + 0.12 * ex;
  const dist = camDist * (title ? 1.12 : camZoom) * (1 + 0.35 * ex);
  shake *= Math.exp(-6 * rdt);
  const sk = shake * 0.35;
  // tiny recoil kick against the aim while the player's gun is firing
  const kick = title || P.downed ? 0 : Math.max(0, P.muzzle) * (P.cls === 'gunner' ? 0.045 : 0.07) * (REDUCED_MOTION ? 0.35 : 1);
  const kx = -P.ax * kick, kz = -P.az * kick;
  camera.position.set(
    camTarget.x + kx + Math.sin(yaw) * Math.cos(pitch) * dist + (rnd() - 0.5) * sk,
    liftY + Math.sin(pitch) * dist + (rnd() - 0.5) * sk,
    camTarget.z + kz + Math.cos(yaw) * Math.cos(pitch) * dist + (rnd() - 0.5) * sk);
  camera.lookAt(camTarget.x + kx, liftY, camTarget.z + kz);
  camera.updateMatrixWorld();   // this frame's view for the bug frustum cull and the HUD projections
}

// ---------- marine visuals ----------
function renderMarines(alpha, rdt) {
  const liftOn = DIR.stage === 'extract';
  for (const m of M) {
    const x = lerp(m.px, m.x, alpha), z = lerp(m.pz, m.z, alpha);
    const y = groundY(x, z) + (liftOn && onLift(m.x, m.z) ? liftGroup.position.y : 0);
    m.aimVis += angDiff(m.aimVis, m.aim) * Math.min(1, 22 * rdt);
    m.mesh.rotation.y = m.aimVis;
    const sp = Math.hypot(m.vx, m.vz);
    if (m.downed) {
      m.mesh.position.set(x, y + 0.28, z);
      m.mesh.rotation.x = -1.35;
      m.legL.rotation.x = 0.2; m.legR.rotation.x = -0.1;
    } else {
      m.mesh.position.set(x, y, z);
      m.mesh.rotation.x = m.dashT > 0 ? 0.35 : 0;
      m.walkPh += sp * rdt * 2.6;
      const w = Math.min(1, sp / 4);
      const sw = Math.sin(m.walkPh) * 0.75 * w;
      // legs swing along the movement direction relative to where the marine faces
      const rel = Math.cos(Math.atan2(m.vx, m.vz) - m.aimVis);
      m.legL.rotation.x = sw * rel; m.legR.rotation.x = -sw * rel;
      m.legL.rotation.z = sw * 0.4 * (1 - Math.abs(rel)); m.legR.rotation.z = -m.legL.rotation.z;
      m.body.position.y = Math.abs(Math.sin(m.walkPh)) * 0.05 * w;
      m.gun.position.z = 0.08 - (m.muzzle > 0 ? 0.05 : 0) - (m.cls === 'gunner' && m.firing ? Math.sin(renderTime * 80) * 0.015 : 0);
      if (m.cls === 'gunner') m.gun.rotation.z += m.spin * rdt * 40;
    }
    const hurt = m.hurtT > 0 ? 0.7 : 0, inv = m.inv > 0 && !m.downed && m.dashT <= 0 ? 0.12 + 0.1 * Math.sin(renderTime * 20) : 0;
    m.mat.emissive.setRGB(hurt, inv * 0.8, inv);
  }
}

// ---------- frame loop ----------
// Adaptive quality judges overload against the cadence the display really delivers: WebKit caps rAF at 30 Hz in
// Low Power Mode and under thermal mitigation, and a steady 30 fps there is not overload. Each 3 s window measures
// its shortest frame interval (snapped to a refresh rate) and its mean; two slow windows in a row step the render
// settings down, three fast ones step them back up. Steps never touch gameplay (simCap) and never go below PR_MIN.
const CADENCES = [8.33, 11.1, 16.67, 33.3];
const PR_MIN = IS_MOBILE ? 0.8 : 0.7;
const MAX_STEPS = IS_MOBILE ? 2 : 4;   // catch-up limit: one slow frame must not double the next frame's sim cost
let winMin = 1e9, winSum = 0, winN = 0, winT = 0, slowWins = 0, fastWins = 0, cadence = 16.67;
function snapCadence(ms) { let b = CADENCES[0]; for (const c of CADENCES) if (Math.abs(c - ms) < Math.abs(b - ms)) b = c; return b; }
function adaptQuality(rawMs, rdt) {
  if (GS.screen !== 'playing' || qLocked) { winMin = 1e9; winSum = winN = winT = 0; slowWins = fastWins = 0; return; }
  if (rawMs > 2 && rawMs < 250) { winMin = Math.min(winMin, rawMs); winSum += Math.min(rawMs, 100); winN++; }
  winT += rdt;
  if (winT < 3 || winN < 10) return;
  cadence = snapCadence(winMin);
  const budget = Math.max(16.67, cadence), mean = winSum / winN;
  winMin = 1e9; winSum = winN = winT = 0;
  slowWins = mean > budget * 1.25 ? slowWins + 1 : 0;
  fastWins = mean < budget * 1.08 ? fastWins + 1 : 0;
  if (slowWins >= 2) {
    slowWins = fastWins = 0;
    if (qName === 'high') applyQuality('med', undefined, true);
    else if (qName === 'med') applyQuality('low', undefined, true);
    else if (prScale > PR_MIN + 1e-3) { prScale = Math.max(PR_MIN, prScale * 0.85); resize(); }
  } else if (fastWins >= 3) {
    slowWins = fastWins = 0;
    // resolution first, then low -> med (no shader change); never above the tier the mission started with
    if (prScale < 1 - 1e-3) { prScale = Math.min(1, prScale / 0.85); resize(); }
    else if (qName === 'low' && simCap > QUALITY.low.cap) applyQuality('med', undefined, true);
  }
}
function frame(now) {
  requestAnimationFrame(frame);
  const rawMs = now - last;
  const rdt = Math.min(0.1, Math.max(0, rawMs / 1000));
  last = now;
  frameMs += (rdt * 1000 - frameMs) * 0.05;
  fps = 1000 / Math.max(1, frameMs);
  pollGamepad();
  // menus over a frozen world: draw the scene once, then only keep the DOM and audio alive (no GPU work, no heat)
  const still = GS.screen === 'paused' || GS.screen === 'levelup' || GS.screen === 'won' || GS.screen === 'lost';
  if (still && stillDrawn) { updateHUD(rdt); audioUpdate(rdt); return; }
  stillDrawn = still;
  const running = GS.screen === 'playing' || GS.screen === 'title';
  // hit-stop slows the whole world (simulation + effects) for a few frames
  let ts = timeScale;
  if (hsCd > 0) hsCd -= rdt;
  if (hsT > 0) { hsT -= rdt; ts *= hsK; if (hsT <= 0) hsK = 1; }
  if (running) {
    acc += rdt * ts;
    // debug time scales above 1 may run more steps per frame; real play keeps the catch-up limit
    const maxSteps = MAX_STEPS * Math.max(1, Math.ceil(timeScale));
    let steps = 0;
    while (acc >= DT && steps < maxSteps) { tick(DT); acc -= DT; steps++; }
    if (acc > DT) acc = DT * 0.5;
  }
  if (GS.screen === 'playing' && GS.pendingLevels > 0 && DIR.stage !== 'extract') openLevelUp();
  // (before rendering, so a resized canvas is redrawn in the same frame)
  adaptQuality(rawMs, rdt);
  const alpha = running ? clamp(acc / DT, 0, 1) : 1;
  const vdt = running ? rdt * ts : 0;
  renderTime += vdt;
  updateCamera(rdt, alpha);
  renderMarines(alpha, rdt);
  writeBugInstances(renderTime, vdt);
  renderFx(vdt, renderTime);
  updateHUD(rdt);
  audioUpdate(rdt);
  renderer.info.reset();
  if (composer) composer.render(); else renderer.render(scene, camera);
}

// ---------- debug API (used by the test harness) ----------
function aliveBugs() { let n = 0; for (let i = 0; i < B.n; i++) if (!B.dead[i]) n++; return n; }
function spawnRing(n, type, r0 = 6, r1 = 26) {
  const P = M[0];
  let made = 0;
  for (let k = 0; k < n * 6 && made < n; k++) {
    const a = rnd() * TAU, r = rr(r0, r1), x = P.x + Math.cos(a) * r, z = P.z + Math.sin(a) * r;
    if (!walkable(x, z)) continue;
    if (spawnBug(type >= 0 ? type : pickType(true), x, z, 0) >= 0) made++;
  }
  return made;
}
function snapMarines() { return M.map(m => { const o = {}; for (const k in m) if (typeof m[k] === 'number' || typeof m[k] === 'boolean') o[k] = m[k]; return o; }); }
window.__dbg = {
  state() {
    const P = M[0];
    return {
      screen: GS.screen, time: +GS.time.toFixed(2), fps: Math.round(fps), bugsAlive: aliveBugs(), bugsKilled: GS.kills,
      stage: DIR.stage, objective: objectiveText(),
      player: { hp: Math.round(P.hp), maxHp: P.maxHp, x: +P.x.toFixed(2), z: +P.z.toFixed(2), cls: P.cls, level: GS.level, xp: GS.xp, downed: P.downed },
      squad: M.map(m => ({ name: m.name, cls: m.cls, hp: Math.round(m.hp), downed: m.downed, x: +m.x.toFixed(2), z: +m.z.toFixed(2) })),
      drawCalls: renderer.info.render.calls, triangles: renderer.info.render.triangles, quality: qName, timeScale,
      beacons: DIR.done, liftT: +DIR.liftT.toFixed(1), particles: PA.n + PN.n, decals: decFill, projectiles: PR.n,
      audio: AU.ctx ? AU.ctx.state : 'off', input: IN.mode, hordes: DIR.hordes, volume: AU.vol, muted: AU.muted,
      cooldowns: { ability: +Math.max(0, P.abCd).toFixed(2), dash: +Math.max(0, P.dashCd).toFixed(2) },
      tier: TH.id, station: stationLabel(),
    };
  },
  start(cls, opts) { startMission(cls, Object.assign({ coach: false }, opts)); return this.state(); },
  spawn(n = 100, type) { const t = type ? BUG_TYPE_IDS.indexOf(type) : -1; return spawnRing(n | 0, t); },
  god(on = true) { dbgGod = !!on; godMode = dbgGod || GS.attract; return godMode; },
  skip() {
    if (DIR.stage === 'beacons') { const b = nextBeacon(); if (b) { const k = DIR.beacons.indexOf(b); if (b.state === 0) DIR.active = k; completeBeacon(k); } }
    else if (DIR.stage === 'toLift') {
      M.forEach((m, k) => { const a = Math.PI / 4 + k * Math.PI / 2; m.x = m.px = LV.lift.x + Math.cos(a) * 2; m.z = m.pz = LV.lift.z + Math.sin(a) * 2; });
      startHold();
    } else if (DIR.stage === 'hold') DIR.liftT = 0.01;
    else if (DIR.stage === 'extract') DIR.extractT = 4.5;
    return DIR.stage;
  },
  setQuality(q) { if (QUALITY[q]) { qPref = q; applyQuality(q, true); } return qName; },
  bench(counts = [500, 1500, 3000]) {
    const saved = { n: B.n, arrays: B_ARRAYS.map(a => a.slice(0, B.n)), marines: snapMarines(), kills: GS.kills, sim: simOnly, god: godMode, simTime, dead: deadPending, hpMul: DIR.hpMul,
      gs: { time: GS.time, playerKills: GS.playerKills, shots: GS.shots, hits: GS.hits, combo: GS.combo, comboT: GS.comboT, bestCombo: GS.bestCombo, xp: GS.xp, level: GS.level, xpNext: GS.xpNext, pendingLevels: GS.pendingLevels, upg: { ...GS.upg } } };
    simOnly = true; godMode = true;
    DIR.hpMul = 1e5;   // bugs survive the volley so every tick processes the full count
    const out = [];
    const run = (n, r0, r1) => { clearBugs(); const made = spawnRing(n, -1, r0, r1); for (let k = 0; k < 10; k++) tick(DT); const t0 = performance.now(); for (let k = 0; k < 60; k++) tick(DT); return [made, (performance.now() - t0) / 60]; };
    for (const c of counts) {
      const n = Math.min(c, MAXB);
      // sparse ring (the classic number) ...
      const [made, ms] = run(n, 4, 34);
      // CPU cost of building the per-frame render data (instance buffers, lasers, particles) — no GPU work
      const t1 = performance.now();
      for (let k = 0; k < 20; k++) { writeBugInstances(renderTime, 0); renderFx(0, renderTime); }
      const prep = (performance.now() - t1) / 20, alive = aliveBugs();
      // ... a dense pile at the squad (the chokepoint case) ...
      const [, dense] = run(n, 2, 12);
      // ... and real combat: normal bug HP, the autopilot shooting, kills, corpses and effects on
      const ap = autoPlayer, mu = AU.muted, seen = GS.seen.slice();
      DIR.hpMul = 1; simOnly = false; benchCombat = true; autoPlayer = true; AU.muted = true; GS.seen.fill(true);
      const [, kill] = run(n, 2, 12);
      autoPlayer = ap; simOnly = true; benchCombat = false; AU.muted = mu; GS.seen = seen; DIR.hpMul = 1e5;
      out.push({ count: c, spawned: made, alive, msPerTick: +ms.toFixed(3), denseMsPerTick: +dense.toFixed(3), combatMsPerTick: +kill.toFixed(3), renderPrepMs: +prep.toFixed(3) });
    }
    clearBugs();
    B.n = saved.n; B_ARRAYS.forEach((a, k) => a.set(saved.arrays[k]));
    deadPending = saved.dead;
    saved.marines.forEach((o, k) => Object.assign(M[k], o));
    GS.kills = saved.kills; simOnly = saved.sim; godMode = saved.god; simTime = saved.simTime; DIR.hpMul = saved.hpMul;
    Object.assign(GS, saved.gs); DIR.queue.length = 0;
    PR.n = 0; for (const g of GRN) g.on = false; for (const n of NAP) n.on = false; for (const k of MED) k.on = false; TUR.on = false;
    GL.n = 0; BOOMS.length = 0;
    fxReset();
    rebuildHash(); updateFlows();
    return out;
  },
  timeScale(x = 1) { timeScale = clamp(+x || 1, 0.05, 8); return timeScale; },
  levelup() { GS.level++; GS.xpNext = xpFor(GS.level); GS.pendingLevels++; if (GS.screen === 'playing') openLevelUp(); return GS.level; },
  // extras for automated balance runs
  auto(on = true) { autoPlayer = !!on; return autoPlayer; },
  // play every procedural sound recipe once (audio smoke test); returns the names that threw
  sfxAll() {
    audioInit();
    const bad = [];
    const names = ['pulse', 'mg', 'tur', 'reload', 'overheat', 'explode', 'pop', 'squish', 'shatter', 'freeze', 'hurt', 'down', 'revive', 'dash', 'throw', 'napalm', 'shock', 'thud', 'kill', 'combo', 'hordeRoar', 'nova', 'turret', 'heal', 'spit', 'acid', 'roar', 'swell', 'siren', 'beacon', 'beaconDone', 'lift', 'levelup', 'click', 'heart', 'victory', 'defeat'];
    for (const n of names) { try { AU.last[n] = -1; sfx(n, M[0].x, M[0].z, true); } catch (e) { bad.push(n + ': ' + e.message); } }
    return { state: AU.ctx ? AU.ctx.state : 'off', played: names.length, bad };
  },
  // trigger a horde of n bugs now (tests / screenshots)
  horde(n = 300) { startHorde(n | 0); return DIR.queue.length; },
  // teleport the squad (tests / screenshots)
  tp(x, z) {
    M.forEach((m, k) => { const a = k * TAU / 4; m.x = m.px = x + (k ? Math.cos(a) * 1.6 : 0); m.z = m.pz = z + (k ? Math.sin(a) * 1.6 : 0); if (!canStand(m.x, m.z)) { m.x = m.px = x; m.z = m.pz = z; } });
    camTarget.set(x, groundY(x, z), z); updateFlows();
    return [x, z, +groundY(x, z).toFixed(2)];
  },
  fast(seconds = 10) {
    const n = Math.round(seconds * 60);
    for (let k = 0; k < n && GS.screen === 'playing'; k++) {
      tick(DT);
      while (GS.pendingLevels > 0) { applyUpgrade(rollUpgrades()[0]); GS.pendingLevels--; }
    }
    return this.state();
  },
};
// per-package debug helpers (window.__dbgExt, filled by the v1.1 files that load before this one)
Object.assign(window.__dbg, window.__dbgExt || {});

// ---------- boot ----------
// Compile every material up front (hidden effects included) so the first explosion / beam does not hitch.
function precompile() {
  const hidden = [];
  scene.traverse(o => { if (!o.visible) { hidden.push(o); o.visible = true; } });
  try { renderer.compile(scene, camera); } catch (e) { /* compile is an optimisation only */ }
  for (const o of hidden) o.visible = false;
}
// Warm every program variant this session can switch to, into the target that is really drawn (desktop: the
// composer's target, so no tone mapping in materials), with and without the flashlight shadow — an adaptive
// high -> med step mid-fight then only re-binds cached programs instead of linking ~20 new ones.
function precompileAll() {
  const rt = composer ? composer.renderTarget1 : null;
  renderer.setRenderTarget(rt);
  precompile();
  if (Q.shadows) {
    renderer.shadowMap.enabled = false; spots[0].castShadow = false; bugShadow.castShadow = false;
    precompile();
    renderer.shadowMap.enabled = true; spots[0].castShadow = true; bugShadow.castShadow = true;
  }
  renderer.setRenderTarget(null);
}
renderer.domElement.addEventListener('webglcontextlost', (e) => { e.preventDefault(); if (GS.screen === 'playing') togglePause(); });
function onResize() { resize(); placeStick('L'); placeStick('R'); markHudLayout(); }
function boot(data) {
  data = data || {};
  // iOS app: sound settings were read at load time, before the bridge restored the saved ones
  if (NATIVE) { AU.muted = !!store.get('muted', AU.muted); AU.vol = clamp(+store.get('vol', AU.vol) || AU.vol, 0.1, 1); }
  GS.cls = CLASSES[data.cls] ? data.cls : store.get('cls', 'assault');
  if (!CLASSES[GS.cls]) GS.cls = 'assault';
  if (typeof data.muted === 'boolean') AU.muted = data.muted;
  GS.best = data.best || store.get('best', null);
  metaBoot(data);
  qPref = store.get('quality', 'auto');
  if (QUALITY[qPref]) applyQuality(qPref, true); else { qPref = 'auto'; applyQuality(qName, false); }
  document.body.classList.toggle('touch', IN.mode === 'touch');
  stationBoot();
  resetWorld(GS.cls, true);
  buildTitle();
  showScreen('title');
  placeStick('L'); placeStick('R');
  updateCamera(0.016, 1);
  precompileAll();
  window.addEventListener('resize', onResize);
  window.addEventListener('orientationchange', () => setTimeout(onResize, 120));
  if (window.visualViewport) window.visualViewport.addEventListener('resize', onResize);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { if (GS.screen === 'playing') togglePause(); audioSuspend(); }
    else audioResume();
  });
  $('sLoad').style.display = 'none';
  requestAnimationFrame((t) => {
    last = t; frame(t);
    // iOS app: the launch splash fades out once the first frame is on screen
    if (NATIVE) requestAnimationFrame(() => NATIVE.booted());
  });
}
// iOS app: the shell's background / foreground events (Capacitor App plugin) drive the existing pause + audio logic
if (NATIVE) window.__game = {
  pause() { if (GS.screen === 'playing') { showScreen('paused'); openPauseUI(); } audioSuspend(); },
  resume() { audioResume(); setTimeout(audioResume, 300); },   // retry: the page may still report hidden at the event
};
// iOS app: boot only after the bridge restored the saved settings into localStorage (ready never rejects, 1.5 s cap)
function bootWhenReady(data) {
  if (!NATIVE || !NATIVE.ready) return boot(data);
  const go = () => boot(data);
  NATIVE.ready.then(go, go);
}
try { window.claude?.hot?.snapshot?.(() => ({ best: GS.best, cls: GS.cls, muted: AU.muted })); } catch (e) { /* no hot reload host */ }
if (window.claude?.hot?.ready) window.claude.hot.ready(bootWhenReady); else bootWhenReady(window.claude?.hot?.data ?? {});
