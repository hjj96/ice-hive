// App Store screenshots from the www bundle (real bundled fonts, real HUD — nothing hidden, nothing drawn on top).
// The moments are staged with the __dbg API; every pixel is the game's own rendering.
// The device's safe-area insets are emulated (Dynamic Island / notch on top, home indicator at the bottom), so the
// HUD sits exactly where the app puts it on that iPhone.
//
//   6.9" (1320x2868): node harness/run.mjs --www --mobile --width 440 --height 956 --dpr 3 --scenario harness/scenarios/store-shots.mjs --dest store/screenshots/6.9
//   6.5" (1284x2778): node harness/run.mjs --www --mobile --width 428 --height 926 --dpr 3 --scenario harness/scenarios/store-shots.mjs --dest store/screenshots/6.5
//   6.3" (1206x2622): node harness/run.mjs --www --mobile --width 402 --height 874 --dpr 3 --scenario harness/scenarios/store-shots.mjs --dest store/screenshots/6.3
//   --only a,c   retake only some of the shots (a title, b swarm, c beacon, d level-up, e extraction)
//   --quality high|med   graphics setting (the in-game «Графика» option; default high)
//   --inset-top N --inset-bottom N   safe-area insets in CSS px (defaults: by viewport, see INSETS; 0 for an unknown size)
import fs from 'node:fs';
import path from 'node:path';

