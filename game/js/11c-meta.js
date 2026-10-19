// ================================================================
//  META — profile, tier choice, mission report (v1.1, package D)
// ================================================================
// metaBoot(data) runs in boot() right after GS.best is read (before buildTitle); tierPrepare(opts) runs first in
// startMission and selects TH. commitRun() runs once per mission end (endGame), buildReport() fills #eRep, titleMeta()
// fills the title (profile line, class chips, the tier row). The DOM is only touched on screen changes, never per frame.

// ---------- profile (one store key, written once per run end / menu action; mirrored to iOS Preferences by store) ----------
// {v:1, runs, wins, earned, recTip, cls:{<id>:{xp, runs, wins, best, bestWin, ev:[Н,В,К], lastT, lossEarly}}}
const RANKS = [0, 300, 900, 1800, 3000, 4600, 6600, 9200, 12500, 16500];   // cumulative выслуга (= score / 10)
const RANK_NAMES = ['Рядовой', 'Ефрейтор', 'Мл. сержант', 'Сержант', 'Ст. сержант', 'Старшина', 'Прапорщик', 'Лейтенант', 'Капитан', 'Майор'];
const TIER_ABBR = ['Н', 'В', 'К'];
const TIER_LOC = ['Новобранце', 'Ветеране', 'Кошмаре'];   // «на «Ветеране»»
const CLS_INS = { assault: 'штурмовиком', pyro: 'огнемётчиком', cryo: 'криотехником', gunner: 'пулемётчиком' };
const PROF_MAX_BYTES = 8192;   // anything bigger is not ours: boot with defaults
function rankOf(xp) { let r = 0; while (r + 1 < RANKS.length && xp >= RANKS[r + 1]) r++; return r; }
function newClsRec() { return { xp: 0, runs: 0, wins: 0, best: 0, bestWin: 0, ev: [0, 0, 0], lastT: 0, lossEarly: 0 }; }
function newProfile() { const p = { v: 1, runs: 0, wins: 0, earned: 0, recTip: 0, cls: {} }; for (const c of CLASS_ORDER) p.cls[c] = newClsRec(); return p; }
function numOr(v, d) { return typeof v === 'number' && isFinite(v) && v >= 0 ? Math.min(Math.round(v), 1e9) : d; }
// defensive copy: unknown fields are dropped, every missing / broken field falls back to its default
function sanitizeProfile(p) {
  if (!p || typeof p !== 'object' || p.v !== 1) return null;
  const d = newProfile();
  for (const k of ['runs', 'wins', 'earned', 'recTip']) d[k] = numOr(p[k], 0);
  for (const c of CLASS_ORDER) {
    const s = p.cls && typeof p.cls === 'object' ? p.cls[c] : null;
    if (!s || typeof s !== 'object') continue;
    const r = d.cls[c];
    for (const k of ['xp', 'runs', 'wins', 'best', 'bestWin', 'lastT', 'lossEarly']) r[k] = numOr(s[k], 0);
    if (Array.isArray(s.ev)) for (let i = 0; i < 3; i++) r.ev[i] = s.ev[i] ? 1 : 0;
  }
  return d;
}
function loadProfile() {
  let raw = null;
  try { raw = localStorage.getItem('ledulei.profile'); } catch (e) { /* storage unavailable */ }
  let p = null;
  if (raw && raw.length <= PROF_MAX_BYTES) { try { p = sanitizeProfile(JSON.parse(raw)); } catch (e) { p = null; } }
  if (p) return p;
  // v1.0 save: only best = {kills, win}. One finished mission; a recorded evacuation counts as a win (→ Ветеран).
  const d = newProfile(), b = store.get('best', null);
  if (b && typeof b === 'object' && (numOr(b.kills, 0) > 0 || numOr(b.win, 0) > 0)) { d.runs = 1; d.wins = numOr(b.win, 0) > 0 ? 1 : 0; }
  return d;
}
let PROF = newProfile();
function saveProfile() { store.set('profile', PROF); }
// explicit tier choice from the title selector (store 'diff'); null until the player taps it once
let diffPick = null;
function loadDiffPick() { const d = store.get('diff', null); return d === 0 || d === 1 || d === 2 ? d : null; }
function effectiveTier() { return diffPick != null ? diffPick : PROF.wins > 0 ? 1 : 0; }

