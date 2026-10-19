// v1.1 package C regression: phone HUD (VX-5), smart nameplates (VX-2), camera zoom (VX-6), pause menu fit.
//   node harness/run.mjs --file dist/artifact.html --mobile [--landscape] --scenario harness/scenarios/v11-hud.mjs
//   ... --width 375 --height 667 --mobile --part rects        (iPhone SE: banner vs objective only)
//   ... --www --fake-ios --width 568 --height 320 --part pause (pause menu with «Обучение» + «Вибрация»)
// Options: --part all|rects|pause, --noshot. Portrait runs the HUD rects, plates, horde glow and the camera zoom;
// landscape runs the plates and the off-screen marker against РЫВОК / the ability button in 8 directions.
export default async (page, h) => {
  const ev = (f, a) => page.evaluate(f, a);
  const part = String(h.args.part || 'all');
  const shots = !h.args.noshot;
  const portrait = h.height > h.width;
  const fail = (m) => h.fail(m);
  const rect = (sel) => ev((s) => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom), w: Math.round(r.width), h: Math.round(r.height) }; }, sel);
  const overlap = (a, b) => a && b && a.w > 0 && b.w > 0 && a.l < b.r && a.r > b.l && a.t < b.b && a.b > b.t;
  const unblock = async () => { for (let k = 0; k < 10 && (await ev(() => window.__dbg.state().screen)) === 'levelup'; k++) { await h.sleep(800); await h.keys.press('Digit1'); await h.sleep(200); } };
  const frames = (n = 2) => ev((n) => new Promise((res) => { let k = 0; const f = () => (++k >= n ? res() : requestAnimationFrame(f)); requestAnimationFrame(f); }), n);
  await ev(() => { localStorage.setItem('ledulei.tut', '1'); window.__dbg.setQuality('low'); });

  // ---------- pause menu (568 x 320, iOS shell adds «Вибрация») ----------
  if (part === 'pause' || part === 'all') {
    await ev(() => window.__dbg.start('assault'));
    await h.sleep(400);
    const pb = await ev(() => { const r = document.getElementById('btnPause').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
    if (h.mobile) await h.touch.tap(pb.x, pb.y); else await page.mouse.click(pb.x, pb.y);
    await h.sleep(600);
    const pm = await ev(() => {
      const s = document.getElementById('sPause'), box = s.querySelector('.m-box'), r = box.getBoundingClientRect();
      const btns = [...box.querySelectorAll('button')].map((b) => { const q = b.getBoundingClientRect(); return { id: b.id, t: Math.round(q.top), b: Math.round(q.bottom), text: b.textContent }; });
      return { screen: window.__dbg.state().screen, scroll: s.scrollHeight, client: s.clientHeight, box: [Math.round(r.top), Math.round(r.bottom)], vh: innerHeight, btns };
    });
    h.log('[pause]', JSON.stringify(pm));
    if (pm.screen !== 'paused') fail('pause did not open');
    if (!pm.btns.some((b) => b.id === 'pTut')) fail('no «Обучение» button in the pause menu');
    if (pm.scroll > pm.client + 1) fail('the pause menu scrolls (' + pm.scroll + ' > ' + pm.client + ')');
    if (pm.btns.some((b) => b.b > pm.vh || b.t < 0)) fail('a pause button is outside the viewport');
    if (shots && part === 'pause') await h.shot('pause');
    // «Обучение» starts a coached mission
    const tb = pm.btns.find((b) => b.id === 'pTut');
    if (tb) {
      const c = await ev(() => { const r = document.getElementById('pTut').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
      if (h.mobile) await h.touch.tap(c.x, c.y); else await page.mouse.click(c.x, c.y);
      await h.sleep(500);
      const t = await ev(() => ({ tut: window.__dbg.tut(), screen: window.__dbg.state().screen }));
      h.log('[pause → Обучение]', JSON.stringify(t));
      if (!t.tut.on || t.screen !== 'playing') fail('«Обучение» did not start a coached mission');
    }
    if (part === 'pause') return;
  }

  // ---------- HUD rects (calm) and banner vs objective ----------
  await ev(() => { window.__dbg.start('assault'); window.__dbg.god(true); window.__dbg.fast(8); });
  await h.sleep(600); await frames(3);
  const calm = await ev(() => {
    const q = (s) => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.right), Math.round(r.bottom)]; };
    const rows = [...document.querySelectorAll('#hSquad .sq')].filter((r) => r.offsetHeight > 0).length;
    return { vw: innerWidth, vh: innerHeight, obj: q('.obj-box'), lab: getComputedStyle(document.getElementById('hObjLab')).display, squadRows: rows, squad: q('#hSquad'), toasts: q('#toasts'), hint: q('#hHint'), me: q('.plate.me'), sticks: q('#stickL') };
  });
  h.log('[calm rects]', JSON.stringify(calm));
  if (h.mobile && calm.squadRows) fail('#hSquad shows ' + calm.squadRows + ' rows while calm (touch)');
  if (h.mobile && portrait && h.width <= 600 && calm.obj[3] > 90) fail('portrait .obj-box bottom ' + calm.obj[3] + ' > 90');
  // objective with its progress bar (a beacon charging)
  await ev(() => { const d = window.__dbg, b = d.nextBeacon(); d.tp(b.x, b.z); d.fast(0.5); });
  await frames(3);
  const bar = await ev(() => { const r = document.querySelector('.obj-box').getBoundingClientRect(); return { bottom: Math.round(r.bottom), obj: window.__dbg.state().objective }; });
  h.log('[objective with bar]', JSON.stringify(bar));
  await ev(() => window.__dbg.horde(250));
  await h.sleep(500);
  const bn = await ev(() => {
    const q = (e) => { const r = e.getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom), w: Math.round(r.width), h: Math.round(r.height) }; };
    const b = document.getElementById('banner');
    return { show: /show/.test(b.className), banner: q(b), bm: q(document.getElementById('bnM')), obj: q(document.querySelector('.obj-box')), font: getComputedStyle(document.getElementById('bnM')).fontSize };
  });
  h.log('[banner]', JSON.stringify(bn));
  if (!bn.show) fail('no horde banner');
  else if (overlap(bn.banner, bn.obj)) fail('the banner overlaps the objective box');
  if (part === 'rects') { await ev(() => window.__dbg.god(false)); return; }

  // ---------- horde glow: the screen centre stays untinted (DOM-only probe: canvas + HUD hidden) ----------
  if (h.mobile && portrait) {
    await ev(() => window.__dbg.timeScale(0.05));
    await unblock();
    if (shots) await h.shot('horde');
    const px = await ev(() => new Promise((res) => {
      const st = document.getElementById('stage'), hud = document.getElementById('hud'), fx = document.getElementById('hordeFx');
      const pl = document.getElementById('plates'), tu = document.getElementById('touchUI'), mk = document.getElementById('marker');
      const keep = [];
      for (const e of [st, hud, pl, tu, mk]) e.style.visibility = 'hidden';
      // a stylesheet !important wins over the per-frame inline opacity writes of updateHUD
      const css = document.createElement('style'); css.id = 'probeCss'; css.textContent = '#hordeFx { opacity: 1 !important; }'; document.head.appendChild(css);
      const shadow = getComputedStyle(fx).boxShadow;
      requestAnimationFrame(() => requestAnimationFrame(() => res({ shadow, keep })));
    }));
    // centre and an edge pixel of the composited page (background is the page's flat colour)
    const shot = await page.screenshot({ clip: { x: 0, y: Math.round(h.height / 2), width: h.width, height: 1 }, timeout: 120000 });
    // decode in the page (no PNG library in the repo)
    const [centre, edge] = await ev(async (b64) => {
      const img = new Image(); img.src = 'data:image/png;base64,' + b64; await img.decode();
      const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
      const g = c.getContext('2d', { willReadFrequently: true }); g.drawImage(img, 0, 0);
      const at = (x) => Array.from(g.getImageData(x, 0, 1, 1).data).slice(0, 3);
      return [at(img.width >> 1), at(2)];
    }, shot.toString('base64'));
    await ev(() => {
      for (const id of ['stage', 'hud', 'plates', 'touchUI', 'marker']) document.getElementById(id).style.visibility = '';
      document.getElementById('probeCss').remove();
    });
    h.log('[horde glow]', JSON.stringify({ shadow: px.shadow, centre, edge }));
    if (!/12vw|46\.8px|47px|min/.test(px.shadow) && !/ 4[0-9](\.\d+)?px /.test(px.shadow)) h.log('[horde glow] note: computed shadow', px.shadow);
    if (centre && edge) {
      const d = (a, b) => Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]);
      const bg = await ev(() => getComputedStyle(document.body).backgroundColor);
      h.log('[horde glow] body bg', bg, '| centre-edge distance', d(centre, edge));
      if (d(centre, edge) < 20) fail('the horde glow edge is not tinted (probe broken?)');
      const m = bg.match(/\d+/g).map(Number);
      if (d(centre, m) > 6) fail('the screen centre is tinted by the horde glow: ' + centre + ' vs ' + m);
    }
    await ev(() => window.__dbg.timeScale(1));
  }

  // ---------- nameplates (bunched squad) ----------
  const bx = 30, bz = -8;
  await ev(([x, z]) => { window.__dbg.start('assault'); window.__dbg.god(true); window.__dbg.fast(1); window.__dbg.tp(x, z); window.__dbg.fast(0.3); window.__dbg.timeScale(0.05); }, [bx, bz]);
  await h.sleep(500); await frames(4);
  const plateRects = () => ev(() => [...document.querySelectorAll('#plates .plate')].map((p) => { const r = p.getBoundingClientRect(); return { name: p.firstElementChild.textContent, mini: p.classList.contains('mini'), down: p.classList.contains('down'), l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, rv: p.lastElementChild.style.transform }; }));
  const stackStat = (pl) => {
    const full = pl.filter((p) => !p.mini);
    let pairs = 0, tower = 1;
    for (const a of full) {
      let col = 1;
      for (const b of full) if (a !== b && a.l < b.r && a.r > b.l && Math.abs(a.t - b.t) < (a.b - a.t) + 8) { col++; if (a.t < b.t) pairs++; }
      tower = Math.max(tower, col);
    }
    return { full: full.length, mini: pl.length - full.length, stackedPairs: pairs, tower };
  };
  const pl1 = await plateRects(), obj = await rect('.obj-box');
  const st1 = stackStat(pl1);
  h.log('[bunched plates]', JSON.stringify(st1), JSON.stringify(pl1.map((p) => [p.name, p.mini ? 'mini' : 'full', Math.round(p.l), Math.round(p.t)])), JSON.stringify(await ev(() => window.__dbg.plates())));
  if (st1.stackedPairs > 1) fail('more than one full plate stacked above another (' + st1.stackedPairs + ' pairs)');
  if (pl1.some((p) => p.w && overlap({ l: p.l, t: p.t, r: p.r, b: p.b, w: p.w }, obj))) fail('a plate overlaps the objective box');
  if (shots) await h.shot('bunched');
  // M[1] at 20 HP gets its full plate back; a downed squadmate shows a full plate + revive bar
  await ev(() => { window.__dbg.hurt(1, 20); });
  await frames(3);
  const pl2 = await plateRects();
  h.log('[M1 20 hp]', JSON.stringify(pl2.map((p) => [p.name, p.mini ? 'mini' : 'full'])));
  if (pl2[1].mini) fail('M[1] at 20 HP is still folded');
  await ev(() => { window.__dbg.hurt(1, 100); window.__dbg.hurt(2, 0); window.__dbg.timeScale(1); });
  await h.sleep(1200); await frames(2);
  const pl3 = await plateRects();
  h.log('[M2 downed]', JSON.stringify(pl3.map((p) => [p.name, p.mini ? 'mini' : 'full', p.down ? 'down' : '', p.rv])));
  if (pl3[2].mini || !pl3[2].down) fail('the downed squadmate has no full plate');
  if (!/scaleX\(0\.[0-9]*[1-9]|scaleX\(1/.test(pl3[2].rv)) fail('no revive bar progress on the downed plate: ' + pl3[2].rv);
  // walking away: the squad spreads out (bots held 5 m apart, the player walks off); names come back within
  // 0.35 s of the overlap clearing, without flicker
  await ev(([x, z]) => { window.__dbg.tp(x, z); window.__dbg.hurt(2, 100); window.__dbg.fast(0.3); window.__dbg.timeScale(1); }, [bx, bz]);
  await h.sleep(300); await frames(3);
  const walk = await ev(([x, z]) => new Promise((res) => {
    const d = window.__dbg, log = [];
    const t0 = performance.now();
    const step = () => {
      const t = performance.now() - t0;
      d.place(0, x, z + Math.min(6, t / 1000 * 4));
      for (let j = 1; j < 4; j++) d.place(j, x + (j - 2) * 5, z - 3);
      const p = d.plates();
      log.push([Math.round(t), p.map((q) => q.mini).join(''), p.map((q) => q.hold).join(',')]);
      if (t < 3000) requestAnimationFrame(step); else res(log);
    };
    requestAnimationFrame(step);
  }), [bx, bz]);
  // per plate: frames with hold at its max (still blocked) → the unfold frame; flicker = full→mini→full→mini
  const res = [1, 2, 3].map((k) => {
    let lastBlocked = -1, firstClear = -1, unfold = -1, toggles = 0, prev = null;
    for (const [t, minis, holds] of walk) {
      const m = minis[k], hd = +holds.split(',')[k];
      if (hd >= 0.349) { lastBlocked = t; firstClear = -1; } else if (lastBlocked >= 0 && firstClear < 0) firstClear = t;
      if (prev !== null && m !== prev) { toggles++; if (m === '0') unfold = t; }
      prev = m;
    }
    return { k, toggles, clearToUnfoldMs: unfold >= 0 && firstClear >= 0 ? unfold - firstClear : null };
  });
  const fdt = walk.length > 1 ? Math.round((walk[walk.length - 1][0] - walk[0][0]) / (walk.length - 1)) : 0;
  let gap = 0; for (let i = 1; i < walk.length; i++) gap = Math.max(gap, walk[i][0] - walk[i - 1][0]);
  h.log('[walk away]', JSON.stringify(res), 'frame ms', fdt, 'max gap', gap, 'frames', walk.length, h.args.verbose ? JSON.stringify(walk) : '');
  for (const r of res) {
    if (r.toggles > 2) fail('plate ' + r.k + ' flickered (' + r.toggles + ' toggles)');
    // the hold is 0.35 s of frame time: allow one (the longest) frame of quantisation (SwiftShader frames are uneven)
    if (r.clearToUnfoldMs == null) fail('plate ' + r.k + ' never unfolded');
    else if (r.clearToUnfoldMs > 350 + gap) fail('plate ' + r.k + ' unfolded ' + r.clearToUnfoldMs + ' ms after clearing');
  }
  await ev(() => window.__dbg.god(false));

  // ---------- landscape: the off-screen marker never sits on РЫВОК / the ability button (8 directions) ----------
  if (h.mobile && !portrait) await markerSweep();

  async function markerSweep() {
    const res = [];
    for (let a = 0; a < 8; a++) {
      const ang = a * Math.PI / 4;
      await ev((ang) => {
        const d = window.__dbg, b = d.nextBeacon();
        d.place(0, b.x - Math.sin(ang) * 26, b.z - Math.cos(ang) * 26, ang);
        for (let j = 1; j < 4; j++) d.place(j, b.x - Math.sin(ang) * 26 + j * 0.8, b.z - Math.cos(ang) * 26);
      }, ang);
      await h.sleep(250); await frames(4);
      const m = await ev(() => {
        const mk = document.querySelector('#marker .mk').getBoundingClientRect(), A = document.getElementById('tAbility').getBoundingClientRect(), D = document.getElementById('tDash').getBoundingClientRect();
        const cx = (mk.left + mk.right) / 2, cy = (mk.top + mk.bottom) / 2;
        const inR = (R) => cx > R.left && cx < R.right && cy > R.top && cy < R.bottom;
        const hit = (R) => mk.left < R.right && mk.right > R.left && mk.top < R.bottom && mk.bottom > R.top;
        return { shown: getComputedStyle(document.getElementById('marker')).display !== 'none', x: Math.round(cx), y: Math.round(cy), inAbility: inR(A), inDash: inR(D), touch: hit(A) || hit(D) };
      });
      res.push(m);
    }
    h.log('[marker sweep]', JSON.stringify(res));
    if (res.some((m) => m.shown && (m.inAbility || m.inDash))) fail('the marker sits inside РЫВОК / the ability button');
    if (res.some((m) => m.shown && m.touch)) h.log('[marker sweep] note: a marker box touches a button edge');
    await ev(() => { window.__dbg.timeScale(1); window.__dbg.god(false); });
  }

  // ---------- portrait camera: no zoom pumping with ~200-260 bugs near ----------
  if (h.mobile && portrait) {
    await ev(() => { window.__dbg.start('gunner'); window.__dbg.god(true); window.__dbg.fast(1); window.__dbg.spawn(240, 'runner'); });
    const zs = await ev(() => new Promise((res) => {
      const d = window.__dbg, log = [];
      const t0 = performance.now();
      let topUp = 0;
      const f = () => {
        const t = performance.now() - t0, c = d.cam();
        log.push([Math.round(t), c.zoom, c.near, c.want]);
        // keep about 200-260 bugs near the camera (the squad keeps killing them)
        if (t - topUp > 400 && c.near < 240) { topUp = t; d.spawn(Math.min(150, 280 - c.near), 'runner'); }
        if (t < 10000) requestAnimationFrame(f); else res(log);
      };
      requestAnimationFrame(f);
    }));
    let flips = 0, rev = 0, lastD = 0, zmin = 9, zmax = 0, nmin = 1e9, nmax = 0;
    for (let i = 1; i < zs.length; i++) {
      if (zs[i][3] !== zs[i - 1][3]) flips++;
      const dz = zs[i][1] - zs[i - 1][1];
      if (Math.abs(dz) > 1e-4) { if (lastD && Math.sign(dz) !== Math.sign(lastD)) rev++; lastD = dz; }
      zmin = Math.min(zmin, zs[i][1]); zmax = Math.max(zmax, zs[i][1]); nmin = Math.min(nmin, zs[i][2]); nmax = Math.max(nmax, zs[i][2]);
    }
    h.log('[camera zoom 10 s]', JSON.stringify({ frames: zs.length, near: [nmin, nmax], zoom: [+zmin.toFixed(3), +zmax.toFixed(3)], wantFlips: flips, zoomReversals: rev, last: zs[zs.length - 1] }));
    if (flips > 2 || rev > 2) fail('camera zoom pumps (' + flips + ' target flips, ' + rev + ' reversals in 10 s)');
    await ev(() => window.__dbg.god(false));
  }
};
