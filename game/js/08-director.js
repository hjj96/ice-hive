// ================================================================
//  DIRECTOR — objectives, swarm pacing, hordes, XP & upgrades
// ================================================================
// a winning run lasts about 6 minutes: three long beacon holds plus the lift climax
const BEACON_TIME = 60, LIFT_TIME = 100, BEACON_R = 4.6;
const GS = {
  screen: 'title', time: 0, kills: 0, playerKills: 0, shots: 0, hits: 0, combo: 0, comboT: 0, bestCombo: 0,
  level: 1, xp: 0, xpNext: 20, pendingLevels: 0, dmgFlash: 0, flash: 0, hordeFx: 0, cls: 'assault', attract: true, upg: {}, seen: [true, true, true, true],
  downs: 0, lastHit: -1, downBy: -1, afkT: 0,
};
const DIR = {
  stage: 'beacons', beacons: LV.beacons.map(b => ({ x: b.x, z: b.z, name: b.name, state: 0, progress: 0, contested: false })),
  active: -1, done: 0, liftT: LIFT_TIME, liftDur: LIFT_TIME, hordeT: 45, waveT: 0, trickle: 0, hpMul: 1, dmgMul: 1,
  queue: [], extractT: 0, hordes: 0, pulseT: 5,
  calm: false, beaconHordeMul: 1, press: 0, idleMul: 1, q: { uid: 0, alive: false, spawned: false, done: false, t0: 0, killT: 0 },
};
function xpFor(level) { return Math.round(40 * Math.pow(1.4, level - 1) + 12 * (level - 1)); }

function resetDirector(attract) {
  DIR.stage = 'beacons'; DIR.active = -1; DIR.done = 0; DIR.liftT = LIFT_TIME; DIR.hordeT = attract ? 1e9 : 50; DIR.waveT = 0;
  DIR.trickle = 0; DIR.hpMul = 1; DIR.dmgMul = 1; DIR.queue.length = 0; DIR.extractT = 0; DIR.hordes = 0;
  // rebuilt in place from LV (stations may change the layout between missions)
  DIR.beacons.length = 0;
  for (const b of LV.beacons) DIR.beacons.push({ x: b.x, z: b.z, name: b.name, state: 0, progress: 0, contested: false });
  DIR.calm = false; DIR.beaconHordeMul = 1; DIR.press = 0; DIR.idleMul = 1;
  const q = DIR.q; q.uid = 0; q.alive = false; q.spawned = false; q.done = false; q.t0 = 0; q.killT = 0;
  liftGroup.position.y = 0;
}
function nextBeacon() {
  if (DIR.active >= 0) return DIR.beacons[DIR.active];
  const P = M[0];
  let best = null, bd = 1e9;
  for (const b of DIR.beacons) { if (b.state === 2) continue; const d = Math.hypot(b.x - P.x, b.z - P.z); if (d < bd) { bd = d; best = b; } }
  return best;
}
function standingIn(x, z, r) { let n = 0; for (const m of M) if (!m.downed && (m.x - x) ** 2 + (m.z - z) ** 2 < r * r) n++; return n; }

