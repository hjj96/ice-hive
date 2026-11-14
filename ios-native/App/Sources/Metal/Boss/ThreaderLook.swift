import Foundation
import Metal
import IceHiveCore

// ================================================================
//  THREADER LOOK — the Threader as the squad sees and hears it (Stage 2
//  B5; design §1.5 «Attacks and telegraphs», §1.1.4 the drop language,
//  §1.1.7 sound for height; B4's state, B2's clips). WorldBoss lays the
//  body; this file decides, every frame, from `Game.threader`:
//    clips     the head by its mode — roam / duct `sweep`, climb `idle`,
//              strike `strike` (P3 `strike_low`) synced to the wind-up so
//              its slam frame is B4's landing, down `down`, recover
//              `recover`, coil `coil`, rime `charge`, squeeze / pull
//              `pull`, deck / charge `charge`; a scream (a popped node, a
//              phase, its pain) `scream` over 1.47 s; death `death`.
//              Segments `grip` (planted claws: phase = distance walked /
//              2.2 + 0.13 × j, a ripple from the head back) or `hold`
//              still — `hold` too on a steep stretch away from any pipe
//              (B2 open issue 2: the strike's neck, a climb's first
//              segments); `coil` on the coil's ring (legs to the deck
//              2 m down); `crawl` on the deck; `stagger` / `stagger_low`;
//              `death`. Nodes `plated` up on the trunks in P1 / P2,
//              `open` exposed, `pop` once then `dark`; `stagger(_dk)`,
//              `death(_dk)`. A change cross-fades from the last pose.
//    the head's look  yaw / pitch toward the lure's spot (the strike's
//              point while locked), ≤ 0.8 rad (the swarm's head group)
//    the lure  B4's lit spot (`lureSpot`, `lureRadius`) under a beam from
//              B2's `lantern` socket (it swings with the clips and the
//              look): the fifth volume cone (VolumeCones.lure) — pale
//              pearl sweeping, hot white locked, brightening as it
//              gathers on a marine (B4's `exposure`) —, the lit disc on
//              the deck (FX.metal FM_SPOT) and a grid light in it
//    telegraph extras (the shapes themselves: MetalEffects.telegraphs)
//              the strike's frost-dust column from the head to its ring
//              and its growing shadow (Occupancy.extra), the landing's
//              frost; the coil's ring of segments glowing; the rime
//              spray along the lane; each squeeze burst's gauge (a red
//              needle swinging over 1.5 s) and hiss puffs, then its
//              curtain's steam; the pull-down's dust along the whole
//              trunk while it shakes, its 0.4 s fall onto the deck, the
//              crash's dust; frost falling from every segment's `dust`
//              socket before a shed; a popped node's flash; the death
//    sounds    (BossSound, GameScene plays them) the scrape of its claws
//              on the pipes while it moves, its moan, its scream, the
//              slam — through the attic voice when it is up there (a
//              phone cannot place «above»: height is a timbre)
//  Its own state is reset with every sortie (WorldBoss).
// ================================================================

/// The boss's own sounds (AudioEngine's `boss` section of the sound manifest; tools/audio/make_boss_sounds.py).
enum BossSound: String, CaseIterable {
    case scrape, moan, scream, slam, creak, hiss
}

/// One part's clip state: the clip it plays, since when, the pose it fades from.
struct BossPartAnim {
    var clip = -1
    var t0: Float = 0
    var from = ClipSample.zero
    var fromW: Float = 0
    var last = ClipSample.zero

    /// Play `c` from now on (a change fades from the last pose over 0.15 s).
    mutating func set(_ c: Int, _ now: Float) {
        guard c != clip else { return }
        if clip >= 0 { from = last; fromW = 1 }
        clip = c
        t0 = now
    }

    /// The pose this frame: `a` the clip's sample (and an optional second clip `b` at weight `wB` when not fading).
    mutating func pose(_ a: ClipSample, _ b: ClipSample = .zero, _ wB: Float = 0, dt: Float) -> (ClipSample, ClipSample, Float) {
        last = wB > 0.5 ? b : a
        if fromW > 0 {
            let w = fromW
            fromW = max(0, fromW - dt / SwarmAnimator.fade)
            return (a, from, w)
        }
        return (a, b, wB)
    }
}

final class ThreaderLook {
    // ---------------------------------------------------------------- the look (B2's type table)
    /// Rim pearl-mauve (no class colour: the swarm's rule), the eye channel — the weak-point membrane alone, lit only in the
    /// punish window —, the sacs, the glands (lantern bulb, node sacs, ocelli: their own albedo, white-hot cores).
    static let rim = F4(0.70, 0.64, 0.88, 0.24)
    static let eye = F4(1.0, 0.75, 0.86, 1.4)
    static let sac = F4(0.82, 0.76, 1.0, 0.5)
    static let gland = F4(1.0, 0.94, 1.0, 2.0)
    /// Its ichor (the hits' spray and stains): a pale mauve-pearl — not the bugs' types', not a class colour.
    static let ichor = F3(0.42, 0.36, 0.5)
    /// The lure: the beam's colour sweeping (pale pearl) and locked (hot white), its in-scatter gain and saturation cap, the
    /// lit disc's radiance on the deck, the grid light's intensity in it. Units: a flashlight's in-scatter is its gain
    /// (VolumeCones.gain 0.024) × its spot's intensity / π — 25 / π for a squad beam (≈ 0.19), the player's 37 / π × 1.15
    /// (≈ 0.33) — under the cap 0.17; the lure's cone has no spot of its own (Atmosphere.metal coneParams: power 1), so its
    /// gain is that product: 0.4 sweeping — a step over the player's beam, and its air sits 5–8 m from the lantern where
    /// the cone's falloff has dropped to 0.25–0.45 —, × 1.5 locked; its cap 0.24, × 1.4 locked (hot white, under the tone
    /// curve's shoulder: a thin shaft, never a white-out).
    static let lureColor = F3(0.74, 0.8, 1.0), lockColor = F3(1.0, 0.98, 0.94)
    static let lureGain: Float = 0.4, lureCap: Float = 0.24
    static let lockGainK: Float = 1.5, lockCapK: Float = 1.4
    static let spotColor = F3(0.55, 0.62, 0.85), spotLocked = F3(1.15, 1.12, 1.05)
    static let spotLight: Float = 26
    /// The lure's half-angle bounds (rad): the cone's foot on the deck is B4's lit spot.
    static let lureAngle: (Float, Float) = (0.08, 0.6)

