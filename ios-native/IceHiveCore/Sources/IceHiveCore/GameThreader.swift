import Foundation

// ================================================================
//  THE THREADER (Stage 2 B4; design §1.5) — the second Kelvin-9 boss, on
//  the boss framework (Boss.swift, GameBoss.swift, GameBossBody.swift): a
//  30 m segmented hive creature threaded through the Manifold's pipe trunks
//  (Manifold.swift). A CHAIN body: an armoured head with a hanging lantern
//  organ, 18 frost-plated segments (1.6 m) following the head's path by arc
//  length, five lantern nodes on segments 3 / 6 / 9 / 12 / 15. Every hit is
//  routed to one boss bar: the head ×1 (×2 while it is down; ×0.25 up on a
//  trunk — its crest to the deck), the nodes ×1.5 with their own 8 % pools
//  (popped: dark, a scream, a 1.5 s stagger; up on a trunk in P1 / P2 behind
//  their frost plates, ×1/6), the body ×0.25. PAIN: 20 % of its health in one
//  exposure (a punish window and its way back up, a coil) and it screams —
//  the head pulls back up at once, the coil lets go, the ice on it breaks.
//  Its moves — all `.custom`, played here (one that cannot start now tries
//  again in 0.5 s):
//    LURE & STRIKE  the lure beam sweeps the deck in slow arcs; 0.8 s in its
//                   light locks it (hot white, a closing ring at the
//                   marine's predicted place); 1.2 s later the head drops:
//                   a 3 m slam, 30 × the damage multiplier, the knock-down;
//                   the head stays down 2 s (×2), then pulls back up its path;
//                   no lock for 6 s after its arrival or a phase, 16 s after
//                   a strike
//    SHED           every 14 s, frost dust along the body for 1.5 s, then
//                   4–6 «ticks» — R4's Droppers, small — along the body
//    CLIMB (P1)     at 14 s, then every 25 s up a riser pipe to the 8 m duct:
//                   untouchable for 4 s while the beam sweeps from above,
//                   then down onto a different trunk
//    COIL (P2)      the body lowers to 2 m round a deck section: a 7 m ring
//                   that glows and shrinks for 2.5 s, then 25 crush to
//                   anyone inside (the bugs inside die too); escape: a dash
//                   through a gap (walking out is blocked: marines collide
//                   with its parts), two frozen ring segments open a gap,
//                   a grenade on a node makes it let go (so does its pain);
//                   its ring stays over the island
//    RIME SPIT (P2) a red lane along a trunk's footprint, 12
//    SQUEEZE (P2)   it crushes a trunk: the valves of its pipe burst one by
//                   one along it, 1.5 s of warning each, then a scald
//                   curtain (marines 10/s, deck bugs 40/s, bugs up on the
//                   trunk die)
//    PULL DOWN (P3) a long red lane and dust along a whole trunk, then it
//                   crashes across the deck: an obstacle on the island (its
//                   snapped middle open) and a bridge over the gaps — the
//                   walk grid changes; the body comes down onto the deck
//    DECK CHASE (P3) it slithers at deck height: away to the ring and round
//                   it for 4 s after the crash, a charge or a lunge; charges
//                   from there that curve after their marine behind the lure
//                   beam pointing along the path (1 s); strikes from low
//                   height with a 0.6 s ring
//  Phases: P1 100–66 % «hunting the racks» (lure & strike, shed, climb); P2
//  66–33 % «constrict» (+ coil, rime spit, squeeze; the duct mouths pour
//  packs); P3 33–0 % «breach» (pull down, the deck chase, enraged ×1.3, the
//  nodes exposed). Class counterplay: the Cryo's frozen part locks the body
//  2 s (the head down stays down), its Ice Wave on the head down: brittle
//  (+50 %); the Pyro's napalm under a strike spot makes the head recoil (+1 s
//  down), its torch strips a node's frost plates (+25 % to that node for the
//  squad); the Assault's pierce rounds go through a segment into a node; the
//  Gunner's turret and the bots put their fire on the nodes and on the head
//  while it is down. Fixed buffers only (ThreaderRuntime is allocated once
//  per Game, the route tables once per spawn): no allocation per tick.
// ================================================================

// ---------------------------------------------------------------- the numbers (design §1.5)
/// Seconds in the lure's light before the beam locks.
public let THREADER_LOCK: Float = 0.8
/// The strike: the closing ring's time before the head lands (P3: from low height), the slam's radius and damage (× the
/// damage multiplier), the knockback (≥ 9: the rig's knock-down), the head's time down.
public let THREADER_STRIKE_WIND: Float = 1.2
public let THREADER_STRIKE_WIND_LOW: Float = 0.6
public let THREADER_STRIKE_R: Float = 3
public let THREADER_STRIKE_DMG: Float = 30
public let THREADER_DOWN: Float = 2
/// The head dropping into the Pyro's napalm recoils: this much longer down.
public let THREADER_RECOIL: Float = 1
/// A punish window that has taken this share of its maximum health ends early: the head screams and pulls back up (one
/// window never takes a whole phase — the fight keeps its rhythm of strikes).
public let THREADER_WINDOW_CAP: Float = 0.2
/// P3, the deck chase: seconds it slithers away to the ring and round it after the crash, a charge or a lunge.
public let THREADER_AWAY: Float = 4
/// A new phase: the scream (untouchable this long), and the lure cannot lock for THREADER_PHASE_GAP s (it threads away first).
public let THREADER_PHASE_UNTOUCHABLE: Float = 1.2
public let THREADER_PHASE_GAP: Float = 6
/// Shed: seconds between sheds, the frost dust before the ticks drop.
public let THREADER_SHED_GAP: Float = 14
public let THREADER_SHED_WARN: Float = 1.5
/// The climb to the ring duct (P1): every this many seconds, untouchable this long up there.
public let THREADER_CLIMB_GAP: Float = 25
/// (the first climb comes this long after its arrival: the rhythm shows early)
public let THREADER_CLIMB_FIRST: Float = 14
public let THREADER_DUCT_TIME: Float = 4
/// The coil (P2): the ring's radius (the design's 7 m ring), its radius at the crush, the shrink, the crush damage, the
/// body's height over the deck (it lowers to 2 m).
public let THREADER_COIL_R: Float = 3.5
public let THREADER_COIL_R_END: Float = 1.2
public let THREADER_COIL_SHRINK: Float = 2.5
public let THREADER_COIL_DMG: Float = 25
public let THREADER_COIL_Y: Float = 2
/// Rime spit (P2): damage of the lane along a trunk's footprint.
public let THREADER_RIME_DMG: Float = 12
/// Squeeze (P2): each burst's warning, then its scald curtain.
public let THREADER_SQUEEZE_WARN: Float = 1.5
public let THREADER_SQUEEZE_VENT: Float = 3
/// Pull down (P3): the red lane's warning, the crash's damage.
public let THREADER_PULL_WARN: Float = 2
public let THREADER_PULL_DMG: Float = 30
/// The deck chase's charge (P3): damage of a hit.
public let THREADER_CHARGE_DMG: Float = 20
/// After a strike the lure sweeps on but cannot lock for this long (s; P3's lunge: THREADER_LUNGE_GAP).
public let THREADER_STRIKE_GAP: Float = 16
public let THREADER_LUNGE_GAP: Float = 10
/// The body just came down onto the deck (P3): the lure cannot lock for this long; nor for THREADER_FIRST_GAP after its arrival
/// (it threads itself through the racks first).
public let THREADER_DECK_GAP: Float = 5
public let THREADER_FIRST_GAP: Float = 6
/// The lure's lit spot on the deck (m), and how near it comes before a bot steps out (design: «within 2 m»).
public let THREADER_LURE_R: Float = 2.4
public let THREADER_LURE_DODGE: Float = 2
/// Enraged (P3): × speed.
public let THREADER_ENRAGE: Float = 1.3
/// A node up on the trunks in P1 / P2 is behind its frost plates: × this (its ×1.5 becomes ×0.25, the body's) until it comes
/// within the deck's reach (the strike's neck, the coil) or P3 exposes them all (design: «nodes exposed»).
public let THREADER_PLATED: Float = 1.0 / 6.0
/// The armoured head up on the trunks (not down, out of the deck's reach) turns its crest to the deck: × this (the body's
/// ×0.25) — it is the punish window's target, not the hunt's.
public let THREADER_HEAD_UP: Float = 0.25
/// The body: 18 segments 1.6 m apart (the first 2 m behind the head), the nodes on these segments.
public let THREADER_SEGMENTS = 18
public let THREADER_NODE_SEGMENTS: [Int] = [3, 6, 9, 12, 15]
/// `BossRuntime.busy` while the Threader's own file holds the boss between moves (the head down, pulling back up, on its
/// way to the duct): no exclusive move starts.
let THREADER_HOLD = 99

/// What the Threader is doing (`ThreaderView.mode`).
public enum ThreaderMode: Int {
    /// Not there (yet).
    case none
    /// Hunting the racks: on a trunk, the lure sweeping.
    case roam
    /// On its way up a riser pipe to the ring duct (P1).
    case climb
    /// Up in the ring duct: untouchable, the beam sweeping from above.
    case duct
    /// The lure locked: the closing ring, the head about to drop.
    case strike
    /// The head down on the deck (the punish window).
    case down
    /// Pulling its head back up its path to the trunk.
    case recover
    /// The coil: down round a deck section, the ring shrinking.
    case coil
    /// Spitting rime along a trunk.
    case rime
    /// Crushing a trunk: its valves burst one by one.
    case squeeze
    /// Ripping a trunk down (P3).
    case pull
    /// On the deck, chasing (P3).
    case deck
    /// A charge on the deck (P3).
    case charge
}

/// The Threader's numbers in one run (calibration rows' `thr` object, tests): when its phases came (s after the spawn;
/// -1 not reached), what it did and what the squad did to it.
public struct ThreaderStats: Equatable {
    public internal(set) var p2T: Float = -1, p3T: Float = -1
    /// Lure locks, strikes landed, strikes that hit a marine, Pyro recoils, climbs to the duct.
    public internal(set) var locks = 0, strikes = 0, strikeHits = 0, recoils = 0, climbs = 0
    /// Coils, marines crushed, coils let go early (a grenade on a node, a pop), gaps opened by frozen segments.
    public internal(set) var coils = 0, crushed = 0, letGo = 0, gaps = 0
    /// Rime spits and their hits, squeezes, squad HP lost to the steam, trunks pulled down, charges and their hits.
    public internal(set) var rimes = 0, rimeHits = 0, squeezes = 0, steamHurt: Float = 0, pulls = 0, charges = 0, chargeHits = 0
    /// Sheds and the ticks they dropped; duct-mouth packs; nodes popped; nodes stripped by the torch; frozen locks; brittles.
    public internal(set) var sheds = 0, ticks = 0, packs = 0, popped = 0, stripped = 0, freezeLocks = 0, brittles = 0
    /// Punish windows cut short by THREADER_WINDOW_CAP.
    public internal(set) var pains = 0
    /// Damage on the boss bar by the part struck: the head, the nodes, the body; and by phase (P1, P2, P3).
    public internal(set) var dmgHead: Float = 0, dmgNode: Float = 0, dmgBody: Float = 0
    public internal(set) var dmgP1: Float = 0, dmgP2: Float = 0, dmgP3: Float = 0
    /// Seconds out of the deck weapons' reach (the head up there and not down), untouchable, the head down.
    public internal(set) var upT: Float = 0, untouchT: Float = 0, downT: Float = 0
    public init() {}
}

/// The Threader as the renderer and the tests read it (`Game.threader`): its mode, the lure (the lantern, the lit spot on
/// the deck, its lock), the strike's ring, the coil, the squeeze, the fallen trunk, the shed's frost dust.
public struct ThreaderView {
    public let mode: ThreaderMode
    /// The lure beam is lit; the lantern organ (x, absolute y, z: the beam's origin), the centre and radius of its lit spot on
    /// the deck; the marine it locked on (-1 none: it sweeps) — the beam hot white while it is locked.
    public let lure: Bool
    public let lantern: SIMD3<Float>
    public let lureSpot: Vec2
    public let lureRadius: Float
    public let locked: Int
    /// Seconds each marine has spent in the light (it locks at THREADER_LOCK).
    public let exposure: SIMD4<Float>
    /// The strike's slam point, its radius, seconds to its landing (-1: no strike winding up), seconds the head stays down.
    public let strike: Vec2
    public let strikeR: Float
    public let strikeT: Float
    public let downT: Float
    /// The coil: on, its centre, its ring's radius now, seconds to the crush (-1 none), the ring segment of an open gap (-1).
    public let coil: Bool
    public let coilCenter: Vec2
    public let coilRadius: Float
    public let coilT: Float
    public let coilGap: Int
    /// The trunk being squeezed (-1 none) and seconds since its first burst's warning.
    public let squeezeTrunk: Int
    public let squeezeT: Float
    /// The trunk being ripped down (-1 none) and seconds left of its warning; the trunk lying on the deck (-1 none).
    public let pullTrunk: Int
    public let pullT: Float
    public let fallenTrunk: Int
    /// Seconds left of the shed's frost dust (0 none).
    public let shedWarn: Float
    /// Up in the ring duct (untouchable).
    public let inDuct: Bool
}

