// ================================================================
//  INPUT — keyboard + mouse, multi-touch twin sticks, gamepad
// ================================================================
const IN = {
  keys: Object.create(null), mx: 0, my: 0, lmb: false, fire: false, abil: false, dash: false,
  mode: IS_TOUCH ? 'touch' : 'mouse', sticks: { L: null, R: null }, gp: null, gpAim: false,
};
const STICK_R = 56;
const stickEls = { L: $('stickL'), R: $('stickR') };

function setInputMode(mode) {
  if (IN.mode === mode) return;
  IN.mode = mode;
  document.body.classList.toggle('touch', mode === 'touch');
  updateControlHints();
}
function stickVec(side) {
  const s = IN.sticks[side];
  if (!s) return null;
  const dx = s.x - s.ox, dy = s.y - s.oy, l = Math.hypot(dx, dy);
  const k = l > STICK_R ? 1 / l : 1 / STICK_R;
  s.vx = dx * k; s.vy = dy * k; s.len = Math.min(1, l / STICK_R);
  return s;
}
function placeStick(side) {
  const el = stickEls[side], s = IN.sticks[side];
  if (!s) {
    // idle "ghost" positions show where to put the thumbs
    const x = side === 'L' ? Math.max(90, viewW * 0.16) : viewW - Math.max(90, viewW * 0.16) - (viewW > viewH ? 90 : 0);
    // above the bottom safe-area inset (home indicator) and, in portrait, clear of the HP bar
    const y = viewH - safeBottom - Math.max(110, viewH * 0.17) - (viewH > viewW ? 20 : 0);
    el.style.transform = `translate3d(${x}px, ${y}px, 0)`;
    el.classList.remove('on');
    el.firstElementChild.style.transform = '';
    return;
  }
  el.classList.add('on');
  el.style.transform = `translate3d(${s.ox}px, ${s.oy}px, 0)`;
  const v = stickVec(side);
  el.firstElementChild.style.transform = `translate3d(${v.vx * v.len * STICK_R}px, ${v.vy * v.len * STICK_R}px, 0)`;
}

const cv = renderer.domElement;
cv.addEventListener('pointerdown', (e) => {
  audioInit();
  if (e.pointerType === 'mouse') {
    setInputMode('mouse');
    IN.mx = e.clientX; IN.my = e.clientY;
    if (e.button === 0) IN.lmb = true;
    if (e.button === 2) IN.abil = true;
    return;
  }
  e.preventDefault();
  setInputMode('touch');
  const side = e.clientX < viewW * 0.5 ? 'L' : 'R';
  if (IN.sticks[side]) return;
  try { cv.setPointerCapture(e.pointerId); } catch (err) { /* capture unsupported */ }
  IN.sticks[side] = { id: e.pointerId, ox: e.clientX, oy: e.clientY, x: e.clientX, y: e.clientY, vx: 0, vy: 0, len: 0 };
  placeStick(side);
}, { passive: false });
cv.addEventListener('pointermove', (e) => {
  if (e.pointerType === 'mouse') { IN.mx = e.clientX; IN.my = e.clientY; if (IN.mode !== 'mouse' && e.movementX * e.movementX + e.movementY * e.movementY > 4) setInputMode('mouse'); return; }
  for (const side of ['L', 'R']) {
    const s = IN.sticks[side];
    if (!s || s.id !== e.pointerId) continue;
    s.x = e.clientX; s.y = e.clientY;
    // the base follows the thumb so the stick never "runs out"
    const dx = s.x - s.ox, dy = s.y - s.oy, l = Math.hypot(dx, dy);
    if (l > STICK_R * 1.25) { s.ox = s.x - dx / l * STICK_R * 1.25; s.oy = s.y - dy / l * STICK_R * 1.25; }
    placeStick(side);
  }
}, { passive: true });
function releasePointer(e) {
  if (e.pointerType === 'mouse') { if (e.button === 0) IN.lmb = false; return; }
  for (const side of ['L', 'R']) if (IN.sticks[side] && IN.sticks[side].id === e.pointerId) { IN.sticks[side] = null; placeStick(side); }
}
cv.addEventListener('pointerup', releasePointer);
cv.addEventListener('pointercancel', releasePointer);
cv.addEventListener('lostpointercapture', releasePointer);
window.addEventListener('blur', () => { IN.lmb = false; IN.sticks.L = IN.sticks.R = null; for (const k in IN.keys) IN.keys[k] = false; });
document.addEventListener('contextmenu', (e) => e.preventDefault());
document.addEventListener('gesturestart', (e) => e.preventDefault());
document.addEventListener('touchmove', (e) => { if (!e.target.closest || !e.target.closest('.screen')) e.preventDefault(); }, { passive: false });
document.addEventListener('dblclick', (e) => e.preventDefault());
// iOS only unlocks WebAudio on touchend / click style activations
document.addEventListener('touchend', () => audioInit(), { passive: true });
document.addEventListener('pointerup', () => audioInit(), { passive: true });

