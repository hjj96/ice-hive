import Foundation

// ================================================================
//  BOSS FRAMEWORK — the data (Stage 2 B1; design §1.5 «Tech: the boss
//  framework, built once», tech §5.1–5.4). A boss is a BossSpec row per
//  tier (`Difficulty`, Tuning.swift):
//    BODY      one swarm bug that walks and fights with its type's own AI
//              (the Queen: a brute's walk, bite and ram), or a CHAIN — a
//              head and N segments that follow the head's path history by
//              arc length, with nodes riding segments; every part is a
//              swarm slot with its own hit circle at its height
//    PHASES    HP thresholds; speed, cooldowns, the hive's answer and arena
//              hazards on entry
//    MOVES     telegraph shape (ring, fill, lane, cone sweep, beam line,
//              drop target), wind-up, active time, cooldown, damage,
//              knockback, adds; the boss's own file plays `.custom` ones
//    WEAK POINTS  per-part damage multipliers and pools, «down» windows,
//              struck from behind; IMMUNITIES (freeze, chill, the lift's
//              pulse); ARENA HOOKS (the hold's lock, the horde clock, the
//              trickle); REWARDS and the DEATH BLAST
//  The runtime is GameBoss.swift (GameBossBody.swift: the chain); each
//  boss's own file builds its rows and plays its custom moves
//  (GameQueen.swift). Plain data: nothing here allocates during a tick.
// ================================================================

/// The bosses. A new boss adds its case here, its `name`, a `BossSpec` row per tier (`Difficulty`, `Difficulty.boss(_:)`)
/// and its own file (the custom moves: `bossOwnTick` / `bossOwnMove` in GameBoss.swift switch over the kinds).
public enum BossKind: String, CaseIterable {
    case queen
    /// Stage 2 B4: the Threader (design §1.5), the boss of the Manifold — GameThreader.swift.
    case threader

    /// Its name in the objective line and the boss bar (catalog `name.bug.<kind>`).
    public var name: NameRef {
        switch self {
        case .queen: return .queen
        case .threader: return .threader
        }
    }
}

// ---------------------------------------------------------------- the body

/// What a part of a chain is (the renderer draws each role with its own mesh; the boss's file may treat them apart).
public enum BossPartRole: Int {
    case head, segment, node
}

/// One part of a chain body: its swarm slot's type, hit circle and draw scale, where it rides and how it takes damage.
public struct BossPartSpec: Equatable {
    public var role: BossPartRole
    /// The swarm type its slot stores (the creature type id the renderer draws; any `BugType` with its `BugSpec` row).
    public var type: BugType
    /// Hit circle radius (m) and draw scale.
    public var radius: Float
    public var scale: Float
    /// Height above the body's path point (m; a node hanging under its segment: negative).
    public var lift: Float
    /// A node: the segment it rides (1 = the first behind the head …); the head and the segments ignore it.
    public var segment: Int
    /// × the damage it takes (design §1.5, the Threader: head 1, body 0.25, nodes 1.5).
    public var damageK: Float
    /// × while a weak-point window is open on it (`bossOpenWindow`: the head ×2 while it is down).
    public var downK: Float
    /// × when struck from behind (the hit's direction within 60° of the part's heading); 1 = no directional weak point.
    public var rearK: Float
    /// Its own pool as a share of the boss's max HP (the Threader's nodes: 0.08); 0 = none. Damage to it still counts on
    /// the boss bar; once the pool is spent the part is popped.
    public var pool: Float
    /// × the damage once its pool is spent (a popped node, dark).
    public var poppedK: Float
    /// The boss staggers this long when its pool is spent (design: 1.5 s; its moves pause).
    public var popStagger: Float

    public init(_ role: BossPartRole, type: BugType, radius: Float, scale: Float = 1, lift: Float = 0, segment: Int = 0,
                damageK: Float = 1, downK: Float = 1, rearK: Float = 1, pool: Float = 0, poppedK: Float = 1, popStagger: Float = 0) {
        self.role = role; self.type = type; self.radius = radius; self.scale = scale; self.lift = lift; self.segment = segment
        self.damageK = damageK; self.downK = downK; self.rearK = rearK; self.pool = pool; self.poppedK = poppedK; self.popStagger = popStagger
    }
}

