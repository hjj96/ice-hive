// ================================================================
//  ЛЕДЯНОЙ УЛЕЙ — single-player top-down squad shooter with AI squadmates (three.js r170)
//  Sections: CORE · TEXTURES · RENDER · LEVEL · SIM · MARINES ·
//            FX · DIRECTOR · AUDIO · INPUT · UI · MAIN/DEBUG
// ================================================================
import * as THREE from 'three';
import { mergeGeometries, mergeVertices } from 'three/addons/utils/BufferGeometryUtils.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

// ================================================================
//  CORE — constants, tuning tables, utilities
// ================================================================
const TAU = Math.PI * 2;
const DT = 1 / 60;                 // fixed simulation step
const MAXB = 3200;                 // bug array capacity (bench may push 3000)
const G = 128;                     // walk grid / spatial hash: 128 x 128 cells of 1 m
const GH = 64;                     // half extent: world x,z in [-64, 64)
const CAM_PITCH = 57 * Math.PI / 180;
const CAM_YAW = Math.PI / 4;       // camera sits at +x,+z looking toward -x,-z
// screen axes expressed in world XZ (screen-up = forward)
const FWD_X = -Math.SQRT1_2, FWD_Z = -Math.SQRT1_2;
const RIGHT_X = Math.SQRT1_2, RIGHT_Z = -Math.SQRT1_2;
const FOG_COLOR = 0x1a2737;     // cold blue-grey chasm haze

const QUALITY = {
  low:  { label: 'Низкая',  pr: 1.0, cap: 700,  particles: 1400, decals: 500,  corpses: 160, snow: 350,  bloom: false, shadows: false },
  med:  { label: 'Средняя', pr: 1.5, cap: 1400, particles: 2600, decals: 1000, corpses: 320, snow: 700,  bloom: false, shadows: false },
  high: { label: 'Высокая', pr: 2.0, cap: 2500, particles: 4000, decals: 1500, corpses: 520, snow: 1300, bloom: true,  shadows: true },
};

// Bug types: indices used in the SoA type array
const RUN = 0, SPIT = 1, BRUTE = 2, BOOM = 3;
const BT = [
  { id: 'runner',  name: 'Бегун',   hp: 18,  speed: 4.5, radius: 0.27, dmg: 5,  atkCd: 0.8, xp: 1,  scale: 0.8,  mass: 1 },
  { id: 'spitter', name: 'Плевун',  hp: 44,  speed: 3.0, radius: 0.36, dmg: 8, atkCd: 1.2, xp: 3,  scale: 1.02, mass: 1.6 },
  { id: 'brute',   name: 'Громила', hp: 360, speed: 2.6, radius: 0.85, dmg: 16, atkCd: 1.3, xp: 10, scale: 2.0,  mass: 7 },
  { id: 'boomer',  name: 'Взрывун', hp: 55,  speed: 3.6, radius: 0.44, dmg: 24, atkCd: 1.0, xp: 3,  scale: 1.15, mass: 2 },
];
const BUG_TYPE_IDS = BT.map(t => t.id);
const BUG_TIPS = ['', 'плюётся кислотой — уходите из кругов', 'таранит по красной полосе — уклоняйтесь рывком', 'взрывается рядом — убейте издалека'];
// bug states
const S_MOVE = 0, S_CLIMB = 1, S_WIND = 2, S_CHARGE = 3, S_SWELL = 4;

const CLASSES = {
  assault: {
    id: 'assault', name: 'Штурмовик', weapon: 'Импульсная винтовка', ability: 'Осколочная граната', abShort: 'Граната',
    laser: 0xff2a22, trim: 0xb8322a, css: 'var(--c-assault)',
    desc: 'Быстрые пробивающие импульсы. Граната разбрасывает рой.',
    rof: 9, dmg: 17, pspeed: 74, pierce: 1, spread: 0.035, range: 24, mag: 40, reload: 1.3, abCd: 8,
  },
  pyro: {
    id: 'pyro', name: 'Огнемётчик', weapon: 'Огнемёт «Факел»', ability: 'Кольцо напалма', abShort: 'Напалм',
    laser: 0xffa214, trim: 0xd29a1c, css: 'var(--c-pyro)',
    desc: 'Конус пламени поджигает рой, огонь перекидывается дальше.',
    dps: 80, range: 7.4, cone: 0.36, burn: 4, burnDps: 11, heatTime: 6.5, abCd: 12,
  },
  cryo: {
    id: 'cryo', name: 'Криотехник', weapon: 'Криолуч', ability: 'Ледяная волна', abShort: 'Волна',
    laser: 0x30b4ff, trim: 0x3a9ccc, css: 'var(--c-cryo)',
    desc: 'Луч замедляет и замораживает. Замёрзшие разлетаются осколками.',
    dps: 34, range: 11.5, chill: 2.4, energyTime: 7.5, abCd: 13,
  },
  gunner: {
    id: 'gunner', name: 'Пулемётчик', weapon: 'Роторный пулемёт', ability: 'Автотурель', abShort: 'Турель',
    laser: 0x3cff58, trim: 0x4fa83c, css: 'var(--c-gunner)',
    desc: 'Раскрутка стволов и шквал огня. Турель держит фланг.',
    rof: 22, dmg: 9.5, pspeed: 95, pierce: 0, spread: 0.075, range: 26, heatTime: 7, spinTime: 0.55, abCd: 18,
  },
};
const CLASS_ORDER = ['assault', 'pyro', 'cryo', 'gunner'];
const BOT_NAMES = ['Кекс', 'Тень', 'Бублик'];