function bindTouchButton(el, fn) {
  el.addEventListener('pointerdown', (e) => { e.preventDefault(); e.stopPropagation(); audioInit(); setInputMode('touch'); fn(); }, { passive: false });
}
bindTouchButton($('tAbility'), () => { IN.abil = true; });
bindTouchButton($('tDash'), () => { IN.dash = true; });
// Menu buttons: a touch tap fires when that finger lifts. WebKit sends no synthetic click while another finger
// rests on the screen (a thumb on the move stick), so click alone would ignore the tap. Mouse / keyboard keep click.
let touchTapT = -1e9;
function onTap(el, fn) {
  let pid = -1;
  el.addEventListener('pointerdown', (e) => { if (e.pointerType !== 'mouse') pid = e.pointerId; });
  el.addEventListener('pointerup', (e) => { if (e.pointerId !== pid) return; pid = -1; touchTapT = performance.now(); fn(e); });
  el.addEventListener('pointercancel', () => { pid = -1; });   // a scroll inside a .screen cancels the tap
  el.addEventListener('click', (e) => fn(e));
}
// the browser's own click that may follow a touch tap must not hit whatever the new screen put under the finger
document.addEventListener('click', (e) => { if (performance.now() - touchTapT < 700) { e.stopPropagation(); e.preventDefault(); } }, true);

window.addEventListener('keydown', (e) => {
  audioInit();
  const c = e.code;
  if (['Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Tab'].includes(c)) e.preventDefault();
  if (e.repeat) return;
  IN.keys[c] = true;
  if (c === 'KeyW' || c === 'KeyA' || c === 'KeyS' || c === 'KeyD' || c.startsWith('Arrow')) setInputMode('mouse');
  if (GS.screen === 'playing') {
    if (c === 'Space' || c === 'ShiftLeft' || c === 'ShiftRight') IN.dash = true;
    if (c === 'KeyQ' || c === 'KeyE') IN.abil = true;
  }
  if (c === 'Escape' || c === 'KeyP') togglePause();
  if (GS.screen === 'levelup' && (c === 'Digit1' || c === 'Digit2' || c === 'Digit3')) pickCard(+c.slice(5) - 1);
  else if (GS.screen === 'levelup') menuNav(c === 'ArrowLeft' || c === 'ArrowUp' ? -1 : c === 'ArrowRight' || c === 'ArrowDown' ? 1 : 0, c === 'Enter' || c === 'NumpadEnter');
  if (GS.screen === 'title' && (c === 'Enter' || c === 'NumpadEnter')) startMission(GS.cls);
  else if ((GS.screen === 'won' || GS.screen === 'lost') && (c === 'Enter' || c === 'NumpadEnter')) startMission(GS.cls);
});
window.addEventListener('keyup', (e) => { IN.keys[e.code] = false; });

