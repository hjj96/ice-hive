// ================================================================
//  MARINES — player + AI squad, weapons, projectiles, abilities
// ================================================================
let godMode = false;
let autoPlayer = false;     // attract mode / debug autopilot: the player marine is AI driven

// Bots keep their targets across kills now (stable bug indices) and fire continuously, so their base damage is
// lower than the player's: the squad backs the player up instead of carrying the fight.
const BOT_DMG = 0.6;
function baseMods(bot) {
  return {
    dmg: bot ? BOT_DMG : 1, rof: 1, pierce: 0, arad: 1, acd: 1, speed: 1, regen: 0, dashCd: 1, range: 1, cone: 1,
    burn: 1, shatter: 1, chill: 1, turretDur: 0, turretRof: 1, heat: 1, cluster: 0, explosive: 0, maxHp: 100,
  };
}

// ---------- marine model ----------
function buildMarineGeos(cls) {
  const C = CLASSES[cls], trim = C.trim, armor = 0x3d4650, dark = 0x1b2025, plate = 0x4b5662, visor = C.laser;
  const body = [];
  const ell = (list, r, sx, sy, sz, x, y, z, color, glow = 0) => { const g = new THREE.IcosahedronGeometry(r, 1); g.scale(sx, sy, sz); g.translate(x, y, z); list.push(paint(g, color, glow)); };
  // hips, belt with pouches
  pBox(body, 0.46, 0.14, 0.3, 0, 0.74, 0, dark);
  for (const s of [-1, 1]) pBox(body, 0.1, 0.12, 0.12, s * 0.2, 0.74, 0.12, 0x2c3238);
  // abdomen + armoured chest
  pBox(body, 0.4, 0.22, 0.26, 0, 0.9, 0, dark);
  pBox(body, 0.58, 0.38, 0.38, 0, 1.15, 0, armor);
  pBox(body, 0.46, 0.22, 0.06, 0, 1.18, 0.2, plate);
  pBox(body, 0.5, 0.06, 0.4, 0, 1.33, 0, trim);
  // chest lamp (where the flashlight comes from)
  pBox(body, 0.08, 0.07, 0.04, 0.14, 1.26, 0.24, 0xfff4dc, 2.6);
  // rounded shoulder pads in the class colour
  for (const s of [-1, 1]) { ell(body, 0.19, 1.25, 0.8, 1.25, s * 0.37, 1.34, 0, trim); pBox(body, 0.05, 0.05, 0.3, s * 0.48, 1.28, 0, dark); }
  // arms holding the weapon (right hand on the grip, left hand on the fore-end)
  pBeam(body, 0.36, 1.28, 0.0, 0.38, 1.05, -0.02, 0.14, 0.14, armor);
  pBeam(body, 0.38, 1.05, -0.02, 0.24, 1.03, 0.17, 0.13, 0.13, dark);
  pBox(body, 0.12, 0.12, 0.12, 0.23, 1.04, 0.18, plate);
  pBeam(body, -0.36, 1.28, 0.0, -0.26, 1.08, 0.2, 0.14, 0.14, armor);
  pBeam(body, -0.26, 1.08, 0.2, 0.1, 1.1, 0.42, 0.13, 0.13, dark);
  pBox(body, 0.12, 0.12, 0.12, 0.11, 1.1, 0.43, plate);
  // helmet with a visor glowing in the marine's laser colour
  pBox(body, 0.16, 0.08, 0.16, 0, 1.45, 0, dark);
  ell(body, 0.19, 1.0, 0.95, 1.12, 0, 1.6, 0.0, armor);
  pBox(body, 0.06, 0.05, 0.36, 0, 1.78, -0.01, trim);
  pBox(body, 0.27, 0.075, 0.08, 0, 1.6, 0.17, visor, 1.7);
  // class backpacks
  if (cls === 'pyro') { for (const s of [-1, 1]) pCyl(body, 0.12, 0.12, 0.6, 8, s * 0.13, 1.12, -0.3, 0xc8761a); pBox(body, 0.36, 0.1, 0.1, 0, 1.4, -0.3, dark); pBox(body, 0.06, 0.06, 0.06, 0, 1.47, -0.3, 0xff9a30, 2); }
  else if (cls === 'cryo') { for (const s of [-1, 1]) pCyl(body, 0.1, 0.1, 0.52, 8, s * 0.12, 1.14, -0.28, 0x2c8fc0, 0.5); pBox(body, 0.34, 0.08, 0.08, 0, 1.4, -0.28, dark); pBox(body, 0.04, 0.3, 0.04, 0, 1.12, -0.42, 0x8ae8ff, 1.6); }
  else if (cls === 'gunner') { pBox(body, 0.5, 0.52, 0.32, 0, 1.1, -0.33, 0x3e5a32); pBox(body, 0.42, 0.06, 0.34, 0, 1.22, -0.33, 0x8ac46a, 0.6); pCyl(body, 0.05, 0.05, 0.5, 6, 0.24, 1.0, -0.12, 0x6a7078, 0, Math.PI / 2.4); }
  else { pBox(body, 0.42, 0.46, 0.24, 0, 1.12, -0.3, 0x4a2a28); pBox(body, 0.08, 0.3, 0.05, 0.12, 1.2, -0.43, 0xff5040, 0.9); pBox(body, 0.02, 0.5, 0.02, -0.14, 1.5, -0.34, dark); }
  const leg = [];
  pBox(leg, 0.2, 0.42, 0.24, 0, -0.2, 0, armor);
  pBox(leg, 0.17, 0.13, 0.08, 0, -0.4, 0.12, trim);
  pBox(leg, 0.18, 0.36, 0.2, 0, -0.56, 0.01, dark);
  pBox(leg, 0.22, 0.12, 0.33, 0, -0.73, 0.05, armor);
  const gun = [];
  if (cls === 'assault') {
    pBox(gun, 0.11, 0.14, 0.86, 0, 0, 0.32, 0x2a2f35); pBox(gun, 0.08, 0.2, 0.14, 0, -0.12, 0.12, dark);
    pBox(gun, 0.13, 0.05, 0.4, 0, 0.09, 0.3, trim); pBox(gun, 0.03, 0.03, 0.06, 0, 0.0, 0.76, 0xff3a2a, 2);
  } else if (cls === 'pyro') {
    pCyl(gun, 0.07, 0.09, 0.8, 8, 0, 0, 0.36, 0x3a3530, 0, Math.PI / 2); pCyl(gun, 0.1, 0.1, 0.18, 8, 0, 0, 0.76, 0x1a1a1a, 0, Math.PI / 2);
    pBox(gun, 0.05, 0.05, 0.1, 0, -0.08, 0.82, 0x5ab4ff, 2);
  } else if (cls === 'cryo') {
    pBox(gun, 0.14, 0.16, 0.76, 0, 0, 0.3, 0x2a3540);
    for (let k = 0; k < 3; k++) pTorus(gun, 0.1, 0.025, 0, 0, 0, 0x60d8ff, 2), gun[gun.length - 1].rotateX(Math.PI / 2), gun[gun.length - 1].translate(0, 0, 0.36 + k * 0.14);
    pBox(gun, 0.06, 0.06, 0.08, 0, 0, 0.72, 0xbff4ff, 2.5);
  } else {
    for (let k = 0; k < 6; k++) { const a = k / 6 * TAU; pCyl(gun, 0.03, 0.03, 0.92, 5, Math.cos(a) * 0.07, Math.sin(a) * 0.07, 0.42, 0x23282e, 0, Math.PI / 2); }
    pCyl(gun, 0.13, 0.13, 0.3, 8, 0, 0, 0.0, 0x3e5a32, 0, Math.PI / 2);
    pCyl(gun, 0.1, 0.1, 0.05, 8, 0, 0, 0.84, 0x6a7078, 0, Math.PI / 2);
  }
  return { body: mergeGeometries(body), leg: mergeGeometries(leg), gun: mergeGeometries(gun) };
}