function metaBoot(data) {
  PROF = sanitizeProfile(data && data.profile) || loadProfile();
  diffPick = loadDiffPick();
  setTier(effectiveTier());
  metaUiInit();
}
function tierPrepare(opts) { setTier(opts.tier != null ? opts.tier : effectiveTier()); }

// ---------- run score: only what the player controls (never squad kills or idle time) ----------
function runScore(won) {
  const parts = [['Ваши убийства', GS.playerKills], ['Маяки ' + DIR.done + '/3', DIR.done * 500]];
  if (DIR.q.spawned && DIR.q.done) parts.push(['Матка убита', 1000]);
  if (won) {
    parts.push(['Эвакуация', 1500]);
    parts.push(['Скорость · ' + fmtTime(GS.time), Math.max(0, Math.round((480 - GS.time) * 5))]);
    if (!GS.downs) parts.push(['Без падений', 500]);
  }
  let raw = 0; for (const q of parts) raw += q[1];
  return { parts, raw, total: Math.round(raw * TH.mul) };
}
// how far the mission got, for the report strip: МАЯК×3 · ЛИФТ · МАТКА · ЭВАКУАЦИЯ
function runStrip(won) {
  const lift = won || DIR.stage === 'hold' || DIR.stage === 'extract';
  return [DIR.done > 0, DIR.done > 1, DIR.done > 2, lift, won || (DIR.q.spawned && DIR.q.done), won];
}
function commitRun(won, surrendered) {
  if (GS.attract) return null;
  const sc = runScore(won), c = PROF.cls[GS.cls] || (PROF.cls[GS.cls] = newClsRec());
  const tier = DIFF.indexOf(TH), xp = Math.round(sc.total / 10);
  const prev = { best: c.best, runs: c.runs, lastT: c.lastT, wins: c.wins, bestWin: c.bestWin };
  const rank0 = rankOf(c.xp);
  c.xp += xp; c.runs++;
  const medal = won && tier >= 0 && !c.ev[tier];
  if (won) { c.wins++; if (tier >= 0) c.ev[tier] = 1; if (!c.bestWin || GS.time < c.bestWin) c.bestWin = Math.round(GS.time); }
  c.best = Math.max(c.best, sc.total);
  c.lastT = Math.round(GS.time);
  // two losses in a row before beacon 2 on Ветеран → a one-time «Попробуйте «Новобранец»» chip
  if (!won && TH.id === 'vet' && DIR.done < 2) c.lossEarly = Math.min(9, c.lossEarly + 1); else c.lossEarly = 0;
  PROF.runs++; if (won) PROF.wins++;
  PROF.earned += sc.total;
  const recTip = !won && TH.id === 'vet' && c.lossEarly >= 2 && !PROF.recTip;
  if (recTip) PROF.recTip = 1;
  saveProfile();
  const rank1 = rankOf(c.xp);
  if (rank1 > rank0) setTimeout(() => haptic('success'), 650);
  return {
    won, surrendered: !!surrendered, sc, xp, tier, prev, rank0, rank1, medal, recTip,
    record: prev.runs > 0 && sc.total > prev.best, first: prev.runs === 0,
    // first evacuation without an explicit choice: say why the next mission is harder
    promo: won && PROF.wins === 1 && diffPick == null && tier === 0,
    // pressure was past its grace when the squad fell (hive pressure, package A)
    press: DIR.press >= TH.grace && DIR.idleMul > 1,
  };
}