// ---------- gamepad (twin stick) ----------
let gpPrev = [];
const gpStick = [0, 0];
function pollGamepad() {
  const pads = navigator.getGamepads ? navigator.getGamepads() : null;
  let gp = null;
  if (pads) for (const p of pads) if (p && p.connected) { gp = p; break; }
  IN.gp = null;
  if (!gp) return;
  const ax = (i) => { const v = gp.axes[i] || 0; return Math.abs(v) < 0.18 ? 0 : v; };
  const btn = (i) => !!(gp.buttons[i] && gp.buttons[i].pressed);
  const st = { lx: ax(0), ly: ax(1), rx: ax(2), ry: ax(3), rt: btn(7), lt: btn(6) };
  if (st.lx || st.ly || st.rx || st.ry || st.rt || gp.buttons.some((b, i) => b && b.pressed && !gpPrev[i])) setInputMode('gamepad');
  const pressed = (i) => btn(i) && !gpPrev[i];
  // stick flicks act like d-pad presses in menus
  const sx = Math.abs(st.lx) > 0.6 ? Math.sign(st.lx) : 0, sy = Math.abs(st.ly) > 0.6 ? Math.sign(st.ly) : 0;
  const flick = (sx !== gpStick[0] || sy !== gpStick[1]) ? (sx || sy) : 0;
  gpStick[0] = sx; gpStick[1] = sy;
  const nav = pressed(14) || pressed(12) ? -1 : pressed(15) || pressed(13) ? 1 : flick;
  const scr = GS.screen;
  if (scr === 'playing') {
    if (pressed(0) || pressed(5)) IN.dash = true;
    if (pressed(4) || pressed(6) || pressed(2)) IN.abil = true;
    if (pressed(9) || pressed(8)) togglePause();
  } else if (scr === 'title') {
    if (nav) { const k = CLASS_ORDER.indexOf(GS.cls); selectClass(CLASS_ORDER[(k + nav + 4) % 4]); }
    if (pressed(0) || pressed(9)) startMission(GS.cls);
  } else if (scr === 'paused') {
    if (pressed(9) || pressed(0) || pressed(1)) togglePause();
  } else if (scr === 'levelup') {
    menuNav(nav, pressed(0));
  } else if (scr === 'won' || scr === 'lost') {
    if (pressed(0) || pressed(9)) startMission(GS.cls);
    else if (pressed(1)) goTitle();
  }
  gpPrev = gp.buttons.map(b => b.pressed);
  IN.gp = st;
}