/// A chain body (design §1.5: «N segments that follow the head's path history by arc length»): parts 0 = the head,
/// 1…segments = the segments (each `spacing` m of path behind the previous one, the first `lead` m behind the head),
/// then the nodes. At most BOSS_PARTS parts.
public struct BossChainSpec: Equatable {
    public var head: BossPartSpec
    public var segment: BossPartSpec
    public var segments: Int
    /// Path length between two segments (m) and from the head to the first segment.
    public var spacing: Float
    public var lead: Float
    /// Each rides its `segment`.
    public var nodes: [BossPartSpec]
    /// The path history keeps a point every `sampleStep` m the head moves (it covers the body: at most BOSS_PATH points).
    public var sampleStep: Float

    public init(head: BossPartSpec, segment: BossPartSpec, segments: Int, spacing: Float, lead: Float, nodes: [BossPartSpec] = [],
                sampleStep: Float = 0.25) {
        self.head = head; self.segment = segment; self.segments = segments; self.spacing = spacing; self.lead = lead; self.nodes = nodes
        self.sampleStep = sampleStep
    }

    /// Parts in all (head + segments + nodes).
    public var partCount: Int { 1 + segments + nodes.count }
    /// Path length from the head to the last segment (m).
    public var length: Float { lead + Float(max(0, segments - 1)) * spacing }
}

public enum BossBodySpec: Equatable {
    /// One swarm bug of `type` that walks and fights with its type's own AI (the Queen: a brute's walk, its bite on the
    /// boss's own clock, the ram on the boss's clock — `BossMoveKind.bodyCharge`); its radius and draw scale replaced.
    case bug(type: BugType, radius: Float, scale: Float)
    /// A chain: the head steered by the boss's file (or along a track, `bossSetTrack`), the parts following its path.
    case chain(BossChainSpec)
}

/// Where the boss comes in (its warning ring stands there for `BossSpec.warn` s first).
public enum BossSpawn: Equatable {
    /// It climbs over the rim of its arena (the step's zone; the classic hold: the lift) from `depth` m below: a rim edge
    /// within the arena's radius + `margin` on its far side (z − centre.z < `backZ`), else any rim edge, else the edge
    /// nearest to the arena (the Queen: depth 3, margin 1.5, backZ −4).
    case rim(depth: Float, margin: Float, backZ: Float)
    /// At a point (x, z) at absolute height `y`, heading `heading` (atan2(dx, dz)); a chain trails behind it.
    case point(x: Float, z: Float, y: Float, heading: Float)
    /// The arena's centre (the step's zone), `lift` m above its deck, heading `heading`.
    case arena(lift: Float, heading: Float)
}

// ---------------------------------------------------------------- moves

/// What a move does. The first three are the Queen's (instant on their clocks); the telegraphed ones run wind-up →
/// active → cooldown (`BossMove`); `.custom` is played by the boss's own file (`bossOwnMove`).
public enum BossMoveKind: Int {
    /// Adds burst out of the body: `count` × `addType` (the cap permitting), climbing out at its feet (the Queen's brood).
    case brood
    /// An acid glob at every standing marine within `range`, aimed `lead` s ahead with ± `spread` m (the Queen's volley; the
    /// globs are a spitter's: 1.5 m splash, 0.95 s flight, a ring + fill telegraph each).
    case volley
    /// A bug body's own charge (a brute's ram: its red lane, its wind-up), allowed only on the boss's clock.
    case bodyCharge
    /// A telegraph on the ground at the aim (`shape` .ring / .fill / .drop, `radius`), then a hit there: `damage` × the
    /// damage multiplier, `knockback` away from its centre; it may open a weak-point window on the head (`opensDown`).
    case slam
    /// A lane (`shape` .lane / .beam) from the boss toward the aim, `length` × `radius` (its width), then a hit along it.
    case lane
    /// A cone from the boss along the aim (`length`, half-angle `angle`), then a hit inside it (a sweep: the aim turns
    /// `sweep` rad/s while it is active, hitting what it crosses once).
    case cone
    /// `count` drop targets (`radius`) round the aim, then a hit in each.
    case drop
    /// A pack of `count` × `addType` climbs over the rim nearest to the boss (the director's queue).
    case pack
    /// The boss's own file plays it (`bossOwnMove`: wind-up, landing, end).
    case custom
}

/// Where a telegraphed move aims.
public enum BossAim: Int {
    /// The nearest standing marine (`lead` s ahead), the boss's position (centred on it), a random standing marine, or
    /// the point the boss's file set (`bossAimAt`).
    case nearest, body, random, set
}