// ---------- spawning ----------
function pickEdge(cx, cz, dmin, dmax) {
  const N = LV.edgeN;
  let fallback = -1;
  for (let t = 0; t < 40; t++) {
    const e = (rnd() * N) | 0, x = LV.edgeX[e], z = LV.edgeZ[e];
    const d = Math.hypot(x - cx, z - cz);
    if (d < dmin || d > dmax) continue;
    const c = cellOf(x, z);
    if (c < 0 || swarmFlow.d[c] === 65535) continue;
    if (fallback < 0) fallback = e;
    // prefer edges the camera is not looking straight at: off-screen arrivals feel like flanking
    if (d > dmin + 4 || rnd() < 0.3) return e;
  }
  return fallback;
}
function edgeNear(e0, r) {
  const x0 = LV.edgeX[e0], z0 = LV.edgeZ[e0];
  for (let t = 0; t < 16; t++) { const e = (rnd() * LV.edgeN) | 0; if (Math.abs(LV.edgeX[e] - x0) < r && Math.abs(LV.edgeZ[e] - z0) < r) return e; }
  return e0;
}
// specials are capped so a single horde can never be a wall of brutes or a carpet of boomers
const SPECIAL_CAP = [0, 30, 12, 18];
function pickType(horde) {
  const t = GS.time, d = DIR.done, k = DIR.stage === 'hold' ? 0.5 : 1;
  // specials follow objective progress (not wall time): the first beacon already brings spitters and boomers,
  // brutes join halfway through it, and later beacons add only a little on top
  const prog = d + (DIR.active >= 0 ? DIR.beacons[DIR.active].progress : 0);
  const pBrute = (d >= 1 || prog > 0.5) ? (0.012 + 0.004 * d) * k : 0;
  const pSpit = t > 15 ? ((horde ? 0.05 : 0.07) + 0.008 * d) * k : 0;
  const pBoom = t > 25 ? ((horde ? 0.03 : 0.045) + 0.004 * d) * k : 0;
  let r = rnd(), ty = RUN;
  if (r < pBrute) ty = BRUTE;
  else if ((r -= pBrute) < pSpit) ty = SPIT;
  else if ((r -= pSpit) < pBoom) ty = BOOM;
  if (ty !== RUN) { if (typeAlive[ty] >= SPECIAL_CAP[ty] + (ty === BRUTE ? 2 * d : 0)) ty = RUN; else typeAlive[ty]++; }
  return ty;
}
// the gameplay cap (simCap) only changes with an explicit quality choice, never with adaptive render steps
function capLeft() { return simCap - B.n; }
function squadCenter() {
  let x = 0, z = 0, n = 0;
  for (const m of M) if (!m.downed) { x += m.x; z += m.z; n++; }
  if (!n) return [M[0].x, M[0].z];
  return [x / n, z / n];
}
// A burst of bugs pouring from an edge (or a vent) over time
function queueBurst(e, n, rate, vent) { DIR.queue.push({ e, n, rate, acc: 0, vent }); }
function startHorde(size, title, sub, rate = 40) {
  const [cx, cz] = squadCenter();
  const k = size > 300 ? 3 : 2;
  if (DIR.stage === 'hold') {
    // a few climb straight onto the lift rim; the bulk funnels up the ramp (visible pile-up, fair chokepoint)
    const rim = pickEdge(LV.lift.x, LV.lift.z, 0, LV.lift.r + 1);
    if (rim >= 0) queueBurst(rim, Math.round(size * 0.12), 14, null);
    size *= 0.88;
  }
  for (let a = 0; a < k; a++) {
    const e = pickEdge(cx, cz, 13, 32);
    if (e >= 0) queueBurst(e, Math.round(size / k), rate + rnd() * 18, null);
  }
  DIR.hordes++;
  if (!simOnly && !GS.attract) {
    banner(title || 'Орда!', sub || 'Рой прорывается из бездны', false);
    GS.hordeFx = 1;
    sfx('siren'); sfx('hordeRoar');
    addShake(0.25);
    haptic('warning');
  }
}
function processQueue(dt) {
  for (let q = 0; q < DIR.queue.length; q++) {
    const s = DIR.queue[q];
    s.acc += s.rate * dt;
    while (s.acc >= 1 && s.n > 0) {
      s.acc -= 1; s.n--;
      if (capLeft() <= 0) continue;
      const ty = pickType(true);
      if (s.vent) spawnBug(ty, s.vent[0], s.vent[1], 2);
      else { const e = edgeNear(s.e, 6); spawnBug(ty, LV.edgeX[e], LV.edgeZ[e], 1, LV.edgeNX[e], LV.edgeNZ[e], 1.8 + rnd() * 2.2); }
    }
    if (s.n <= 0) { DIR.queue.splice(q, 1); q--; }
  }
}
function hordeScale() { return Math.min(1, simCap / 1400); }