/// The Threader's runtime (one per Game, its buffers allocated once; the route tables once per spawn).
final class ThreaderRuntime {
    // ---- the arena (built at the spawn from the level's routes and `LevelLayout.manifold`)
    var ready = false
    var N = 0
    /// N × N: the cheapest path cost from node a to b, and the first edge to take (roaming prices the duct and the riser pipes
    /// ×3: it hunts on the trunks; the true lengths for the climb), -1 none.
    var distRoam: [Float] = [], hopRoam: [Int16] = []
    var distTrue: [Float] = [], hopTrue: [Int16] = []
    /// Per edge: its trunk (-1 none); a ring-duct edge; a riser pipe (leg → duct); a duct mouth's edge.
    var edgeTrunk: [Int8] = [], edgeDuct: [Bool] = [], edgeConn: [Bool] = [], edgeMouth: [Bool] = []
    /// Its moves' indices in the spec (-1 absent).
    var iStrike = -1, iStrikeLow = -1, iShed = -1, iClimb = -1, iCoil = -1, iRime = -1, iSqueeze = -1, iPull = -1, iCharge = -1
    // ---- the head on the route graph
    var e = -1
    var s: Float = 0
    var onGraph = false
    // ---- the mode
    var mode: ThreaderMode = .none
    var t: Float = 0
    var phaseSeen = 0
    /// The head's arc length and place when it left the graph (the path back up), the mode's point (the slam, the coil's centre).
    var sBack: Float = 0
    var bx: Float = 0, by: Float = 0, bz: Float = 0
    var px: Float = 0, pz: Float = 0
    var downLeft: Float = 0
    var lockExtended = false
    // ---- the lure
    var lureOn = false
    var lx: Float = 0, lz: Float = 0
    var lr: Float = THREADER_LURE_R
    var sweep: Float = 0, arc: Float = 4.5, ang: Float = 0
    var target = -1
    var targetT: Float = 0
    var exposure = [Float](repeating: 0, count: 4)
    var locked = -1
    var noLock: Float = 0
    /// Seconds before the lure may lock again (after a strike).
    var lockGap: Float = 0
    var lantern = SIMD3<Float>(0, 0, 0)
    var saidLight = false
    // ---- the climb
    var ductGoal = -1, ductBack = -1
    var ductT: Float = 0
    // ---- the coil
    var cx: Float = 0, cz: Float = 0, cy: Float = 0
    var cr: Float = THREADER_COIL_R
    var ca0: Float = 0, csign: Float = 1
    var ringHead = -1, ringCount = 0
    var coilGap = -1
    var letGo = false
    var crushed = false
    // ---- the squeeze, the rime, the pull-down
    var sqTrunk = -1, lastSqueeze = -1, lastRime = -1
    var sqT: Float = 0
    var sqFromB = false
    var steamAcc = [Float](repeating: 0, count: 4)
    var pullTrunk = -1, fallen = -1
    // ---- the deck chase
    var hd: Float = 0
    var chargeHit: UInt8 = 0
    var lowCd: Float = 0
    // ---- shed, duct packs, the freeze lock's cooldown, the torch on the nodes
    var shedWarn: Float = 0
    var packT: Float = 0
    var lockCd: Float = 0, lockPrev: Float = 0
    var strip = [Float](repeating: 0, count: BOSS_PARTS)
    var stripped = [Bool](repeating: false, count: BOSS_PARTS)
    var stats = ThreaderStats()
    /// Its moves whose start was «not now» (the boss busy elsewhere, nobody in place): tried again in 0.5 s, not after a whole
    /// cooldown (bits by move index).
    var retry: UInt32 = 0
    /// Damage on the boss bar in the current punish window (THREADER_WINDOW_CAP).
    var winDmg: Float = 0
    var pained = false
    var brittlePrev: Float = 0
    /// P3: seconds left of keeping away (out to the ring and round it); the flow field toward the ring's middle line and its
    /// sources (built once), valid since the last pull-down.
    var awayT: Float = 0
    var ringReady = false
    lazy var ringFlow = FlowField()
    var ringSrc: [Float] = []

    func reset() {
        ready = false
        e = -1; s = 0; onGraph = false
        mode = .none; t = 0; phaseSeen = 0; sBack = 0; downLeft = 0; lockExtended = false
        lureOn = false; sweep = 0; arc = 4.5; ang = 0; target = -1; targetT = 0; locked = -1; noLock = 0; lockGap = 0; saidLight = false
        for k in 0..<4 { exposure[k] = 0; steamAcc[k] = 0 }
        ductGoal = -1; ductBack = -1; ductT = 0
        ringHead = -1; ringCount = 0; coilGap = -1; letGo = false; crushed = false
        sqTrunk = -1; lastSqueeze = -1; lastRime = -1; sqT = 0; pullTrunk = -1; fallen = -1
        hd = 0; chargeHit = 0; lowCd = 0; shedWarn = 0; packT = 0; lockCd = 0; lockPrev = 0; retry = 0; winDmg = 0
        awayT = 0; ringReady = false; brittlePrev = 0; pained = false
        for q in 0..<BOSS_PARTS { strip[q] = 0; stripped[q] = false }
        stats = ThreaderStats()
    }
}

// ---------------------------------------------------------------- the rows

extension BossSpec {
    /// The Threader on one tier (design §1.5): `hp` × the director's HP multiplier at its spawn, `speed` on the trunks (6 m/s),
    /// 4…`shedMax` ticks per shed, the coil / rime spit / squeeze / charge every `coilT` / `rimeT` / `squeezeT` / `chargeT` s,
    /// × `trickle` on the arena's stream while it lives. It comes out of the pipes at the Manifold's north leg of trunk 2.
    public static func threader(hp: Float, speed: Float = 6, shedMax: Int = 6, coilT: Float, rimeT: Float, squeezeT: Float, chargeT: Float,
                                trickle: Float) -> BossSpec {
        let head = BossPartSpec(.head, type: .brute, radius: 1.1, scale: 1, damageK: 1, downK: 2)
        let seg = BossPartSpec(.segment, type: .runner, radius: 0.75, scale: 1, damageK: 0.25)
        let nodes = THREADER_NODE_SEGMENTS.map {
            BossPartSpec(.node, type: .spitter, radius: 0.55, scale: 1, lift: -0.55, segment: $0, damageK: 1.5, pool: 0.08, poppedK: 0.25, popStagger: 1.5)
        }
        let chain = BossChainSpec(head: head, segment: seg, segments: THREADER_SEGMENTS, spacing: 1.6, lead: 2, nodes: nodes, sampleStep: 0.25)
        let frost = SIMD3<Float>(0.86, 0.94, 1.0), red = SIMD3<Float>(1.0, 0.18, 0.1)
        // (P1 = bit 0, P2 = bit 1, P3 = bit 2)
        var strike = BossMove("strike", .custom, first: 999, cooldown: 999)
        strike.phases = 0b011; strike.shape = .drop; strike.aim = .set; strike.windUp = THREADER_STRIKE_WIND
        strike.damage = THREADER_STRIKE_DMG; strike.knockback = 10; strike.radius = THREADER_STRIKE_R; strike.opensDown = THREADER_DOWN
        strike.color = frost
        var low = strike
        low.id = "strikeLow"; low.phases = 0b100; low.windUp = THREADER_STRIKE_WIND_LOW
        var shed = BossMove("shed", .custom, first: 8, cooldown: THREADER_SHED_GAP)
        shed.active = THREADER_SHED_WARN; shed.exclusive = false; shed.count = shedMax; shed.addType = .dropper
        var climb = BossMove("climb", .custom, first: THREADER_CLIMB_FIRST, cooldown: THREADER_CLIMB_GAP)
        climb.phases = 0b001; climb.active = 30
        var coil = BossMove("coil", .custom, first: 7, cooldown: coilT)
        coil.phases = 0b010; coil.active = 12; coil.damage = THREADER_COIL_DMG; coil.knockback = 9; coil.radius = THREADER_COIL_R
        coil.hitsBugs = true
        var rime = BossMove("rime", .custom, first: 8, cooldown: rimeT)
        rime.phases = 0b010; rime.shape = .beam; rime.aim = .set; rime.windUp = 1; rime.active = 0.35; rime.damage = THREADER_RIME_DMG
        rime.knockback = 3; rime.radius = 2.6; rime.length = 35; rime.color = red
        var squeeze = BossMove("squeeze", .custom, first: 12, cooldown: squeezeT)
        squeeze.phases = 0b010; squeeze.active = 14
        var pull = BossMove("pull", .custom, first: 0.5, cooldown: 9999)
        pull.phases = 0b100; pull.active = 12; pull.damage = THREADER_PULL_DMG; pull.knockback = 11; pull.radius = 3.2; pull.length = 35
        pull.color = red
        var charge = BossMove("charge", .custom, first: 4, cooldown: chargeT)
        charge.phases = 0b100; charge.shape = .cone; charge.aim = .set; charge.windUp = 1; charge.active = 1.6
        charge.damage = THREADER_CHARGE_DMG; charge.knockback = 11; charge.length = 12; charge.angle = 0.3; charge.color = frost
        var p2 = BossPhase(below: 0.66)
        p2.stagger = 1.2
        var p3 = BossPhase(below: 0.33)
        p3.enraged = true; p3.speedK = THREADER_ENRAGE; p3.stagger = 1.2
        var s = BossSpec(at: .infinity, hp: hp, speed: speed, body: .chain(chain),
                         spawn: .point(x: -Manifold.trunkOff, z: -Manifold.legAt, y: Manifold.trunkY, heading: 0),
                         phases: [BossPhase(below: 1), p2, p3], moves: [strike, low, shed, climb, coil, rime, squeeze, pull, charge],
                         source: .threader)
        s.warn = 2.5; s.warnRing = 3
        s.immune.freeze = false; s.immune.chillCap = 0.6; s.immune.pulse = true; s.immune.freezeLock = 2; s.immune.brittle = 1.5
        s.trickle = trickle; s.pausesHordes = true
        s.areaOnce = true
        s.reward = BossReward(xp: 80, medkits: [Vec2(1.2, 0), Vec2(-1.2, 0)])
        s.banner = BannerText(title: .bannerThreader, sub: .bannerThreaderSub)
        s.deathBanner = BannerText(title: .bannerThreaderDead, sub: .bannerThreaderDeadSub)
        s.roar = .roar; s.arrivalShake = 0.5
        return s
    }

    /// No Threader on this tier (the hidden legacy row): its structure, health 0.
    public static let threaderNone = BossSpec.threader(hp: 0, speed: 0, coilT: 99, rimeT: 99, squeezeT: 99, chargeT: 99, trickle: 1)
}

extension Game {

    // ================================================================ public views

    /// The Threader is the boss of the current step and alive.
    var threaderActive: Bool { boss.alive && boss.kind == .threader && bossRT.parts > 0 }

    /// The Threader as the renderer reads it (meaningful while `boss.kind == .threader`).
    public var threader: ThreaderView {
        let T = thr, R = bossRT
        let ex = SIMD4<Float>(T.exposure[0], T.exposure[1], T.exposure[2], T.exposure[3])
        var st: Float = -1
        // (no array literal: the renderer reads this every frame)
        if T.iStrike >= 0 && R.stage[T.iStrike] == 1 { st = max(0, R.timer[T.iStrike]) }
        if T.iStrikeLow >= 0 && R.stage[T.iStrikeLow] == 1 { st = max(0, R.timer[T.iStrikeLow]) }
        let coil = T.mode == .coil
        var coilT: Float = -1
        if coil && !T.letGo && !T.crushed { coilT = max(0, threaderCoilEnd - T.t) }
        let pullT: Float = T.mode == .pull ? max(0, THREADER_PULL_WARN - T.t) : -1
        return ThreaderView(mode: T.mode, lure: T.lureOn && boss.alive, lantern: T.lantern, lureSpot: Vec2(T.lx, T.lz), lureRadius: T.lr,
                            locked: T.locked, exposure: ex, strike: Vec2(T.px, T.pz), strikeR: THREADER_STRIKE_R, strikeT: st,
                            downT: T.mode == .down ? T.downLeft : 0, coil: coil, coilCenter: Vec2(T.cx, T.cz), coilRadius: T.cr, coilT: coilT,
                            coilGap: T.coilGap, squeezeTrunk: T.mode == .squeeze ? T.sqTrunk : -1, squeezeT: T.mode == .squeeze ? T.sqT : -1,
                            pullTrunk: T.mode == .pull ? T.pullTrunk : -1, pullT: pullT, fallenTrunk: T.fallen, shedWarn: max(0, T.shedWarn),
                            inDuct: T.mode == .duct)
    }

    /// The Threader's numbers so far (calibration, tests).
    public var threaderStats: ThreaderStats { thr.stats }