/// One move of a boss (a row of `BossSpec.moves`). The fields a kind does not use stay 0.
public struct BossMove: Equatable {
    /// Stable id (tests, tuning overrides, the boss's file: `BossSpec.move(_:)`).
    public var id: String
    public var kind: BossMoveKind
    /// The phases it runs in (bit p = phase p).
    public var phases: UInt8 = 0xFF
    /// Seconds after the spawn before its first use, and between uses (× the phase's `cooldownK`).
    public var first: Float
    public var cooldown: Float
    // ---- telegraphed moves (slam, lane, cone, drop, pack, custom)
    public var shape: TelegraphShape = .ring
    public var aim: BossAim = .nearest
    /// The telegraph's time before it lands, and how long it acts after (a lane stays lit, a sweep turns).
    public var windUp: Float = 0
    public var active: Float = 0
    /// × the damage multiplier; the knockback impulse (m/s; ≥ 9 plays the rig's knock-down).
    public var damage: Float = 0
    public var knockback: Float = 0
    /// A ring / fill / drop target's radius, a lane's width; a lane's or a cone's length; a cone's half-angle (rad); a
    /// sweep's turn rate (rad/s).
    public var radius: Float = 0
    public var length: Float = 0
    public var angle: Float = 0
    public var sweep: Float = 0
    /// The aim leads a marine by `lead` s, ± `spread` m; only marines within `range` m (0 = any).
    public var lead: Float = 0
    public var spread: Float = 0
    public var range: Float = 0
    /// Adds, globs or drop targets per use; the adds' type.
    public var count: Int = 0
    public var addType: BugType = .runner
    /// Its hit also strikes the bugs in it (design §1.5: the coil kills bugs inside).
    public var hitsBugs = false
    /// Its landing opens a weak-point window on the head for this many s (0 none).
    public var opensDown: Float = 0
    /// Only one exclusive move runs at a time (a waiting one keeps its clock run out until the boss is free).
    public var exclusive = true
    /// The telegraph's colour.
    public var color = SIMD3<Float>(1.0, 0.18, 0.1)

    public init(_ id: String, _ kind: BossMoveKind, first: Float, cooldown: Float) {
        self.id = id; self.kind = kind; self.first = first; self.cooldown = cooldown
    }

    /// It runs in phase `p`.
    @inline(__always) public func runs(in p: Int) -> Bool { p < 0 || p > 7 || (phases & UInt8(1 << p)) != 0 }
}

// ---------------------------------------------------------------- phases, immunities, hooks, rewards

/// An arena hazard a phase sets off on entry (design §5.2 «arena hooks»).
public enum BossHazard: Equatable {
    /// The hold's lift pulse stops while the boss lives.
    case pulseOff
    /// The `count` lit light circuits nearest to the arena go dark (R6's circuits; the squad can throw their breakers again).
    case lightsOut(count: Int)
    /// A pack of `count` runners pours onto the overhead routes from the entry nearest to the arena (R2's queue; a
    /// station without routes ignores it).
    case overheadBrood(count: Int)
}

/// A phase: it begins when the boss's health falls below `below` × its max (the first phase: 1).
public struct BossPhase: Equatable {
    public var below: Float
    /// Enraged (the HUD and the events say so; the Queen's second phase).
    public var enraged: Bool = false
    /// × the boss's speed.
    public var speedK: Float = 1
    /// × each move's cooldown in this phase (by move index; missing = 1).
    public var cooldownK: [Float] = []
    /// The hive's answer on entry: a horde of `horde` (× `hordeWavesK` on the wave pacing, × the horde scale; 0 none) with
    /// `hordeTitle` (nil: the horde's own banner) at `hordeRate` bugs/s.
    public var horde: Float = 0
    public var hordeWavesK: Float = 1
    public var hordeRate: Float = 40
    public var hordeTitle: TextID? = nil
    public var hazards: [BossHazard] = []
    /// The boss staggers this long on entry (its moves pause; a scream).
    public var stagger: Float = 0

    public init(below: Float) { self.below = below }

    /// × the cooldown of move `m`.
    @inline(__always) func cooldownK(_ m: Int) -> Float { m < cooldownK.count ? cooldownK[m] : 1 }
}