// ---------- player commands (called from the fixed-step tick) ----------
const _cmd = { mx: 0, mz: 0, fire: false };
const _gp = [0, 0], _ray = new THREE.Vector3();
function screenToGround(sx, sy, h, out) {
  _ray.set(sx / viewW * 2 - 1, -(sy / viewH) * 2 + 1, 0.5).unproject(camera).sub(camera.position);
  const t = (h - camera.position.y) / (_ray.y || -1e-4);
  out[0] = camera.position.x + _ray.x * t; out[1] = camera.position.z + _ray.z * t;
  return out;
}
// Soft aim assist: among bugs inside a ~23° cone around the stick direction, prefer well-aligned, close
// targets in dense clumps (more hits per shot), and boomers / brutes. Density = bugs in the 3x3 hash cells.
function cellDensity(c) {
  let n = 0;
  const i = c % G, j = (c / G) | 0;
  for (let dj = -1; dj <= 1; dj++) {
    const jj = j + dj; if (jj < 0 || jj >= G) continue;
    for (let di = -1; di <= 1; di++) { const ii = i + di; if (ii < 0 || ii >= G) continue; const cc = jj * G + ii; n += hStart[cc + 1] - hStart[cc]; }
  }
  return n;
}
const _aa = new THREE.Vector3();
function aimAssist(m, dx, dz) {
  const cnt = queryCircle(m.x + dx * 8, m.z + dz * 8, 9);
  let best = -1, bs = -1e9;
  for (let q = 0; q < cnt; q++) {
    const b = QB[q];
    if (B.st[b] === S_CLIMB && B.y[b] < -0.6) continue;
    const vx = B.x[b] - m.x, vz = B.z[b] - m.z, d = Math.hypot(vx, vz);
    if (d < 0.6 || d > 17) continue;
    const cs = (vx * dx + vz * dz) / d;
    if (cs < 0.92) continue;
    // never snap to (or lob a grenade at) a bug the player cannot see
    _aa.set(B.x[b], groundY(B.x[b], B.z[b]) + B.y[b] + 0.5, B.z[b]).project(camera);
    if (_aa.x < -0.95 || _aa.x > 0.95 || _aa.y < -0.95 || _aa.y > 0.95 || _aa.z > 1) continue;
    const dens = Math.min(14, cellDensity(hCell[b]));
    const s = cs * 5 - d * 0.1 + dens * 0.07 + (B.type[b] === BOOM ? 0.6 : 0) + (B.type[b] === BRUTE ? 0.4 : 0);
    if (s > bs) { bs = s; best = b; }
  }
  return best;
}
function playerCommands(m) {
  const K = IN.keys;
  let sx = (K.KeyD || K.ArrowRight ? 1 : 0) - (K.KeyA || K.ArrowLeft ? 1 : 0);
  let sy = (K.KeyS || K.ArrowDown ? 1 : 0) - (K.KeyW || K.ArrowUp ? 1 : 0);
  const L = stickVec('L');
  if (L && L.len > 0.12) { sx += L.vx * L.len; sy += L.vy * L.len; }
  const gp = IN.gp;
  if (gp) { sx += gp.lx; sy += gp.ly; }
  const wx = RIGHT_X * sx - FWD_X * sy, wz = RIGHT_Z * sx - FWD_Z * sy;
  _cmd.mx = wx; _cmd.mz = wz; _cmd.fire = false;
  let aimed = false;
  if (IN.mode === 'mouse') {
    screenToGround(IN.mx, IN.my, m.mesh.position.y + 1.2, _gp);
    const dx = _gp[0] - m.x, dz = _gp[1] - m.z;
    if (dx * dx + dz * dz > 0.04) { m.aim = Math.atan2(dx, dz); aimed = true; }
    _cmd.fire = IN.lmb;
  } else if (IN.mode === 'touch') {
    const R = stickVec('R');
    if (R) {
      if (R.len > 0.2) {
        const dx = RIGHT_X * R.vx - FWD_X * R.vy, dz = RIGHT_Z * R.vx - FWD_Z * R.vy, l = Math.hypot(dx, dz) || 1;
        let ang = Math.atan2(dx / l, dz / l);
        const b = aimAssist(m, dx / l, dz / l);
        if (b >= 0) ang += angDiff(ang, Math.atan2(B.x[b] - m.x, B.z[b] - m.z)) * 0.75;
        m.aim = ang; aimed = true;
      } else aimed = true;
      _cmd.fire = true;
    }
  } else if (gp) {
    if (Math.abs(gp.rx) + Math.abs(gp.ry) > 0.3) {
      const dx = RIGHT_X * gp.rx - FWD_X * gp.ry, dz = RIGHT_Z * gp.rx - FWD_Z * gp.ry, l = Math.hypot(dx, dz) || 1;
      let ang = Math.atan2(dx / l, dz / l);
      const b = aimAssist(m, dx / l, dz / l);
      if (b >= 0) ang += angDiff(ang, Math.atan2(B.x[b] - m.x, B.z[b] - m.z)) * 0.6;
      m.aim = ang; aimed = true; _cmd.fire = true;
    }
    if (gp.rt) _cmd.fire = true;
  }
  if (!aimed && Math.abs(wx) + Math.abs(wz) > 0.15) m.aim += angDiff(m.aim, Math.atan2(wx, wz)) * 0.25;
  m.ax = Math.sin(m.aim); m.az = Math.cos(m.aim);
  if (IN.abil) {
    IN.abil = false;
    let tx = m.x + m.ax * 9, tz = m.z + m.az * 9;
    if (IN.mode === 'mouse') {
      // intersect the floor plane at the player's height, then refine once with the floor height there (stairs)
      screenToGround(IN.mx, IN.my, m.mesh.position.y, _gp);
      screenToGround(IN.mx, IN.my, groundY(_gp[0], _gp[1]), _gp); tx = _gp[0]; tz = _gp[1];
    }
    else { const b = aimAssist(m, m.ax, m.az); if (b >= 0) { tx = B.x[b]; tz = B.z[b]; } }
    useAbility(m, tx, tz);
  }
  if (IN.dash) { IN.dash = false; tryDash(m, wx, wz); }
  return _cmd;
}