// one material per squad slot, created once: disposing them per mission released the shared program (relink)
const MARINE_MATS = [];
function makeMarine(i, cls, name, isPlayer) {
  const C = CLASSES[cls], geos = buildMarineGeos(cls);
  const mat = MARINE_MATS[i] || (MARINE_MATS[i] = makeGlowMaterial({ snow: false, roughness: 0.55, metalness: 0.5 }));
  const g = new THREE.Group(); g.rotation.order = 'YXZ';
  const body = new THREE.Mesh(geos.body, mat);
  const legL = new THREE.Mesh(geos.leg, mat), legR = new THREE.Mesh(geos.leg, mat);
  legL.position.set(-0.13, 0.78, 0); legR.position.set(0.13, 0.78, 0);
  const gun = new THREE.Mesh(geos.gun, mat); gun.position.set(0.2, 1.12, 0.08);
  for (const o of [body, legL, legR, gun]) { o.castShadow = true; g.add(o); }
  g.scale.setScalar(1.12);
  scene.add(g);
  return {
    i, cls, C, name, isPlayer, mods: baseMods(!isPlayer), color: C.laser,
    x: 0, z: 0, px: 0, pz: 0, vx: 0, vz: 0, kx: 0, kz: 0, aim: 0, aimVis: 0, ax: 0, az: 1, faceX: FWD_X, faceZ: FWD_Z,
    hp: 100, maxHp: 100, downed: false, revive: 0, inv: 0, hurtT: 0, dashT: 0, dashCd: 0, dashX: 0, dashZ: 0,
    abCd: 0, fireCd: 0, heat: 0, over: 0, spin: 0, energy: 1, ammo: C.mag || 0, reload: 0, bar: 1, firing: false,
    beamLen: 0, laserLen: 0, walkPh: 0, muzzle: 0, calm: 0, bite: 3,
    ai: { think: 0, target: -1, tuid: 0, dodge: 0, stuck: 0, lx: 0, lz: 0, sideX: 0, sideZ: 0, sideT: 0 },
    mesh: g, body, legL, legR, gun, mat,
  };
}

const M = [];
let pyroIdx = -1, cryoIdx = -1;
function setupSquad(playerCls) {
  for (const m of M) { scene.remove(m.mesh); m.body.geometry.dispose(); m.legL.geometry.dispose(); m.gun.geometry.dispose(); }
  M.length = 0;
  const others = CLASS_ORDER.filter(c => c !== playerCls);
  M.push(makeMarine(0, playerCls, 'ВЫ', true));
  others.forEach((c, k) => { const b = makeMarine(k + 1, c, BOT_NAMES[k], false); b.hp = b.maxHp = 120; M.push(b); });
  pyroIdx = M.findIndex(m => m.cls === 'pyro');
  cryoIdx = M.findIndex(m => m.cls === 'cryo');
  const s = LV.start;
  M.forEach((m, k) => {
    m.x = m.px = s.x + [0, -1.6, 1.6, 0][k]; m.z = m.pz = s.z + [0, 1.4, 1.4, 2.6][k];
    m.aim = m.aimVis = Math.atan2(FWD_X, FWD_Z); m.ax = FWD_X; m.az = FWD_Z;
  });
}
function pyroSpread() { return pyroIdx >= 0 ? M[pyroIdx].mods.burn : 1; }
function pyroBurnMul(src) { return src >= 0 && src < 4 ? M[src].mods.burn : 1; }

