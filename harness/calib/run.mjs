// Balance measurement scenario (dev only): drives a calibration build (harness/calib/mkcalib.mjs) through one
// mission with fixed 60 Hz ticks and drawing switched off, then prints one '[R] {json}' result line.
//   node harness/run.mjs --file dist/v11-a-calib.html --scenario harness/calib/run.mjs --width 320 --height 180 \
//        --cls assault --tier 1 --mode auto [--q med] [--maxs 600] [--tag name] [--th '{"trickle":1.25}']
// Modes: auto      — autopilot player (perfect aim, kites poorly)
//        passive   — autopilot that deals no damage and never uses its ability
//        afk       — no input at all for --maxs s (default 420 here)
//        afkbeacon — autopilot until the first beacon starts, then no input
// --th overrides fields of DIFF[tier] for this run only (tuning without a rebuild).
// Port of the combat lens' run2.mjs onto the v1.1 sources: tiers come from DIFF via __dbg.start(cls, {tier, coach: false, seed}).
export default async (page, h) => {
  const ev = (f, a) => page.evaluate(f, a);
  const cls = h.args.cls || 'assault', q = h.args.q || 'med', mode = h.args.mode || 'auto';
  const tier = +(h.args.tier ?? 1), seed = +(h.args.seed ?? 0);
  const maxS = +(h.args.maxs || (mode === 'afk' ? 420 : 600));
  const TH = h.args.th ? JSON.parse(h.args.th) : {};
  const tag = h.args.tag || ['rec', 'vet', 'nm'][tier] || 't' + tier;
  const ok = await ev(() => !!(window.__int && window.__dbg));
  if (!ok) { h.fail('not a calibration build (no window.__int): build it with harness/calib/mkcalib.mjs'); return; }
  await ev((q) => window.__dbg.setQuality(q), q);
  await ev(([cls, mode, tier, seed, TH]) => {
    const I = window.__int, d = window.__dbg;
    Object.assign(I.DIFF[tier], TH);
    window.__noDraw = true;
    d.timeScale(0.05);   // the real-time frame loop barely ticks between our chunks
    d.start(cls, { tier, coach: false, seed });
    window.__mode = mode;
    d.auto(mode !== 'afk');
    window.__W = {
      stageAt: {}, downs: [0, 0, 0, 0], minHp: [999, 999, 999, 999], wasDown: [0, 0, 0, 0], maxAlive: 0, aliveSum: 0, aliveN: 0, holdAliveMax: 0,
      lowHpT: 0, halfHpT: 0, pTaken: 0, picks: 0, firstDown: -1, pFirstDown: -1, afkStop: false, aliveAt: [], hpAt: [], idleMax: 1, pressMax: 0,
      nearMax: 0, holdDowns: 0, deckMax: 0, downSt: {}, firstBrute: -1, queen: null, qDowns0: 0,
    };
  }, [cls, mode, tier, seed, TH]);
  let res;
  for (let chunk = 0; chunk < Math.ceil(maxS / 20) + 1; chunk++) {
    res = await ev((maxS) => {
      const I = window.__int, W = window.__W, B = I.B, mode = window.__mode;
      // the real-time loop may have opened the level-up screen between chunks: pick and resume
      if (I.GS.screen === 'levelup') { while (I.GS.pendingLevels > 0) { I.applyUpgrade(I.rollUpgrades()[0]); I.GS.pendingLevels--; W.picks++; } I.showScreen('playing'); }
      for (let k = 0; k < 20 * 60 && I.GS.screen === 'playing' && I.GS.time < maxS; k++) {
        const P = I.M[0];
        if (mode === 'passive') { P.mods.dmg = 0; P.abCd = 99; P.mods.explosive = 0; }
        if (mode === 'afkbeacon' && !W.afkStop && I.DIR.active >= 0) { W.afkStop = true; I.autoPlayer = false; }
        const hp0 = P.hp;
        I.tick(1 / 60);
        if (!P.downed && P.hp < hp0) W.pTaken += hp0 - P.hp; else if (P.downed && hp0 > 0) W.pTaken += hp0;
        while (I.GS.pendingLevels > 0) { const o = I.rollUpgrades(); I.applyUpgrade(o[0]); I.GS.pendingLevels--; W.picks++; }
        const st = I.DIR.stage, t = +I.GS.time.toFixed(1);
        if (W.stageAt[st] == null) W.stageAt[st] = t;
        if (I.DIR.active >= 0) { const key = 'b' + (I.DIR.done + 1); if (W.stageAt[key] == null) W.stageAt[key] = t; }
        if (I.DIR.done > 0) { const key = 'c' + I.DIR.done; if (W.stageAt[key] == null) W.stageAt[key] = t; }
        for (let m = 0; m < 4; m++) {
          const Mm = I.M[m];
          if (Mm.downed && !W.wasDown[m]) {
            W.downs[m]++; if (W.firstDown < 0) W.firstDown = t; if (m === 0 && W.pFirstDown < 0) W.pFirstDown = t;
            if (st === 'hold') W.holdDowns++;
            const sk = st === 'beacons' ? (I.DIR.active >= 0 ? 'b' + (I.DIR.done + 1) : 'trav') : st;
            W.downSt[sk] = (W.downSt[sk] || 0) + 1;
          }
          W.wasDown[m] = Mm.downed ? 1 : 0;
          if (!Mm.downed && Mm.hp < W.minHp[m]) W.minHp[m] = Mm.hp;
        }
        if (!P.downed && P.hp < P.maxHp * 0.3) W.lowHpT += 1 / 60;
        if (!P.downed && P.hp < P.maxHp * 0.5) W.halfHpT += 1 / 60;
        if (I.DIR.idleMul > W.idleMax) W.idleMax = I.DIR.idleMul;
        if (I.DIR.press > W.pressMax) W.pressMax = I.DIR.press;
        if (W.firstBrute < 0 && I.typeAlive[2] > 0) W.firstBrute = t;
        // the Матка
        const Q = I.DIR.q;
        if (Q.spawned && !W.queen) {
          let hp = 0; for (let i = 0; i < B.n; i++) if (B.uid[i] === Q.uid) { hp = Math.round(B.hpMax[i]); break; }
          W.queen = { spawnT: t, liftT: +I.DIR.liftT.toFixed(1), hp, squadAtSpawn: I.M.map(m => m.downed ? 'D' : Math.round(m.hp)).join('/'), killT: null, downs: 0 };
          W.qDowns0 = W.downs.reduce((a, b) => a + b, 0);
        }
        if (W.queen && Q.done && W.queen.killT == null && Q.killT > 0) {
          W.queen.killT = +Q.killT.toFixed(1); W.queen.liftAtKill = +I.DIR.liftT.toFixed(1);
          W.queen.squadAtKill = I.M.map(m => m.downed ? 'D' : Math.round(m.hp)).join('/');
        }
        if (W.queen) W.queen.downs = W.downs.reduce((a, b) => a + b, 0) - W.qDowns0;
        if (k % 30 === 0) {
          let alive = 0, near = 0;
          for (let i = 0; i < B.n; i++) if (!B.dead[i]) { alive++; if ((B.x[i] - P.x) ** 2 + (B.z[i] - P.z) ** 2 < 64) near++; }
          if (alive > W.maxAlive) W.maxAlive = alive;
          if (near > W.nearMax) W.nearMax = near;
          W.aliveSum += alive; W.aliveN++;
          if (st === 'hold') { if (alive > W.holdAliveMax) W.holdAliveMax = alive; const dk = I.queryCircle(I.LV.lift.x, I.LV.lift.z, I.LV.lift.r); if (dk > W.deckMax) W.deckMax = dk; }
          if (k % 600 === 0) { W.aliveAt.push(alive); W.hpAt.push(I.M.map(m => m.downed ? 'D' : Math.round(m.hp)).join('/')); }
        }
      }
      return { t: I.GS.time, screen: I.GS.screen };
    }, maxS);
    if ((res.screen !== 'playing' && res.screen !== 'levelup') || res.t >= maxS - 0.05) break;
  }
  const out = await ev(() => {
    const W = window.__W, I = window.__int;
    return {
      result: I.GS.screen, t: +I.GS.time.toFixed(1), tier: I.TH.id, shots: Math.round(I.GS.shots), hits: Math.round(I.GS.hits), pKills: I.GS.playerKills,
      stage: I.DIR.stage, beacons: I.DIR.done, kills: I.GS.kills, level: I.GS.level,
      stageAt: W.stageAt, downs: W.downs, pDowns: I.GS.downs, downBy: I.GS.downBy, firstDown: W.firstDown, pFirstDown: W.pFirstDown, holdDowns: W.holdDowns,
      minHp: W.minHp.map(x => Math.round(x)), pLowS: +W.lowHpT.toFixed(1), pHalfS: +W.halfHpT.toFixed(1), pTakenPerMin: Math.round(W.pTaken / Math.max(0.1, I.GS.time / 60)),
      maxAlive: W.maxAlive, avgAlive: Math.round(W.aliveSum / Math.max(1, W.aliveN)), holdAliveMax: W.holdAliveMax, deckMax: W.deckMax, nearMax: W.nearMax,
      idleMax: +W.idleMax.toFixed(2), pressMax: +W.pressMax.toFixed(1), firstBrute: W.firstBrute, downSt: W.downSt, queen: W.queen,
      aliveAt: W.aliveAt.join(','), hpAt: W.hpAt.join(' '),
    };
  });
  h.log('[R]', JSON.stringify({ tag, cls, q, mode, tierIx: tier, seed, th: TH, ...out }));
};