    /// The squeeze's burst `k` of the trunk being squeezed: its curtain strip on the deck (from, to; half-width), its state —
    /// 0 waiting, 1 warning (the gauge needle, the hiss), 2 venting, 3 over — and seconds into that state. nil: no squeeze.
    public func threaderBurst(_ k: Int) -> (from: Vec2, to: Vec2, width: Float, state: Int, time: Float)? {
        let T = thr
        guard T.mode == .squeeze, let A = level.layout.manifold, T.sqTrunk >= 0, T.sqTrunk < A.trunks.count else { return nil }
        let tr = A.trunks[T.sqTrunk]
        guard k >= 0 && k < tr.bursts.count else { return nil }
        let (a, b) = threaderBurstSpan(tr, k, A)
        let t0 = threaderBurstStart(k, tr.bursts.count)
        let tt = T.sqT - t0
        let state = tt < 0 ? 0 : (tt < THREADER_SQUEEZE_WARN ? 1 : (tt < THREADER_SQUEEZE_WARN + THREADER_SQUEEZE_VENT ? 2 : 3))
        let into: Float = state == 0 ? 0 : (state == 1 ? tt : (state == 2 ? tt - THREADER_SQUEEZE_WARN : tt - THREADER_SQUEEZE_WARN - THREADER_SQUEEZE_VENT))
        return (a, b, A.burstWidth, state, into)
    }

    // ================================================================ set-up

    /// The arena's tables (the first tick after its arrival): the route graph's all-pairs costs, the trunk / duct / riser-pipe /
    /// mouth edges, its moves; the head on the graph at the node it came out at.
    func threaderSetup() {
        let T = thr, B = bossSpec
        T.ready = true
        T.iStrike = B.moveIndex("strike"); T.iStrikeLow = B.moveIndex("strikeLow"); T.iShed = B.moveIndex("shed")
        T.iClimb = B.moveIndex("climb"); T.iCoil = B.moveIndex("coil"); T.iRime = B.moveIndex("rime"); T.iSqueeze = B.moveIndex("squeeze")
        T.iPull = B.moveIndex("pull"); T.iCharge = B.moveIndex("charge")
        T.mode = .roam; T.t = 0; T.phaseSeen = boss.phase
        T.packT = 4; T.lockGap = THREADER_FIRST_GAP
        guard let G = level.overhead else { T.N = 0; T.mode = .deck; T.hd = boss.heading; return }
        let N = G.nodeCount, E = G.edgeCount
        T.N = N
        T.edgeTrunk = [Int8](repeating: -1, count: E)
        if let A = level.layout.manifold {
            for (k, tr) in A.trunks.enumerated() { for e in tr.edges where e < E { T.edgeTrunk[e] = Int8(k) } }
        }
        T.edgeDuct = [Bool](repeating: false, count: E); T.edgeConn = [Bool](repeating: false, count: E)
        T.edgeMouth = [Bool](repeating: false, count: E)
        let nodes = G.layout.nodes
        for e in 0..<E {
            let a = nodes[G.ea[e]], b = nodes[G.eb[e]]
            if a.kind == .ductMouth || b.kind == .ductMouth { T.edgeMouth[e] = true; continue }
            if G.kind(e) == .duct { T.edgeDuct[e] = true; continue }
            if T.edgeTrunk[e] < 0 && abs(a.p.y - b.p.y) > 1 { T.edgeConn[e] = true }
        }
        func costs(_ roam: Bool) -> ([Float], [Int16]) {
            var d = [Float](repeating: .infinity, count: N * N)
            var w = [Float](repeating: 0, count: E)
            for e in 0..<E {
                var k: Float = 1
                if T.edgeMouth[e] { k = 100 } else if roam && (T.edgeDuct[e] || T.edgeConn[e]) { k = 3 }
                w[e] = G.length[e] * k
            }
            for src in 0..<N {
                var done = [Bool](repeating: false, count: N)
                d[src * N + src] = 0
                for _ in 0..<N {
                    var u = -1
                    var bd: Float = .infinity
                    for k in 0..<N where !done[k] && d[src * N + k] < bd { bd = d[src * N + k]; u = k }
                    if u < 0 { break }
                    done[u] = true
                    for e in G.nodeEdges[u] {
                        let o = G.ea[e] == u ? G.eb[e] : G.ea[e]
                        let nd = bd + w[e]
                        if nd < d[src * N + o] { d[src * N + o] = nd }
                    }
                }
            }
            // the first edge from a toward b: the edge at a whose far node is cheapest from there
            var hop = [Int16](repeating: -1, count: N * N)
            for a in 0..<N {
                for b in 0..<N where a != b && d[a * N + b].isFinite {
                    var best = -1
                    var bc: Float = .infinity
                    for e in G.nodeEdges[a] {
                        let o = G.ea[e] == a ? G.eb[e] : G.ea[e]
                        let c = w[e] + d[o * N + b]
                        if c < bc { bc = c; best = e }
                    }
                    hop[a * N + b] = Int16(best)
                }
            }
            return (d, hop)
        }
        (T.distRoam, T.hopRoam) = costs(true)
        (T.distTrue, T.hopTrue) = costs(false)
        // the head stands at a node (its spawn point): onto the trunk edge there that leads inward
        let R = bossRT
        var bn = -1
        var bd: Float = .infinity
        for n in 0..<N {
            let p = nodes[n].p
            let d = (p.x - R.headX) * (p.x - R.headX) + (p.y - R.headY) * (p.y - R.headY) + (p.z - R.headZ) * (p.z - R.headZ)
            if d < bd { bd = d; bn = n }
        }
        if bn < 0 || bd > 4 { T.mode = .deck; T.hd = boss.heading; return }
        var pick = -1
        var pc: Float = .infinity
        for e in G.nodeEdges[bn] where T.edgeTrunk[e] >= 0 {
            let o = G.ea[e] == bn ? G.eb[e] : G.ea[e]
            let p = nodes[o].p
            let c = p.x * p.x + p.z * p.z
            if c < pc { pc = c; pick = e }
        }
        if pick < 0 { pick = G.nodeEdges[bn].first ?? -1 }
        if pick < 0 { T.mode = .deck; T.hd = boss.heading; return }
        T.e = pick; T.s = G.ea[pick] == bn ? 0 : G.length[pick]; T.onGraph = true
    }

    // ================================================================ the tick (bossOwnTick)

    /// Every tick while it lives, before its body follows its head (GameBoss.bossTick).
    func threaderOwnTick(_ dt: Float) {
        let T = thr
        if !T.ready { threaderSetup() }
        if T.retry != 0 {
            let R = bossRT
            for m in 0..<BOSS_MOVES where (T.retry >> UInt32(m)) & 1 != 0 { R.clock[m] = minf(R.clock[m], 0.5) }
            T.retry = 0
        }
        threaderCollide()
        if boss.phase != T.phaseSeen { threaderPhase(boss.phase) }
        if T.lockCd > 0 { T.lockCd -= dt }
        if T.shedWarn > 0 { T.shedWarn -= dt }
        if T.lowCd > 0 { T.lowCd -= dt }
        if T.lockGap > 0 && T.mode != .strike && T.mode != .down && T.mode != .recover { T.lockGap -= dt }
        T.t += dt
        threaderTorch(dt)
        threaderNodes()
        threaderPacks(dt)
        let still = boss.lock > 0 || boss.stagger > 0
        switch T.mode {
        case .none, .roam: if !still { threaderRoam(dt) }
        case .climb, .duct: if !still { threaderClimb(dt) }
        case .strike: threaderStrikeWind(dt)
        case .down: threaderDown(dt)
        case .recover: if !still { threaderRecover(dt) }
        case .coil: threaderCoil(dt)
        case .rime: break
        case .squeeze: threaderSqueeze(dt)
        case .pull: threaderPull(dt)
        case .deck: if !still { threaderDeck(dt) }
        case .charge: threaderCharge(dt)
        }
        threaderLure(dt)
        threaderAccount(dt)
        T.lockPrev = boss.lock
        if boss.brittle > 0 && T.brittlePrev <= 0 { T.stats.brittles += 1 }
        T.brittlePrev = boss.brittle
    }

    /// A new phase: P2 — the duct mouths start pouring soon; P3 — «Node's open!» (the body comes down: the nodes exposed).
    func threaderPhase(_ p: Int) {
        let T = thr, R = bossRT
        T.phaseSeen = p
        // (a new phase ends a punish window: the scream, a moment untouchable, the head back up its path)
        if T.mode == .down {
            T.downLeft = 0
            if R.parts > 0 { R.down[0] = 0 }
        }
        bossUntouchable(THREADER_PHASE_UNTOUCHABLE)
        T.lockGap = maxf(T.lockGap, THREADER_PHASE_GAP)
        let since = time - boss.t0
        if p >= 1 && T.stats.p2T < 0 { T.stats.p2T = since; T.packT = 4 }
        if p >= 2 && T.stats.p3T < 0 { T.stats.p3T = since; toast(GameText(.toastThreaderNode), .gold) }
    }

    // ---------------------------------------------------------------- moves (bossOwnMove)

