// ================================================================
//  TEXTURES — everything procedural on <canvas>
// ================================================================
function mkCanvas(w, h) { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; }
function speckle(g, w, h, n, light, dark, R) {
  for (let i = 0; i < n; i++) { g.fillStyle = R() < 0.5 ? light : dark; g.fillRect(R() * w, R() * h, 1 + R() * 2, 1 + R() * 2); }
}
function rrect(g, x, y, w, h, r) {
  g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
}
function canvasTex(c, { repeat = false, srgb = true, aniso = 4, mips = true } = {}) {
  const t = new THREE.CanvasTexture(c);
  if (repeat) t.wrapS = t.wrapT = THREE.RepeatWrapping;
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = aniso;
  if (!mips) { t.generateMipmaps = false; t.minFilter = THREE.LinearFilter; }
  return t;
}

// Grated steel floor tile (one tile = 2 m x 2 m)
function texGrating() {
  const S = 256, c = mkCanvas(S, S), g = c.getContext('2d'), R = mulberry32(11);
  g.fillStyle = '#4b5560'; g.fillRect(0, 0, S, S);
  speckle(g, S, S, 3200, 'rgba(255,255,255,0.06)', 'rgba(0,0,0,0.16)', R);
  g.fillStyle = '#66717d'; g.fillRect(0, 0, S, 4); g.fillRect(0, 0, 4, S);
  g.fillStyle = '#1b2026'; g.fillRect(0, S - 4, S, 4); g.fillRect(S - 4, 0, 4, S);
  for (let p = 0; p < 2; p++) {
    const ox = 9 + p * 124;
    g.fillStyle = '#262c33'; g.fillRect(ox + 117, 8, 3, S - 16);
    for (let r = 0; r < 10; r++) {
      for (let k = 0; k < 3; k++) {
        const x = ox + 4 + k * 37, y = 11 + r * 24;
        g.fillStyle = '#040608'; rrect(g, x, y, 31, 12, 6); g.fill();
        g.fillStyle = 'rgba(170,185,200,0.32)'; g.fillRect(x + 6, y + 12.5, 19, 1.5);
      }
    }
  }
  g.fillStyle = '#7d8995';
  for (const [x, y] of [[10, 10], [S - 12, 10], [10, S - 12], [S - 12, S - 12], [S / 2, 10], [S / 2, S - 12]]) { g.beginPath(); g.arc(x, y, 2.6, 0, TAU); g.fill(); }
  // rust / grime streaks
  for (let i = 0; i < 14; i++) { g.fillStyle = `rgba(${60 + R() * 40 | 0},${40 + R() * 20 | 0},${30},${0.05 + R() * 0.07})`; g.fillRect(R() * S, R() * S, 4 + R() * 30, 2 + R() * 6); }
  return canvasTex(c, { repeat: true });
}

// Solid snow-crusted concrete walkway tile (2 m)
function texSlab() {
  const S = 256, c = mkCanvas(S, S), g = c.getContext('2d'), R = mulberry32(23);
  g.fillStyle = '#6f7a85'; g.fillRect(0, 0, S, S);
  for (let i = 0; i < 260; i++) {
    const v = 90 + R() * 50 | 0; g.fillStyle = `rgba(${v},${v + 6},${v + 14},0.18)`;
    g.beginPath(); g.arc(R() * S, R() * S, 3 + R() * 18, 0, TAU); g.fill();
  }
  speckle(g, S, S, 4000, 'rgba(255,255,255,0.08)', 'rgba(0,0,0,0.12)', R);
  g.strokeStyle = '#3b434c'; g.lineWidth = 3; g.strokeRect(1.5, 1.5, S - 3, S - 3);
  g.strokeStyle = 'rgba(30,35,40,0.6)'; g.lineWidth = 1;
  for (let i = 0; i < 5; i++) {
    g.beginPath(); let x = R() * S, y = R() * S; g.moveTo(x, y);
    for (let k = 0; k < 6; k++) { x += (R() - 0.5) * 40; y += (R() - 0.5) * 40; g.lineTo(x, y); }
    g.stroke();
  }
  return canvasTex(c, { repeat: true });
}

// Amber/black hazard stripes, repeats along u
function texHazard() {
  const W = 128, H = 32, c = mkCanvas(W, H), g = c.getContext('2d'), R = mulberry32(5);
  g.fillStyle = '#d99a1c'; g.fillRect(0, 0, W, H);
  g.fillStyle = '#121212';
  for (let x = -H; x < W + H; x += 32) { g.beginPath(); g.moveTo(x, H); g.lineTo(x + 16, H); g.lineTo(x + 16 + H, 0); g.lineTo(x + H, 0); g.closePath(); g.fill(); }
  speckle(g, W, H, 900, 'rgba(255,255,255,0.12)', 'rgba(0,0,0,0.3)', R);
  for (let i = 0; i < 40; i++) { g.fillStyle = 'rgba(90,96,104,0.55)'; g.fillRect(R() * W, R() * H, 2 + R() * 9, 1 + R() * 3); }
  return canvasTex(c, { repeat: true });
}