/// What does not work on the boss.
public struct BossImmunities: Equatable {
    /// It never freezes (the cryo beam, the Ice Wave, frost blasts and a coolant mist pass it by). When false, a part that
    /// would freeze calls the boss's reaction instead (`freezeLock`, `brittle`) — a boss never freezes solid.
    public var freeze: Bool = true
    /// Its chill never exceeds this (the Queen: 0.5 — at most 30 % slower).
    public var chillCap: Float = 1
    /// The lift's shock pulse passes it by.
    public var pulse: Bool = true
    /// Not immune to freezing: a frozen part locks the body this long (design §1.5, the Cryo vs the Threader: 2 s)…
    public var freezeLock: Float = 0
    /// …and an Ice Wave on a part whose weak-point window is open makes the boss brittle this long (× BOSS_BRITTLE_K).
    public var brittle: Float = 0
    public init() {}
}

/// The blast when it dies (a pending explosion: `src` 0 gives the player the kills).
public struct BossBlast: Equatable {
    public var r: Float
    public var dmg: Float
    public var src: Int
    public var kind: ExplosionKind
    public init(r: Float, dmg: Float, src: Int = 0, kind: ExplosionKind = .frag) { self.r = r; self.dmg = dmg; self.src = src; self.kind = kind }
}

/// The bounty: XP on the kill (before the kill's own XP), medkits dropped at these offsets from where it died.
public struct BossReward: Equatable {
    public var xp: Int
    public var medkits: [Vec2]
    public init(xp: Int = 0, medkits: [Vec2] = []) { self.xp = xp; self.medkits = medkits }
}

/// One boss on one tier: a row of `Difficulty` (Tuning.swift; its shared structure comes from the boss's own file, e.g.
/// `BossSpec.queen(…)` in GameQueen.swift).
public struct BossSpec: Equatable {
    /// A hold's rider comes `at` s into the counted hold (`BossArrival.holdTime(nil)`; ∞: it never comes on this tier).
    public var at: Float
    /// Health (× the director's HP multiplier at the spawn) and speed.
    public var hp: Float
    public var speed: Float
    public var body: BossBodySpec
    public var spawn: BossSpawn
    /// Seconds of warning (a red ring of `warnRing` m where it comes) before it is there.
    public var warn: Float = 2
    public var warnRing: Float = 3
    /// At least one (the first `below` 1).
    public var phases: [BossPhase]
    /// At most BOSS_MOVES.
    public var moves: [BossMove]
    public var immune = BossImmunities()
    /// A bug body's bite: × its type's bite, on the boss's own clock (the Queen: ×1.6).
    public var bite: Float = 1
    /// What its hits count as (the report's loss cause, the calibration ledger).
    public var source: DamageSource
    /// ARENA HOOKS — × the step's spawn stream while it lives (the Queen: «she is the horde»), and the hold's periodic
    /// horde clock waits while it lives (a hold rider that `locks` the hold is the third: `BossRider.locks`).
    public var trickle: Float = 1
    public var pausesHordes: Bool = true
    /// REWARDS and the death blast.
    public var deathBlast: BossBlast? = nil
    public var reward = BossReward()
    /// Presentation: the banner when it is there (red) and when it dies (teal), its roar (non-positional, after the siren),
    /// the shake of its arrival.
    public var banner: BannerText? = nil
    public var deathBanner: BannerText? = nil
    public var roar: SoundID? = nil
    public var arrivalShake: Float = 0.4
    /// Stage 2 B4: a chain body takes an area hit as one creature — a blast's or a continuous weapon's (the torch, the beam,
    /// the napalm) damage on its parts in one tick counts once per source on the boss bar, the part that took the most (the
    /// Threader; off for the Queen and B1's toy: every part hit counts).
    public var areaOnce = false

    public init(at: Float, hp: Float, speed: Float, body: BossBodySpec, spawn: BossSpawn, phases: [BossPhase], moves: [BossMove],
                source: DamageSource) {
        self.at = at; self.hp = hp; self.speed = speed; self.body = body; self.spawn = spawn; self.phases = phases; self.moves = moves
        self.source = source
    }

    /// No boss (the runtime's state before a step brings one).
    public static let none = BossSpec(at: .infinity, hp: 0, speed: 0, body: .bug(type: .brute, radius: 1, scale: 1),
                                      spawn: .rim(depth: 3, margin: 1.5, backZ: -4), phases: [BossPhase(below: 1)], moves: [],
                                      source: .environment)