    // ---------------------------------------------------------------- clips
    private struct Clips {
        let idle, sweep, strike, down, recover, scream, coil, pull, charge, strikeLow, death, hit: Int
        let hold, grip, crawl, sCoil, stagger, staggerLow, sDeath: Int
        let plated, open, pop, dark, nStagger, nStaggerDk, nDeath, nDeathDk: Int
    }
    private let lib: BossLibrary
    private let C: Clips
    private let head: [IHVClip], seg: [IHVClip], node: [IHVClip]

    // ---------------------------------------------------------------- state
    private var anims = [BossPartAnim](repeating: BossPartAnim(), count: WorldBoss.maxParts)
    private var popT = [Float](repeating: -1, count: WorldBoss.maxParts)
    private var wasPopped = [Bool](repeating: false, count: WorldBoss.maxParts)
    /// Nodes whose frost plates the torch stripped (B4's `.plateStrip`: for the rest of the fight they show `open`).
    private var stripped = [Bool](repeating: false, count: WorldBoss.maxParts)
    private var screamT0: Float = -9
    private var deathT0: Float = -1
    private var modePrev: ThreaderMode = .none
    private var modeT0: Float = 0
    private var odo: Float = 0, speed: Float = 0
    private var lastHead = F3.zero
    private var haveHead = false
    private var lookY: Float = 0, lookP: Float = 0
    private var lockGlow: Float = 0
    /// The lure lit this frame (WorldBoss dims the lantern's glint without it).
    private(set) var lureLit = false
    /// The death's sink applied so far (WorldBoss).
    var sunk: Float = 0
    // ---- effects
    private var rng = SeededRNG(seed: 7351)
    private var acc = [Float](repeating: 0, count: 8)
    private var spray: Set<Int> = []
    private var scrapeT: Float = 0, moanT: Float = 6
    private var crashSeen = -1
    private var landed = false
    private var lastVent = [Int](repeating: 0, count: 4)
    private var pending: [(BossSound, Vec2, Bool, Float)] = []
    private var lastLock = -1
    private var exposureMax: Float = 0
    /// Diagnostics tail of WorldBoss's `hb boss` line.
    private(set) var heartbeatTail = ""

    init(library: BossLibrary) {
        lib = library
        head = library.head.clips; seg = library.segment.clips; node = library.node.clips
        func h(_ n: String) -> Int { library.head.clip(n) ?? 0 }
        func s(_ n: String) -> Int { library.segment.clip(n) ?? 0 }
        func d(_ n: String) -> Int { library.node.clip(n) ?? 0 }
        C = Clips(idle: h("idle"), sweep: h("sweep"), strike: h("strike"), down: h("down"), recover: h("recover"), scream: h("scream"),
                  coil: h("coil"), pull: h("pull"), charge: h("charge"), strikeLow: h("strike_low"), death: h("death"), hit: h("hit"),
                  hold: s("hold"), grip: s("grip"), crawl: s("crawl"), sCoil: s("coil"), stagger: s("stagger"), staggerLow: s("stagger_low"),
                  sDeath: s("death"),
                  plated: d("plated"), open: d("open"), pop: d("pop"), dark: d("dark"), nStagger: d("stagger"), nStaggerDk: d("stagger_dk"),
                  nDeath: d("death"), nDeathDk: d("death_dk"))
    }

    func reset() {
        anims = [BossPartAnim](repeating: BossPartAnim(), count: WorldBoss.maxParts)
        popT = [Float](repeating: -1, count: WorldBoss.maxParts)
        wasPopped = [Bool](repeating: false, count: WorldBoss.maxParts)
        stripped = [Bool](repeating: false, count: WorldBoss.maxParts)
        screamT0 = -9; deathT0 = -1; modePrev = .none; modeT0 = 0; odo = 0; speed = 0; haveHead = false
        lookY = 0; lookP = 0; lockGlow = 0; lureLit = false; sunk = 0
        spray.removeAll(); crashSeen = -1; landed = false; lastLock = -1
        lastVent = [0, 0, 0, 0]
    }

    func died(at t: Float) { deathT0 = t }

    /// The sounds asked for since the last call: (sound, deck position, from up there — the attic voice, gain).
    func takeSounds() -> [(BossSound, Vec2, Bool, Float)] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    private func sound(_ s: BossSound, _ p: F3, gain: Float = 1, deckY: Float = 0) {
        if pending.count < 16 { pending.append((s, Vec2(p.x, p.z), p.y - deckY > 3, gain)) }
    }

    @inline(__always) private func rnd() -> Float { rng.next() }

