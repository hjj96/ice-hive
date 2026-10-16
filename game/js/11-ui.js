// ================================================================
//  UI — DOM HUD, nameplates, objective marker, screens, cards
// ================================================================
const UI = {
  hud: $('hud'), kills: $('hKills'), time: $('hTime'), combo: $('hCombo'), obj: $('hObj'), objLab: $('hObjLab'), objBar: $('hObjBar'), objFill: $('hObjFill'),
  hp: $('hHp'), hpT: $('hHpT'), lvl: $('hLvl'), xp: $('hXp'), abil: $('hAbil'), abilL: $('hAbilL'), dash: $('hDash'),
  tAbil: $('tAbility'), tAbilL: $('tAbilityL'), tDash: $('tDash'), hint: $('hHint'), toasts: $('toasts'), squad: $('hSquad'),
  plates: $('plates'), marker: $('marker'), mkL: $('mkL'), banner: $('banner'), bnM: $('bnM'), bnS: $('bnS'),
  dmg: $('dmg'), hordeFx: $('hordeFx'), flash: $('flash'), touch: $('touchUI'),
};
const uiCache = Object.create(null);
function setText(el, key, v) { if (uiCache[key] !== v) { uiCache[key] = v; el.textContent = v; } }
function setStyle(el, key, prop, v) { if (uiCache[key] !== v) { uiCache[key] = v; el.style[prop] = v; } }
function setVar(el, key, name, v) { if (uiCache[key] !== v) { uiCache[key] = v; el.style.setProperty(name, v); } }
function setClass(el, key, cls, on) { const k = key + cls; if (uiCache[k] !== on) { uiCache[k] = on; el.classList.toggle(cls, on); } }

// ---------- transient messages ----------
function banner(main, sub, teal) {
  UI.bnM.textContent = main; UI.bnS.textContent = sub || '';
  UI.banner.classList.remove('show', 'teal');
  void UI.banner.offsetWidth;
  UI.banner.classList.add('show');
  if (teal) UI.banner.classList.add('teal');
}
function toast(text, kind) {
  if (GS.screen === 'title') return;
  const el = document.createElement('div');
  el.className = 'toast' + (kind ? ' ' + kind : '');
  el.textContent = text;
  UI.toasts.appendChild(el);
  while (UI.toasts.children.length > 4) UI.toasts.firstElementChild.remove();
  setTimeout(() => el.remove(), 3300);
}