// ---------- texts ----------
function plural(n, a, b, c) { const m = n % 100, k = n % 10; return m > 10 && m < 20 ? c : k === 1 ? a : k > 1 && k < 5 ? b : c; }
function fmtN(v) { return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ' '); }
function fmtMul(m) { return '×' + m.toFixed(1).replace('.', ','); }
const LOSS_TIPS = [
  'Бегуны берут числом — держитесь у союзников и стреляйте на ходу',
  'Плевун: уходите из светящихся кругов кислоты',
  'Громила: красная полоса — его таран, уходите рывком вбок',
  'Взрывун: убивайте издалека, не давайте раздуться рядом',
  'Матка: уходите с полосы тарана и из кислоты, сначала бейте выводок',   // SRC_QUEEN
];
const PRESS_TIP = 'Пока маяк не запущен, улей стягивает рой — не задерживайтесь';
function lossTip(res) {
  if (res.won || res.surrendered) return '';
  if (res.press) return PRESS_TIP;
  return GS.downBy >= 0 && GS.downBy < LOSS_TIPS.length ? LOSS_TIPS[GS.downBy] : '';
}
// the one goal under the report: the nearest thing the player has not reached yet
function nextGoal(res) {
  const c = PROF.cls[GS.cls], r = rankOf(c.xp), ins = CLS_INS[GS.cls] || '';
  if (!c.wins) return 'Цель: эвакуироваться ' + ins + ' (+1 500 очков)';
  const left = r + 1 < RANKS.length ? RANKS[r + 1] - c.xp : 0;
  const n = left ? Math.max(1, Math.ceil(left / Math.max(150, res.xp))) : 0;
  const t = res.tier >= 0 ? res.tier : 1;
  // a medal on this tier first, then the next tier when the next rank is still far away
  let mt = -1;
  if (!c.ev[t]) mt = t; else if (t < 2 && !c.ev[t + 1] && (!left || n > 2)) mt = t + 1;
  if (mt >= 0) return 'Нашивка: эвакуируйтесь ' + ins + ' на «' + TIER_LOC[mt] + '»';
  if (left) return 'До звания «' + RANK_NAMES[r + 1] + '» — ' + fmtN(left) + ' выслуги';
  return 'Побейте свой рекорд: ' + fmtN(c.best);
}