// ---------- collision ----------
function canStand(x, z) { return walkable(x, z) && walkable(x + 0.32, z) && walkable(x - 0.32, z) && walkable(x, z + 0.32) && walkable(x, z - 0.32); }
function moveMarine(m, dt, wx, wz) {
  const crowdMul = clamp(1 - crowd[m.i] * 0.045, 0.42, 1);
  const spd = 5.3 * m.mods.speed * crowdMul;
  if (m.dashT > 0) { m.dashT -= dt; m.vx = m.dashX * 17; m.vz = m.dashZ * 17; }
  else { const k = Math.min(1, 12 * dt); m.vx += (wx * spd - m.vx) * k; m.vz += (wz * spd - m.vz) * k; }
  const kd = Math.exp(-7 * dt); m.kx *= kd; m.kz *= kd;
  const tx = m.vx + m.kx, tz = m.vz + m.kz;
  const nx = m.x + tx * dt, nz = m.z + tz * dt;
  if (canStand(nx, nz)) { m.x = nx; m.z = nz; }
  else if (canStand(nx, m.z)) { m.x = nx; m.vz *= 0.5; }
  else if (canStand(m.x, nz)) { m.z = nz; m.vx *= 0.5; }
  // squad members don't overlap
  for (const o of M) {
    if (o === m) continue;
    const dx = m.x - o.x, dz = m.z - o.z, d2 = dx * dx + dz * dz;
    if (d2 < 0.64 && d2 > 1e-6) { const d = Math.sqrt(d2), p = (0.8 - d) * 0.5; const qx = m.x + dx / d * p, qz = m.z + dz / d * p; if (canStand(qx, qz)) { m.x = qx; m.z = qz; } }
  }
}
function tryDash(m, dx, dz) {
  if (m.dashCd > 0 || m.downed) return;
  const l = Math.hypot(dx, dz);
  if (l < 0.1) { dx = m.ax; dz = m.az; } else { dx /= l; dz /= l; }
  m.dashX = dx; m.dashZ = dz; m.dashT = 0.22; m.inv = Math.max(m.inv, 0.32); m.dashCd = 3 * m.mods.dashCd;
  if (!simOnly) { fxDash(m); sfx('dash', m.x, m.z); if (m.isPlayer) haptic('select'); }
}

// ---------- damage to marines ----------
function hurtMarine(m, dmg, kx, kz) {
  if (m.downed) return;
  if (godMode || m.inv > 0 || m.dashT > 0) { m.kx += kx * 0.3; m.kz += kz * 0.3; return; }
  m.hp -= dmg; m.hurtT = 0.22; m.kx += kx; m.kz += kz; m.calm = 0;
  // taking a hit breaks the combo: it rewards clean play, not just standing in a horde
  if (m.isPlayer) { GS.combo = 0; GS.comboT = 0; }
  if (m.isPlayer && !simOnly) { GS.dmgFlash = Math.min(1, GS.dmgFlash + dmg / 28); addShake(0.12 + dmg * 0.012); sfx('hurt'); haptic(dmg >= 12 ? 'heavy' : 'light'); }
  if (m.hp <= 0) downMarine(m);
}
function downMarine(m) {
  m.hp = 0; m.downed = true; m.revive = 0; m.firing = false; m.dashT = 0;
  if (!simOnly) { toast(m.isPlayer ? 'Вы ранены — ждите помощи' : m.name + ' ранен', 'warn'); sfx('down', m.x, m.z); if (m.isPlayer) { hitStop(0.3, 0.2); addShake(0.4); haptic('error'); } }
}
function updateRevive(dt) {
  for (const m of M) {
    if (!m.downed) continue;
    let helped = false;
    for (const o of M) if (o !== m && !o.downed && (o.x - m.x) ** 2 + (o.z - m.z) ** 2 < 5.3) helped = true;
    m.revive = helped ? m.revive + dt / 3 : Math.max(0, m.revive - dt * 0.25);
    if (m.revive >= 1) {
      m.downed = false; m.hp = m.maxHp * 0.45; m.inv = 1.6; m.revive = 0;
      if (!simOnly) { toast((m.isPlayer ? 'Вы снова в строю' : m.name + ' в строю'), 'gold'); sfx('revive', m.x, m.z); }
    }
  }
}