    // ================================================================ events
    func handle(_ e: GameEvent, game: Game, clock: Float, fx: MetalEffects, boss: WorldBoss) {
        switch e {
        case .bossWarning(let kind, let pos) where kind == .threader:
            // something big in the pipes: dust shaken off the trunks, its moan from up there
            let level = game.level
            for _ in 0..<Int(14 * max(0.5, fx.fxK)) {
                let a = Float.random(in: -17...17), off: Float = rnd() < 0.5 ? -3.5 : 3.5
                let p = rnd() < 0.5 ? F3(a, 4.2, off) : F3(off, 4.2, a)
                fx.gpu.burst(.ice, 2, at: p, jitter: F3(0.4, 0.1, 0.4), vel: F3(0, -0.6, 0), velJitter: F3(0.2, 0.3, 0.2), life: (1.4, 2.2),
                             size: (0.04, 0.02), color: F4(0.55, 0.66, 0.82, 0.8), gravity: 1.6, drag: 1.0)
            }
            sound(.moan, F3(pos.x, 6, pos.y), gain: 1, deckY: level.groundY(pos.x, pos.y))
        case .bossSpawned(let kind, let pos) where kind == .threader:
            // it comes out of the pipes: a burst of frost and rust from the trunk where it appears
            let p = F3(pos.x, Manifold.trunkY - 0.3, pos.y)
            fx.gpu.burst(.ice, Int(24 * max(0.5, fx.fxK)), at: p, jitter: F3(0.6, 0.2, 0.6), sphere: 3.5, life: (0.8, 1.4), size: (0.07, 0.03),
                         color: F4(0.8, 0.95, 1.25, 1), gravity: 6, drag: 0.8)
            fx.gpu.burst(.debris, 6, at: p, sphere: 3, life: (1.0, 1.6), size: (0.1, 0.07), color: F4(0.12, 0.1, 0.09, 1), gravity: 12,
                         drag: 0.3, spin: 7)
            fx.flash(p, F3(0.75, 0.8, 1.0), peak: 60, dur: 0.5, range: 9, priority: 20)
            sound(.scream, p, gain: 0.9, deckY: game.level.groundY(pos.x, pos.y))
        case .bossPhase(let kind, _, _, _) where kind == .threader:
            screamT0 = clock
        case .bossPartPopped(let kind, let part, let pos) where kind == .threader:
            // the sac bursts: a pearl flash, a spray of light and torn plates, the node goes dark (its clip), a scream
            if part < boss.partCount {
                popT[part] = clock
                let p = boss.worldPoint(part, socket: "sac") ?? F3(pos.x, game.bossPart(part).position.y + 0.9, pos.y)
                fx.gpu.burst(.glow, Int(22 * max(0.5, fx.fxK)), at: p, sphere: 4.5, life: (0.25, 0.6), size: (0.18, 0.05),
                             color: F4(1.6, 1.5, 2.0, 1), gravity: 2, drag: 1.2)
                fx.gpu.burst(.ichor, 8, at: p, sphere: 4, upper: true, life: (0.5, 0.9), size: (0.1, 0.07), color: F4(0.42, 0.36, 0.5, 1),
                             gravity: 12)
                fx.gpu.burst(.debris, 5, at: p, sphere: 4, upper: true, life: (0.8, 1.3), size: (0.12, 0.08), color: F4(0.5, 0.56, 0.66, 1),
                             gravity: 13, drag: 0.3, spin: 9)
                fx.flash(p, F3(0.95, 0.88, 1.0), peak: 140, dur: 0.35, range: 8, priority: 26)
            }
            screamT0 = clock
        case .bossKilled(let kind, let pos) where kind == .threader:
            // the body bursts along its length; the head's death clip; the last scream
            for k in stride(from: 0, to: boss.partCount, by: 3) {
                let p = boss.xf[k].pos + F3(0, 0.5, 0)
                fx.gpu.burst(.ichor, 4, at: p, sphere: 3.5, upper: true, life: (0.5, 0.9), size: (0.12, 0.08), color: F4(0.4, 0.33, 0.48, 1),
                             gravity: 12)
                fx.gpu.burst(.ice, 4, at: p, sphere: 3, upper: true, life: (0.4, 0.8), size: (0.07, 0.03), color: F4(0.8, 0.9, 1.2, 1),
                             gravity: 8, drag: 0.6)
            }
            let hp = boss.partCount > 0 ? boss.xf[0].pos : F3(pos.x, 1, pos.y)
            fx.flash(hp + F3(0, 1, 0), F3(0.9, 0.8, 1.0), peak: 220, dur: 0.8, range: 14, priority: 40)
            sound(.scream, hp, gain: 1.2, deckY: game.level.groundY(hp.x, hp.z))
            sound(.slam, hp, gain: 0.8, deckY: game.level.groundY(hp.x, hp.z))
        case .bossCue(let kind, let cue, let pos, let value) where kind == .threader:
            cueFX(cue, pos, value, game: game, clock: clock, fx: fx, boss: boss)
        default: break
        }
    }