// ---------- per-tick ----------
function tickDirector(dt) {
  GS.time += dt;
  const minutes = GS.time / 60;
  // flat per-beacon steps: escalation comes from the objective, not a cliff after the second beacon
  DIR.hpMul = 1 + 0.06 * DIR.done + 0.06 * minutes;
  DIR.dmgMul = 1 + 0.03 * DIR.done;
  const P = M[0];
  let stageMul = 1;
  if (!GS.attract) {
    if (DIR.stage === 'beacons') {
      if (DIR.active < 0) {
        for (let k = 0; k < DIR.beacons.length; k++) {
          const b = DIR.beacons[k];
          if (b.state === 0 && standingIn(b.x, b.z, BEACON_R) > 0) {
            b.state = 1; DIR.active = k; DIR.waveT = 2;
            startHorde(Math.round((270 + 50 * DIR.done) * hordeScale()), 'Защищайте маяк', 'Маяк «' + b.name + '» запускается — держите кольцо');
            if (!simOnly) sfx('beacon');
            break;
          }
        }
      } else {
        const b = DIR.beacons[DIR.active];
        stageMul = 2.0;
        // the ring charges only with a marine inside; bugs crowding the ring slow it down
        b.contested = queryCircle(b.x, b.z, BEACON_R - 0.5) >= 6;
        if (standingIn(b.x, b.z, BEACON_R) > 0) b.progress = Math.min(1, b.progress + dt / BEACON_TIME * (b.contested ? 0.3 : 1));
        DIR.waveT -= dt;
        if (DIR.waveT <= 0) {
          DIR.waveT = 6 + rnd() * 3;
          const vents = LV.vents.filter(v => Math.hypot(v[0] - b.x, v[1] - b.z) < 14);
          if (vents.length) { const v = vents[(rnd() * vents.length) | 0]; queueBurst(-1, Math.round((38 + 8 * DIR.done) * hordeScale()), 22, v); }
          else { const e = pickEdge(b.x, b.z, 8, 22); if (e >= 0) queueBurst(e, Math.round(30 * hordeScale()), 24, null); }
        }
        if (b.progress >= 1) completeBeacon(DIR.active);
      }
    } else if (DIR.stage === 'toLift') {
      stageMul = 1.6;
      if (!P.downed && onLift(P.x, P.z)) startHold();
    } else if (DIR.stage === 'hold') {
      stageMul = 3.2;
      let on = false; for (const m of M) if (!m.downed && onLift(m.x, m.z)) on = true;
      if (on) {
        DIR.liftT -= dt;
        // lift defence circuit: periodic shock pulse across the deck
        DIR.pulseT -= dt;
        if (DIR.pulseT <= 0) { DIR.pulseT = 5; queueBoom(LV.lift.x, LV.lift.z, LV.lift.r + 0.6, 48 * DIR.hpMul, -1, 'pulse'); }
      }
      if (DIR.liftT <= 0) {
        DIR.liftT = 0;
        // the lift only leaves with the player on it (a downed player is carried back by the squad first)
        if (onLift(P.x, P.z)) { DIR.stage = 'extract'; DIR.extractT = 0; DIR.queue.length = 0; if (!simOnly) { banner('Эвакуация', 'Лифт поднимается', true); sfx('lift'); } }
      }
    } else if (DIR.stage === 'extract') {
      stageMul = 0;
      DIR.extractT += dt;
      const u = DIR.extractT / 4.5;
      liftGroup.position.y = u * u * 22;
      if (DIR.extractT >= 4.6) { endGame(true); return; }
    }
  } else stageMul = B.n < 220 ? 1.5 : 0;
  // continuous trickle from the abyss edges
  if (stageMul > 0) {
    const rate = (1.8 + 0.5 * minutes + 0.5 * DIR.done) * stageMul * (GS.attract ? 3 : 1);
    DIR.trickle += rate * dt;
    if (DIR.trickle >= 1) {
      const [cx, cz] = squadCenter();
      while (DIR.trickle >= 1) {
        DIR.trickle -= 1;
        if (capLeft() <= 0) { DIR.trickle = 0; break; }
        const e = pickEdge(cx, cz, 12, 32);
        if (e >= 0) spawnBug(pickType(false), LV.edgeX[e], LV.edgeZ[e], 1, LV.edgeNX[e], LV.edgeNZ[e]);
      }
    }
    // periodic hordes (the timer pauses while a beacon defence is running)
    if (DIR.active < 0) DIR.hordeT -= dt;
    if (DIR.hordeT <= 0) {
      if (DIR.stage === 'hold') { DIR.hordeT = 13 + rnd() * 4; startHorde(Math.round((360 + rnd() * 160) * hordeScale()), 'Орда!', 'Они лезут на платформу', 55); }
      else { DIR.hordeT = 45 + rnd() * 15; startHorde(Math.round(Math.min(520, 120 + 55 * DIR.done + 25 * minutes) * hordeScale())); }
    }
  }
  processQueue(dt);
  if (GS.comboT > 0) { GS.comboT -= dt; if (GS.comboT <= 0) GS.combo = 0; }
  if (!GS.attract && !godMode && M[0].downed && M[1].downed && M[2].downed && M[3].downed) endGame(false);
}
function completeBeacon(k) {
  const b = DIR.beacons[k];
  b.state = 2; b.progress = 1; DIR.active = -1; DIR.done++;
  // a breather for the squad: everyone standing patches up a quarter of their armour
  for (const m of M) if (!m.downed) m.hp = Math.min(m.maxHp, m.hp + m.maxHp * 0.25);
  DIR.hordeT = Math.max(DIR.hordeT, 28 + rnd() * 10);   // breather before the next push
  if (!simOnly) { sfx('beaconDone'); flashLight(b.x, 3, b.z, 0x40ffe0, 600, 1.0); haptic('success'); }
  if (DIR.done >= 3) {
    DIR.stage = 'toLift';
    if (!simOnly) banner('Лифт вызван', 'Все к грузовой платформе', true);
  } else if (!simOnly) banner('Маяк запущен', DIR.done + ' из 3 · ищите следующий', true);
}
function startHold() {
  DIR.stage = 'hold'; DIR.liftT = LIFT_TIME; DIR.hordeT = 3; DIR.pulseT = 4;
  const sub = 'Лифт прибудет через ' + LIFT_TIME + ' секунд';
  if (!simOnly) { banner('Держитесь', sub, false); sfx('beacon'); }
  startHorde(Math.round(480 * hordeScale()), 'Держитесь', sub, 70);
}