// ---------- projectiles (pulse bolts, minigun & turret rounds) ----------
const PMAX = 700;
const PR = {
  n: 0, x: new Float32Array(PMAX), z: new Float32Array(PMAX), dx: new Float32Array(PMAX), dz: new Float32Array(PMAX),
  spd: new Float32Array(PMAX), life: new Float32Array(PMAX), dmg: new Float32Array(PMAX), pierce: new Uint8Array(PMAX),
  own: new Int8Array(PMAX), col: new Uint8Array(PMAX), last: new Int32Array(PMAX), flags: new Uint8Array(PMAX),
};
const PR_ARR = Object.keys(PR).filter(k => k !== 'n').map(k => PR[k]);
// colour index: 0 red pulse, 1 green minigun, 2 green turret
function fireBolt(ox, oz, ang, spd, dmg, pierce, own, col, playerShot) {
  if (PR.n >= PMAX) return;
  const k = PR.n++;
  PR.x[k] = ox; PR.z[k] = oz; PR.dx[k] = Math.sin(ang); PR.dz[k] = Math.cos(ang); PR.spd[k] = spd; PR.life[k] = 0.42;
  PR.dmg[k] = dmg; PR.pierce[k] = pierce; PR.own[k] = own; PR.col[k] = col; PR.last[k] = 0; PR.flags[k] = playerShot ? 1 : 0;
  if (playerShot) GS.shots++;
}
let segT = 0;
function segHit(sx, sz, dx, dz, len, exclude) {
  let best = -1; segT = len;
  const ex = sx + dx * len, ez = sz + dz * len;
  const i0 = Math.max(0, Math.floor(Math.min(sx, ex) - 1 + GH)), i1 = Math.min(G - 1, Math.floor(Math.max(sx, ex) + 1 + GH));
  const j0 = Math.max(0, Math.floor(Math.min(sz, ez) - 1 + GH)), j1 = Math.min(G - 1, Math.floor(Math.max(sz, ez) + 1 + GH));
  for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) {
    const c = j * G + i, e = hStart[c + 1];
    for (let k = hStart[c]; k < e; k++) {
      const b = hItems[k];
      if (B.dead[b] || B.uid[b] === exclude || B.st[b] === S_CLIMB) continue;
      const bx = B.x[b] - sx, bz = B.z[b] - sz, t = bx * dx + bz * dz;
      if (t < -0.3 || t > segT) continue;
      const px = bx - dx * t, pz = bz - dz * t, r = B.r[b] + 0.08;
      if (px * px + pz * pz < r * r) { segT = Math.max(0, t); best = b; }
    }
  }
  return best;
}
function updateProjectiles(dt) {
  for (let k = 0; k < PR.n; k++) {
    let sx = PR.x[k], sz = PR.z[k];
    const dx = PR.dx[k], dz = PR.dz[k];
    let len = PR.spd[k] * dt, alive = true, guard = 4;
    while (alive && guard-- > 0) {
      const b = segHit(sx, sz, dx, dz, len, PR.last[k]);
      if (b < 0) break;
      const own = PR.own[k];
      const hx = sx + dx * segT, hz = sz + dz * segT;
      if (PR.flags[k] & 1) { if (!(PR.flags[k] & 2)) { GS.hits++; PR.flags[k] |= 2; } }
      B.vx[b] += dx * 1.2; B.vz[b] += dz * 1.2;
      const killed = hitBug(b, PR.dmg[k], own);
      if (!simOnly) fxBulletHit(hx, hz, dx, dz, killed);
      if (own >= 0 && own < 4 && M[own].mods.explosive > 0 && rnd() < 0.12 * M[own].mods.explosive) queueBoom(hx, hz, 1.7, 22 * M[own].mods.dmg, own, 'mini');
      if (PR.pierce[k] > 0) { PR.pierce[k]--; PR.last[k] = B.uid[b]; len -= segT; sx = hx; sz = hz; }
      else alive = false;
    }
    PR.x[k] += dx * PR.spd[k] * dt; PR.z[k] += dz * PR.spd[k] * dt;
    PR.life[k] -= dt;
    if (!alive || PR.life[k] <= 0) {
      const l = --PR.n;
      if (k !== l) for (const A of PR_ARR) A[k] = A[l];
      k--;
    }
  }
}

// ---------- weapons ----------
const _mz = [0, 0];
function muzzlePos(m) { _mz[0] = m.x + m.ax * 0.95 + m.az * 0.22; _mz[1] = m.z + m.az * 0.95 - m.ax * 0.22; return _mz; }
function updateWeapon(m, dt, want) {
  const C = m.C, md = m.mods;
  m.firing = false;
  if (m.cls === 'assault') {
    if (m.reload > 0) { m.reload -= dt; if (m.reload <= 0) m.ammo = C.mag; }
    m.fireCd -= dt;
    if (want && m.reload <= 0) {
      m.firing = true;
      let shots = 0;
      while (m.fireCd <= 0 && m.ammo > 0 && shots < 3) {
        const mp = muzzlePos(m);
        fireBolt(mp[0], mp[1], m.aim + (rnd() - 0.5) * C.spread * 2, C.pspeed, C.dmg * md.dmg, C.pierce + md.pierce, m.i, 0, m.isPlayer);
        m.ammo--; m.fireCd += 1 / (C.rof * md.rof); m.muzzle = 1; shots++;
        if (!simOnly) sfx('pulse', m.x, m.z, m.isPlayer);
      }
      if (m.ammo <= 0) { m.reload = C.reload; if (!simOnly) sfx('reload', m.x, m.z, m.isPlayer); }
    }
    if (!want && m.fireCd < 0) m.fireCd = 0;
    m.bar = m.reload > 0 ? 1 - m.reload / C.reload : m.ammo / C.mag;
  } else if (m.cls === 'gunner') {
    const spinning = want && m.over <= 0;
    m.spin = spinning ? Math.min(1, m.spin + dt / C.spinTime) : Math.max(0, m.spin - dt / 0.9);
    if (m.over > 0) { m.over -= dt; m.heat = Math.max(0, m.heat - dt * 0.45); }
    else if (spinning && m.spin > 0.35) {
      m.firing = true; m.fireCd -= dt;
      const rate = C.rof * md.rof * (0.3 + 0.7 * m.spin);
      let shots = 0;
      while (m.fireCd <= 0 && shots < 4) {
        const mp = muzzlePos(m);
        fireBolt(mp[0], mp[1], m.aim + (rnd() - 0.5) * C.spread * 2, C.pspeed, C.dmg * md.dmg, C.pierce + md.pierce, m.i, 1, m.isPlayer);
        m.fireCd += 1 / rate; m.muzzle = 1; shots++;
        if (!simOnly) sfx('mg', m.x, m.z, m.isPlayer);
      }
      m.heat += dt / (C.heatTime * md.heat);
      if (m.heat >= 1) { m.heat = 1; m.over = 2.4; if (!simOnly) sfx('overheat', m.x, m.z, m.isPlayer); }
    } else { m.heat = Math.max(0, m.heat - dt * 0.35); if (m.fireCd < 0) m.fireCd = 0; }
    m.bar = 1 - m.heat;
  } else if (m.cls === 'pyro') {
    if (m.over > 0) { m.over -= dt; m.heat = Math.max(0, m.heat - dt * 0.5); }
    else if (want) {
      m.firing = true; flameTick(m, dt);
      m.heat += dt / (C.heatTime * md.heat);
      if (m.heat >= 1) { m.heat = 1; m.over = 2.0; if (!simOnly) sfx('overheat', m.x, m.z, m.isPlayer); }
    } else m.heat = Math.max(0, m.heat - dt * 0.42);
    m.bar = 1 - m.heat;
  } else {
    if (m.over > 0) { m.over -= dt; m.energy = Math.min(1, m.energy + dt * 0.5); }
    else if (want && m.energy > 0) {
      m.firing = true; beamTick(m, dt);
      m.energy -= dt / (C.energyTime * md.heat);
      if (m.energy <= 0) { m.energy = 0; m.over = 1.6; if (!simOnly) sfx('overheat', m.x, m.z, m.isPlayer); }
    } else m.energy = Math.min(1, m.energy + dt * 0.3);
    m.bar = m.energy;
  }
  if (m.isPlayer && (m.cls === 'pyro' || m.cls === 'cryo') && m.firing) GS.shots += 1 / 6;
}
function flameTick(m, dt) {
  const C = m.C, md = m.mods, range = C.range * md.range, cosC = Math.cos(C.cone * md.cone);
  const ox = m.x + m.ax * 0.7, oz = m.z + m.az * 0.7;
  const cnt = queryCircle(ox + m.ax * range * 0.5, oz + m.az * range * 0.5, range * 0.58);
  let hitAny = false;
  for (let q = 0; q < cnt; q++) {
    const b = QB[q];
    const dx = B.x[b] - ox, dz = B.z[b] - oz, d = Math.sqrt(dx * dx + dz * dz) + 1e-4;
    if (d > range + B.r[b]) continue;
    if (d > 0.9 && (dx * m.ax + dz * m.az) / d < cosC) continue;
    hitAny = true;
    B.burn[b] = C.burn; B.bsrc[b] = m.i;
    B.vx[b] += m.ax * 3 * dt; B.vz[b] += m.az * 3 * dt;
    hitBug(b, C.dps * md.dmg * md.rof * dt * (1 - 0.35 * d / range), m.i, true);
  }
  if (m.isPlayer && hitAny) GS.hits += 1 / 6;
}
function beamTick(m, dt) {
  const C = m.C, md = m.mods, len = C.range * md.range;
  const ox = m.x + m.ax * 0.8, oz = m.z + m.az * 0.8;
  const cnt = queryCircle(ox + m.ax * len * 0.5, oz + m.az * len * 0.5, len * 0.56);
  let hitAny = false;
  for (let q = 0; q < cnt; q++) {
    const b = QB[q];
    const dx = B.x[b] - ox, dz = B.z[b] - oz, t = dx * m.ax + dz * m.az;
    if (t < -0.3 || t > len) continue;
    const perp = Math.abs(dx * m.az - dz * m.ax), w = 0.42 + t / len * 0.75;
    if (perp > w + B.r[b]) continue;
    hitAny = true;
    if (B.frz[b] <= 0) {
      B.chill[b] += C.chill * md.chill * dt;
      if (B.chill[b] >= 1) { B.chill[b] = 1; B.frz[b] = B.type[b] === BRUTE ? 1.3 : 2.6; if (!simOnly) sfx('freeze', B.x[b], B.z[b]); }
    }
    hitBug(b, C.dps * md.dmg * md.rof * dt, m.i, true);
  }
  m.beamLen = len;
  if (m.isPlayer && hitAny) GS.hits += 1 / 6;
}