    private func cueFX(_ cue: BossCue, _ pos: Vec2, _ value: Int, game: Game, clock: Float, fx: MetalEffects, boss: WorldBoss) {
        let gy = game.level.groundY(pos.x, pos.y)
        switch cue {
        case .strikeDrop:
            landed = false
        case .strikeLand, .recoil:
            // the slam: a frost puff and ice chips round the ring, rime on the deck, a thump
            if cue == .strikeLand {
                let p = F3(pos.x, gy + 0.08, pos.y)
                fx.gpu.burst(.steam, 3, at: p, jitter: F3(0.4, 0.05, 0.4), radial: 2.4, life: (0.6, 1.0), size: (0.7, 2.2),
                             color: F4(0.7, 0.78, 0.88, 0.32), drag: 1.2)
                fx.gpu.burst(.ice, Int(28 * max(0.5, fx.fxK)), at: p, ring: THREADER_STRIKE_R * 0.5, sphere: 5, upper: true, life: (0.4, 0.8),
                             size: (0.07, 0.035), color: F4(0.85, 1.0, 1.3, 1), gravity: 10, drag: 0.5)
                fx.gpu.burst(.glow, 16, at: p, ring: THREADER_STRIKE_R, vel: F3(0, 0.2, 0), radial: 1.2, life: (0.3, 0.5), size: (0.24, 0.05),
                             color: F4(1.1, 1.2, 1.5, 1), drag: 1.5)
                fx.decals.add(pos.x, pos.y, size: 3.6, cell: .frost, kind: .frost, tint: F3(0.75, 0.86, 0.98), opacity: 0.6)
                sound(.slam, p, gain: 1, deckY: gy)
                landed = true
            } else {
                // its head in the Pyro's fire: it recoils, sparks and steam
                let p = F3(pos.x, gy + 0.6, pos.y)
                fx.gpu.burst(.steam, 4, at: p, jitter: F3(0.3, 0.2, 0.3), vel: F3(0, 1.6, 0), life: (0.5, 0.9), size: (0.4, 1.4),
                             color: F4(0.7, 0.7, 0.72, 0.35), gravity: -0.5, drag: 1.4)
                sound(.scream, p, gain: 0.8, deckY: gy)
            }
        case .lureLock:
            lastLock = value
        case .climb:
            sound(.scrape, F3(pos.x, 6, pos.y), gain: 0.9, deckY: gy)
        case .duct:
            sound(.moan, F3(pos.x, 8, pos.y), gain: 0.8, deckY: gy)
        case .descend:
            sound(.scrape, F3(pos.x, 6, pos.y), gain: 0.8, deckY: gy)
        case .coil:
            sound(.creak, F3(pos.x, 2, pos.y), gain: 1, deckY: gy)
        case .coilCrush:
            let p = F3(pos.x, gy + 0.3, pos.y)
            fx.gpu.burst(.ice, Int(30 * max(0.5, fx.fxK)), at: p, ring: 1.2, sphere: 5, upper: true, life: (0.4, 0.9), size: (0.08, 0.035),
                         color: F4(0.85, 1.0, 1.3, 1), gravity: 10, drag: 0.5)
            fx.gpu.burst(.steam, 3, at: p, jitter: F3(0.5, 0.1, 0.5), radial: 1.8, life: (0.6, 1.0), size: (0.6, 1.8),
                         color: F4(0.7, 0.78, 0.88, 0.3), drag: 1.2)
            sound(.slam, p, gain: 0.9, deckY: gy)
        case .coilLetGo, .pain:
            screamT0 = clock
            // the ice on it breaks
            for k in stride(from: 1, to: boss.partCount, by: 2) {
                let p = boss.xf[k].pos + F3(0, 0.4, 0)
                fx.gpu.burst(.ice, 3, at: p, sphere: 3, upper: true, life: (0.4, 0.8), size: (0.06, 0.03), color: F4(0.8, 0.95, 1.25, 1),
                             gravity: 9, drag: 0.6)
            }
            sound(.scream, boss.partCount > 0 ? boss.xf[0].pos : F3(pos.x, 4, pos.y), gain: 1, deckY: gy)
        case .coilGap:
            if value >= 0 && value < boss.partCount {
                let p = boss.xf[value].pos + F3(0, 0.4, 0)
                fx.gpu.burst(.ice, 12, at: p, sphere: 3.5, upper: true, life: (0.5, 0.9), size: (0.08, 0.035), color: F4(0.8, 1.0, 1.3, 1),
                             gravity: 9, drag: 0.5)
            }
        case .rimeSpit:
            spray.removeAll()
            sound(.hiss, F3(pos.x, 5, pos.y), gain: 1, deckY: gy)
        case .squeeze:
            sound(.creak, F3(pos.x, 5, pos.y), gain: 1, deckY: gy)
        case .squeezeBurst:
            sound(.hiss, F3(pos.x, 5, pos.y), gain: 0.9, deckY: gy)
        case .squeezeVent:
            break
        case .pullRip:
            sound(.creak, F3(pos.x, 5, pos.y), gain: 1.2, deckY: gy)
        case .pullCrash:
            crashSeen = value
            if let A = game.level.layout.manifold, value >= 0 && value < A.trunks.count {
                let tr = A.trunks[value]
                var s: Float = 0.5
                while s < tr.length {
                    let q = tr.point(s)
                    let y = game.level.groundY(q.x, q.y)
                    fx.gpu.burst(.steam, 1, at: F3(q.x, y + 0.4, q.y), jitter: F3(0.5, 0.2, 0.5), radial: 1.6, life: (0.9, 1.6),
                                 size: (0.8, 2.4), color: F4(0.5, 0.55, 0.6, 0.34), gravity: -0.15, drag: 1.0)
                    fx.gpu.burst(.ice, 3, at: F3(q.x, y + 0.5, q.y), sphere: 4.5, upper: true, life: (0.4, 0.9), size: (0.07, 0.03),
                                 color: F4(0.8, 0.9, 1.2, 1), gravity: 10, drag: 0.5)
                    if rnd() < 0.3 {
                        fx.gpu.burst(.spark, 3, at: F3(q.x, y + 0.5, q.y), sphere: 5, upper: true, life: (0.2, 0.45), size: (0.04, 0.02),
                                     color: F4(1.4, 1.0, 0.7, 1), gravity: 12, drag: 0.3)
                    }
                    s += 1.4
                }
                let mid = tr.point(tr.length / 2)
                fx.flash(F3(mid.x, 1.5, mid.y), F3(0.8, 0.85, 1.0), peak: 160, dur: 0.6, range: 16, priority: 34)
                sound(.slam, F3(mid.x, 0.5, mid.y), gain: 1.3, deckY: 0)
            }
        case .deckDrop:
            sound(.slam, F3(pos.x, 0.6, pos.y), gain: 0.7, deckY: gy)
        case .charge:
            sound(.scream, F3(pos.x, 0.8, pos.y), gain: 0.7, deckY: gy)
        case .shed:
            break
        case .ticks:
            sound(.scrape, F3(pos.x, 5, pos.y), gain: 0.6, deckY: gy)
        case .plateStrip:
            // the torch strips a node's frost plates: shards of ice fall off it (the node shows `open` from now on)
            if value >= 0 && value < stripped.count { stripped[value] = true }
            if value >= 0 && value < boss.partCount {
                let p = boss.xf[value].pos + F3(0, 0.7, 0)
                fx.gpu.burst(.ice, 16, at: p, sphere: 3, upper: true, life: (0.6, 1.1), size: (0.09, 0.04), color: F4(0.8, 0.95, 1.25, 1),
                             gravity: 10, drag: 0.4)
                fx.gpu.burst(.steam, 2, at: p, jitter: F3(0.2, 0.1, 0.2), vel: F3(0, 1, 0), life: (0.5, 0.8), size: (0.3, 1.0),
                             color: F4(0.75, 0.8, 0.85, 0.3), gravity: -0.4, drag: 1.4)
            }
        case .scream:
            screamT0 = clock
        case .packs:
            break
        }
    }