export default async (page, h) => {
  const { log, fail, sleep } = h;
  const dest = path.resolve(String(h.args.dest || 'store/screenshots/test'));
  fs.mkdirSync(dest, { recursive: true });
  const only = h.args.only ? String(h.args.only).split(',') : ['a', 'b', 'c', 'd', 'e'];
  const quality = String(h.args.quality || 'high');
  const dbg = (fn, ...a) => page.evaluate(([f, a]) => window.__dbg[f](...a), [fn, a]);
  // let the renderer draw a few real frames of the staged state (SwiftShader: ~0.5 s per frame at 3x)
  const frames = (n) => page.evaluate((n) => new Promise((r) => { let k = 0; const f = () => (++k >= n ? r() : requestAnimationFrame(f)); requestAnimationFrame(f); }), n);
  const save = async (name, expect) => {
    const p = path.join(dest, name + '.png');
    for (let attempt = 1; ; attempt++) {
      // a level-up that pops up while the frames render would cover the moment: clear it and render again
      for (let k = 0; expect && k < 3 && (await S()).screen !== expect; k++) await settle(4);
      if (expect && (await S()).screen !== expect) fail(name + ': screen is ' + (await S()).screen + ', expected ' + expect);
      await page.screenshot({ path: p, timeout: 120000 });   // SwiftShader at 3x: one frame can take seconds on a busy machine
      // the capture itself renders for seconds: a level-up that came due meanwhile is in the picture (half-faded
      // cards over the fight), so check again afterwards and retake
      const now = (await S()).screen;
      if (!expect || now === expect) break;
      if (attempt >= 4) { fail(name + ': the screen kept changing to ' + now + ' during the capture'); break; }
      log('[store-shot]', name + ': screen changed to', now, 'during the capture, retaking');
    }
    await dbg('timeScale', 1);
    const b = fs.readFileSync(p);
    const w = b.readUInt32BE(16), hh = b.readUInt32BE(20);
    log('[store-shot]', p, w + 'x' + hh, JSON.stringify(await h.stats().then((s) => ({ screen: s.screen, stage: s.stage, obj: s.objective, bugs: s.bugsAlive, kills: s.bugsKilled, lvl: s.player.level, q: s.quality }))));
    return p;
  };
  const S = async () => h.stats();

  // portrait safe-area insets of the iPhones behind each App Store slot (points = CSS px)
  const INSETS = {
    '440x956': [62, 34],   // 6.9": iPhone 16/17 Pro Max (Dynamic Island)
    '402x874': [62, 34],   // 6.3": iPhone 16/17 Pro (Dynamic Island)
    '428x926': [47, 34],   // 6.5": iPhone 12–14 Pro Max / 14 Plus (notch)
  };
  const [defTop, defBottom] = INSETS[h.width + 'x' + h.height] || [0, 0];
  const top = Number(h.args['inset-top'] ?? defTop), bottom = Number(h.args['inset-bottom'] ?? defBottom);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setSafeAreaInsetsOverride', { insets: { top, topMax: top, bottom, bottomMax: bottom, left: 0, leftMax: 0, right: 0, rightMax: 0 } });
  await page.evaluate(() => window.dispatchEvent(new Event('resize')));   // the game re-reads the insets on resize
  const pad = await page.evaluate(() => { const cs = getComputedStyle(document.documentElement); return [cs.paddingTop, cs.paddingBottom]; });
  if (pad[0] !== top + 'px' || pad[1] !== bottom + 'px') fail('safe-area inset emulation did not apply: ' + pad.join(' / '));
  log('[store-shot] safe-area insets top', top, 'bottom', bottom, '->', pad.join(' / '));
  // a level-up that comes due while frames render opens the card screen: pick cards like a player would
  const resolveLevels = async () => {
    for (let k = 0; k < 10 && (await S()).screen === 'levelup'; k++) {
      await sleep(700);
      await page.evaluate(() => { const c = document.querySelector('#lvCards .card'); if (c) c.click(); });
      await sleep(150);
    }
  };
  // advance the simulation without rendering (fast stops while the level-up cards are open)
  const run = async (sec) => { await resolveLevels(); return dbg('fast', sec); };
  // render real frames of the staged moment with the simulation slowed down, so the moment does not run away
  const settle = async (n = 4) => {
    for (let k = 0; k < 3; k++) {
      await resolveLevels();
      await dbg('timeScale', 0.05);   // stays slowed through the screenshot (save restores it)
      await frames(n);
      if ((await S()).screen !== 'levelup') return;
    }
  };

  // (a) title screen with the class cards over the live attract mode
  if (only.includes('a')) {
    await frames(6);
    await save('1-title', 'title');
  }
  if (!only.some((k) => 'bcde'.includes(k))) return;

  // one continuous mission; god mode keeps the squad standing while the swarm is staged
  await dbg('start', 'gunner');
  await dbg('setQuality', quality);
  await dbg('god', true);
  await frames(2);
  // the player's own thumbs: twin-stick touch input, exactly what a player does (the sticks show where they are)
  const W = h.width, H = h.height;
  const LS = { x: W * 0.22, y: H * 0.8, id: 1 }, RS = { x: W * 0.78, y: H * 0.8, id: 2 };

  // (b) a big swarm fight: ~600 bugs closing in, lasers, flashlights, gunfire
  if (only.includes('b') || only.includes('d')) {
    await run(12);                  // past the opening control hint (the squad holds the drop zone)
    await dbg('tp', 0, -5);         // the crossing between the bridges: room for the swarm all around
    await h.touch.start([LS]); await h.touch.move([{ ...LS, x: LS.x + 50, y: LS.y - 20 }]);
    await run(1.5);                 // a few steps, so the squad fans out behind the player
    await h.touch.end();
    await run(1.5);
    await dbg('spawn', 600);
    await h.touch.start([RS]); await h.touch.move([{ ...RS, x: RS.x - 40, y: RS.y - 45 }]);   // aim and fire
    await run(1.6);
    await settle(4);
    if (only.includes('b')) await save('2-swarm', 'playing');
    await h.touch.end();
    await dbg('auto', true);        // from here on the autopilot aims and fires (no input overlay)
    // (d) level-up cards, the fight frozen behind them
    if (only.includes('d')) {
      await run(0.5);
      await settle(2);
      await dbg('levelup');
      await frames(4);
      await save('4-levelup', 'levelup');
      // take the first card like a tap would
      await resolveLevels();
      if ((await S()).screen !== 'playing') fail('level-up cards did not resume the game');
    }
  }

  // (c) beacon defence: the ring charging with the horde pouring in
  const BEACONS = { 'Альфа': [-32, 27], 'Бета': [30, -8], 'Гамма': [-34, -9] };
  const done = new Set();
  // the beacon being held right now (the autopilot may have walked into one), else the next one not yet launched
  const beaconTarget = async () => {
    const m = /маяк «(.+)»/.exec((await S()).objective);
    if (m) return m[1];
    return Object.keys(BEACONS).find((n) => !done.has(n));
  };
  const holdBeacon = async (name) => {
    for (let guard = 0; guard < 20; guard++) {
      const before = (await S()).beacons;
      await dbg('tp', ...BEACONS[name]);
      await run(8);
      if ((await S()).beacons > before) { done.add(name); return; }
    }
    fail('beacon ' + name + ' did not complete');
  };
  if (only.includes('c') || only.includes('e')) {
    await dbg('auto', true);
    // a beacon the autopilot already started is held to the end first, so the shot shows a fresh horde
    if (/маяк «/.test((await S()).objective)) await holdBeacon(await beaconTarget());
    const first = await beaconTarget();
    await dbg('tp', ...BEACONS[first]);
    await run(9);                   // the beacon horde is still pouring in
    let s = await S();
    log('[beacon]', first, s.objective, 'bugs', s.bugsAlive);
    await settle(4);
    if (only.includes('c')) await save('3-beacon', 'playing');
    if (only.includes('e')) {
      // finish the run for real: hold each beacon to 100 %, then the lift
      for (let k = 0; k < 3 && (await S()).beacons < 3; k++) await holdBeacon(await beaconTarget());
      s = await S(); log('[beacons]', s.beacons, s.stage, 'time', s.time);
      await dbg('tp', -3, -42);     // the cargo lift
      await run(1);
      for (let guard = 0; guard < 30 && (await S()).stage === 'hold'; guard++) await run(5);
      s = await S(); log('[lift]', s.stage, s.objective, 'liftT', s.liftT);
      // (e) extraction: the lift rising out of the swarm. No mission-report shot: after a god-mode run its numbers
      // (kills, combo) are far beyond what a player gets, so it would misrepresent the game.
      if (s.stage === 'extract') {
        await run(1.4);
        await settle(4);
        await save('5-extraction', 'playing');
      } else fail('the lift did not reach extraction: ' + s.stage);
    }
  }
};