// ---------- squad list + nameplates ----------
let squadRows = [], plates = [];
function buildSquadUI() {
  UI.squad.textContent = ''; UI.plates.textContent = '';
  squadRows = M.map(m => {
    const row = document.createElement('div'); row.className = 'sq';
    row.innerHTML = '<span class="chip"></span><span class="nm"></span><span class="bar"><i></i></span>';
    row.children[0].style.background = m.C.css;
    row.children[0].style.boxShadow = '0 0 8px ' + m.C.css;
    row.children[1].textContent = m.isPlayer ? 'ВЫ' : m.name;
    UI.squad.appendChild(row);
    return { row, bar: row.children[2].firstElementChild };
  });
  plates = M.map(m => {
    const p = document.createElement('div'); p.className = 'plate' + (m.isPlayer ? ' me' : '');
    p.innerHTML = '<div class="pn"></div><div class="ph"><i></i></div><div class="ps"></div><div class="rv"></div>';
    p.firstElementChild.textContent = m.isPlayer ? 'ВЫ' : m.name;
    UI.plates.appendChild(p);
    return { el: p, hp: p.children[1].firstElementChild, seg: p.children[2], rv: p.children[3] };
  });
  UI.abilL.textContent = M[0].C.abShort; UI.tAbilL.textContent = M[0].C.abShort;
}
const _pv = new THREE.Vector3();
function project(x, y, z) {
  _pv.set(x, y, z).project(camera);
  return _pv;
}
const plX = new Float32Array(4), plY = new Float32Array(4), PLATE_GAP = 26;
// layout read lazily, once per resize / screen change / hint change (never every frame)
let plateTop = 0, plateTopDirty = true, hintRect = null;
function markHudLayout() { plateTopDirty = true; hintRect = null; }
function updatePlates() {
  if (plateTopDirty) { plateTopDirty = false; const r = document.querySelector('.obj-box').getBoundingClientRect(); plateTop = r.height ? r.bottom + 4 : 0; }
  for (let k = 0; k < M.length; k++) {
    const m = M[k];
    const v = project(m.mesh.position.x, m.mesh.position.y + (m.downed ? 1.3 : 2.55), m.mesh.position.z);
    plX[k] = (v.x * 0.5 + 0.5) * viewW; plY[k] = (-v.y * 0.5 + 0.5) * viewH - 30;
  }
  // keep clustered nameplates readable: stack overlapping plates upward (never down onto the marines);
  // where the stack would run into the objective box at the top, spread the pair sideways instead
  for (let it = 0; it < 6; it++) for (let a = 0; a < M.length; a++) for (let b = a + 1; b < M.length; b++) {
    const dx = plX[a] - plX[b];
    if (Math.abs(dx) > 84) continue;
    const dy = plY[a] - plY[b];
    if (Math.abs(dy) >= PLATE_GAP) continue;
    const up = dy < 0 ? a : b, lo = up === a ? b : a;
    if (plY[lo] - PLATE_GAP >= plateTop) plY[up] = plY[lo] - PLATE_GAP;
    else { const l = dx < 0 ? a : b, r = l === a ? b : a, mid = (plX[a] + plX[b]) / 2; plX[l] = mid - 43; plX[r] = mid + 43; }
  }
  for (let k = 0; k < M.length; k++) plX[k] = clamp(plX[k], 40, viewW - 40);
  // the contextual hint wins over plates that end up under it (they fade while it shows)
  const hintOn = !!uiCache.hint;
  if (hintOn && !hintRect) hintRect = UI.hint.getBoundingClientRect();
  // a bot plate drawn over the player's own marine fades so the player stays visible
  const me = M[0] ? project(M[0].mesh.position.x, M[0].mesh.position.y + 1.0, M[0].mesh.position.z) : null;
  const meX = me ? (me.x * 0.5 + 0.5) * viewW : -1e4, meY = me ? (-me.y * 0.5 + 0.5) * viewH : -1e4;
  for (let k = 0; k < M.length; k++) {
    const m = M[k], p = plates[k];
    if (!p) continue;
    p.el.style.transform = `translate3d(${plX[k].toFixed(1)}px, ${plY[k].toFixed(1)}px, 0)`;
    setClass(p.el, 'pdim' + k, 'dim', k > 0 && Math.abs(meX - plX[k]) < 40 && meY > plY[k] - 4 && meY < plY[k] + 28);
    setClass(p.el, 'phint' + k, 'under', hintOn && plX[k] + 40 > hintRect.left && plX[k] - 40 < hintRect.right && plY[k] + 26 > hintRect.top && plY[k] < hintRect.bottom);
    setStyle(p.hp, 'php' + k, 'transform', 'scaleX(' + (m.hp / m.maxHp).toFixed(3) + ')');
    setStyle(p.seg, 'pseg' + k, 'clipPath', 'inset(0 ' + ((1 - clamp(m.bar, 0, 1)) * 100).toFixed(1) + '% 0 0)');
    setClass(p.el, 'pl' + k, 'low', m.over > 0 || m.reload > 0);
    setClass(p.el, 'pd' + k, 'down', m.downed);
    setStyle(p.rv, 'prv' + k, 'transform', 'scaleX(' + (m.downed ? m.revive : 0).toFixed(2) + ')');
    const r = squadRows[k];
    setStyle(r.bar, 'sqb' + k, 'transform', 'scaleX(' + (m.hp / m.maxHp).toFixed(3) + ')');
    setClass(r.row, 'sq' + k, 'down', m.downed);
  }
}