// ---------- mission report (#eRep / #eRepB) ----------
function mk(tag, cls, txt) { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }
function buildReport(won, surrendered, res) {
  const repA = $('eRep'), repB = $('eRepB'), st = $('eStats');
  repA.textContent = ''; repB.textContent = ''; st.textContent = '';
  $('eTag').textContent = 'Отчёт миссии · ' + stationLabel();
  // primary button: a win invites a new station, a loss the same one again
  const again = $('eAgain'), nw = $('eNew');
  again.classList.toggle('btn-go', !won); again.classList.toggle('btn-ghost', won);
  nw.classList.toggle('btn-go', won); nw.classList.toggle('btn-ghost', !won);
  $('eBox').classList.toggle('new-first', won);
  const acc = GS.shots > 0 ? Math.round(100 * Math.min(1, GS.hits / GS.shots)) : 0;
  for (const [a, b] of [['Время', fmtTime(GS.time)], ['Комбо', '×' + GS.bestCombo], ['Точность', acc + '%'], ['Уровень', String(GS.level)]]) {
    const d = mk('div'); d.appendChild(mk('span', '', a)); d.appendChild(mk('b', '', b)); st.appendChild(d);
  }
  if (!res) return;
  const C = CLASSES[GS.cls], c = PROF.cls[GS.cls];
  // A: how far the mission got, the score and where it came from
  const strip = mk('div', 'r-strip');
  const on = runStrip(won);
  ['Маяк', 'Маяк', 'Маяк', 'Лифт', 'Матка', 'Эвакуация'].forEach((t, k) => strip.appendChild(mk('span', on[k] ? 'on' : '', t)));
  repA.appendChild(strip);
  const head = mk('div', 'r-score');
  head.appendChild(mk('span', 'r-lab', 'Очки'));
  head.appendChild(mk('b', 'r-tot', fmtN(res.sc.total)));
  if (res.record) head.appendChild(mk('i', 'r-new', 'Новый рекорд'));
  else if (!res.first) head.appendChild(mk('i', 'r-cmp', 'рекорд ' + fmtN(res.prev.best)));
  repA.appendChild(head);
  const lines = mk('div', 'r-lines');
  for (const [a, b] of res.sc.parts) { const d = mk('div'); d.appendChild(mk('span', '', a)); d.appendChild(mk('b', '', '+' + fmtN(b))); lines.appendChild(d); }
  const dt = res.sc.total - res.sc.raw, tl = mk('div', 'r-tier');
  tl.appendChild(mk('span', '', TH.name + ' · ' + fmtMul(TH.mul) + ' очков'));
  tl.appendChild(mk('b', '', dt ? (dt > 0 ? '+' : '−') + fmtN(Math.abs(dt)) : ''));
  lines.appendChild(tl);
  repA.appendChild(lines);
  // B: class rank, a medal, why it went wrong, one next goal
  const r1 = res.rank1, lo = RANKS[r1], hi = RANKS[r1 + 1] || RANKS[r1];
  const rk = mk('div', 'r-rank'), top = mk('div', 'r-rk-top');
  top.appendChild(mk('span', '', C.name + ' · ' + RANK_NAMES[r1]));
  const xpEl = mk('b', '', '+' + fmtN(res.xp)); xpEl.appendChild(mk('span', '', ' выслуги'));
  top.appendChild(xpEl);
  rk.appendChild(top);
  const bar = mk('div', 'r-bar'), fill = mk('i');
  fill.style.transform = 'scaleX(' + (hi > lo ? clamp((c.xp - lo) / (hi - lo), 0, 1) : 1).toFixed(3) + ')';
  bar.appendChild(fill); rk.appendChild(bar);
  if (r1 > res.rank0) rk.appendChild(mk('div', 'r-up', 'Новое звание: ' + RANK_NAMES[r1]));
  repB.appendChild(rk);
  if (res.medal) repB.appendChild(mk('div', 'r-medal', 'Новая нашивка: ' + C.name + ' · ' + TH.name));
  const tip = lossTip(res);
  if (tip) repB.appendChild(mk('div', 'r-tip', tip));
  if (!won && !surrendered && res.prev.lastT && GS.time > res.prev.lastT + 5) repB.appendChild(mk('div', 'r-tip good', 'Продержались на ' + fmtTime(GS.time - res.prev.lastT) + ' дольше прошлой попытки'));
  if (res.promo) repB.appendChild(mk('div', 'r-tip good', 'Дальше — «Ветеран»: так задумано. Сложность меняется на главном экране'));
  if (res.recTip) {
    const b = mk('button', 'r-chip', 'Попробуйте «Новобранец»');
    onTap(b, () => { if (GS.screen !== 'lost') return; pickDiff(0); startMission(GS.cls); });
    repB.appendChild(b);
  }
  repB.appendChild(mk('div', 'r-goal', nextGoal(res)));
}