    // ================================================================ per frame
    func frame(game: Game, boss: WorldBoss, clock: Float, dt: Float, camera: MetalCamera, fx: MetalEffects, cones: VolumeCones) {
        let v = game.threader
        let n = boss.partCount
        let level = game.level
        if v.mode != modePrev { modePrev = v.mode; modeT0 = clock }
        // the odometer of the head (its path, 3-D): the segments' gait
        let hp = boss.xf[0].pos
        if haveHead {
            let d = hp - lastHead
            let l = (d * d).sum().squareRoot()
            if l < 3 { odo += l; speed += (l / max(dt, 1e-4) - speed) * min(1, dt * 8) }
        }
        lastHead = hp
        haveHead = true
        let screaming = clock - screamT0 < 1.47 && clock >= screamT0
        let phase = game.boss.phase
        let S = game.bugs
        // ---------------------------------------------------------- the head
        var P0 = BossPartPose()
        let hc: Int
        var ht: Float = clock - modeT0
        var loop = true
        if screaming {
            hc = C.scream; ht = clock - screamT0; loop = false
        } else {
            switch v.mode {
            case .none, .roam, .duct: hc = C.sweep; ht = clock
            case .climb: hc = C.idle; ht = clock
            case .strike:
                let low = phase >= 2
                hc = low ? C.strikeLow : C.strike
                let wind = low ? THREADER_STRIKE_WIND_LOW : THREADER_STRIKE_WIND
                ht = v.strikeT >= 0 ? wind - v.strikeT : wind
                loop = false
            case .down: hc = C.down
            case .recover:
                if clock - modeT0 < head[C.recover].duration { hc = C.recover; loop = false } else { hc = C.sweep; ht = clock }
            case .coil: hc = C.coil
            case .rime: hc = C.charge
            case .squeeze, .pull: hc = C.pull
            case .deck, .charge: hc = C.charge; ht = clock
            }
        }
        anims[0].set(hc, clock)
        let hClip = head[hc]
        let ha = loop ? clipLoop(hClip, ht / max(0.05, hClip.duration)) : clipShot(hClip, ht)
        (P0.a, P0.b, P0.wB) = anims[0].pose(ha, dt: dt)
        // the look: toward the lit spot (the strike's point while locked), only while it hunts with the light
        var ty: Float = 0, tp: Float = 0
        let aim: Vec2? = v.mode == .strike ? v.strike : (v.lure ? v.lureSpot : nil)
        if let a = aim {
            let t = boss.xf[0]
            let neck = WorldBoss.place(t, F3(0, 0.5, -0.5))
            let g = F3(a.x, level.groundY(a.x, a.y), a.y) - neck
            // into the head's frame: heading, then pitch
            let c = cosf(-t.heading), s = sinf(-t.heading)
            let lx = c * g.x + s * g.z, lz = -s * g.x + c * g.z
            let cp = cosf(-t.pitch), sp = sinf(-t.pitch)
            let ly = cp * g.y + sp * lz, lz2 = -sp * g.y + cp * lz
            ty = max(-0.8, min(0.8, atan2f(lx, max(0.2, lz2))))
            tp = max(-0.8, min(0.35, atan2f(ly, (lx * lx + lz2 * lz2).squareRoot()) * 0.5 + 0.25))
        }
        let k = min(1, dt * 5)
        lookY += (ty - lookY) * k
        lookP += (tp - lookP) * k
        P0.lookY = lookY; P0.lookP = lookP
        // the lantern flares while locked; the window's membrane is in the eye channel of the clip
        lockGlow += ((v.locked >= 0 || v.mode == .strike ? 1 : 0) - lockGlow) * min(1, dt * 6)
        P0.boost = 0.6 * lockGlow
        partState(&P0, game.bossPart(0), S)
        boss.setPose(0, P0)
        // ---------------------------------------------------------- the segments and the nodes
        let gripC = seg[C.grip], holdC = seg[C.hold], crawlC = seg[C.crawl]
        let moving = smoothf(0.3, 1.6, speed)
        for q in 1..<n {
            let pv = game.bossPart(q)
            let t = boss.xf[q]
            let gy = level.groundY(t.pos.x, t.pos.z)
            let h = t.pos.y - gy
            var P = BossPartPose()
            if boss.kinds[q] == 1 {
                let j = Float(max(1, pv.segment))
                let ph = odo / 2.2 + 0.13 * j
                let onDeck = h < 1.2
                let inCoil = v.mode == .coil && h > 1.3 && h < 2.8
                let steep = abs(t.pitch) > 0.42
                var c = C.hold
                var a = clipLoop(holdC, clock / holdC.duration + 0.07 * j)
                var b = ClipSample.zero
                var wB: Float = 0
                if screaming {
                    c = onDeck ? C.staggerLow : C.stagger
                    a = clipShot(seg[c], clock - screamT0)
                } else if inCoil {
                    c = C.sCoil
                    a = clipLoop(seg[c], clock / seg[c].duration + 0.11 * j)
                    P.boost = 0.55 + 0.35 * sinf(clock * 9 + j * 0.6)
                } else if onDeck {
                    c = C.crawl
                    a = clipLoop(crawlC, ph)
                    b = clipLoop(holdC, clock / holdC.duration)
                    wB = 1 - moving
                } else if !steep {
                    c = C.grip
                    a = clipLoop(gripC, ph)
                    b = clipLoop(holdC, clock / holdC.duration + 0.07 * j)
                    wB = 1 - moving
                }
                anims[q].set(c, clock)
                (P.a, P.b, P.wB) = anims[q].pose(a, b, wB, dt: dt)
                partState(&P, pv, S)
                boss.setPose(q, P)
                // the shed's warning: frost dust off every segment's back (its `dust` socket in this frame's pose)
                if v.shedWarn > 0 && dt > 0 && rnd() < dt * 9 * fx.fxK, let d = boss.worldPoint(q, socket: "dust") {
                    fx.gpu.burst(.ice, 2, at: d, jitter: F3(0.25, 0.05, 0.25), vel: F3(0, -0.8, 0), velJitter: F3(0.3, 0.3, 0.3),
                                 life: (1.0, 1.6), size: (0.06, 0.03), color: F4(0.85, 0.98, 1.25, 1), gravity: 2.4, drag: 0.8)
                }
            } else if boss.kinds[q] == 2 {
                // a node: plated up on the trunks in P1 / P2, open low or in P3, a pop once, then dark
                if pv.popped && !wasPopped[q] && popT[q] < 0 { popT[q] = clock }
                wasPopped[q] = pv.popped
                var c: Int
                var a: ClipSample
                if pv.popped {
                    if popT[q] >= 0 && clock - popT[q] < node[C.pop].duration {
                        c = C.pop; a = clipShot(node[c], clock - popT[q])
                    } else {
                        c = C.dark; a = clipLoop(node[c], clock / node[c].duration)
                    }
                    if screaming { c = C.nStaggerDk; a = clipShot(node[c], clock - screamT0) }
                } else if screaming {
                    c = C.nStagger; a = clipShot(node[c], clock - screamT0)
                } else {
                    c = pv.up && phase < 2 && !stripped[q] ? C.plated : C.open
                    a = clipLoop(node[c], clock / node[c].duration + 0.2 * Float(q))
                }
                anims[q].set(c, clock)
                (P.a, P.b, P.wB) = anims[q].pose(a, dt: dt)
                partState(&P, pv, S)
                boss.setPose(q, P)
            }
        }
        effects(game: game, boss: boss, v: v, clock: clock, dt: dt, fx: fx, cones: cones, camera: camera)
        sounds(game: game, boss: boss, v: v, dt: dt)
        heartbeatTail = String(format: " odo=%.0fm v=%.1f", odo, speed) + (screaming ? " scream" : "")
            + (v.locked >= 0 ? " locked=\(v.locked)" : "") + String(format: " exposure=%.2f", exposureMax)
    }