// ---------- objective text + marker ----------
function objectiveText() {
  if (GS.attract) return '';
  if (DIR.stage === 'beacons') {
    if (DIR.active >= 0) { const b = DIR.beacons[DIR.active]; return 'Удерживайте маяк «' + b.name + '»'; }
    return 'Запустите маяки ' + DIR.done + '/3';
  }
  if (DIR.stage === 'toLift') return 'Лифт вызван — к платформе';
  if (DIR.stage === 'hold') return 'Держитесь на лифте · ' + fmtTime(Math.ceil(DIR.liftT));
  if (DIR.stage === 'extract') return 'Эвакуация!';
  return '';
}
function objectiveProgress() {
  if (DIR.stage === 'beacons' && DIR.active >= 0) return DIR.beacons[DIR.active].progress;
  if (DIR.stage === 'hold') return 1 - DIR.liftT / DIR.liftDur;
  return -1;
}
function updateMarker() {
  const P = M[0];
  let tx, tz, show = false;
  // the next beacon, or the active one once the player has wandered out of its ring
  if (DIR.stage === 'beacons') { const b = nextBeacon(); if (b && (b.state === 0 || Math.hypot(b.x - P.x, b.z - P.z) > BEACON_R)) { tx = b.x; tz = b.z; show = true; } }
  else if (DIR.stage === 'toLift' || (DIR.stage === 'hold' && !onLift(P.x, P.z))) { tx = LV.lift.x; tz = LV.lift.z; show = true; }
  if (show && Math.hypot(tx - P.x, tz - P.z) < 4) show = false;
  setStyle(UI.marker, 'mkd', 'display', show ? 'block' : 'none');
  if (!show) return;
  const v = project(tx, groundY(tx, tz) + 1.5, tz);
  let x = (v.x * 0.5 + 0.5) * viewW, y = (-v.y * 0.5 + 0.5) * viewH;
  if (v.z > 1) { x = viewW - x; y = viewH - y; }
  // safe box: below the top HUD band, above the bottom controls
  const top = viewW < 600 ? 150 : 96, bot = viewH - (IN.mode === 'touch' ? 150 : 100), left = 34, right = viewW - 34;
  const inside = v.z <= 1 && x > left && x < right && y > top && y < bot;
  let ang = 0;
  if (!inside) {
    const cx = viewW / 2, cy = (top + bot) / 2, dx = x - cx, dy = y - cy;
    const k = Math.min((dx > 0 ? right - cx : cx - left) / Math.max(1e-3, Math.abs(dx)), (dy > 0 ? bot - cy : cy - top) / Math.max(1e-3, Math.abs(dy)));
    x = cx + dx * k; y = cy + dy * k;
    ang = Math.atan2(dy, dx) + Math.PI / 2;
  }
  UI.marker.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
  UI.marker.firstElementChild.firstElementChild.style.transform = inside ? '' : `rotate(${(ang - Math.PI / 4).toFixed(3)}rad)`;
  setClass(UI.marker, 'mk', 'on-screen', inside);
  setText(UI.mkL, 'mkl', Math.round(Math.hypot(tx - P.x, tz - P.z)) + ' м');
}