// ---------- title: profile line, class chips (rank + medals), tier selector ----------
let tierEls = null;
function metaUiInit() {
  // two-column end report: column A (header, strip, score, numbers), column B (rank, tips, goal, buttons). Built once:
  // the stage-0 nodes keep their ids, so the other packages' handlers (#eNew) still find them.
  const box = $('eBox');
  if (!box.querySelector('.e-a')) {
    const a = mk('div', 'e-col e-a'), b = mk('div', 'e-col e-b'), repB = mk('div', '');
    repB.id = 'eRepB';
    a.append($('eTag'), $('eTitle'), $('eSub'), $('eRep'), $('eStats'));
    b.append(repB, box.querySelector('.row'));
    box.append(a, b);
  }
  $('eStats').classList.add('mini');
  // tier selector
  const tt = $('tTier');
  tt.textContent = '';
  const head = mk('div', 'tt-head'); head.appendChild(mk('span', 'tt-lab', 'Сложность'));
  const seg = mk('div', 'tt-seg'), line = mk('div', 'tt-line');
  seg.setAttribute('role', 'radiogroup'); seg.setAttribute('aria-label', 'Сложность');
  const btns = DIFF.map((d, i) => {
    const b = mk('button', 'tt-b', d.name);
    b.setAttribute('role', 'radio');
    onTap(b, () => { audioInit(); pickDiff(i); sfx('click'); });
    seg.appendChild(b);
    return b;
  });
  tt.append(head, seg, line);
  tierEls = { btns, line };
  // the profile line follows the selected class (a tap, a gamepad flick or the keyboard all go through selectClass)
  if (typeof MutationObserver === 'function') new MutationObserver(profileLine).observe($('classes'), { subtree: true, attributes: true, attributeFilter: ['class'] });
}
function pickDiff(i) {
  diffPick = clamp(i | 0, 0, DIFF.length - 1);
  store.set('diff', diffPick);
  tierRow();
}
function tierRow() {
  if (!tierEls) return;
  const t = effectiveTier();
  tierEls.btns.forEach((b, i) => { b.classList.toggle('on', i === t); b.setAttribute('aria-checked', i === t ? 'true' : 'false'); });
  tierEls.line.textContent = DIFF[t].line;
}
let profLineKey = '';
function profileLine() {
  const c = PROF.cls[GS.cls], C = CLASSES[GS.cls];
  let s = '';
  if (c && C && c.runs) s = C.name + ' · ' + RANK_NAMES[rankOf(c.xp)] + ' · рекорд ' + fmtN(c.best);
  else if (PROF.runs) s = 'Вылетов: ' + PROF.runs + ' · эвакуаций: ' + PROF.wins;
  if (s !== profLineKey) { profLineKey = s; $('tBest').textContent = s; }
}
// called from buildTitle after the class cards are built
function titleMeta() {
  CLASS_ORDER.forEach((id, k) => {
    const card = $('classes').children[k], c = PROF.cls[id];
    if (!card || !c || !c.runs) return;
    const top = card.querySelector('.cc-top');
    const chip = mk('span', 'cc-rk', 'ЗВ. ' + (rankOf(c.xp) + 1));
    chip.title = RANK_NAMES[rankOf(c.xp)];
    const pips = mk('span', 'cc-ev');
    for (let i = 0; i < 3; i++) pips.appendChild(mk('i', c.ev[i] ? 'on' : '', TIER_ABBR[i]));
    pips.setAttribute('aria-label', 'Нашивки: ' + DIFF.filter((d, i) => c.ev[i]).map(d => d.name).join(', '));
    top.classList.add('meta');
    top.insertBefore(pips, top.lastElementChild);
    top.insertBefore(chip, pips);
  });
  $('sTitle').classList.toggle('t-ret', PROF.runs > 0);
  profLineKey = '';
  profileLine();
  tierRow();
}
// pause heading: «Пауза · Ветеран»
function pauseMeta() {
  const h = $('sPause').querySelector('h2');
  h.textContent = 'Пауза';
  h.appendChild(mk('span', 'p-tier', '· ' + TH.name));
}

window.__dbgExt = Object.assign(window.__dbgExt || {}, {
  profile(reset) { if (reset) { PROF = newProfile(); saveProfile(); } return JSON.parse(JSON.stringify(PROF)); },
  // tier state; optional patches force report inputs in tests (e.g. {downBy: SRC_QUEEN}, {press: 99, idleMul: 2})
  meta(gs, dir) { if (gs) Object.assign(GS, gs); if (dir) Object.assign(DIR, dir); return { tier: TH.id, effective: effectiveTier(), pick: diffPick, bytes: JSON.stringify(PROF).length, downs: GS.downs, downBy: GS.downBy }; },
});
