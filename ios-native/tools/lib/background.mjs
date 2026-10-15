// Far background: the icy haze far below the decks, distant towers fading into the fog, pink motes rising from the
// abyss. Atlas Background (towers: lit @2x/@3x at 1/4 scale + BackgroundGlow lights; haze / motes: single @2x).
import path from 'node:path';
import { MPPM, COS_P, FOG, savePNG } from './pipeline.mjs';
import { make, draw, addOnto, downscale } from './img.mjs';
import { cvBox } from './level.mjs';
import { maskImage, sheet2d } from './tex2d.mjs';

const TK = 4;   // towers are rendered at 1/TK scale: draw them with setScale(TK)

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export async function renderBackground(ctx) {
  const { set, cat, manifest, SHEETS, PREVIEWS, images, previewBegin, previewEnd } = ctx;
  for (const k of Object.keys(manifest.sets)) if (manifest.sets[k].group === 'bg') delete manifest.sets[k];
  const t0 = Date.now();
  // ------------------------------------------------------------ haze: the web game's radial gradient plane (220 m, y -16)
  const haze = maskImage(512, 512, () => 1);
  for (let y = 0; y < 512; y++) for (let x = 0; x < 512; x++) {
    const r = Math.hypot(x + 0.5 - 256, y + 0.5 - 256) / 256, o = (y * 512 + x) * 4;
    // colour stops: 0 rgba(120,150,185,.55), .5 rgba(80,105,135,.35), 1 rgba(40,55,75,0)
    const st = r < 0.5 ? [r / 0.5, [120, 150, 185, 0.55], [80, 105, 135, 0.35]] : [Math.min(1, (r - 0.5) / 0.5), [80, 105, 135, 0.35], [40, 55, 75, 0]];
    const [t, a, b] = st;
    for (let c = 0; c < 3; c++) haze.data[o + c] = a[c] + (b[c] - a[c]) * t;
    haze.data[o + 3] = (a[3] + (b[3] - a[3]) * t) * 255;
  }
  cat.imageset('Background', 'bg_haze', { '2x': haze });
  // ------------------------------------------------------------ motes: tileable field of pink sparks (additive)
  const R = mulberry32(41), motes = make(512, 512);
  for (let k = 0; k < 90; k++) {
    const cx = R() * 512, cy = R() * 512, rad = 1.2 + R() * 3.2, a = 0.35 + R() * 0.65;
    for (let dy = -8; dy <= 8; dy++) for (let dx = -8; dx <= 8; dx++) {
      const d = Math.hypot(dx, dy) / rad; if (d >= 1) continue;
      const x = ((Math.round(cx) + dx) % 512 + 512) % 512, y = ((Math.round(cy) + dy) % 512 + 512) % 512, o = (y * 512 + x) * 4;
      const v = (1 - d) * (1 - d) * a, old = motes.data[o + 3] / 255, na = Math.min(1, old + v);
      motes.data[o] = 255; motes.data[o + 1] = 51; motes.data[o + 2] = 115; motes.data[o + 3] = na * 255;
    }
  }
  cat.imageset('Background', 'bg_motes', { '2x': motes });
  manifest.sets.bg_textures = {
    group: 'bg', atlas: 'Background', kind: 'groundTexture', frames: ['bg_haze', 'bg_motes'],
    blend: { bg_haze: 'alpha', bg_motes: 'add' },
    note: 'bg_haze: the icy haze plane far below the decks — web: 220 x 220 m at y = -16 centred on (0, -16, -5), drawn first (scene background = fog #1a2737). In the ortho view put it in the ground container (220 m = 5280 pt wide, yScale 0.838671) offset by -16 m * 0.544639 * 24 pt. bg_motes: tileable 512 px field of pink sparks (web: 420 motes between y -6 and -46 twinkling 0.4 + 0.6 sin(...)); tile 2–3 copies at different scales, drift them slowly, alpha 0.5…1, blendMode .add.',
  };
  // ------------------------------------------------------------ distant towers (web buildSupports: 14 boxes 74…100 m out)
  const fogTower = (img, { AY }) => {
    for (let y = 0; y < img.h; y++) {
      const depth = Math.max(0, (y - AY) / (MPPM * COS_P)) * TK, f = Math.exp(-((depth / 70) ** 2));
      for (let x = 0; x < img.w; x++) {
        const o = (y * img.w + x) * 4;
        if (!img.data[o + 3]) continue;
        for (let c = 0; c < 3; c++) img.data[o + c] = img.data[o + c] * 0.16 + FOG[c] * 0.84;
        img.data[o + 3] *= f;
      }
    }
    return img;
  };
  const TR = mulberry32(31), frames = [];
  const towers = [];
  for (let k = 0; k < 6; k++) {
    const w = 5 + TR() * 9, d = w * (0.6 + TR() * 0.6), h = 100, ry = TR() * 3, seed = 100 + k;
    towers.push({ w, d, h, ry, seed });
    frames.push({ name: `bg_tower_${k}`, fn: 'piece', args: ['tower', { w, h, d, ry, seed, k: TK }] });
  }
  previewBegin('background');
  await set({ id: 'bg_tower', atlas: 'Background', glowAtlas: 'BackgroundGlow', post: fogTower, ...cvBox([-3, -100 / TK, -3], [3, 0.2, 3]), frames,
    meta: { group: 'bg', kind: 'background', layer: 'background', pattern: 'bg_tower_{0..5}', renderScale: 1 / TK, setScale: TK,
      note: `distant tower silhouettes rendered at 1/${TK} scale (draw with setScale(${TK})), already fogged and fading out 60–100 m below the top; anchor = tower top centre. Web: 14 towers at angle a = k/14·2π (+ up to 0.3 rad), distance 74…100 m from (0, -5), top at y -8…+22. Glow layer: their red / teal beacon lights.`,
      towers: towers.map(t => ({ w: +t.w.toFixed(2), d: +t.d.toFixed(2), ry: +t.ry.toFixed(3) })) } }, 6, { dark: false });
  previewEnd(2);
  // sheet of the flat ones
  savePNG(path.join(SHEETS, 'bg_textures.png'), sheet2d([{ img: haze, mode: 'over' }, { img: motes, mode: 'add' }], { cols: 2, cell: 512 }));
  console.log(`  background: ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}