// ---------- per-frame HUD ----------
function q05(v) { return (Math.round(v * 20) / 20).toFixed(2); }
let lastCombo = 0, comboBumpT = 0;
function nearDowned(P) { for (let k = 1; k < M.length; k++) if (M[k].downed && Math.hypot(M[k].x - P.x, M[k].z - P.z) < 6) return true; return false; }
function updateHUD(rdt) {
  if (GS.screen === 'title') return;
  const P = M[0];
  setText(UI.kills, 'k', String(GS.kills));
  setText(UI.time, 't', fmtTime(GS.time));
  setText(UI.combo, 'c', GS.combo >= 5 ? '×' + GS.combo : '');
  setClass(UI.combo, 'c', 'on', GS.combo >= 5);
  setClass(UI.combo, 'c', 'hot', GS.combo >= 25);
  setClass(UI.combo, 'c', 'blaze', GS.combo >= 60);
  // punchy scale bump on every new kill in a combo (Web Animations: no forced layout)
  const now = performance.now();
  if (GS.combo >= 5 && GS.combo !== lastCombo && now - comboBumpT > 70 && UI.combo.animate && !REDUCED_MOTION) {
    comboBumpT = now;
    UI.combo.animate([{ transform: 'scale(' + (GS.combo % 25 === 0 ? 1.9 : 1.35) + ')' }, { transform: 'scale(1)' }], { duration: GS.combo % 25 === 0 ? 380 : 160, easing: 'ease-out' });
  }
  lastCombo = GS.combo;
  setText(UI.obj, 'o', objectiveText());
  const pr = objectiveProgress();
  setClass(UI.objBar, 'ob', 'on', pr >= 0);
  if (pr >= 0) setStyle(UI.objFill, 'of', 'transform', 'scaleX(' + pr.toFixed(3) + ')');
  setStyle(UI.hp, 'hp', 'transform', 'scaleX(' + (P.hp / P.maxHp).toFixed(3) + ')');
  setText(UI.hpT, 'hpt', String(Math.ceil(P.hp)));
  setText(UI.lvl, 'lv', 'УР ' + GS.level);
  setStyle(UI.xp, 'xp', 'transform', 'scaleX(' + (GS.xp / GS.xpNext).toFixed(3) + ')');
  const abP = P.abCd > 0 ? (P.abCd / (P.C.abCd * P.mods.acd)).toFixed(3) : '0';
  const abReady = P.abCd <= 0 && !P.downed;
  setVar(UI.abil, 'ab', '--p', abP); setClass(UI.abil, 'ab', 'ready', abReady);
  setVar(UI.tAbil, 'tab', '--p', abP); setClass(UI.tAbil, 'tab', 'ready', abReady);
  const dP = P.dashCd > 0 ? (P.dashCd / (3 * P.mods.dashCd)).toFixed(3) : '0';
  setVar(UI.tDash, 'tdp', '--p', dP);
  setClass(UI.tDash, 'td', 'ready', P.dashCd <= 0 && !P.downed);
  setStyle(UI.dash, 'ds', 'transform', 'scaleX(' + (1 - +dP).toFixed(3) + ')');
  // contextual hint
  let hint = '', red = false;
  if (P.downed) { hint = 'Вы ранены — союзники идут на помощь'; red = true; }
  else if (GS.time < 7) hint = IN.mode === 'touch' ? 'Левый палец — бег · правый — прицел и огонь' : IN.mode === 'gamepad' ? 'Стики — бег и прицел · LB — способность · A — рывок' : 'WASD — бег · мышь — прицел · ЛКМ — огонь · Q — способность';
  else if (nearDowned(P)) hint = 'Встаньте рядом с раненым, чтобы поднять его';
  else if (DIR.stage === 'beacons' && DIR.active >= 0 && standingIn(DIR.beacons[DIR.active].x, DIR.beacons[DIR.active].z, BEACON_R) === 0) { hint = 'Вернитесь в кольцо маяка!'; red = true; }
  else if (DIR.stage === 'beacons' && DIR.active >= 0 && DIR.beacons[DIR.active].contested) { hint = 'Рой в кольце — зарядка замедлена'; red = true; }
  else if (DIR.stage === 'beacons' && DIR.active < 0) { const b = nextBeacon(); if (b && Math.hypot(b.x - P.x, b.z - P.z) < 9) hint = 'Встаньте в кольцо маяка'; }
  else if (DIR.stage === 'hold' && !onLift(P.x, P.z)) { hint = 'На платформу! Отсчёт стоит'; red = true; }
  else if (DIR.stage === 'hold' && DIR.liftT > LIFT_TIME - 8) hint = 'Защитный контур лифта бьёт током каждые 5 секунд';
  if (uiCache.hint !== hint) hintRect = null;
  setText(UI.hint, 'hint', hint);
  setClass(UI.hint, 'h', 'on', !!hint);
  setClass(UI.hint, 'h', 'red', red);
  // screen-space damage / horde / flash overlays
  GS.dmgFlash = Math.max(0, GS.dmgFlash - rdt * 1.6);
  // (the overlays are their own compositor layers: opacity changes never repaint them; values step by 0.05)
  const lowHp = !P.downed && P.hp / P.maxHp < 0.3 ? 0.35 + 0.15 * Math.sin(performance.now() / 160) : 0;
  setStyle(UI.dmg, 'dmg', 'opacity', q05(Math.max(GS.dmgFlash, lowHp, P.downed ? 0.5 : 0)));
  GS.hordeFx = Math.max(0, GS.hordeFx - rdt * 0.4);
  setStyle(UI.hordeFx, 'hf', 'opacity', q05(GS.hordeFx * (0.6 + 0.4 * Math.sin(performance.now() / 90))));
  GS.flash = Math.max(0, GS.flash - rdt * 3);
  setStyle(UI.flash, 'fl', 'opacity', q05(GS.flash));
  updatePlates();
  updateMarker();
  updateThreatHUD();
}