// ---------- abilities ----------
const GRN = [];
for (let k = 0; k < 12; k++) GRN.push({ on: false, sx: 0, sz: 0, tx: 0, tz: 0, t: 0, dur: 1, own: 0, r: 5, dmg: 150, cluster: 0, big: true });
const NAP = [];
for (let k = 0; k < 3; k++) NAP.push({ on: false, x: 0, z: 0, r: 5, t: 0, own: 0 });
const TUR = { on: false, x: 0, z: 0, t: 0, ang: 0, cd: 0, own: 0, think: 0, target: -1, tuid: 0, laser: 0 };
// «Расширенный заряд» widens the turret's reach for the gunner
function turretRange() { const o = M[TUR.own]; return 15 * (o ? o.mods.arad : 1); }

function useAbility(m, tx, tz) {
  if (m.abCd > 0 || m.downed) return false;
  const md = m.mods;
  m.abCd = m.C.abCd * md.acd;
  if (m.cls === 'assault') {
    let dx = tx - m.x, dz = tz - m.z; const d = Math.hypot(dx, dz);
    if (d > 13) { tx = m.x + dx / d * 13; tz = m.z + dz / d * 13; }
    throwGrenade(m.x + m.ax * 0.6, m.z + m.az * 0.6, tx, tz, m.i, 5 * md.arad, 150 * md.dmg, md.cluster, true);
    if (!simOnly) sfx('throw', m.x, m.z, m.isPlayer);
  } else if (m.cls === 'pyro') {
    const n = NAP.find(e => !e.on) || NAP[0];
    n.on = true; n.x = m.x; n.z = m.z; n.r = 5 * md.arad; n.t = 5; n.own = m.i;
    const cnt = queryCircle(m.x, m.z, n.r);
    for (let q = 0; q < cnt; q++) { const b = QB[q]; B.burn[b] = 5; B.bsrc[b] = m.i; hitBug(b, 30 * md.dmg, m.i); }
    if (!simOnly) { fxNapalmBurst(m.x, m.z, n.r); sfx('napalm', m.x, m.z, m.isPlayer); }
  } else if (m.cls === 'cryo') {
    const r = 7 * md.arad, cnt = queryCircle(m.x, m.z, r);
    for (let q = 0; q < cnt; q++) { const b = QB[q]; B.frz[b] = B.type[b] === BRUTE ? 1.6 : 3.2; B.chill[b] = 1; B.vx[b] = B.vz[b] = 0; hitBug(b, 30 * md.dmg, m.i); }
    if (!simOnly) { fxNova(m.x, m.z, r); sfx('nova', m.x, m.z, m.isPlayer); }
  } else {
    let x = m.x + m.ax * 1.3, z = m.z + m.az * 1.3;
    if (!canStand(x, z)) { x = m.x; z = m.z; }
    Object.assign(TUR, { on: true, x, z, t: 15 + md.turretDur, ang: m.aim, cd: 0, own: m.i, think: 0, target: -1 });
    if (!simOnly) { fxTurretDrop(x, z); sfx('turret', x, z, m.isPlayer); }
  }
  if (m.isPlayer) haptic('light');
  return true;
}
function throwGrenade(sx, sz, tx, tz, own, r, dmg, cluster, big) {
  const g = GRN.find(e => !e.on); if (!g) return;
  Object.assign(g, { on: true, sx, sz, tx, tz, t: 0, dur: big ? 0.7 : 0.38, own, r, dmg, cluster, big });
}
function updateAbilities(dt) {
  for (const g of GRN) {
    if (!g.on) continue;
    g.t += dt;
    if (g.t < g.dur) continue;
    g.on = false;
    queueBoom(g.tx, g.tz, g.r, g.dmg, g.own, g.big ? 'frag' : 'mini');
    for (let k = 0; k < g.cluster; k++) {
      const a = rnd() * TAU, d = 2 + rnd() * 2.5;
      throwGrenade(g.tx, g.tz, g.tx + Math.cos(a) * d, g.tz + Math.sin(a) * d, g.own, 2.6, g.dmg * 0.4, 0, false);
    }
  }
  for (const n of NAP) {
    if (!n.on) continue;
    n.t -= dt;
    if (n.t <= 0) { n.on = false; continue; }
    const cnt = queryCircle(n.x, n.z, n.r + 1.4);
    for (let q = 0; q < cnt; q++) {
      const b = QB[q], d = Math.hypot(B.x[b] - n.x, B.z[b] - n.z);
      if (Math.abs(d - n.r) > 1.3) continue;
      B.burn[b] = 3.5; B.bsrc[b] = n.own;
      hitBug(b, 28 * M[n.own].mods.dmg * dt, n.own, true);
    }
  }
  if (TUR.on) {
    TUR.t -= dt;
    if (TUR.t <= 0) { TUR.on = false; if (!simOnly) fxTurretDrop(TUR.x, TUR.z); }
    else {
      TUR.think -= dt;
      if (TUR.think <= 0) {
        TUR.think = 0.12; TUR.target = -1;
        const cnt = queryCircle(TUR.x, TUR.z, turretRange());
        let bd = 1e9;
        for (let q = 0; q < cnt; q++) { const b = QB[q]; const d = (B.x[b] - TUR.x) ** 2 + (B.z[b] - TUR.z) ** 2 - (B.type[b] === BOOM ? 30 : 0); if (d < bd) { bd = d; TUR.target = b; } }
        if (TUR.target >= 0) TUR.tuid = B.uid[TUR.target];
      }
      const b = TUR.target;
      if (b >= 0 && !B.dead[b] && B.uid[b] === TUR.tuid) {
        const want = Math.atan2(B.x[b] - TUR.x, B.z[b] - TUR.z);
        const d = angDiff(TUR.ang, want);
        TUR.ang += clamp(d, -9 * dt, 9 * dt);
        TUR.cd -= dt;
        if (Math.abs(d) < 0.2 && TUR.cd <= 0) {
          const md = M[TUR.own].mods;
          TUR.cd = 1 / (10 * md.turretRof);
          fireBolt(TUR.x + Math.sin(TUR.ang) * 0.7, TUR.z + Math.cos(TUR.ang) * 0.7, TUR.ang + (rnd() - 0.5) * 0.05, 90, 11 * md.dmg, 0, TUR.own, 2, false);
          TUR.laser = 1;
          if (!simOnly) sfx('tur', TUR.x, TUR.z);
        }
      }
    }
  }
}