// ---------- utilities ----------
function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
function lerp(a, b, t) { return a + (b - a) * t; }
function smooth01(t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); }
function rnd() { return Math.random(); }
function rr(a, b) { return a + (b - a) * Math.random(); }
function angDiff(a, b) { let d = b - a; while (d > Math.PI) d -= TAU; while (d < -Math.PI) d += TAU; return d; }
function damp(k, dt) { return 1 - Math.exp(-k * dt); }
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function fmtTime(s) { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
function $(id) { return document.getElementById(id); }
// iOS app shell (www/native.js over Capacitor). null in a browser and in the artifact: every NATIVE hook is then a no-op.
const NATIVE = window.__native || null;
const store = {
  get(k, d) { try { const v = localStorage.getItem('ledulei.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) {
    let s;
    try { s = JSON.stringify(v); localStorage.setItem('ledulei.' + k, s); } catch (e) { /* storage unavailable */ }
    // the app mirrors every setting into native Preferences (WebKit may purge a web view's localStorage)
    if (NATIVE && s !== undefined) NATIVE.save('ledulei.' + k, s);
  },
};
// haptic feedback in the iOS app (the bridge throttles per kind and honours the «Вибрация» setting); never in the
// title attract mode or the bench
function haptic(kind) { if (NATIVE && !GS.attract && !simOnly && !benchCombat) NATIVE.haptic(kind); }
const IS_TOUCH = (typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches) || ('ontouchstart' in window) || navigator.maxTouchPoints > 0;
const REDUCED_MOTION = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

// ---------- v1.1 difficulty tiers (shared table; package A owns the numbers, the field names are frozen) ----------
// Each field multiplies or replaces the v1.0 value. q* = the Матка on the lift hold.
const DIFF = [
  { id: 'rec', name: 'Новобранец', line: 'Рой мягче, отряд сильнее — для первого знакомства', mul: 0.8,
    hp: 1.0, dmg: 0.9, trickle: 1.09, horde: 1.07, step: 50, spec: 1, specCap: 1, bot: 1.0, botGrow: 1.04,
    regen: 4, regenT: 3.5, regenCap: 1, heal: 0.25, revive: 0.45, medkit: 0.35, edge: 12,
    pulse: 1.0, pulseT: 5, pulseFall: 0, stall: 90, grace: 40, runHp: 15,
    qAt: 35, qHp: 2500, qSpd: 1.5, qRamT: 9, qVolleyT: 6, qBroodT: 8, qBroodN: 6, qHorde: 80, qTrickle: 0.4 },
  { id: 'vet', name: 'Ветеран', line: 'Как задумано: падения случаются, Матка опасна', mul: 1.0,
    hp: 1.1, dmg: 1.2, trickle: 1.2, horde: 1.12, step: 30, spec: 1.15, specCap: 1.2, bot: 0.85, botGrow: 1.025,
    regen: 4, regenT: 4, regenCap: 0.6, heal: 0.2, revive: 0.4, medkit: 0.35, edge: 11,
    pulse: 1.0, pulseT: 6, pulseFall: 0.5, stall: 60, grace: 25, runHp: 15,
    qAt: 35, qHp: 3500, qSpd: 1.5, qRamT: 9, qVolleyT: 6, qBroodT: 8, qBroodN: 6, qHorde: 80, qTrickle: 0.4 },
  { id: 'nm', name: 'Кошмар', line: 'Рой беспощаден, союзники слабее — Матку переживают единицы', mul: 1.5,
    hp: 1.15, dmg: 1.25, trickle: 1.25, horde: 1.17, step: 40, spec: 1.25, specCap: 1.3, bot: 0.8, botGrow: 1.02,
    regen: 3, regenT: 5, regenCap: 0.5, heal: 0.15, revive: 0.35, medkit: 0.25, edge: 10,
    pulse: 0.8, pulseT: 7, pulseFall: 0.6, stall: 40, grace: 15, runHp: 15,
    qAt: 30, qHp: 4500, qSpd: 1.6, qRamT: 8, qVolleyT: 5, qBroodT: 7, qBroodN: 8, qHorde: 150, qTrickle: 0.6 },
];
let TH = DIFF[1];   // the active tier; tierPrepare (11c-meta.js) picks it per mission
function setTier(i) { TH = DIFF[clamp(i | 0, 0, DIFF.length - 1)]; return TH; }
const SRC_QUEEN = 4;   // damage source id of the Матка (hurtMarine src), for the mission report