// ---------- screens ----------
const SCREENS = { title: $('sTitle'), paused: $('sPause'), levelup: $('sLevel'), won: $('sEnd'), lost: $('sEnd') };
function showScreen(name) {
  GS.screen = name;
  for (const k in SCREENS) SCREENS[k].classList.remove('on');
  if (SCREENS[name]) SCREENS[name].classList.add('on');
  const inGame = name !== 'title';
  UI.hud.style.display = inGame ? 'block' : 'none';
  UI.plates.style.display = inGame ? 'block' : 'none';
  UI.touch.style.visibility = name === 'playing' ? 'visible' : 'hidden';
  stillDrawn = false; markHudLayout();
  // one-shot presses queued on another screen (pause, cards, downed) must not fire after it
  IN.abil = IN.dash = false;
  if (name !== 'playing') IN.lmb = false;
  // thumbs held through a level-up or pause keep steering afterwards (pointerup / cancel still release them)
  if (name === 'title' || name === 'won' || name === 'lost') IN.sticks.L = IN.sticks.R = null;
  placeStick('L'); placeStick('R');
  if (!inGame) UI.marker.style.display = 'none';
}
function controlHint() {
  if (IN.mode === 'touch') return '<b>Левый палец</b> — движение · <b>правый палец</b> — прицел и автоогонь · кнопки справа — способность и рывок';
  if (IN.mode === 'gamepad') return '<b>Левый стик</b> — движение · <b>правый стик</b> — прицел и огонь · <b>LB</b> — способность · <b>A</b> — рывок · <b>Start</b> — пауза · <b>крестовина</b> — выбор в меню';
  return '<b>WASD</b> — движение · <b>мышь</b> — прицел · <b>ЛКМ</b> — огонь · <b>ПКМ / Q</b> — способность · <b>Пробел</b> — рывок · <b>Esc</b> — пауза';
}
function updateControlHints() {
  $('tHint').innerHTML = controlHint();
  $('pHint').innerHTML = controlHint();
}
function soundLabel() { return 'Звук: ' + (AU.muted ? 'выкл' : 'вкл'); }
function volLabel() { return 'Громкость: ' + Math.round(AU.vol * 100) + '%'; }
let qPref = 'auto';
function qualityLabel() { return 'Графика: ' + (qPref === 'auto' ? 'авто (' + QUALITY[qName].label.toLowerCase() + ')' : QUALITY[qPref].label.toLowerCase()); }
function selectClass(id) {
  sfx('click');
  GS.cls = id; store.set('cls', id);
  CLASS_ORDER.forEach((c, k) => { const el = $('classes').children[k]; if (el) el.classList.toggle('sel', c === id); });
}
// keyboard / gamepad focus on the level-up cards
let cardFocus = 0;
function menuNav(dir, confirm) {
  const cards = $('lvCards').children;
  if (!cards.length) return;
  if (dir) { cardFocus = (cardFocus + dir + cards.length) % cards.length; sfx('click'); }
  for (let k = 0; k < cards.length; k++) cards[k].classList.toggle('focus', k === cardFocus);
  if (confirm && !$('lvCards').classList.contains('lock')) pickCard(cardFocus);
}
function buildTitle() {
  const wrap = $('classes');
  wrap.textContent = '';
  CLASS_ORDER.forEach((id, k) => {
    const C = CLASSES[id];
    const b = document.createElement('button');
    b.className = 'ccard' + (id === GS.cls ? ' sel' : '');
    b.style.setProperty('--cc', C.css);
    b.innerHTML = `<div class="cc-top"><span>0${k + 1}</span><span class="ln"></span></div><div class="cc-name"></div><div class="cc-w"></div><div class="cc-a"></div><div class="cc-d"></div>`;
    b.querySelector('.cc-name').textContent = C.name;
    b.querySelector('.cc-w').textContent = C.weapon;
    b.querySelector('.cc-a').textContent = '◆ ' + C.ability;
    b.querySelector('.cc-d').textContent = C.desc;
    onTap(b, () => { audioInit(); selectClass(id); });
    wrap.appendChild(b);
  });
  $('btnSound').textContent = soundLabel();
  updateControlHints();
  const best = GS.best;
  $('tBest').textContent = best && (best.kills || best.win) ? 'Рекорд: ' + best.kills + ' убито' + (best.win ? ' · лучшая эвакуация ' + fmtTime(best.win) : '') : '';
}
// menu buttons fire on the finger lifting (onTap), so they work while the other thumb still rests on the screen
onTap($('btnGo'), () => startMission(GS.cls));
onTap($('btnSound'), () => { audioInit(); setMuted(!AU.muted); $('btnSound').textContent = soundLabel(); sfx('click'); });
$('btnPause').addEventListener('pointerdown', (e) => { e.stopPropagation(); e.preventDefault(); togglePause(); });
onTap($('pResume'), () => togglePause());
onTap($('pSound'), () => { setMuted(!AU.muted); $('pSound').textContent = soundLabel(); sfx('click'); });
onTap($('pVol'), () => { audioInit(); cycleVolume(); if (AU.muted) { setMuted(false); $('pSound').textContent = soundLabel(); } $('pVol').textContent = volLabel(); sfx('click'); });
onTap($('pQuality'), () => {
  const order = ['auto', 'low', 'med', 'high'];
  qPref = order[(order.indexOf(qPref) + 1) % order.length];
  if (qPref === 'auto') { qLocked = false; applyQuality(IS_MOBILE ? 'med' : 'high', false); }
  else applyQuality(qPref, true);
  store.set('quality', qPref);
  $('pQuality').textContent = qualityLabel(); sfx('click');
});
onTap($('pQuit'), () => { sfx('click'); endGame(false, true); });
// iOS app only: vibration toggle in the pause menu (the bridge persists the choice)
function hapticsLabel() { return 'Вибрация: ' + (NATIVE && NATIVE.hapticsOn() ? 'вкл' : 'выкл'); }
if (NATIVE) {
  const b = document.createElement('button');
  b.className = 'btn btn-ghost'; b.id = 'pHaptics'; b.textContent = hapticsLabel();
  $('pVol').after(b);
  onTap(b, () => { NATIVE.setHaptics(!NATIVE.hapticsOn()); b.textContent = hapticsLabel(); sfx('click'); NATIVE.haptic('select'); });
}
onTap($('eAgain'), () => startMission(GS.cls));
onTap($('eMenu'), () => { sfx('click'); goTitle(); });