    /// The part's hit flash, frost (frozen: the crust; chilled: a part of it) from its swarm slot.
    private func partState(_ P: inout BossPartPose, _ pv: BossPartView, _ S: Swarm) {
        if pv.slot >= 0 && pv.slot < S.count {
            P.flash = max(0, S.flashes[pv.slot]) / 0.6
            P.frost = pv.frozen > 0 ? 1 : min(1, S.chills[pv.slot]) * 0.55
        } else {
            P.frost = pv.frozen > 0 ? 1 : 0
        }
    }

    /// The death: every part's death clip from the moment it died (its last pose held), the dead value band.
    func dying(boss: WorldBoss, clock: Float, since: Float) {
        let n = boss.partCount
        for q in 0..<n {
            var P = BossPartPose()
            let c: Int
            let a: ClipSample
            switch boss.kinds[q] {
            case 0: c = C.death; a = clipShot(head[c], since)
            case 1: c = C.sDeath; a = clipShot(seg[c], since)
            default:
                c = wasPopped[q] ? C.nDeathDk : C.nDeath
                a = clipShot(node[c], since)
            }
            anims[q].set(c, clock)
            (P.a, P.b, P.wB) = anims[q].pose(a, dt: 1.0 / 60.0)
            P.dead = smoothf(0, 2.4, since)
            boss.setPose(q, P)
        }
        lureLit = false
    }

