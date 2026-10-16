// Web reference frames for the native renderers (ios-native, -renderer metal | spritekit): the moments the native CI
// demos stage, rendered by the web game itself at the CI simulator's size (iPhone 17 Pro, 402x874 @3x), so a CI
// screenshot can be compared with the web look of the same place, camera and light rig.
//
//   node harness/run.mjs --www --mobile --width 402 --height 874 --dpr 3 --scenario harness/scenarios/native-ref.mjs \
//        --dest ios-native/tools/previews/web-ref [--quality high|med]
//
//   calm   mission start (assault), no bugs, the squad idling on the landing pad    ↔ -demo calm
// The swarm reference is the store shot itself (store-shots.mjs (b), store/screenshots/6.3/2-swarm.png at this size)
//   ↔ -demo swarmshot, which stages the same moment in the native app.
import fs from 'node:fs';
import path from 'node:path';

export default async (page, h) => {
  const { log } = h;
  const dest = path.resolve(String(h.args.dest || 'ios-native/tools/previews/web-ref'));
  fs.mkdirSync(dest, { recursive: true });
  const quality = String(h.args.quality || 'high');
  const dbg = (fn, ...a) => page.evaluate(([f, a]) => window.__dbg[f](...a), [fn, a]);
  const frames = (n) => page.evaluate((n) => new Promise((r) => { let k = 0; const f = () => (++k >= n ? r() : requestAnimationFrame(f)); requestAnimationFrame(f); }), n);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setSafeAreaInsetsOverride', { insets: { top: 62, topMax: 62, bottom: 34, bottomMax: 34, left: 0, leftMax: 0, right: 0, rightMax: 0 } });
  await page.evaluate(() => window.dispatchEvent(new Event('resize')));
  const save = async (name) => {
    const p = path.join(dest, name + '.png');
    await page.screenshot({ path: p, timeout: 120000 });
    log('[native-ref]', p, JSON.stringify(await h.stats().then((s) => ({ screen: s.screen, bugs: s.bugsAlive, q: s.quality, player: s.player }))));
  };
  await dbg('start', 'assault');
  await dbg('setQuality', quality);
  await dbg('god', true);
  await dbg('timeScale', 0.05);
  await frames(6);
  await save('calm');
};