function openPauseUI() {
  $('pSound').textContent = soundLabel();
  $('pVol').textContent = volLabel();
  $('pQuality').textContent = qualityLabel();
  if (NATIVE) $('pHaptics').textContent = hapticsLabel();
  updateControlHints();
}
function renderCards() {
  $('lvN').textContent = String(GS.level - GS.pendingLevels + 1);
  const wrap = $('lvCards');
  wrap.textContent = '';
  // brief lock so a thumb already on the screen cannot pick a card by accident
  wrap.classList.add('lock');
  clearTimeout(renderCards.t);
  renderCards.t = setTimeout(() => wrap.classList.remove('lock'), IN.mode === 'touch' ? 650 : 250);
  cardFocus = 0;
  const showFocus = IN.mode === 'gamepad';
  rollUpgrades().forEach((u, k) => {
    const b = document.createElement('button');
    b.className = 'card' + (u.cls ? ' cls' : '') + (showFocus && k === 0 ? ' focus' : '');
    b.innerHTML = '<span class="ck"></span><span class="ct"></span><span class="cn"></span><span class="cdsc"></span><span class="cs"></span>';
    b.children[0].textContent = IN.mode === 'mouse' ? String(k + 1) : IN.mode === 'gamepad' && k === 0 ? 'A' : '';
    b.children[1].textContent = u.cls ? 'Класс · ' + M[0].C.name : 'Снаряжение';
    b.children[2].textContent = u.name;
    b.children[3].textContent = u.desc;
    const n = GS.upg[u.id] || 0;
    b.children[4].textContent = n ? 'Взято: ' + n : 'Новое';
    onTap(b, () => pickCard(k));
    wrap.appendChild(b);
  });
}
function showEnd(won, surrendered) {
  const box = $('eBox');
  box.classList.toggle('won', won); box.classList.toggle('lost', !won);
  $('eTitle').textContent = won ? 'Эвакуация успешна' : 'Рой победил';
  $('eSub').textContent = won ? 'Отряд поднялся над бездной. Кельвин-9 остаётся рою — но вы живы.'
    : surrendered ? 'Отряд отозван. Маяки погасли один за другим.' : 'Последний фонарь погас. Связь с отрядом потеряна.';
  const acc = GS.shots > 0 ? Math.round(100 * Math.min(1, GS.hits / GS.shots)) : 0;
  const rows = [
    ['Время', fmtTime(GS.time)], ['Убито отрядом', String(GS.kills)], ['Ваши убийства', String(GS.playerKills)],
    ['Точность', acc + '%'], ['Лучшее комбо', '×' + GS.bestCombo], ['Уровень', String(GS.level)],
  ];
  const st = $('eStats');
  st.textContent = '';
  for (const [a, b] of rows) { const d = document.createElement('div'); d.innerHTML = '<span></span><b></b>'; d.children[0].textContent = a; d.children[1].textContent = b; st.appendChild(d); }
  if (GS.newRecord) st.children[1].classList.add('rec');
}