// ---------- medkits ----------
const MED = [];
for (let k = 0; k < 6; k++) MED.push({ on: false, x: 0, z: 0, t: 0 });
function dropMedkit(x, z) {
  const m = MED.find(e => !e.on); if (!m) return;
  if (!walkable(x, z)) return;
  m.on = true; m.x = x; m.z = z; m.t = 30;
}
function updateMedkits(dt) {
  for (const k of MED) {
    if (!k.on) continue;
    k.t -= dt;
    if (k.t <= 0) { k.on = false; continue; }
    let best = null, bd = 1.7;
    for (const m of M) { if (m.downed || m.hp >= m.maxHp) continue; const d = Math.hypot(m.x - k.x, m.z - k.z); if (d < bd) { bd = d; best = m; } }
    if (best) {
      best.hp = Math.min(best.maxHp, best.hp + 40); k.on = false;
      if (!simOnly) { fxHeal(best); sfx('heal', k.x, k.z, best.isPlayer); if (best.isPlayer) toast('Аптечка +40', 'gold'); }
    }
  }
}

// ---------- AI ----------
const FORM = [[0, 0], [-2.4, -1.5], [2.4, -1.5], [0, -2.9]];
const _bot = { mx: 0, mz: 0, fire: false };
function aiPickTarget(m, range) {
  const cnt = queryCircle(m.x, m.z, range);
  let best = -1, bs = 1e9;
  const P = M[0];
  for (let q = 0; q < cnt; q++) {
    const b = QB[q];
    if (B.st[b] === S_CLIMB && B.y[b] < -0.8) continue;
    const dx = B.x[b] - m.x, dz = B.z[b] - m.z, d = Math.sqrt(dx * dx + dz * dz);
    const off = Math.abs(angDiff(m.aim, Math.atan2(dx, dz)));
    let s = d + off * 2.2;
    const ty = B.type[b];
    if (ty === BOOM && d < 8) s -= 6;
    if (ty === BRUTE) s -= 2.5;
    if (B.st[b] === S_CHARGE || B.st[b] === S_WIND) s -= 3;
    if (!P.downed && (B.x[b] - P.x) ** 2 + (B.z[b] - P.z) ** 2 < 16) s -= 3;
    if (m.cls === 'cryo' && B.frz[b] > 0) s += 4;
    if (s < bs) { bs = s; best = b; }
  }
  return best;
}
function objectivePoint() {
  if (DIR.stage === 'beacons') { const b = nextBeacon(); if (b) return [b.x, b.z]; }
  if (DIR.stage === 'toLift' || DIR.stage === 'hold' || DIR.stage === 'extract') return [LV.lift.x, LV.lift.z];
  return [M[0].x, M[0].z];
}
function botThink(m, dt) {
  const ai = m.ai, P = M[0], C = m.C, md = m.mods;
  const range = m.cls === 'pyro' ? C.range * md.range + 1.2 : m.cls === 'cryo' ? C.range * md.range : 17;
  ai.think -= dt;
  if (ai.think <= 0) {
    ai.think = 0.12 + rnd() * 0.08;
    ai.target = aiPickTarget(m, range);
    ai.tuid = ai.target >= 0 ? B.uid[ai.target] : 0;
    // abilities
    if (m.abCd <= 0) {
      if (m.cls === 'assault' && ai.target >= 0) {
        const tx = B.x[ai.target], tz = B.z[ai.target];
        if (Math.hypot(tx - m.x, tz - m.z) > 4 && (queryCircle(tx, tz, 3.5) >= 7 || B.type[ai.target] === BRUTE)) useAbility(m, tx, tz);
      } else if (m.cls === 'pyro' && queryCircle(m.x, m.z, 4.5) >= 9) useAbility(m, 0, 0);
      else if (m.cls === 'cryo' && queryCircle(m.x, m.z, 6.5) >= 13) useAbility(m, 0, 0);
      else if (m.cls === 'gunner' && queryCircle(m.x, m.z, 12) >= 18) useAbility(m, 0, 0);
    }
  }
  // --- where to stand ---
  let gx = m.x, gz = m.z, urgent = false;
  let reviveT = null, rd = 1e9;
  for (const o of M) {
    if (!o.downed || o === m) continue;
    // nearest standing bot takes the job
    let mine = true;
    for (const h of M) if (h !== m && !h.downed && !h.isPlayer && Math.hypot(h.x - o.x, h.z - o.z) < Math.hypot(m.x - o.x, m.z - o.z) - 0.5) mine = false;
    if (o.isPlayer) mine = true;
    const d = Math.hypot(o.x - m.x, o.z - m.z);
    if (mine && d < rd && d < 40) { rd = d; reviveT = o; }
  }
  if (m.isPlayer) {
    const [ox, oz] = objectivePoint(); gx = ox; gz = oz;
    const b = DIR.stage === 'beacons' ? nextBeacon() : null;
    // orbit outside the 2x2 blocked base (its corners need ~1.9 m clearance)
    if (b && b.state === 1) { gx = b.x + Math.cos(simTime * 0.3) * 2.6; gz = b.z + Math.sin(simTime * 0.3) * 2.6; }
    if (reviveT) { gx = reviveT.x; gz = reviveT.z; urgent = true; }
  } else if (reviveT) { gx = reviveT.x; gz = reviveT.z; urgent = true; }
  else if ((DIR.stage === 'hold' || DIR.stage === 'extract') && onLift(P.x, P.z)) {
    const a = Math.PI / 4 + m.i * Math.PI / 2; gx = LV.lift.x + Math.cos(a) * 5.2; gz = LV.lift.z + Math.sin(a) * 5.2;
  } else if (DIR.active >= 0 && Math.hypot(P.x - DIR.beacons[DIR.active].x, P.z - DIR.beacons[DIR.active].z) < 7) {
    const b = DIR.beacons[DIR.active], a = m.i * TAU / 3 + 0.5; gx = b.x + Math.cos(a) * 2.6; gz = b.z + Math.sin(a) * 2.6;
  } else {
    const fx = P.faceX, fz = P.faceZ, sx = -fz, sz = fx;
    const s = FORM[m.i][0], bk = FORM[m.i][1];
    gx = P.x + sx * s + fx * bk; gz = P.z + sz * s + fz * bk;
    if (!canStand(gx, gz)) { gx = P.x - fx * 1.5; gz = P.z - fz * 1.5; }
  }
  let wx = gx - m.x, wz = gz - m.z;
  const dist = Math.hypot(wx, wz);
  let mx = 0, mz = 0;
  const arrive = urgent ? 0.6 : 1.1;
  if (dist > arrive) { const sp = clamp((dist - arrive) / 2.5, 0.25, 1); mx = wx / dist * sp; mz = wz / dist * sp; }
  // path along catwalks with a flow field when the straight line is blocked or the goal is far
  if (dist > 2) {
    const c = cellOf(m.x, m.z);
    const F = reviveT ? reviveFlow : m.isPlayer ? objFlow : squadFlow;
    const blocked = !canStand(m.x + wx / dist * 1.3, m.z + wz / dist * 1.3) || ai.stuck > 0.3;
    const farFromLeader = !m.isPlayer && Math.hypot(P.x - m.x, P.z - m.z) > 9;
    if (c >= 0 && (F.x[c] || F.z[c]) && (blocked || farFromLeader || m.isPlayer)) {
      // aim a little ahead of the current cell centre: follows the field and keeps off the railings
      const tx = cellX(c) + F.x[c] * 1.3 - m.x, tz = cellZ(c) + F.z[c] * 1.3 - m.z, l = Math.hypot(tx, tz) || 1;
      mx = tx / l; mz = tz / l;
    }
  }
  // safety net: wedged for a while -> step back to the centre of the current cell (always a valid standing spot)
  if (ai.stuck > 1.5) { const c = cellOf(m.x, m.z); if (c >= 0) { mx = cellX(c) - m.x; mz = cellZ(c) - m.z; } }
  // keep some distance from the swarm (pyro likes it closer)
  const t = ai.target;
  const valid = t >= 0 && !B.dead[t] && B.uid[t] === ai.tuid;
  if (valid && !urgent) {
    const dx = B.x[t] - m.x, dz = B.z[t] - m.z, d = Math.hypot(dx, dz);
    const keep = m.cls === 'pyro' ? 2.2 : 3.6;
    if (d < keep) { mx -= dx / d * 0.7; mz -= dz / d * 0.7; }
  }
  // dodge brute charges
  ai.dodge -= dt;
  if (ai.dodge <= 0) {
    ai.dodge = 0.1;
    const cnt = queryCircle(m.x, m.z, 13);
    for (let q = 0; q < cnt; q++) {
      const b = QB[q];
      if (B.type[b] !== BRUTE || (B.st[b] !== S_WIND && B.st[b] !== S_CHARGE)) continue;
      const rx = m.x - B.x[b], rz = m.z - B.z[b], along = rx * B.ax[b] + rz * B.az[b];
      const perp = rx * B.az[b] - rz * B.ax[b];
      if (along > 0 && along < 13 && Math.abs(perp) < 2.0) {
        const s = perp >= 0 ? 1 : -1;
        ai.sideX = B.az[b] * s; ai.sideZ = -B.ax[b] * s; ai.sideT = 0.5;
        if (B.st[b] === S_CHARGE && along < 6) tryDash(m, ai.sideX, ai.sideZ);
      }
    }
  }
  // sidestep acid globs that are about to land on us
  for (let k = 0; k < GL.n; k++) {
    const left = GL.dur[k] - GL.t[k];
    if (left > 0.75) continue;
    const dx = m.x - GL.x1[k], dz = m.z - GL.z1[k], d = Math.hypot(dx, dz);
    if (d < 1.9) { ai.sideX = d > 0.05 ? dx / d : 1; ai.sideZ = d > 0.05 ? dz / d : 0; ai.sideT = 0.35; }
  }
  if (ai.sideT > 0) { ai.sideT -= dt; mx = ai.sideX; mz = ai.sideZ; }
  // stuck detection: wants to move but barely moves -> rely on the flow field for a while
  if (Math.abs(mx) + Math.abs(mz) > 0.5 && Math.hypot(m.x - ai.lx, m.z - ai.lz) < 1.2 * dt) ai.stuck = Math.min(2, ai.stuck + dt * 2); else ai.stuck = Math.max(0, ai.stuck - dt);
  ai.lx = m.x; ai.lz = m.z;
  if (m.hp < m.maxHp * 0.3 && crowd[m.i] > 4 && m.dashCd <= 0) tryDash(m, -m.vx || m.ax, -m.vz || m.az);
  // aim + fire
  let fire = false;
  if (valid) {
    const d = Math.hypot(B.x[t] - m.x, B.z[t] - m.z);
    const lead = m.cls === 'pyro' || m.cls === 'cryo' ? 0 : d / 80;
    const want = Math.atan2(B.x[t] + B.vx[t] * lead - m.x, B.z[t] + B.vz[t] * lead - m.z);
    const diff = angDiff(m.aim, want);
    m.aim += clamp(diff, -10 * dt, 10 * dt);
    const tol = m.cls === 'pyro' || m.cls === 'cryo' ? 0.3 : 0.14;
    fire = Math.abs(diff) < tol && d < range + 0.5;
    if (m.cls === 'pyro' && d > C.range * md.range + 0.4) fire = false;
  } else if (Math.abs(mx) + Math.abs(mz) > 0.2) {
    m.aim += clamp(angDiff(m.aim, Math.atan2(mx, mz)), -6 * dt, 6 * dt);
  }
  if (coachHoldFire(m)) fire = false;
  _bot.mx = mx; _bot.mz = mz; _bot.fire = fire;
  return _bot;
}