    /// A `.custom` move: stage 0 its start (false: not now), 1 it lands, 2 it ends, 3 a stagger cancelled its wind-up.
    func threaderOwnMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr
        if !T.ready { threaderSetup() }
        var ok = false
        switch m {
        case T.iStrike, T.iStrikeLow: return threaderStrikeMove(m, stage)
        case T.iShed: ok = threaderShedMove(m, stage)
        case T.iClimb: ok = threaderClimbMove(stage)
        case T.iCoil: ok = threaderCoilMove(m, stage)
        case T.iRime: ok = threaderRimeMove(m, stage)
        case T.iSqueeze: ok = threaderSqueezeMove(stage)
        case T.iPull: ok = threaderPullMove(m, stage)
        case T.iCharge: ok = threaderChargeMove(m, stage)
        default: return false
        }
        // (a start that is «not now» comes again shortly: the strike's is the lure's, never retried)
        if stage == 0 && !ok && m >= 0 && m < 32 { T.retry |= 1 << UInt32(m) }
        return ok
    }

    /// The boss's own file holds it between moves (no exclusive move starts) / lets it go again.
    @inline(__always) func threaderHold(_ on: Bool) {
        let R = bossRT
        if on { if R.busy < 0 { R.busy = THREADER_HOLD } } else if R.busy == THREADER_HOLD { R.busy = -1 }
    }

    /// Its own move `m` is over now (its maneuver done): the runner ends it on the next tick.
    @inline(__always) func threaderEndMove(_ m: Int) {
        if m >= 0 && m < BOSS_MOVES && bossRT.stage[m] == 2 { bossRT.timer[m] = 0 }
    }

    // ---------------------------------------------------------------- the head on the route graph

    /// The cost from node `n` to the point `gs` m along edge `ge` (a table: roaming or true lengths).
    @inline(__always) func threaderCost(_ n: Int, _ ge: Int, _ gs: Float, _ D: [Float], _ G: OverheadGraph) -> Float {
        let N = thr.N
        return minf(D[n * N + G.ea[ge]] + gs, D[n * N + G.eb[ge]] + (G.length[ge] - gs))
    }

    /// The head walks toward the point `gs` m along edge `ge` at `speed` m/s (roaming or true costs); true when it is there.
    @discardableResult
    func threaderWalk(_ ge: Int, _ gs: Float, _ speed: Float, _ dt: Float, roam: Bool) -> Bool {
        let T = thr
        guard let G = level.overhead, T.onGraph, T.e >= 0, ge >= 0, ge < G.edgeCount else { return true }
        let D = roam ? T.distRoam : T.distTrue, H = roam ? T.hopRoam : T.hopTrue
        var budget = speed * dt
        var guardN = 6
        var arrived = false
        while budget > 1e-5 && guardN > 0 {
            guardN -= 1
            let len = G.length[T.e]
            if T.e == ge {
                let ds = gs - T.s
                if absf(ds) <= budget { T.s = gs; arrived = true; break }
                T.s += ds > 0 ? budget : -budget
                budget = 0
                break
            }
            // out through the end that is cheaper to the goal
            let a = G.ea[T.e], b = G.eb[T.e]
            let viaA = T.s + threaderCost(a, ge, gs, D, G), viaB = (len - T.s) + threaderCost(b, ge, gs, D, G)
            var toB = viaB < viaA
            // (a tie: on along the edge, away from the end it stands at — its path goes across this edge)
            if absf(viaB - viaA) < 1e-3 { toB = T.s < len * 0.5 }
            let left = toB ? len - T.s : T.s
            if left > budget { T.s += toB ? budget : -budget; budget = 0; break }
            budget -= left
            let n = toB ? b : a
            // at node n: onto the goal's edge if it is here, else the next edge of the cheapest path
            if G.ea[ge] == n || G.eb[ge] == n { T.e = ge; T.s = G.ea[ge] == n ? 0 : G.length[ge]; continue }
            let N = T.N
            let ca = D[n * N + G.ea[ge]] + gs, cb = D[n * N + G.eb[ge]] + (G.length[ge] - gs)
            let hop = Int(ca <= cb ? H[n * N + G.ea[ge]] : H[n * N + G.eb[ge]])
            if hop < 0 { arrived = true; break }
            T.e = hop; T.s = G.ea[hop] == n ? 0 : G.length[hop]
        }
        let p = G.point(T.e, T.s)
        bossSetHead(p.x, p.y, p.z)
        return arrived
    }

    /// The trunk point nearest to (x, z) in plan (an edge and the metres along it; a fallen trunk's edges and the risers' stubs
    /// left out), `back` m toward the head along that edge; nil when there is none.
    func threaderTrunkPoint(_ x: Float, _ z: Float, back: Float) -> (e: Int, s: Float)? {
        let T = thr
        guard let G = level.overhead else { return nil }
        var best = -1
        var bs: Float = 0
        var bd: Float = .infinity
        for e in 0..<G.edgeCount where T.edgeTrunk[e] >= 0 && !G.isBlocked(e) {
            let pr = G.project(e, x, z)
            if pr.d2 < bd { bd = pr.d2; best = e; bs = pr.s }
        }
        if best < 0 { return nil }
        if back > 0 && T.e >= 0 {
            // (from the side the head is on: it hunts from a little way off, so its beam can reach)
            let hp = G.point(T.e, T.s), a = G.nodePos(G.ea[best]), b = G.nodePos(G.eb[best])
            let len = G.length[best]
            let ux = (b.x - a.x) / len, uz = (b.z - a.z) / len
            let side: Float = (hp.x - (a.x + ux * bs)) * ux + (hp.z - (a.z + uz * bs)) * uz >= 0 ? 1 : -1
            bs = clampf(bs + side * back, 0, len)
        }
        return (best, bs)
    }

    // ---------------------------------------------------------------- hunting the racks

    /// Roaming: toward the trunk point near its marine (fast while far, creeping while near), the lure sweeping.
    func threaderRoam(_ dt: Float) {
        let T = thr
        T.mode = .roam
        threaderHold(false)
        guard T.onGraph else { T.mode = .deck; return }
        T.targetT -= dt
        if T.targetT <= 0 || T.target < 0 || marines[T.target].downed {
            T.targetT = 2.5
            T.target = threaderNearestMarine(boss.position.x, boss.position.y)
        }
        if T.target < 0 { return }
        let m = marines[T.target]
        guard let g = threaderTrunkPoint(m.x, m.z, back: 3) else { return }
        let hp = level.overhead!.point(T.e, T.s), gp = level.overhead!.point(g.e, g.s)
        let far = hypotf2(gp.x - hp.x, gp.z - hp.z) > 3.5 || T.e != g.e
        let v = bossSpec.speed * bossSpec.phases[boss.phase].speedK * (far ? 1 : 0.25)
        threaderWalk(g.e, g.s, v, dt, roam: true)
    }

    /// The nearest standing marine to (x, z) in plan (-1 none).
    func threaderNearestMarine(_ x: Float, _ z: Float) -> Int {
        var best = -1
        var bd: Float = .infinity
        for m in marines where !m.downed {
            let d = (m.x - x) * (m.x - x) + (m.z - z) * (m.z - z)
            if d < bd { bd = d; best = m.index }
        }
        return best
    }

    // ---------------------------------------------------------------- the lure

    /// The lure: its lit spot sweeps the deck in slow arcs round the head (toward its marine), faster and closer after a long
    /// hunt; a marine in it gathers light, out of it the light ebbs; THREADER_LOCK s of it locks the beam — the strike.
    /// P3: it points ahead along the head's path. Off while it climbs, spits, squeezes, pulls or coils.
    func threaderLure(_ dt: Float) {
        let T = thr, R = bossRT
        let hx = R.headX, hz = R.headZ
        T.lantern = SIMD3(hx, R.headY - 0.9, hz)
        let striking = T.mode == .strike
        let on = T.mode == .roam || T.mode == .duct || T.mode == .climb || T.mode == .deck || T.mode == .charge || striking
        T.lureOn = on
        if !on {
            T.locked = -1
            for k in 0..<4 { T.exposure[k] = maxf(0, T.exposure[k] - 2 * dt) }
            return
        }
        if striking {
            // locked: the beam stays on the strike's ring, hot white
            T.lx = T.px; T.lz = T.pz; T.lr = THREADER_LURE_R
            return
        }
        T.locked = -1
        let deck = T.mode == .deck || T.mode == .charge
        if deck {
            // P3: along the path, a short cone ahead of the head
            let fx = sinf2(R.headHd), fz = cosf2(R.headHd)
            T.lx = hx + fx * 3.6; T.lz = hz + fz * 3.6; T.lr = 2.2
        } else {
            let tgt = T.target >= 0 ? marines[T.target] : nil
            T.noLock += dt
            let hunt = T.noLock > 9
            let center: Float = tgt.map { atan2f2($0.x - hx, $0.z - hz) } ?? R.headHd
            let dist: Float = tgt.map { hypotf2($0.x - hx, $0.z - hz) } ?? 4
            T.sweep += dt * (hunt ? 0.62 : 0.32)
            let tri = 4 * absf(T.sweep - T.sweep.rounded(.down) - 0.5) - 1
            let amp: Float = hunt ? 0.45 : 1.15
            T.ang = center + amp * tri
            let up = T.mode == .duct || T.mode == .climb
            let want = clampf(dist, 2.5, up ? 8.5 : 6.5)
            T.arc += (want - T.arc) * minf(1, dt * (hunt ? 2.5 : 0.8))
            T.lx = hx + sinf2(T.ang) * T.arc; T.lz = hz + cosf2(T.ang) * T.arc
            T.lr = hunt ? 2.7 : THREADER_LURE_R
        }
        // light on the marines
        let r2 = T.lr * T.lr
        var lockOn = -1
        var lmax: Float = 0
        for m in marines {
            let k = m.index
            if m.downed { T.exposure[k] = 0; continue }
            let dx = m.x - T.lx, dz = m.z - T.lz
            if dx * dx + dz * dz <= r2 { T.exposure[k] += dt } else { T.exposure[k] = maxf(0, T.exposure[k] - 1.2 * dt) }
            if T.exposure[k] >= THREADER_LOCK && T.exposure[k] > lmax { lmax = T.exposure[k]; lockOn = k }
        }
        if lockOn < 0 || boss.untouchable > 0 || boss.stagger > 0 || T.mode == .duct || T.mode == .climb || T.mode == .charge { return }
        if T.lockGap > 0 { return }
        if R.busy >= 0 { return }
        let mv = deck ? T.iStrikeLow : T.iStrike
        if mv < 0 || R.stage[mv] != 0 || (deck && T.lowCd > 0) { return }
        threaderLock(lockOn, mv, lead: deck ? 0.3 : 0.5)
    }

    /// The beam locks on marine `k`: the strike `mv` aims at its predicted place (a deck spot it can stand on) and starts now.
    func threaderLock(_ k: Int, _ mv: Int, lead: Float) {
        let T = thr, R = bossRT
        let m = marines[k]
        var ax = m.x + m.vx * lead, az = m.z + m.vz * lead
        if !level.canStand(ax, az) { ax = m.x; az = m.z }
        bossAimAt(ax, az)
        R.clock[mv] = 0
        T.locked = k; T.noLock = 0
        for j in 0..<4 { T.exposure[j] = 0 }
        T.stats.locks += 1
        emit(.bossCue(kind: .threader, cue: .lureLock, pos: Vec2(ax, az), value: k))
        if !T.saidLight { T.saidLight = true; toast(GameText(.toastThreaderLight), .warn) }
    }

    // ---------------------------------------------------------------- the strike

    func threaderStrikeMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr, R = bossRT
        switch stage {
        case 0:
            // (only out of the hunt, or the deck chase)
            if T.mode != .roam && T.mode != .deck && T.mode != .none { return false }
            T.bx = R.headX; T.by = R.headY; T.bz = R.headZ; T.sBack = R.headS
            T.px = R.ax[m]; T.pz = R.az[m]
            T.mode = .strike; T.t = 0
            return true
        case 1:
            // the head lands: the slam, a recoil out of the Pyro's fire
            let y = level.groundY(T.px, T.pz) + 0.5
            bossSetHead(T.px, y, T.pz)
            let hit0 = threaderMarinesIn(T.px, T.pz, THREADER_STRIKE_R + 0.42)
            bossStrike(m, bossSpec.moves[m])
            T.stats.strikes += 1
            if hit0 > 0 { T.stats.strikeHits += 1 }
            var down = THREADER_DOWN
            if threaderInNapalm(T.px, T.pz) {
                down += THREADER_RECOIL
                bossOpenWindow(0, down)
                T.stats.recoils += 1
                emit(.bossCue(kind: .threader, cue: .recoil, pos: Vec2(T.px, T.pz), value: 0))
            }
            T.mode = .down; T.t = 0; T.downLeft = down; T.lockExtended = false; T.winDmg = 0; T.pained = false
            T.lockGap = boss.phase >= 2 ? THREADER_LUNGE_GAP : THREADER_STRIKE_GAP
            threaderHold(true)
            emit(.bossCue(kind: .threader, cue: .strikeLand, pos: Vec2(T.px, T.pz), value: hit0))
            return true
        case 3:
            // a stagger broke the wind-up: back up if the head had started down, else on with the hunt
            if T.mode == .strike {
                let dropped = hypotf2(R.headX - T.bx, R.headZ - T.bz) > 0.2 || absf(R.headY - T.by) > 0.2
                if T.fallen >= 0 || !T.onGraph { T.mode = .deck } else { T.mode = dropped ? .recover : .roam }
                if T.mode == .recover { threaderHold(true) }
            }
            return true
        default:
            return true
        }
    }

    /// The wind-up: the head waits on its trunk, then drops onto the ring in its last moment (P3: lunges from low height).
    func threaderStrikeWind(_ dt: Float) {
        let T = thr, R = bossRT
        let m = boss.phase >= 2 ? T.iStrikeLow : T.iStrike
        guard m >= 0, R.stage[m] == 1 else { return }
        let drop: Float = boss.phase >= 2 ? 0.25 : 0.35
        let left = R.timer[m]
        if left > drop { return }
        let u = clampf(1 - left / drop, 0, 1)
        let ty = level.groundY(T.px, T.pz) + 0.5
        bossSetHead(T.bx + (T.px - T.bx) * u, T.by + (ty - T.by) * u * u, T.bz + (T.pz - T.bz) * u)
        if u > 0.05 && R.timer[m] + dt > drop { emit(.bossCue(kind: .threader, cue: .strikeDrop, pos: Vec2(T.px, T.pz), value: 0)) }
    }

    /// The head down (the punish window): it stays while the body is locked (a frozen part: the Cryo's), then pulls back up.
    func threaderDown(_ dt: Float) {
        let T = thr
        if boss.lock <= 0 { T.downLeft -= dt }
        if T.downLeft > 0 { return }
        if T.fallen >= 0 || !T.onGraph { T.mode = .deck; T.awayT = THREADER_AWAY; threaderHold(false); return }
        T.mode = .recover; T.t = 0
    }

    /// Pulling back up: the head goes back along its own path to where it left the trunk (the body slides back with it).
    func threaderRecover(_ dt: Float) {
        let T = thr
        threaderHold(true)
        if threaderRetract((T.pained ? 18 : 9) * dt, to: T.sBack) {
            T.mode = .roam; T.t = 0
            threaderHold(false)
            if T.onGraph, let G = level.overhead {
                let p = G.point(T.e, T.s)
                bossSetHead(p.x, p.y, p.z)
            }
        }
    }

    /// The head goes `ds` m back along its path history (no further than arc length `to`): the newer points are dropped, the
    /// body follows back. True once it is back at `to`.
    @discardableResult
    func threaderRetract(_ ds: Float, to: Float) -> Bool {
        let R = bossRT
        var target = R.headS - ds
        var done = false
        if target <= to { target = to; done = true }
        if R.hCount < 2 { return true }
        let (p, hd) = bossPathPoint(behind: R.headS - target)
        while R.hCount > 1 && R.hs[R.hHead] > target {
            R.hHead = (R.hHead - 1) & (BOSS_PATH - 1)
            R.hCount -= 1
        }
        R.headX = p.x; R.headY = p.y; R.headZ = p.z; R.headHd = hd; R.headS = target
        R.steered = true
        return done
    }

    // ---------------------------------------------------------------- the shed

    func threaderShedMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr
        switch stage {
        case 0:
            T.shedWarn = THREADER_SHED_WARN
            emit(.bossCue(kind: .threader, cue: .shed, pos: boss.position, value: 0))
        case 2:
            threaderShedTicks(bossSpec.moves[m].count)
        default: break
        }
        return true
    }

    /// 4…`maxN` ticks — R4's Droppers, smaller — drop along the body: up on a route they ride it (and drop like any Dropper),
    /// elsewhere they fall to the deck under them; the tier's live Dropper cap, the route cap and the swarm cap hold.
    func threaderShedTicks(_ maxN: Int) {
        let T = thr, R = bossRT, S = bugs
        let n = 4 + rng.int(max(1, maxN - 3))
        var made = 0
        for k in 0..<n {
            if droppersAlive + queuedRouteBugs(of: T_DROP) >= difficulty.dropperCap || capLeft() <= 0 { break }
            let q = 3 + Int((Float(k) * 14 / Float(max(1, n - 1))).rounded())
            if q >= R.parts { continue }
            let x = R.px[q], y = R.py[q], z = R.pz[q]
            var i = -1
            if let G = level.overhead, y - level.groundY(x, z) > BOSS_REACH, routeAlive < difficulty.routeCap {
                // on the route under the segment
                var be = -1
                var bs: Float = 0
                var bd: Float = 0.64
                for e in 0..<G.edgeCount where !T.edgeMouth[e] && !G.isBlocked(e) {
                    let pr = G.project(e, x, z)
                    if pr.d2 < bd && absf(G.point(e, pr.s).y - y) < 1.2 { bd = pr.d2; be = e; bs = pr.s }
                }
                if be >= 0 { i = threaderRouteTick(be, bs) }
            }
            if i < 0, let c = nearestDeck(x, z, 2.5, clearOfMarines: 1.0) {
                // off a route: it falls to the deck under it
                i = spawnBug(T_DROP, x, z, mode: 0)
                if i >= 0 {
                    S.rx[i] = x; S.ry[i] = y; S.rz[i] = z
                    S.ax[i] = c.x; S.az[i] = c.y; S.rs[i] = 0
                    S.st[i] = S_FALL; S.t[i] = fallTime(y - level.groundY(c.x, c.y)); S.re[i] = 0; S.up[i] = 1; S.y[i] = y
                    S.hit[i] = UInt8(bitPattern: Int8(-1))
                    typeAlive[Int(T_DROP)] += 1
                }
            }
            if i < 0 { continue }
            // (a tick: smaller and lighter than a Dropper sent up the routes)
            S.sc[i] *= 0.75; S.r[i] *= 0.8; S.hp[i] *= 0.6; S.hpMax[i] = S.hp[i]
            made += 1
        }
        T.stats.sheds += 1; T.stats.ticks += made
        if made > 0 { emit(.bossCue(kind: .threader, cue: .ticks, pos: boss.position, value: made)) }
    }

    /// A Dropper onto route edge `e`, `s` m along it (riding toward the squad). Its slot, -1 when the arrays are full.
    func threaderRouteTick(_ e: Int, _ s: Float) -> Int {
        guard let G = level.overhead else { return -1 }
        let p = G.point(e, s)
        let i = spawnBug(T_DROP, p.x, p.z, mode: 0)
        if i < 0 { return -1 }
        let S = bugs
        let c = squadCenter()
        let a = G.nodePos(G.ea[e]), b = G.nodePos(G.eb[e])
        let fwd = (b.x - a.x) * (c.x - p.x) + (b.z - a.z) * (c.y - p.z) >= 0
        S.re[i] = routeEnc(e, fwd); S.rs[i] = s
        S.up[i] = 1; S.vx[i] = 0; S.vz[i] = 0; S.t[i] = 0; S.mood[i] = M_CALM; S.mt[i] = 0; S.hit[i] = 0
        S.lt[i] = DROPPER_PATIENCE; S.rz[i] = 0
        S.st[i] = S_HIGH; S.y[i] = p.y; S.ax[i] = s; S.az[i] = 0
        S.hd[i] = atan2f2(fwd ? b.x - a.x : a.x - b.x, fwd ? b.z - a.z : a.z - b.z)
        typeAlive[Int(T_DROP)] += 1
        oh.stats.droppers += 1; oh.tickSpawns += 1; oh.stats.spawns += 1
        return i
    }

    // ---------------------------------------------------------------- the climb to the ring duct (P1)

    func threaderClimbMove(_ stage: Int) -> Bool {
        let T = thr
        guard let G = level.overhead else { return false }
        switch stage {
        case 0:
            if T.mode != .roam || !T.onGraph || T.e < 0 || T.edgeTrunk[T.e] < 0 { return false }
            // the riser pipe nearest along the trunks: its duct end
            var best = -1
            var bc: Float = .infinity
            for e in 0..<G.edgeCount where T.edgeConn[e] {
                let a = G.ea[e], b = G.eb[e]
                let top = G.nodePos(a).y > G.nodePos(b).y ? a : b
                let c = threaderCost(top, T.e, T.s, T.distTrue, G)
                if c < bc { bc = c; best = top }
            }
            if best < 0 { return false }
            T.ductGoal = best; T.ductBack = -1; T.ductT = 0
            T.mode = .climb; T.t = 0
            T.stats.climbs += 1
            emit(.bossCue(kind: .threader, cue: .climb, pos: boss.position, value: 0))
        case 2:
            // (the runner's time ran out: wherever it is, it hunts on)
            if T.mode == .climb || T.mode == .duct { T.mode = .roam }
        default: break
        }
        return true
    }

    /// Up the riser pipe, round the duct (untouchable, THREADER_DUCT_TIME s) to another trunk's riser pipe, down onto that trunk.
    func threaderClimb(_ dt: Float) {
        let T = thr
        guard let G = level.overhead, T.onGraph, T.ductGoal >= 0 else { T.mode = .roam; return }
        let v = bossSpec.speed * bossSpec.phases[boss.phase].speedK
        let ge = G.nodeEdges[T.ductGoal].first(where: { T.edgeDuct[$0] }) ?? G.nodeEdges[T.ductGoal][0]
        let gs: Float = G.ea[ge] == T.ductGoal ? 0 : G.length[ge]
        if T.ductBack < 0 {
            // on the way up / round the duct
            if threaderWalk(ge, gs, v, dt, roam: false) {
                if T.mode == .climb {
                    // up in the duct: untouchable while it goes round to another trunk's riser pipe
                    T.mode = .duct; T.ductT = 0
                    bossUntouchable(THREADER_DUCT_TIME + 0.4)
                    emit(.bossCue(kind: .threader, cue: .duct, pos: boss.position, value: 0))
                    T.ductGoal = threaderDuctExit(T.ductGoal)
                } else if T.ductT >= THREADER_DUCT_TIME {
                    // down its riser pipe to the leg below
                    for e in G.nodeEdges[T.ductGoal] where T.edgeConn[e] { T.ductBack = G.ea[e] == T.ductGoal ? G.eb[e] : G.ea[e] }
                    if T.ductBack < 0 { T.mode = .roam; threaderEndMove(T.iClimb) }
                    else { emit(.bossCue(kind: .threader, cue: .descend, pos: boss.position, value: 0)) }
                }
            }
            if T.mode == .duct { T.ductT += dt }
            return
        }
        let be = G.nodeEdges[T.ductBack].first(where: { T.edgeTrunk[$0] >= 0 }) ?? G.nodeEdges[T.ductBack][0]
        let bs: Float = G.ea[be] == T.ductBack ? 0 : G.length[be]
        if threaderWalk(be, bs, v, dt, roam: false) {
            T.mode = .roam; T.t = 0; T.ductBack = -1
            threaderEndMove(T.iClimb)
        }
    }

    /// The duct node of another trunk's riser pipe about THREADER_DUCT_TIME s round the duct from `from` (at the trunk speed).
    func threaderDuctExit(_ from: Int) -> Int {
        let T = thr
        guard let G = level.overhead else { return from }
        let want = bossSpec.speed * THREADER_DUCT_TIME * 0.95
        let fromTrunk = threaderTrunkOfDuct(from)
        var best = from
        var bd: Float = .infinity
        for e in 0..<G.edgeCount where T.edgeConn[e] {
            let a = G.ea[e], b = G.eb[e]
            let top = G.nodePos(a).y > G.nodePos(b).y ? a : b
            if top == from || threaderTrunkOfDuct(top) == fromTrunk { continue }
            let d = absf(T.distTrue[from * T.N + top] - want)
            if d < bd { bd = d; best = top }
        }
        return best
    }

    /// The trunk whose leg a duct node's riser pipe comes up from (-1 none).
    func threaderTrunkOfDuct(_ n: Int) -> Int {
        let T = thr
        guard let G = level.overhead else { return -1 }
        for e in G.nodeEdges[n] where T.edgeConn[e] {
            let leg = G.ea[e] == n ? G.eb[e] : G.ea[e]
            for f in G.nodeEdges[leg] where T.edgeTrunk[f] >= 0 { return Int(T.edgeTrunk[f]) }
        }
        return -1
    }

    // ---------------------------------------------------------------- the coil (P2)

    /// Seconds into the coil when the crush comes (the descent, the wrap, the shrink).
    var threaderCoilEnd: Float { 0.6 + 0.9 + THREADER_COIL_SHRINK }

    func threaderCoilMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr, R = bossRT
        switch stage {
        case 0:
            if T.mode != .roam { return false }
            // round the marine with the most squadmates near it (ties: the nearest to the head), on deck it can stand on
            var best = -1
            var bscore: Float = -1
            for m in marines where !m.downed && level.canStand(m.x, m.z) {
                var n: Float = 0
                for o in marines where !o.downed && hypotf2(o.x - m.x, o.z - m.z) < 3.2 { n += 1 }
                let d = hypotf2(m.x - R.headX, m.z - R.headZ)
                if d > 16 { continue }
                let sc = n * 100 - d
                if sc > bscore { bscore = sc; best = m.index }
            }
            if best < 0 { return false }
            let c = marines[best]
            // (its ring stays over the island: the centre no nearer its edge than the ring's radius)
            var ccx = c.x, ccz = c.z
            if let A = level.layout.manifold {
                ccx = clampf(ccx, A.island.x + THREADER_COIL_R, A.island.z - THREADER_COIL_R)
                ccz = clampf(ccz, A.island.y + THREADER_COIL_R, A.island.w - THREADER_COIL_R)
            }
            T.cx = ccx; T.cz = ccz; T.cy = level.groundY(ccx, ccz) + THREADER_COIL_Y; T.cr = THREADER_COIL_R
            T.ca0 = atan2f2(R.headX - ccx, R.headZ - ccz)
            T.csign = (best & 1) == 0 ? 1 : -1
            T.bx = R.headX; T.by = R.headY; T.bz = R.headZ; T.sBack = R.headS
            T.mode = .coil; T.t = 0; T.coilGap = -1; T.letGo = false; T.crushed = false; T.ringHead = -1; T.winDmg = 0; T.pained = false
            // (room for the ring's rewrites in the history: keep it under 400 points)
            if R.hCount > 400 { R.hCount = 400 }
            T.stats.coils += 1
            teleShape(.ring, ccx, ccz, r0: THREADER_COIL_R, color: SIMD3(1.0, 0.45, 0.12), life: 1.5, pulse: true)
            emit(.bossCue(kind: .threader, cue: .coil, pos: Vec2(ccx, ccz), value: best))
            toast(GameText(.toastThreaderCoil), .warn)
            return true
        case 2:
            // (the runner's time ran out: let go)
            if T.mode == .coil && !T.letGo && !T.crushed { T.letGo = true }
            return true
        default:
            return true
        }
    }

    /// The coil: down to its entry on the ring (0.6 s), round the ring once (0.9 s), the shrink (its ring rewritten on the path
    /// every tick at the shrinking radius), the crush; or it lets go; then back up its path to the trunk.
    func threaderCoil(_ dt: Float) {
        let T = thr, R = bossRT
        threaderHold(false)
        let ex = T.cx + sinf2(T.ca0) * THREADER_COIL_R, ez = T.cz + cosf2(T.ca0) * THREADER_COIL_R
        if T.letGo || T.crushed {
            // back up its path to the trunk
            // (after its pain it yanks itself out)
            if threaderRetract((T.pained ? 30 : 11) * dt, to: T.sBack) {
                T.mode = T.onGraph ? .roam : .deck; T.t = 0; T.ringHead = -1
                threaderEndMove(T.iCoil)
                if T.onGraph, let G = level.overhead { let p = G.point(T.e, T.s); bossSetHead(p.x, p.y, p.z) }
            }
            return
        }
        if T.t < 0.6 {
            let u = T.t / 0.6
            bossSetHead(T.bx + (ex - T.bx) * u, T.by + (T.cy - T.by) * u, T.bz + (ez - T.bz) * u)
            return
        }
        if T.ringHead < 0 {
            // the ring starts here: its entry point is pinned in the history
            bossSetHead(ex, T.cy, ez)
            bossPathRecord()
            bossPathPush(ex, T.cy, ez)
            R.headX = ex; R.headY = T.cy; R.headZ = ez; R.headS = R.hs[R.hHead]
            T.ringHead = R.hHead; T.ringCount = R.hCount
            teleShape(.drop, T.cx, T.cz, r0: THREADER_COIL_R, r1: THREADER_COIL_R_END, color: SIMD3(1.0, 0.45, 0.12),
                      life: 0.9 + THREADER_COIL_SHRINK)
        }
        if T.t < 1.5 {
            // the wrap: round the ring
            let a = T.ca0 + T.csign * TAU * minf(1, (T.t - 0.6) / 0.9)
            bossSetHead(T.cx + sinf2(a) * THREADER_COIL_R, T.cy, T.cz + cosf2(a) * THREADER_COIL_R)
            return
        }
        // the shrink
        let u = clampf((T.t - 1.5) / THREADER_COIL_SHRINK, 0, 1)
        T.cr = THREADER_COIL_R + (THREADER_COIL_R_END - THREADER_COIL_R) * smooth01(u)
        threaderRing(T.cr)
        threaderCoilGap()
        if u >= 1 { threaderCrush() }
    }

    /// The ring part of the path at radius `r`: from the ring's pinned entry round once to the head.
    func threaderRing(_ r: Float) {
        let T = thr, R = bossRT
        R.hHead = T.ringHead; R.hCount = T.ringCount
        let step = R.hStep / maxf(0.3, r)
        let n = Int((TAU / step).rounded(.down))
        var k = 0
        while k <= n {
            let a = T.ca0 + T.csign * Float(k) * step
            bossPathPush(T.cx + sinf2(a) * r, T.cy, T.cz + cosf2(a) * r)
            k += 1
        }
        let a = T.ca0 + T.csign * TAU
        let hx = T.cx + sinf2(a) * r, hz = T.cz + cosf2(a) * r
        let l = R.hHead
        R.headX = hx; R.headY = T.cy; R.headZ = hz
        R.headS = R.hs[l] + hypotf2(hx - R.hx[l], hz - R.hz[l])
        R.headHd = atan2f2(cosf2(a) * T.csign, -sinf2(a) * T.csign)
        R.steered = true
    }

    /// Two frozen ring segments open a gap there (their part of the ring lets go of the deck: no collision).
    func threaderCoilGap() {
        let T = thr, R = bossRT
        if T.coilGap >= 0 { return }
        let ringLen = TAU * T.cr
        var first = -1, n = 0
        var q = 1
        while q <= THREADER_SEGMENTS && q < R.parts {
            let behind = 2 + Float(q - 1) * 1.6
            if behind <= ringLen && R.frozen[q] > 0 { n += 1; if first < 0 { first = q } }
            q += 1
        }
        if n >= 2 {
            T.coilGap = first
            T.stats.gaps += 1
            emit(.bossCue(kind: .threader, cue: .coilGap, pos: Vec2(R.px[first], R.pz[first]), value: first))
        }
    }

    /// The crush: 25 × the damage multiplier to every marine still inside, knocked outward; the bugs inside die.
    func threaderCrush() {
        let T = thr
        T.crushed = true
        let rIn = T.cr + 0.6
        let dmg = THREADER_COIL_DMG * dmgMul
        for m in marines where !m.downed {
            let dx = m.x - T.cx, dz = m.z - T.cz, d = hypotf2(dx, dz)
            if d >= rIn { continue }
            let ux = d > 0.05 ? dx / d : 1, uz = d > 0.05 ? dz / d : 0
            hurtMarine(m, dmg, ux * 9, uz * 9, .threader)
            T.stats.crushed += 1
        }
        let S = bugs
        var i = 0
        while i < S.count {
            defer { i += 1 }
            if S.dead[i] != 0 || S.boss[i] != 0 || S.up[i] != 0 { continue }
            if hypotf2(S.x[i] - T.cx, S.z[i] - T.cz) < rIn + S.r[i] { hitBug(i, 1e6, -1) }
        }
        shake(0.35)
        emit(.bossCue(kind: .threader, cue: .coilCrush, pos: Vec2(T.cx, T.cz), value: 0))
    }

    /// It lets go before the crush (a grenade on a node).
    func threaderLetGo() {
        let T = thr
        if T.mode != .coil || T.letGo || T.crushed { return }
        T.letGo = true
        T.stats.letGo += 1
        for k in 0..<telegraphs.count where telegraphs[k].active && telegraphs[k].cause == .bossMove && telegraphs[k].shape == .drop
            && absf(telegraphs[k].x - T.cx) < 0.01 && absf(telegraphs[k].z - T.cz) < 0.01 {
            telegraphs[k].active = false
        }
        emit(.bossCue(kind: .threader, cue: .coilLetGo, pos: Vec2(T.cx, T.cz), value: 0))
    }

    // ---------------------------------------------------------------- rime spit (P2)

    /// The trunk with the most standing marines near its footprint (not `skip` unless it is the only one with any), ties to
    /// the one nearest the head; -1 when no marine is within 4 m of any trunk.
    func threaderBusiestTrunk(skip: Int, within: Float = 4) -> Int {
        guard let A = level.layout.manifold else { return -1 }
        let R = bossRT
        var best = -1
        var bs: Float = -1
        for (k, tr) in A.trunks.enumerated() where k != thr.fallen {
            var n: Float = 0
            for m in marines where !m.downed && tr.project(m.x, m.z).d < within { n += 1 }
            if n == 0 { continue }
            let sc = n * 100 - tr.project(R.headX, R.headZ).d - (k == skip ? 150 : 0)
            if sc > bs { bs = sc; best = k }
        }
        return best
    }

    func threaderRimeMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr, R = bossRT
        switch stage {
        case 0:
            if T.mode != .roam { return false }
            let k = threaderBusiestTrunk(skip: T.lastRime)
            guard k >= 0, let A = level.layout.manifold else { return false }
            let tr = A.trunks[k], d = tr.dir
            R.ax[m] = tr.a.x; R.az[m] = tr.a.y; R.adx[m] = d.x; R.adz[m] = d.y
            T.lastRime = k
            T.mode = .rime; T.t = 0
            T.stats.rimes += 1
            emit(.bossCue(kind: .threader, cue: .rimeSpit, pos: Vec2(R.headX, R.headZ), value: k))
        case 1:
            let hit0 = threaderLaneMarines(R.ax[m], R.az[m], R.adx[m], R.adz[m], bossSpec.moves[m].length, bossSpec.moves[m].radius * 0.5)
            bossStrike(m, bossSpec.moves[m])
            if hit0 > 0 { T.stats.rimeHits += 1 }
        case 2, 3:
            if T.mode == .rime { T.mode = T.onGraph ? .roam : .deck }
        default: break
        }
        return true
    }

    // ---------------------------------------------------------------- the squeeze (P2)

    func threaderSqueezeMove(_ stage: Int) -> Bool {
        let T = thr
        switch stage {
        case 0:
            if T.mode != .roam { return false }
            var k = threaderBusiestTrunk(skip: T.lastSqueeze)
            if k < 0, let A = level.layout.manifold {
                // nobody near a trunk: the one nearest the squad
                let c = squadCenter()
                k = A.nearestTrunk(c.x, c.y)
            }
            guard k >= 0, let A = level.layout.manifold else { return false }
            let tr = A.trunks[k]
            T.sqTrunk = k; T.sqT = 0; T.lastSqueeze = k
            // (its bursts run from the end nearer the head)
            T.sqFromB = hypotf2(tr.b.x - bossRT.headX, tr.b.y - bossRT.headZ) < hypotf2(tr.a.x - bossRT.headX, tr.a.y - bossRT.headZ)
            for j in 0..<4 { T.steamAcc[j] = 0 }
            T.mode = .squeeze; T.t = 0
            T.stats.squeezes += 1
            emit(.bossCue(kind: .threader, cue: .squeeze, pos: tr.point(tr.length * 0.5), value: k))
        case 2:
            if T.mode == .squeeze { T.mode = T.onGraph ? .roam : .deck; T.sqTrunk = -1 }
        default: break
        }
        return true
    }

    /// When burst `k` of `n` starts its warning (s into the squeeze): one after another, each when the last one vents.
    @inline(__always) func threaderBurstStart(_ k: Int, _ n: Int) -> Float { Float(k) * THREADER_SQUEEZE_WARN }

    /// Burst `k`'s curtain strip on the deck (from, to) along its trunk — in the squeeze's order (from the end nearer the head).
    func threaderBurstSpan(_ tr: ManifoldTrunk, _ k: Int, _ A: ManifoldArena) -> (Vec2, Vec2) {
        let n = tr.bursts.count
        let j = thr.sqFromB ? n - 1 - k : k
        let s = tr.bursts[max(0, min(n - 1, j))]
        return (tr.point(maxf(0, s - A.burstHalf)), tr.point(minf(tr.length, s + A.burstHalf)))
    }

    /// The squeeze's bursts: warnings (the steam lane and the gauge's amber ring), then the curtains — marines CURTAIN_MARINE_DPS
    /// (in 2.5 HP steps), deck bugs CURTAIN_BUG_DPS, bugs up on the trunk over a curtain scalded off it (dead).
    func threaderSqueeze(_ dt: Float) {
        let T = thr
        threaderHold(false)
        guard let A = level.layout.manifold, T.sqTrunk >= 0 else { T.mode = .roam; return }
        let tr = A.trunks[T.sqTrunk], n = tr.bursts.count
        let t0 = T.sqT
        T.sqT += dt
        for k in 0..<n {
            let ts = threaderBurstStart(k, n)
            let (a, b) = threaderBurstSpan(tr, k, A)
            if t0 < ts && T.sqT >= ts {
                let dx = b.x - a.x, dz = b.y - a.y, l = maxf(0.1, hypotf2(dx, dz))
                teleSteam(a.x, a.y, dx / l, dz / l, l, A.burstWidth * 2, THREADER_SQUEEZE_WARN, THREADER_SQUEEZE_VENT)
                let mid = Vec2((a.x + b.x) / 2, (a.y + b.y) / 2)
                teleRing(mid.x, mid.y, 0.6, 1.0, 0.45, 0.1, THREADER_SQUEEZE_WARN, r1: 1.6, pulse: true, cause: .steam)
                sound(.overheat, mid.x, mid.y)
                emit(.bossCue(kind: .threader, cue: .squeezeBurst, pos: mid, value: k))
            }
            let tv = ts + THREADER_SQUEEZE_WARN
            if t0 < tv && T.sqT >= tv { emit(.bossCue(kind: .threader, cue: .squeezeVent, pos: Vec2((a.x + b.x) / 2, (a.y + b.y) / 2), value: k)) }
            if T.sqT >= tv && T.sqT < tv + THREADER_SQUEEZE_VENT { threaderCurtain(a, b, A.burstWidth, tr, dt) }
        }
        let end = threaderBurstStart(n - 1, n) + THREADER_SQUEEZE_WARN + THREADER_SQUEEZE_VENT
        // the head holds the trunk while it crushes it (it walks to it first)
        if T.onGraph, boss.lock <= 0, boss.stagger <= 0, let G = level.overhead {
            var be = -1
            var bs: Float = 0
            var bd: Float = .infinity
            for e in tr.edges where e < G.edgeCount {
                let pr = G.project(e, bossRT.headX, bossRT.headZ)
                if pr.d2 < bd { bd = pr.d2; be = e; bs = pr.s }
            }
            if be >= 0 { threaderWalk(be, bs, bossSpec.speed, dt, roam: true) }
        }
        if T.sqT >= end {
            T.mode = T.onGraph ? .roam : .deck; T.sqTrunk = -1
            threaderEndMove(T.iSqueeze)
        }
    }

    /// One tick of a squeeze curtain on the strip a → b (half-width `w`).
    func threaderCurtain(_ a: Vec2, _ b: Vec2, _ w: Float, _ tr: ManifoldTrunk, _ dt: Float) {
        let T = thr, S = bugs
        let dx = b.x - a.x, dz = b.y - a.y, l2 = maxf(1e-4, dx * dx + dz * dz)
        @inline(__always) func dist(_ x: Float, _ z: Float) -> Float {
            let u = clampf(((x - a.x) * dx + (z - a.y) * dz) / l2, 0, 1)
            return hypotf2(x - (a.x + dx * u), z - (a.y + dz * u))
        }
        var i = 0
        while i < S.count {
            defer { i += 1 }
            if S.dead[i] != 0 || S.boss[i] != 0 { continue }
            let st = S.st[i]
            if st == S_FALL { continue }
            if (st >= S_HIGH && st != S_PIN) || S.up[i] != 0 {
                // up on the trunk over the curtain: scalded off it
                if dist(S.x[i], S.z[i]) < 1.0 && absf(S.y[i] - tr.y) < 1.2 { hitBug(i, 1e6, -1) }
            } else if dist(S.x[i], S.z[i]) <= w + S.r[i] * 0.5 && !(st == S_CLIMB && S.y[i] < -0.6) {
                hitBug(i, CURTAIN_BUG_DPS * dt, -1, true)
            }
        }
        for m in marines where !m.downed {
            let j = m.index
            if dist(m.x, m.z) > w { continue }
            T.steamAcc[j] += CURTAIN_MARINE_DPS * dt
            if T.steamAcc[j] >= 2.5 {
                let hp0 = m.hp
                hurtMarine(m, T.steamAcc[j], 0, 0, .threader)
                T.stats.steamHurt += maxf(0, hp0 - maxf(0, m.hp))
                T.steamAcc[j] = 0
            }
        }
    }

    // ---------------------------------------------------------------- pull down (P3)

    func threaderPullMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr
        switch stage {
        case 0:
            if T.mode != .roam && T.mode != .none { return false }
            guard let A = level.layout.manifold else {
                // (no trunks to pull: straight down to the deck chase)
                threaderToDeck(nil)
                return false
            }
            var k = threaderBusiestTrunk(skip: -1, within: 7)
            if k < 0 { let c = squadCenter(); k = A.nearestTrunk(c.x, c.y) }
            if k < 0 { return false }
            let tr = A.trunks[k], d = tr.dir
            T.pullTrunk = k
            T.mode = .pull; T.t = 0
            teleShape(.lane, tr.a.x, tr.a.y, dx: d.x, dz: d.y, len: tr.length, w: bossSpec.moves[m].radius, color: bossSpec.moves[m].color,
                      life: THREADER_PULL_WARN + 0.3, wind: THREADER_PULL_WARN)
            emit(.bossCue(kind: .threader, cue: .pullRip, pos: tr.point(tr.length * 0.5), value: k))
        case 2:
            if T.mode == .pull { threaderPullCrash() }
        default: break
        }
        return true
    }

    /// The warning: the head goes to the trunk's middle and rips it; then it crashes.
    func threaderPull(_ dt: Float) {
        let T = thr
        threaderHold(false)
        guard let A = level.layout.manifold, T.pullTrunk >= 0 else { T.mode = .deck; return }
        let tr = A.trunks[T.pullTrunk]
        if T.onGraph, let G = level.overhead, boss.stagger <= 0 {
            let mid = tr.point(tr.length * 0.5)
            var be = -1
            var bs: Float = 0
            var bd: Float = .infinity
            for e in tr.edges where e < G.edgeCount {
                let pr = G.project(e, mid.x, mid.y)
                if pr.d2 < bd { bd = pr.d2; be = e; bs = pr.s }
            }
            if be >= 0 { threaderWalk(be, bs, bossSpec.speed * bossSpec.phases[boss.phase].speedK, dt, roam: false) }
        }
        if T.t >= THREADER_PULL_WARN { threaderPullCrash() }
    }

    /// The trunk crashes across the deck: the lane's damage, the bugs under it crushed, the ones up on it knocked down, its
    /// routes gone, the walk grid changed (an obstacle on the island, its middle open; a bridge over the gaps); the body comes
    /// down onto the deck.
    func threaderPullCrash() {
        let T = thr
        guard let A = level.layout.manifold, T.pullTrunk >= 0 else { threaderToDeck(nil); return }
        let k = T.pullTrunk
        let tr = A.trunks[k], d = tr.dir
        let mv = T.iPull >= 0 ? bossSpec.moves[T.iPull] : BossMove("pull", .custom, first: 0, cooldown: 0)
        let half = mv.radius * 0.5
        // marines in the lane: the crash and the knock-down, sideways out of it
        for m in marines where !m.downed {
            let pr = tr.project(m.x, m.z)
            if pr.d > half { continue }
            let p = tr.point(pr.s)
            var nx = m.x - p.x, nz = m.z - p.y
            let l = hypotf2(nx, nz)
            if l < 0.05 { nx = -d.y; nz = d.x } else { nx /= l; nz /= l }
            hurtMarine(m, mv.damage * dmgMul, nx * mv.knockback, nz * mv.knockback, .threader)
        }
        // the bugs under it crushed, the ones up on its routes knocked down
        let S = bugs
        var i = 0
        while i < S.count {
            defer { i += 1 }
            if S.dead[i] != 0 || S.boss[i] != 0 { continue }
            if S.up[i] != 0 || S.st[i] >= S_HIGH {
                if S.st[i] == S_HIGH || S.st[i] == S_COIL || S.st[i] == S_PERCH || S.st[i] == S_RISER {
                    let (e, _) = routeDec(S.re[i])
                    if e >= 0 && e < T.edgeTrunk.count && T.edgeTrunk[e] == Int8(k) { knockDown(i, src: -1) }
                }
                continue
            }
            if tr.project(S.x[i], S.z[i]).d < half + S.r[i] { hitBug(i, 1e6, -1) }
        }
        // its routes
        if let G = level.overhead { for e in tr.edges where e < G.edgeCount { G.setBlocked(e) } }
        // the walk grid: island cells under it blocked (its snapped middle open), the abyss cells over the gaps a bridge
        threaderFallTrunk(tr, A)
        T.fallen = k; T.pullTrunk = -1
        T.stats.pulls += 1
        shake(0.6)
        emit(.bossCue(kind: .threader, cue: .pullCrash, pos: tr.point(tr.length * 0.5), value: k))
        threaderToDeck(tr)
        threaderEndMove(T.iPull)
    }

    /// The fallen trunk in the walk grid (the cells whose centre its line passes through): on the island a 1-cell obstacle
    /// with its snapped middle (`pullGap`) open, over the abyss gaps a 1-cell bridge; marines left inside the obstacle step out.
    func threaderFallTrunk(_ tr: ManifoldTrunk, _ A: ManifoldArena) {
        let L = level
        var s: Float = 0.5
        let len = tr.length
        var last = -1
        while s < len {
            let p = tr.point(s)
            s += 0.5
            let c = L.cellOf(p.x, p.y)
            if c < 0 || c == last { continue }
            last = c
            let cx = Level.cellX(c), cz = Level.cellZ(c)
            let w = L.walkValue(c)
            if A.onIsland(cx, cz) {
                let along = (cx - A.center.x) * tr.dir.x + (cz - A.center.y) * tr.dir.y
                if absf(along) < A.pullGap { continue }
                if w == 1 { L.setDynamicCell(c, walk: 2) }
            } else if w == 0 {
                // (between the island and the ring: a bridge at the deck's height)
                let ring = absf(cx - A.center.x) > A.ringOut || absf(cz - A.center.y) > A.ringOut
                if !ring { L.setDynamicCell(c, walk: 1, height: L.groundY(cx, cz)) }
            }
        }
        // marines inside a cell that is solid now: out to the nearest one they can stand on
        for m in marines where !L.canStand(m.x, m.z) {
            if let p = nearestDeck(m.x, m.z, 3, clearOfMarines: 0) { m.x = p.x; m.z = p.y; m.px = m.x; m.pz = m.z }
        }
        objFlowKey = (Int.min, Int.min)
        flowTimer = 0
    }

    /// The body comes down onto the deck: along the fallen trunk `tr` (the head at its point nearest the squad, on the island),
    /// or where it is; the deck chase begins.
    func threaderToDeck(_ tr: ManifoldTrunk?) {
        let T = thr, R = bossRT
        T.onGraph = false; T.e = -1
        T.mode = .deck; T.t = 0
        T.lockGap = maxf(T.lockGap, THREADER_DECK_GAP)
        threaderHold(false)
        guard let t = tr, let A = level.layout.manifold else {
            let y = level.groundY(R.headX, R.headZ) + 0.6
            bossSetHead(R.headX, y, R.headZ)
            T.hd = R.headHd
            return
        }
        let c = squadCenter()
        var s = t.project(c.x, c.y).s
        // (the head on the island part, the body along the trunk toward its farther end)
        let lo = t.project(A.island.x + 0.5, A.island.y + 0.5).s, hi = t.project(A.island.z - 0.5, A.island.w - 0.5).s
        s = clampf(s, minf(lo, hi), maxf(lo, hi))
        let toB = s < t.length * 0.5
        let d = t.dir, sgn: Float = toB ? 1 : -1
        let body: Float = 2 + Float(THREADER_SEGMENTS) * 1.6 + 6
        let head = t.point(s)
        // the history: from the tail end along the trunk to the head, at the deck's height (+0.6)
        R.hHead = -1; R.hCount = 0
        var u = body
        while u >= 0 {
            let x = head.x + d.x * sgn * u, z = head.y + d.y * sgn * u
            bossPathPush(x, level.groundY(x, z) + 0.6, z)
            u -= R.hStep
        }
        let hy = level.groundY(head.x, head.y) + 0.6
        R.headX = head.x; R.headY = hy; R.headZ = head.y; R.headS = R.hs[R.hHead]
        R.headHd = atan2f2(-d.x * sgn, -d.y * sgn); R.steered = true
        T.hd = R.headHd
        T.awayT = THREADER_AWAY
        threaderRingFlow()
        emit(.bossCue(kind: .threader, cue: .deckDrop, pos: head, value: 0))
    }

    /// The point `a` rad round the arena's square ring (its middle line `r` m out), from its centre.
    func threaderSquare(_ a: Float, _ r: Float, _ A: ManifoldArena) -> Vec2 {
        let sx = sinf2(a), cz = cosf2(a), m = maxf(absf(sx), absf(cz))
        return Vec2(A.center.x + sx / m * r, A.center.y + cz / m * r)
    }

    /// The flow field toward the ring's middle line on the walk grid as it is now (after the pull-down: its bridge).
    func threaderRingFlow() {
        let T = thr
        guard let A = level.layout.manifold else { T.ringReady = false; return }
        if T.ringSrc.isEmpty {
            let r = (A.ringIn + A.ringOut) * 0.5
            T.ringSrc.reserveCapacity(128)
            for k in 0..<64 { let p = threaderSquare(Float(k) / 64 * TAU, r, A); T.ringSrc.append(p.x); T.ringSrc.append(p.y) }
        }
        let lv = level, q = flowQueue, f = T.ringFlow
        T.ringSrc.withUnsafeBufferPointer { f.compute(level: lv, sources: $0, queue: q) }
        T.ringReady = true
    }

    /// P3 keeping away: the heading out to the ring (its flow field), then round it its own way.
    func threaderAwayHeading() -> Float {
        let T = thr, R = bossRT
        guard let A = level.layout.manifold, T.ringReady else {
            let c = squadCenter()
            return atan2f2(R.headX - c.x, R.headZ - c.y)
        }
        let c = level.cellOf(R.headX, R.headZ)
        let d = T.ringFlow.distance(c)
        if d > 1 && d < FlowField.unreachable {
            let f = T.ringFlow.direction(c)
            if f.x != 0 || f.y != 0 { return atan2f2(f.x, f.y) }
        }
        let a = atan2f2(R.headX - A.center.x, R.headZ - A.center.y)
        let p = threaderSquare(a + T.csign * 0.35, (A.ringIn + A.ringOut) * 0.5, A)
        return atan2f2(p.x - R.headX, p.y - R.headZ)
    }

    /// The lunge (strikeLow) on a marine within `range` m when it may strike again. True when it started.
    @discardableResult
    func threaderTryLunge(_ range: Float = 4) -> Bool {
        let T = thr, R = bossRT
        guard T.iStrikeLow >= 0, T.lowCd <= 0, T.lockGap <= 0, R.busy < 0, R.stage[T.iStrikeLow] == 0, boss.stagger <= 0 else { return false }
        let k = threaderNearestMarine(R.headX, R.headZ)
        if k < 0 || hypotf2(marines[k].x - R.headX, marines[k].z - R.headZ) >= range { return false }
        T.lowCd = THREADER_LUNGE_GAP
        threaderLock(k, T.iStrikeLow, lead: 0.3)
        return true
    }

    // ---------------------------------------------------------------- the deck chase (P3)

    /// On the deck: after the crash, a charge or a lunge it keeps away for THREADER_AWAY s — out to the ring and round it (its
    /// charges come from there); then after its marine (straight in, or the swarm's flow field from further off), turning at
    /// most 2.5 rad/s, at deck height; the lunge (strikeLow) at a marine within 4 m.
    func threaderDeck(_ dt: Float) {
        let T = thr, R = bossRT
        T.mode = .deck
        let v = bossSpec.speed * bossSpec.phases[boss.phase].speedK * 0.55
        if T.awayT > 0 {
            T.awayT -= dt
            threaderSlither(threaderAwayHeading(), v * 1.2, 2.5, dt)
            return
        }
        T.targetT -= dt
        if T.targetT <= 0 || T.target < 0 || marines[T.target].downed {
            T.targetT = 2; T.target = threaderNearestMarine(R.headX, R.headZ)
        }
        if T.target < 0 { return }
        let m = marines[T.target]
        let dx = m.x - R.headX, dz = m.z - R.headZ, dist = hypotf2(dx, dz)
        // the lunge: strikeLow on a marine close in
        if threaderTryLunge() { return }
        var want = atan2f2(dx, dz)
        if dist > 6 {
            let c = level.cellOf(R.headX, R.headZ)
            if c >= 0 && (swarmFlow.x[c] != 0 || swarmFlow.z[c] != 0) { want = atan2f2(swarmFlow.x[c], swarmFlow.z[c]) }
        }
        if dist < 1.6 { return }
        threaderSlither(want, v, 2.5, dt)
    }

    /// The head on the deck turns toward `want` (at most `turn` rad/s) and moves `v` m/s if open deck goes on there — round the
    /// pump housing and its own fallen trunk (through the trunk's snapped middle), over the bridges — else it tries a little to
    /// either side, else it turns on the spot; a head on a blocked cell (the trunk it fell along) may step off it. True when it
    /// moved.
    @discardableResult
    func threaderSlither(_ want: Float, _ v: Float, _ turn: Float, _ dt: Float) -> Bool {
        let T = thr, R = bossRT, L = level
        T.hd += clampf(angDiff(T.hd, want), -turn * dt, turn * dt)
        let step = v * dt
        let here = L.walkable(R.headX, R.headZ)
        for k in 0..<5 {
            let off: Float = k == 0 ? 0 : (k % 2 == 1 ? 1 : -1) * Float((k + 1) / 2) * 0.55
            let a = T.hd + off
            let nx = R.headX + sinf2(a) * step, nz = R.headZ + cosf2(a) * step
            if (L.walkable(nx, nz) || (!here && L.solid(nx, nz))) && L.walkable(nx + sinf2(a) * 0.8, nz + cosf2(a) * 0.8) {
                if k > 0 { T.hd = a }
                bossSetHead(nx, level.groundY(nx, nz) + 0.6, nz)
                return true
            }
        }
        return false
    }

    func threaderChargeMove(_ m: Int, _ stage: Int) -> Bool {
        let T = thr, R = bossRT
        switch stage {
        case 0:
            if T.mode != .deck { return false }
            let k = threaderNearestMarine(R.headX, R.headZ)
            if k < 0 { return false }
            let mm = marines[k]
            let dx = mm.x - R.headX, dz = mm.z - R.headZ, d = hypotf2(dx, dz)
            if d < 5 || d > 20 { return false }
            R.ax[m] = R.headX; R.az[m] = R.headZ; R.adx[m] = dx / d; R.adz[m] = dz / d
            T.target = k; T.hd = atan2f2(dx, dz)
            T.mode = .charge; T.t = 0; T.chargeHit = 0
            emit(.bossCue(kind: .threader, cue: .charge, pos: Vec2(R.headX, R.headZ), value: k))
        case 1:
            T.t = 0; T.chargeHit = 0
            T.stats.charges += 1
        case 2, 3:
            // (over: a lunge at a marine close by, else away to the ring again)
            if T.mode == .charge { T.mode = .deck; if !threaderTryLunge(6.5) { T.awayT = THREADER_AWAY } }
        default: break
        }
        return true
    }

    /// The charge: the wind-up (the beam along its path), then 12 m/s for the move's active time, curving after its marine
    /// (≤ 1.8 rad/s); a marine it runs into is hit once (the knock-down); the deck's end stops it.
    func threaderCharge(_ dt: Float) {
        let T = thr, R = bossRT
        let m = T.iCharge
        guard m >= 0 else { T.mode = .deck; return }
        if R.stage[m] == 1 {
            // the wind-up: it turns toward its marine behind the beam
            if T.target >= 0 && !marines[T.target].downed {
                let mm = marines[T.target]
                T.hd += clampf(angDiff(T.hd, atan2f2(mm.x - R.headX, mm.z - R.headZ)), -2 * dt, 2 * dt)
            }
            return
        }
        if R.stage[m] != 2 { T.mode = .deck; return }
        var want = T.hd
        if T.target >= 0 && !marines[T.target].downed {
            let mm = marines[T.target]
            want = atan2f2(mm.x - R.headX, mm.z - R.headZ)
        }
        // (the abyss in the way: the swarm's flow finds the bridge — the charge curves along its path)
        if !level.walkable(R.headX + sinf2(want) * 2, R.headZ + cosf2(want) * 2) {
            let c = level.cellOf(R.headX, R.headZ)
            if c >= 0 && (swarmFlow.x[c] != 0 || swarmFlow.z[c] != 0) { want = atan2f2(swarmFlow.x[c], swarmFlow.z[c]) }
        }
        let mv = bossSpec.moves[m]
        if !threaderSlither(want, 12, 1.8, dt) { threaderEndMove(m); T.mode = .deck; return }
        for mm in marines where !mm.downed && (T.chargeHit & UInt8(1 << mm.index)) == 0 {
            let dx = mm.x - R.headX, dz = mm.z - R.headZ, d = hypotf2(dx, dz)
            if d > 1.6 { continue }
            T.chargeHit |= UInt8(1 << mm.index)
            let fx = sinf2(T.hd), fz = cosf2(T.hd)
            var sx = -fz, sz = fx
            if dx * sx + dz * sz < 0 { sx = -sx; sz = -sz }
            hurtMarine(mm, mv.damage * dmgMul, (sx * 0.8 + fx * 0.6) * mv.knockback, (sz * 0.8 + fz * 0.6) * mv.knockback, .threader)
            T.stats.chargeHits += 1
        }
    }

    // ---------------------------------------------------------------- parts, blasts, damage (the framework's hooks)

    /// A part's pool was spent (a node popped: dark, its scream and stagger come from the spec) or a part froze (the body locks:
    /// the nodes stay where they are, the head down stays down — its ×2 window ends on time; a lock does not come again within
    /// 6 s of the last one's end).
    func threaderOwnPart(_ p: Int, popped: Bool) {
        let T = thr, R = bossRT
        if popped {
            T.stats.popped += 1
            emit(.bossCue(kind: .threader, cue: .scream, pos: Vec2(R.px[p], R.pz[p]), value: p))
            return
        }
        if T.lockCd > 0 {
            // too soon after the last lock: ice on the part, no lock
            boss.lock = T.lockPrev
            return
        }
        T.lockCd = bossSpec.immune.freezeLock + 6
        T.stats.freezeLocks += 1
    }

    /// One of the squad's blasts struck part `p` (GameSwarm.processBooms, GameOverhead.overheadBlast): a grenade on a node
    /// makes the coil let go.
    func threaderOwnBlast(_ p: Int, _ kind: ExplosionKind, _ src: Int) {
        let T = thr, R = bossRT
        guard T.mode == .coil, !T.letGo, !T.crushed, p >= 0, p < R.parts, R.role[p] == UInt8(BossPartRole.node.rawValue) else { return }
        if (kind == .frag || kind == .mini) && src >= 0 && src < 4 { threaderLetGo() }
    }

    /// The boss bar took `d` through part `p` (bossPartHit): the calibration's share by part, an Ice Wave's brittle counted.
    func threaderOwnDamage(_ p: Int, _ d: Float) {
        let T = thr, R = bossRT
        switch R.role[p] {
        case UInt8(BossPartRole.head.rawValue): T.stats.dmgHead += d
        case UInt8(BossPartRole.node.rawValue): T.stats.dmgNode += d
        default: T.stats.dmgBody += d
        }
        // (pain: THREADER_WINDOW_CAP of its health in one exposure — a punish window and its way back up, a coil and its
        // retreat — and it screams: the head pulls back up, the coil lets go, the ice on it breaks)
        if !T.pained && (T.mode == .down || T.mode == .recover || T.mode == .coil) {
            T.winDmg += d
            let h = bossPartSlot(0)
            if h >= 0 && T.winDmg >= THREADER_WINDOW_CAP * bugs.hpMax[h] {
                T.pained = true
                T.stats.pains += 1
                let coil = T.mode == .coil
                if T.mode == .down { if R.parts > 0 { R.down[0] = 0 }; T.downLeft = 0 }
                if coil { threaderLetGo() }
                boss.lock = 0
                emit(.bossCue(kind: .threader, cue: .pain, pos: Vec2(R.headX, R.headZ), value: coil ? 1 : 0))
            }
        }
        switch boss.phase {
        case 0: T.stats.dmgP1 += d
        case 1: T.stats.dmgP2 += d
        default: T.stats.dmgP3 += d
        }
    }

    /// The warning (GameBoss.bossWarn): «Something big in the pipes.»
    func threaderOwnWarn() {
        toast(GameText(.toastThreaderPipes), .warn)
    }

    // ---------------------------------------------------------------- the squad and the parts

    /// Marines and its low parts: a marine walking into a part (≤ 2.2 m above the deck) is pushed back out — the coil's ring
    /// keeps them in; a dash goes through (its gap is open where two segments froze).
    func threaderCollide() {
        let T = thr, R = bossRT, L = level
        let n = R.parts
        if n == 0 { return }
        for m in marines where !m.downed && m.dashT <= 0 {
            var q = 0
            while q < n {
                defer { q += 1 }
                if T.mode == .coil && T.coilGap >= 0 && q >= T.coilGap - 1 && q <= T.coilGap + 1 { continue }
                let py = R.py[q]
                if py - L.groundY(R.px[q], R.pz[q]) > 2.2 { continue }
                let rr: Float = (q == 0 ? 1.1 : (R.role[q] == UInt8(BossPartRole.node.rawValue) ? 0.55 : 0.75)) + 0.32
                let dx = m.x - R.px[q], dz = m.z - R.pz[q], d2 = dx * dx + dz * dz
                if d2 >= rr * rr { continue }
                let d = d2.squareRoot()
                var ux = dx, uz = dz
                if d < 1e-3 { ux = cosf2(R.phd[q]); uz = -sinf2(R.phd[q]) } else { ux /= d; uz /= d }
                let nx = R.px[q] + ux * rr, nz = R.pz[q] + uz * rr
                if L.canStand(nx, nz) { m.x = nx; m.z = nz }
                else if L.canStand(m.x + ux * (rr - d), m.z) { m.x += ux * (rr - d) }
                else if L.canStand(m.x, m.z + uz * (rr - d)) { m.z += uz * (rr - d) }
            }
        }
    }

    /// The torch strips a node's frost plates: 1 s of a Pyro's flame on it (its cone, in plan — up there too) and it takes
    /// × 1.25 for the whole squad from then on («Node's open!»).
    func threaderTorch(_ dt: Float) {
        let T = thr, R = bossRT
        for m in marines where m.cls == .pyro && m.firing && !m.downed {
            let C = m.spec, md = m.mods
            let range = C.range * md.range, cosC = cosf2(C.cone * md.cone)
            let ox = m.x + m.ax * 0.7, oz = m.z + m.az * 0.7
            var q = 1 + THREADER_SEGMENTS
            while q < R.parts {
                defer { q += 1 }
                if T.stripped[q] || R.popped[q] { continue }
                let dx = R.px[q] - ox, dz = R.pz[q] - oz, d = hypotf2(dx, dz) + 1e-4
                if d > range + 0.55 || (d > 0.9 && (dx * m.ax + dz * m.az) / d < cosC) { continue }
                T.strip[q] += dt
                if T.strip[q] >= 1 {
                    T.stripped[q] = true
                    T.stats.stripped += 1
                    emit(.bossCue(kind: .threader, cue: .plateStrip, pos: Vec2(R.px[q], R.pz[q]), value: q))
                    toast(GameText(.toastThreaderNode), .gold)
                }
            }
        }
    }

    /// The armour (`BossRuntime.bonus`): the head up on the trunks and not down × THREADER_HEAD_UP; the nodes' frost plates —
    /// up on the trunks in P1 / P2 a node takes × THREADER_PLATED, exposed when low (within the deck's reach) or from P3 on;
    /// once the torch stripped it, × 1.25 more for the whole squad (design).
    func threaderNodes() {
        let T = thr, R = bossRT
        if R.parts > 0 { R.bonus[0] = R.up[0] && R.down[0] <= 0 ? THREADER_HEAD_UP : 1 }
        // (frost-plated: the torch hurts a part while it plays on it, nothing of it burns on — B1's parts never tick a burn)
        var p = 0
        while p < R.parts { let b = bossPartSlot(p); if b >= 0 { bugs.burn[b] = 0 }; p += 1 }
        var q = 1 + THREADER_SEGMENTS
        while q < R.parts {
            let exposed = !R.up[q] || boss.phase >= 2
            R.bonus[q] = (exposed ? 1 : THREADER_PLATED) * (T.stripped[q] ? 1.25 : 1)
            q += 1
        }
    }

    /// P2 and P3: a duct mouth pours a pack every 15–19 s (R4's rattle first; the nearest open one to the squad).
    func threaderPacks(_ dt: Float) {
        let T = thr
        if boss.phase < 1 || oh.ducts.isEmpty { return }
        T.packT -= dt
        if T.packT > 0 { return }
        T.packT = 15 + rng.next() * 4
        let c = squadCenter()
        var best = -1
        var bd: Float = .infinity
        for (k, d) in oh.ducts.enumerated() where d.open {
            let dd = hypotf2(d.pos.x - c.x, d.pos.z - c.y)
            if dd < bd { bd = dd; best = k }
        }
        if best < 0 { return }
        let D = difficulty
        let n = Int((3 * D.horde * (D.waves ? D.popK : 1) * streamK).rounded())
        if queueRoutePack(n, entry: oh.ducts[best].node, rate: 3, delay: DUCT_RATTLE) > 0 {
            T.stats.packs += 1
            emit(.bossCue(kind: .threader, cue: .packs, pos: Vec2(oh.ducts[best].pos.x, oh.ducts[best].pos.z), value: best))
        }
    }

    /// The seconds it spends out of reach, untouchable, down (calibration).
    func threaderAccount(_ dt: Float) {
        let T = thr, R = bossRT
        if boss.untouchable > 0 { T.stats.untouchT += dt }
        if T.mode == .down { T.stats.downT += dt } else if R.parts > 0 && R.up[0] { T.stats.upT += dt }
    }

    // ---------------------------------------------------------------- small queries

    /// Standing marines within `r` of (x, z).
    func threaderMarinesIn(_ x: Float, _ z: Float, _ r: Float) -> Int {
        var n = 0
        for m in marines where !m.downed && !(m.dashT > 0) && (m.x - x) * (m.x - x) + (m.z - z) * (m.z - z) < r * r { n += 1 }
        return n
    }

    /// Standing marines in the lane from (x, z) along (dx, dz), `len` long, `half` wide each side.
    func threaderLaneMarines(_ x: Float, _ z: Float, _ dx: Float, _ dz: Float, _ len: Float, _ half: Float) -> Int {
        var n = 0
        for m in marines where !m.downed && !(m.dashT > 0) {
            let ex = m.x - x, ez = m.z - z, t = ex * dx + ez * dz
            if t < -0.4 || t > len + 0.4 { continue }
            if absf(ex * dz - ez * dx) <= half + 0.42 { n += 1 }
        }
        return n
    }

    /// (x, z) inside a burning napalm ring's disc (the head drops into the Pyro's fire).
    func threaderInNapalm(_ x: Float, _ z: Float) -> Bool {
        for n in napalms where n.active && hypotf2(x - n.x, z - n.z) < n.r + 1.3 { return true }
        return false
    }
}