    /// It comes on this tier as a hold's rider (the classic «the tier has a Queen»).
    public var comes: Bool { at.isFinite }

    /// The chain of a chain body (nil: a bug body).
    public var chain: BossChainSpec? {
        if case .chain(let c) = body { return c }
        return nil
    }

    /// Index of the move `id` (-1 none).
    public func moveIndex(_ id: String) -> Int { moves.firstIndex { $0.id == id } ?? -1 }
    /// The move `id`.
    public func move(_ id: String) -> BossMove? { let k = moveIndex(id); return k >= 0 ? moves[k] : nil }
    /// Change the move `id` (tuning overrides, tests); no such move: nothing.
    public mutating func setMove(_ id: String, _ body: (inout BossMove) -> Void) {
        let k = moveIndex(id)
        if k >= 0 { body(&moves[k]) }
    }
}

/// The public view of the boss of the current step (the Queen in the classic hold). It replaces v1.1's QueenState with
/// the same fields — the HUD, the threat state, the report and calibration read it as before — and the framework's own.
/// `uid` stays after its death (uids are never reused): the swarm slot of its body (a chain: the head, whose health is
/// the boss bar).
public struct BossState {
    public internal(set) var kind: BossKind = .queen
    public internal(set) var uid: Int32 = 0
    public internal(set) var spawned = false
    public internal(set) var alive = false
    public internal(set) var done = false
    /// The current phase is an enraged one.
    public internal(set) var enraged = false
    /// The current phase (index into the spec's phases).
    public internal(set) var phase = 0
    /// Mission time of its spawn, seconds it lived (set at its death).
    public internal(set) var t0: Float = 0
    public internal(set) var killT: Float = 0
    /// Health 0…1 (boss bar = 1 − hpFraction).
    public internal(set) var hpFraction: Float = 1
    /// Seconds left of the warning ring before it comes, -1 = none.
    public internal(set) var warning: Float = -1
    public internal(set) var position = Vec2(0, 0)
    /// A chain's head: absolute height and heading (atan2(dx, dz)); a bug body: 0, its slot's heading.
    public internal(set) var height: Float = 0
    public internal(set) var heading: Float = 0
    /// Seconds left: untouchable (no damage), staggered (its moves pause), its body locked (a chain stops), brittle
    /// (× BOSS_BRITTLE_K damage).
    public internal(set) var untouchable: Float = 0
    public internal(set) var stagger: Float = 0
    public internal(set) var lock: Float = 0
    public internal(set) var brittle: Float = 0
    /// Times it came in the current step (a periodic rider: `BossArrival.every`).
    public internal(set) var arrivals = 0
    public init() {}
}

/// A part of a chain body as the renderer and the tests read it (`Game.bossPart(_:)`).
public struct BossPartView: Equatable {
    public let role: BossPartRole
    /// Segment number (1…; the head 0; a node: the segment it rides).
    public let segment: Int
    /// World x, absolute height, z; heading (atan2(dx, dz)) along the body.
    public let position: SIMD3<Float>
    public let heading: Float
    public let radius: Float
    public let scale: Float
    /// Its swarm slot (hit flash, burn, chill: `Game.bugs`), -1 when gone.
    public let slot: Int
    /// Seconds left of an open weak-point window.
    public let down: Float
    /// Seconds left of its freeze (a boss that is not freeze-immune: it froze and locked the body; ice on it).
    public let frozen: Float
    /// Its pool is spent (a dark node).
    public let popped: Bool
    /// Its own pool 0…1 (1 without one).
    public let pool: Float
    /// Out of the deck weapons' reach (filed under the overhead's sentinel bucket: aimed-up fire, the blasts' upper reach).
    public let up: Bool
}

/// Bounds of the framework's fixed buffers.
public let BOSS_MOVES = 16
public let BOSS_PARTS = 32
public let BOSS_PATH = 512
/// × the damage while the boss is brittle (design §1.5: «brittle means +50 % damage»).
public let BOSS_BRITTLE_K: Float = 1.5
/// A part higher than this above the deck under it is out of the deck weapons' reach (the overhead's rule).
public let BOSS_REACH: Float = 2.6
/// A bug body's charge waits on the boss's clock: its attack cooldown is held at this until the clock runs out.
let BOSS_CHARGE_HOLD: Float = 0.5
/// `Swarm.boss` of a bug body's slot (a chain part: its index + 1).
let BOSS_BUG: UInt8 = 255