// ---------- per-tick marine update ----------
function onLift(x, z) { return (x - LV.lift.x) ** 2 + (z - LV.lift.z) ** 2 < (LV.lift.r - 0.6) ** 2; }
function tickMarines(dt) {
  for (const m of M) {
    m.px = m.x; m.pz = m.z;
    if (m.inv > 0) m.inv -= dt;
    if (m.hurtT > 0) m.hurtT -= dt;
    if (m.dashCd > 0) m.dashCd -= dt;
    if (m.abCd > 0) m.abCd -= dt;
    if (m.muzzle > 0) m.muzzle -= dt * 10;
    m.bite = Math.min(3, m.bite + dt * 5.5);
    if (m.downed) {
      // presses made while downed must not fire later in a random direction
      if (m.isPlayer) IN.abil = IN.dash = false;
      m.vx = m.vz = 0; m.firing = false; updateWeapon(m, dt, false); continue;
    }
    let mx = 0, mz = 0, fire = false;
    if (m.isPlayer && !autoPlayer) {
      const c = playerCommands(m);
      mx = c.mx; mz = c.mz; fire = c.fire;
    } else {
      const c = botThink(m, dt);
      mx = c.mx; mz = c.mz; fire = c.fire;
    }
    if (DIR.stage === 'extract' && onLift(m.x, m.z)) { mx = 0; mz = 0; m.dashT = 0; }
    const ml = Math.hypot(mx, mz);
    if (ml > 1) { mx /= ml; mz /= ml; }
    if (ml > 0.2) { const k = Math.min(1, 6 * dt); m.faceX += (mx / ml - m.faceX) * k; m.faceZ += (mz / ml - m.faceZ) * k; const fl = Math.hypot(m.faceX, m.faceZ) || 1; m.faceX /= fl; m.faceZ /= fl; }
    moveMarine(m, dt, mx, mz);
    m.ax = Math.sin(m.aim); m.az = Math.cos(m.aim);
    updateWeapon(m, dt, fire);
    m.calm += dt;
    const regen = m.mods.regen + (m.calm > 3.5 ? 4 : 0);
    if (regen > 0 && m.hp < m.maxHp) m.hp = Math.min(m.maxHp, m.hp + regen * dt);
  }
  updateRevive(dt);
}