// Landing pad marking (circle + chevrons)
function texPadMark() {
  const S = 256, c = mkCanvas(S, S), g = c.getContext('2d'), R = mulberry32(9);
  g.clearRect(0, 0, S, S);
  g.strokeStyle = 'rgba(255,180,32,0.85)'; g.lineWidth = 9; g.beginPath(); g.arc(128, 128, 108, 0, TAU); g.stroke();
  g.lineWidth = 3; g.beginPath(); g.arc(128, 128, 92, 0, TAU); g.stroke();
  g.fillStyle = 'rgba(230,236,240,0.85)';
  g.fillRect(84, 70, 20, 116); g.fillRect(152, 70, 20, 116); g.fillRect(84, 118, 88, 20);
  g.globalCompositeOperation = 'destination-out';
  for (let i = 0; i < 1600; i++) { g.fillStyle = `rgba(0,0,0,${R() * 0.6})`; g.fillRect(R() * S, R() * S, 2 + R() * 6, 2 + R() * 4); }
  return canvasTex(c);
}

// Decal atlas 2x2: 0 splat, 1 streak splat, 2 corpse remains (colored), 3 scorch
function texDecals() {
  const S = 256, H = 128, c = mkCanvas(S, S), g = c.getContext('2d'), R = mulberry32(77);
  function blob(cx, cy, n, rmin, rmax, spread) {
    for (let i = 0; i < n; i++) { const a = R() * TAU, d = R() * spread; g.beginPath(); g.arc(cx + Math.cos(a) * d, cy + Math.sin(a) * d, rmin + R() * (rmax - rmin), 0, TAU); g.fill(); }
  }
  // cell 0: round splat with droplets
  g.fillStyle = 'rgba(255,255,255,0.95)'; blob(64, 64, 14, 9, 22, 20);
  for (let i = 0; i < 26; i++) { const a = R() * TAU, d = 30 + R() * 28; g.beginPath(); g.arc(64 + Math.cos(a) * d, 64 + Math.sin(a) * d, 1 + R() * 4, 0, TAU); g.fill(); }
  g.fillStyle = 'rgba(0,0,0,0.25)'; blob(64, 64, 8, 4, 12, 14);
  // cell 1: directional streak splat
  g.save(); g.translate(H, 0);
  g.fillStyle = 'rgba(255,255,255,0.95)'; blob(56, 64, 10, 8, 18, 14);
  for (let i = 0; i < 9; i++) { const y = 64 + (R() - 0.5) * 34, l = 20 + R() * 40, w = 2 + R() * 6; g.beginPath(); g.ellipse(64 + l * 0.6, y, l * 0.55, w, 0, 0, TAU); g.fill(); }
  for (let i = 0; i < 18; i++) { g.beginPath(); g.arc(70 + R() * 54, 64 + (R() - 0.5) * 60, 1 + R() * 3, 0, TAU); g.fill(); }
  g.fillStyle = 'rgba(0,0,0,0.22)'; blob(56, 64, 6, 4, 10, 10);
  g.restore();
  // cell 2: corpse remains — curled legs, chitin chunks, pink glands (drawn in final colors)
  g.save(); g.translate(0, H);
  g.strokeStyle = '#1a1018'; g.lineCap = 'round';
  for (let i = 0; i < 7; i++) {
    const a = R() * TAU, l = 20 + R() * 22; g.lineWidth = 2 + R() * 2.5;
    g.beginPath(); g.moveTo(64, 64); g.quadraticCurveTo(64 + Math.cos(a) * l, 64 + Math.sin(a) * l, 64 + Math.cos(a + 0.9) * l * 1.2, 64 + Math.sin(a + 0.9) * l * 1.2); g.stroke();
  }
  g.fillStyle = 'rgba(80,30,50,0.85)'; blob(64, 64, 9, 6, 16, 18);
  g.fillStyle = '#2a1626'; blob(64, 62, 6, 8, 16, 10);
  g.fillStyle = '#3d2236'; blob(58, 58, 3, 4, 8, 6);
  g.fillStyle = '#ff4f8a'; for (let i = 0; i < 7; i++) { g.beginPath(); g.arc(50 + R() * 28, 50 + R() * 28, 1.2 + R() * 2.2, 0, TAU); g.fill(); }
  g.restore();
  // cell 3: scorch mark
  g.save(); g.translate(H, H);
  const rg = g.createRadialGradient(64, 64, 4, 64, 64, 60);
  rg.addColorStop(0, 'rgba(0,0,0,0.92)'); rg.addColorStop(0.55, 'rgba(10,8,8,0.7)'); rg.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = rg; g.beginPath(); g.arc(64, 64, 62, 0, TAU); g.fill();
  g.strokeStyle = 'rgba(0,0,0,0.6)'; g.lineWidth = 2;
  for (let i = 0; i < 16; i++) { const a = R() * TAU; g.beginPath(); g.moveTo(64 + Math.cos(a) * 18, 64 + Math.sin(a) * 18); g.lineTo(64 + Math.cos(a) * (40 + R() * 22), 64 + Math.sin(a) * (40 + R() * 22)); g.stroke(); }
  g.restore();
  return canvasTex(c, { aniso: 2 });
}