    // ================================================================ effects
    private func effects(game: Game, boss: WorldBoss, v: ThreaderView, clock: Float, dt: Float, fx: MetalEffects, cones: VolumeCones,
                         camera: MetalCamera) {
        let level = game.level
        let k = max(0.4, fx.fxK)
        // ---------------------------------------------------------- the lure
        lureLit = v.lure
        exposureMax = max(max(v.exposure.x, v.exposure.y), max(v.exposure.z, v.exposure.w))
        if v.lure, let L = boss.worldPoint(0, socket: "lantern") {
            let gy = level.groundY(v.lureSpot.x, v.lureSpot.y)
            let spot = F3(v.lureSpot.x, gy, v.lureSpot.y)
            let d = spot - L
            let dist = max(0.5, (d * d).sum().squareRoot())
            let dir = d / dist
            let half = max(ThreaderLook.lureAngle.0, min(ThreaderLook.lureAngle.1, atanf(v.lureRadius / dist)))
            let locked = v.locked >= 0
            // it gathers on a marine: the beam and the disc brighten with the light's hold on them (B4's 0.8 s to lock)
            let gather = min(1, exposureMax / THREADER_LOCK)
            let col = locked ? ThreaderLook.lockColor * 1.25 : ThreaderLook.lureColor * (0.85 + 0.35 * gather)
            let T = ThreaderLook.self
            cones.lure = VolumeCones.Lure(apex: L, dir: dir, length: dist * 2.2, cosOut: cosf(half), cosIn: cosf(half * 0.55), deck: gy,
                                          gain: T.lureGain * (locked ? T.lockGainK : 1), color: col, cap: T.lureCap * (locked ? T.lockCapK : 1))
            let sc = locked ? ThreaderLook.spotLocked : ThreaderLook.spotColor * (0.8 + 0.5 * gather)
            let pulse: Float = locked ? 0.85 + 0.15 * sinf(clock * 24) : 1
            fx.addFloor(FloorFx(center: F4(spot.x, gy + 0.05, spot.z, v.lureRadius), color: F4(sc.x, sc.y, sc.z, pulse),
                                params: F4(FloorMode.spot.rawValue, gather, 0.1, clock * 0.4), axis: .zero), max: false)
            LightingHub.current?.emit(spot + F3(0, 1.4, 0), color: locked ? F3(1.0, 0.97, 0.92) : F3(0.7, 0.78, 1.0),
                                      intensity: ThreaderLook.spotLight * (locked ? 1.5 : 1), range: v.lureRadius + 2.5, priority: 22)
            // the lantern itself: a cold point light (the head lit from under its bulb)
            LightingHub.current?.emit(L, color: F3(0.75, 0.8, 1.0), intensity: 10 * (locked ? 1.6 : 1), range: 4, priority: 18)
        }
        // ---------------------------------------------------------- the strike: the drop language
        if v.mode == .strike && v.strikeT >= 0, dt > 0 {
            let gy = level.groundY(v.strike.x, v.strike.y)
            let land = F3(v.strike.x, gy + 0.05, v.strike.y)
            let from = boss.worldPoint(0, socket: "lantern") ?? boss.xf[0].pos
            let d = land - from
            acc[0] += dt * 90 * k
            while acc[0] >= 1 {
                acc[0] -= 1
                let q = from + d * rnd()
                fx.gpu.burst(.ice, 1, at: q, jitter: F3(0.15, 0.05, 0.15), vel: d * 0.3 + F3(0, -1.2, 0), velJitter: F3(0.25, 0.3, 0.25),
                             life: (0.5, 0.8), size: (0.08, 0.035), color: F4(0.85, 1.0, 1.3, 1), gravity: 2, drag: 0.6)
            }
            let wind = game.boss.phase >= 2 ? THREADER_STRIKE_WIND_LOW : THREADER_STRIKE_WIND
            let p = max(0, min(1, 1 - v.strikeT / wind))
            Occupancy.extra.append(F4(land.x, land.z, THREADER_STRIKE_R * (0.55 + 0.35 * p), 0.25 + 0.6 * p))
        }
        // the coil's ring: its shadow on the deck inside the closing ring
        if v.coil && v.coilT >= 0 {
            Occupancy.extra.append(F4(v.coilCenter.x, v.coilCenter.y, v.coilRadius * 1.1, 0.35))
        }
        // ---------------------------------------------------------- the rime spray (its lane lit: B4's beam telegraph)
        for (ti, e) in game.telegraphs.enumerated() where e.active && e.cause == .bossMove && e.shape == .beam {
            if e.t >= e.wind && !spray.contains(ti) {
                spray.insert(ti)
                var s: Float = 0
                while s < e.len {
                    let q = F3(e.x + e.dx * s, 0, e.z + e.dz * s)
                    let gy = level.groundY(q.x, q.z)
                    fx.gpu.burst(.ice, 3, at: F3(q.x, gy + 0.3, q.z), jitter: F3(0.5, 0.2, 0.5), vel: F3(0, 0.6, 0), velJitter: F3(0.6, 0.5, 0.6),
                                 life: (0.5, 0.9), size: (0.09, 0.04), color: F4(0.9, 1.05, 1.35, 1), gravity: 3, drag: 0.8)
                    fx.gpu.burst(.steam, 1, at: F3(q.x, gy + 0.3, q.z), jitter: F3(0.4, 0.1, 0.4), vel: F3(0, 0.4, 0), life: (0.6, 1.0),
                                 size: (0.5, 1.4), color: F4(0.65, 0.75, 0.9, 0.25), drag: 1.2)
                    s += 1.5
                }
            }
        }
        if v.mode != .rime && !spray.isEmpty && !game.telegraphs.contains(where: { $0.active && $0.shape == .beam }) { spray.removeAll() }
        // ---------------------------------------------------------- the squeeze: gauges, hiss, the curtains' steam
        if let A = level.layout.manifold, v.squeezeTrunk >= 0 && v.squeezeTrunk < A.trunks.count, dt > 0 {
            let tr = A.trunks[v.squeezeTrunk]
            for b in 0..<tr.bursts.count {
                guard let br = game.threaderBurst(b) else { continue }
                // (at the burst's own strip: B4 bursts them in turn from the end nearer the head — the order of `bursts`
                // or its reverse —, so the midpoint of its curtain, not `bursts[b]`)
                let q = Vec2((br.from.x + br.to.x) * 0.5, (br.from.y + br.to.y) * 0.5)
                let axis = F3(q.x, tr.y - 0.45, q.y)
                // the gauge sits on the trunk's camera side (+x +z), its needle swinging from amber into the red
                let side = F3(tr.dir.y, 0, -tr.dir.x) * ((tr.dir.y - tr.dir.x) >= 0 ? 1 : -1)
                let g = axis + side * 0.55 + F3(0, 0.2, 0)
                if br.state == 1 {
                    let u = min(1, br.time / THREADER_SQUEEZE_WARN)
                    let ang = -1.1 + 2.2 * u
                    let up = F3(0, 1, 0), across = F3(-camera.right.x, 0, -camera.right.z) * -1
                    let tip = g + (up * cosf(ang) + across * sinf(ang)) * 0.42
                    let red = F3(2.6, 0.25 + 0.6 * (1 - u), 0.08)
                    fx.ribbons.add(g, tip, width: 0.05, mode: .glint, color: red, intensity: 1.6 + 1.4 * u)
                    fx.ribbons.add(g - up * 0.1, g + up * 0.1, width: 0.42, mode: .halo, color: F3(1.0, 0.5, 0.08), intensity: 0.5 + 0.5 * u)
                    acc[1] += dt * 26 * k
                    while acc[1] >= 1 {
                        acc[1] -= 1
                        fx.gpu.burst(.steam, 1, at: axis + side * 0.5, jitter: F3(0.1, 0.1, 0.1), vel: side * 1.6 + F3(0, 0.9, 0),
                                     velJitter: F3(0.6, 0.6, 0.6), life: (0.25, 0.5), size: (0.12, 0.55), color: F4(0.85, 0.88, 0.92, 0.35),
                                     gravity: -0.6, drag: 2.0, spin: 0.8)
                    }
                } else if br.state == 2 {
                    // the scald curtain: jets down from the burst trunk across its strip, billows over it
                    acc[2] += dt * 30 * k
                    while acc[2] >= 1 {
                        acc[2] -= 1
                        let a = rnd()
                        let p = F3(br.from.x + (br.to.x - br.from.x) * a, tr.y - 0.95, br.from.y + (br.to.y - br.from.y) * a)
                        let gy = level.groundY(p.x, p.z)
                        fx.gpu.burst(.steam, 2, at: p, jitter: F3(0.15, 0.06, 0.15), vel: F3(0, -max(1, p.y - gy) * 1.1, 0),
                                     velJitter: F3(0.5, 0.6, 0.5), life: (0.6, 1.0), size: (0.25, 1.3), color: F4(0.84, 0.89, 0.95, 0.32),
                                     gravity: -0.4, drag: 1.4, spin: 0.6)
                        let w = (rnd() * 2 - 1) * br.width
                        let o = F3(-tr.dir.y, 0, tr.dir.x) * w
                        fx.gpu.burst(.steam, 1, at: F3(p.x, gy + 0.3 + rnd() * 1.4, p.z) + o, jitter: F3(0.2, 0.15, 0.2), vel: F3(0, 0.25, 0),
                                     velJitter: F3(0.35, 0.3, 0.35), life: (0.8, 1.4), size: (0.5, 1.7), color: F4(0.8, 0.86, 0.92, 0.22),
                                     gravity: -0.7, drag: 1.1, spin: 0.4)
                    }
                    if lastVent[min(3, b)] == 0 {
                        lastVent[min(3, b)] = 1
                        fx.flash(axis, F3(1.0, 0.85, 0.7), peak: 50, dur: 0.3, range: 7, priority: 14)
                    }
                }
            }
        } else {
            lastVent = [0, 0, 0, 0]
        }
        // ---------------------------------------------------------- the pull-down: dust along the whole trunk while it rips
        if let A = level.layout.manifold, v.pullTrunk >= 0 && v.pullTrunk < A.trunks.count, v.pullT > 0, dt > 0 {
            let tr = A.trunks[v.pullTrunk]
            acc[3] += dt * 60 * k
            while acc[3] >= 1 {
                acc[3] -= 1
                let q = tr.point(rnd() * tr.length)
                fx.gpu.burst(rnd() < 0.7 ? .ice : .debris, 1, at: F3(q.x, tr.y - 0.95, q.y), jitter: F3(0.3, 0.05, 0.3), vel: F3(0, -1, 0),
                             velJitter: F3(0.3, 0.4, 0.3), life: (0.9, 1.4), size: (0.06, 0.03), color: F4(0.6, 0.66, 0.74, 0.9),
                             gravity: 5, drag: 0.6)
            }
        }
        // ---------------------------------------------------------- the punish window: its weak point lit
        if v.mode == .down, let w = boss.worldPoint(0, socket: "weak") {
            LightingHub.current?.emit(w + F3(0, 0.4, 0), color: F3(1.0, 0.55, 0.75), intensity: 9 + 4 * sinf(clock * 10), range: 3.5, priority: 20)
        }
        // the Manifold's valves (their lamp: R6's gauge colours — the valves ride the trunks here, WorldProps leaves them)
        if level.layout.manifold != nil {
            // (not on a trunk that fell, nor in its last 0.4 s up: WorldBoss.trunks hides it then)
            let falling = v.pullTrunk >= 0 && v.pullT >= 0 && v.pullT < 0.4 ? v.pullTrunk : -1
            for (vi, vs) in game.valves.enumerated() where vi < 4 && vi != v.fallenTrunk && vi != falling {
                let c: F3
                switch vs.phase {
                case .ready: c = F3(1.0, 0.55, 0.08) * (0.9 + 0.1 * sinf(clock * 3 + Float(vi)))
                case .burst: c = F3(1.3, 0.12, 0.05) * (sinf(clock * 40) > 0 ? 1 : 0.2)
                case .venting: c = F3(1.2, 1.0, 0.8)
                case .recharge: let g = vs.gauge; c = (F3(0.5, 0.06, 0.02) * (1 - g) + F3(1.0, 0.55, 0.08) * g) * (0.2 + 0.5 * g)
                }
                if let gp = ManifoldBuild.valveGauge(vs.site, level: level) {
                    fx.ribbons.add(gp - F3(0, 0.05, 0), gp + F3(0, 0.05, 0), width: 0.11, mode: .halo, color: c, intensity: 1.2)
                }
            }
        }
    }

    // ================================================================ sounds
    /// The scrape of its claws on the metal while it moves up there (through the attic voice), a moan now and then.
    private func sounds(game: Game, boss: WorldBoss, v: ThreaderView, dt: Float) {
        let hp = boss.xf[0].pos
        let gy = game.level.groundY(hp.x, hp.z)
        scrapeT -= dt
        if speed > 1.2 && scrapeT <= 0 {
            scrapeT = 0.75 + 0.5 * rnd()
            // from the middle of the body: the long scrape of 18 pairs of claws
            let mid = boss.partCount > 9 ? boss.xf[9].pos : hp
            sound(.scrape, mid, gain: min(1, 0.45 + speed / 10), deckY: game.level.groundY(mid.x, mid.z))
        }
        moanT -= dt
        if moanT <= 0 {
            moanT = 11 + 6 * rnd()
            if v.mode == .roam || v.mode == .duct || v.mode == .deck { sound(.moan, hp, gain: 0.7, deckY: gy) }
        }
    }
}