// ---------- kills, XP, combo ----------
function onBugKilled(ty, src, x, z) {
  GS.kills++;
  if (simOnly || GS.attract) return;
  GS.xp += BT[ty].xp;
  if (src === 0) {
    GS.playerKills++; GS.combo++; GS.comboT = 1.0;   // a real streak: a second without a kill (or a hit taken) ends it
    if (GS.combo > GS.bestCombo) GS.bestCombo = GS.combo;
    sfx('kill');
    if (GS.combo % 25 === 0) sfx('combo');
  }
  while (GS.xp >= GS.xpNext) { GS.xp -= GS.xpNext; GS.level++; GS.xpNext = xpFor(GS.level); GS.pendingLevels++; }
}

// ---------- upgrades ----------
const UPG = [
  { id: 'dmg', name: 'Калибр', desc: '+15% к урону основного оружия', apply: m => { m.mods.dmg *= 1.15; } },
  { id: 'rof', name: 'Ускоренный затвор', desc: '+12% к темпу огня', apply: m => { m.mods.rof *= 1.12; } },
  { id: 'pierce', cls: ['assault', 'gunner'], name: 'Бронебойные', desc: 'Каждый выстрел пробивает ещё одну цель', apply: m => { m.mods.pierce++; } },
  { id: 'range', cls: ['pyro', 'cryo'], name: 'Форсаж', desc: '+18% к дальности оружия', apply: m => { m.mods.range *= 1.18; } },
  { id: 'arad', name: 'Расширенный заряд', desc: '+20% к радиусу способности', apply: m => { m.mods.arad *= 1.2; } },
  { id: 'acd', name: 'Быстрая зарядка', desc: '−15% к перезарядке способности', apply: m => { m.mods.acd *= 0.85; m.abCd *= 0.85; } },
  { id: 'spd', name: 'Сервоприводы', desc: '+8% к скорости бега', apply: m => { m.mods.speed *= 1.08; } },
  { id: 'hp', name: 'Бронепластины', desc: '+20 к максимальной броне и полное восстановление', apply: m => { m.maxHp += 20; if (!m.downed) m.hp = m.maxHp; } },
  { id: 'regen', name: 'Нанобинты', desc: 'Восстановление 1,5 брони в секунду', apply: m => { m.mods.regen += 1.5; } },
  { id: 'dash', name: 'Импульсный ранец', desc: '−25% к перезарядке рывка', apply: m => { m.mods.dashCd *= 0.75; } },
  { id: 'squad', name: 'Боевой дух', desc: 'Союзники наносят +15% урона', apply: () => { for (const o of M) if (!o.isPlayer) o.mods.dmg *= 1.15; } },
  { id: 'cluster', cls: ['assault'], name: 'Кассетная граната', desc: 'Граната разлетается на три суббоеприпаса', apply: m => { m.mods.cluster += 3; } },
  { id: 'explosive', cls: ['assault'], name: 'Разрывные импульсы', desc: 'Попадания иногда детонируют', apply: m => { m.mods.explosive++; } },
  { id: 'burn', cls: ['pyro'], name: 'Липкий напалм', desc: '+50% к урону горения, огонь перекидывается чаще', apply: m => { m.mods.burn *= 1.5; } },
  { id: 'cone', cls: ['pyro'], name: 'Широкое сопло', desc: '+25% к ширине конуса пламени', apply: m => { m.mods.cone *= 1.25; } },
  { id: 'shatter', cls: ['cryo'], name: 'Хрупкий лёд', desc: '+60% к радиусу и урону ледяных осколков', apply: m => { m.mods.shatter *= 1.6; } },
  { id: 'chill', cls: ['cryo'], name: 'Глубокий холод', desc: 'Заморозка наступает на 35% быстрее', apply: m => { m.mods.chill *= 1.35; } },
  { id: 'turret', cls: ['gunner'], name: 'Турель Мк2', desc: '+5 с работы турели и +30% к её темпу', apply: m => { m.mods.turretDur += 5; m.mods.turretRof *= 1.3; } },
  { id: 'cool', cls: ['gunner', 'pyro', 'cryo'], name: 'Охладитель', desc: 'Перегрев наступает на 35% позже', apply: m => { m.mods.heat *= 1.35; } },
];
let offer = [];
function rollUpgrades() {
  const cls = M[0].cls;
  const pool = UPG.filter(u => !u.cls || u.cls.includes(cls));
  const pick = [];
  while (pick.length < 3 && pool.length) {
    // class cards are a bit more likely
    let tot = 0; for (const u of pool) tot += u.cls ? 1.5 : 1;
    let r = rnd() * tot, k = 0;
    for (; k < pool.length; k++) { r -= pool[k].cls ? 1.5 : 1; if (r <= 0) break; }
    pick.push(pool.splice(Math.min(k, pool.length - 1), 1)[0]);
  }
  offer = pick;
  return pick;
}
function applyUpgrade(u) {
  u.apply(M[0]);
  GS.upg[u.id] = (GS.upg[u.id] || 0) + 1;
  // bots grow a little with the player so the squad keeps up with the escalation
  for (const o of M) if (!o.isPlayer) { o.mods.dmg *= 1.04; o.maxHp += 3; if (!o.downed) o.hp = Math.min(o.maxHp, o.hp + 10); }
}