// Soft radial glow (white -> transparent)
function texGlow() {
  const S = 64, c = mkCanvas(S, S), g = c.getContext('2d');
  const rg = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  rg.addColorStop(0, 'rgba(255,255,255,1)'); rg.addColorStop(0.35, 'rgba(255,255,255,0.45)'); rg.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = rg; g.fillRect(0, 0, S, S);
  return canvasTex(c, { srgb: false, aniso: 1 });
}

// Telegraph ring: bright rim + faint fill + ticks
function texRing() {
  const S = 128, c = mkCanvas(S, S), g = c.getContext('2d');
  g.fillStyle = 'rgba(255,255,255,0.13)'; g.beginPath(); g.arc(64, 64, 58, 0, TAU); g.fill();
  g.strokeStyle = 'rgba(255,255,255,1)'; g.lineWidth = 5; g.beginPath(); g.arc(64, 64, 60, 0, TAU); g.stroke();
  g.lineWidth = 2; g.strokeStyle = 'rgba(255,255,255,0.6)'; g.beginPath(); g.arc(64, 64, 50, 0, TAU); g.stroke();
  for (let i = 0; i < 12; i++) { const a = i / 12 * TAU; g.beginPath(); g.moveTo(64 + Math.cos(a) * 42, 64 + Math.sin(a) * 42); g.lineTo(64 + Math.cos(a) * 49, 64 + Math.sin(a) * 49); g.stroke(); }
  return canvasTex(c, { srgb: false, aniso: 1 });
}

// Filled disc with a bright rim (acid landing countdown)
function texFill() {
  const S = 128, c = mkCanvas(S, S), g = c.getContext('2d');
  const rg = g.createRadialGradient(64, 64, 0, 64, 64, 62);
  rg.addColorStop(0, 'rgba(255,255,255,0.18)'); rg.addColorStop(0.75, 'rgba(255,255,255,0.32)'); rg.addColorStop(0.9, 'rgba(255,255,255,0.85)'); rg.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = rg; g.beginPath(); g.arc(64, 64, 63, 0, TAU); g.fill();
  return canvasTex(c, { srgb: false, aniso: 1 });
}

// Brute charge lane: border + chevrons pointing toward +v
function texLane() {
  const W = 64, H = 256, c = mkCanvas(W, H), g = c.getContext('2d');
  g.fillStyle = 'rgba(255,255,255,0.12)'; g.fillRect(4, 0, W - 8, H);
  g.fillStyle = 'rgba(255,255,255,0.95)'; g.fillRect(2, 0, 4, H); g.fillRect(W - 6, 0, 4, H);
  g.strokeStyle = 'rgba(255,255,255,0.85)'; g.lineWidth = 6;
  for (let y = 20; y < H; y += 40) { g.beginPath(); g.moveTo(12, y + 16); g.lineTo(32, y); g.lineTo(52, y + 16); g.stroke(); }
  return canvasTex(c, { srgb: false, aniso: 1 });
}

// Laser sight dash pattern (dotted beam look of the references)
function texDash() {
  const W = 64, H = 4, c = mkCanvas(W, H), g = c.getContext('2d');
  g.fillStyle = 'rgba(255,255,255,0.35)'; g.fillRect(0, 0, W, H);
  g.fillStyle = 'rgba(255,255,255,1)'; for (let x = 0; x < W; x += 16) g.fillRect(x, 0, 9, H);
  const t = canvasTex(c, { repeat: true, srgb: false, aniso: 1 });
  return t;
}

// Streaky noise for the cryo beam
function texStreak() {
  const W = 128, H = 32, c = mkCanvas(W, H), g = c.getContext('2d'), R = mulberry32(3);
  g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
  for (let i = 0; i < 140; i++) { const y = R() * H, l = 10 + R() * 60, a = 0.15 + R() * 0.5; g.fillStyle = `rgba(255,255,255,${a})`; g.fillRect(R() * W, y, l, 1 + R() * 2); }
  const rg = g.createLinearGradient(0, 0, 0, H); rg.addColorStop(0, 'rgba(0,0,0,0.9)'); rg.addColorStop(0.5, 'rgba(0,0,0,0)'); rg.addColorStop(1, 'rgba(0,0,0,0.9)');
  g.fillStyle = rg; g.fillRect(0, 0, W, H);
  return canvasTex(c, { repeat: true, srgb: false, aniso: 1 });
}

const TEX = {
  grating: texGrating(), slab: texSlab(), hazard: texHazard(), pad: texPadMark(), decals: texDecals(),
  glow: texGlow(), ring: texRing(), fill: texFill(), lane: texLane(), dash: texDash(), streak: texStreak(),
};
