import Foundation

// ================================================================
//  GAME — public facade of the simulation (the JS globals GS / DIR / M / B …
//  live here as one object). Pure logic: Foundation only, deterministic for
//  a given seed + input sequence, fixed step SIM_DT.
//
//  Frame loop on the app side:
//      game.setPlayerInput(...)          // world-space move / aim / buttons
//      while accumulator >= SIM_DT { game.tick(); accumulator -= SIM_DT }
//      game.drainEvents { event in ... } // fx, audio, haptics, HUD toasts
//      render from game.bugs / marines / projectiles / telegraphs …
//      if game.wantsLevelUp { cards = game.rollUpgrades(); … game.chooseUpgrade(k) }
// ================================================================

/// The coarse stage of the mission as the renderer, the report and the demos read it (the lift's part in it). The
/// mission plan (Mission.swift) decides it: the classic plan walks beacons → toLift → hold → extract; the director, the
/// HUD and calibration read the plan itself (GameMission.swift).
public enum MissionStage: Int {
    /// A RING step: light the beacons.
    case beacons
    /// On the way to the lift (a HOLD or an EXTRACT there).
    case toLift
    /// Holding the lift (a HOLD there).
    case hold
    /// The lift rises (an EXTRACT: victory after 4.6 s).
    case extract
    /// A SWITCH step.
    case switches
    /// A HOLD on a deck away from the lift (on the way and holding).
    case area
    /// A BOSS step (on the way to the arena and the fight).
    case boss
}

public enum GamePhase: Int {
    case playing, won, lost
}

public struct BeaconState {
    public let name: NameRef
    public let x: Float, z: Float
    /// 0 idle, 1 charging, 2 done.
    public internal(set) var state: Int = 0
    public internal(set) var progress: Float = 0
    /// 6+ bugs inside the ring: charging is slowed to 30 %.
    public internal(set) var contested: Bool = false
    public var position: Vec2 { Vec2(x, z) }
}

public struct GameConfig {
    /// Quality tier that sets the gameplay bug cap (web: simCap = QUALITY[q].cap).
    public var quality: QualityTier = .med
    /// Explicit live-bug cap (overrides `quality`).
    public var bugCap: Int? = nil
    /// The tier of this mission (web TH); the app passes `Difficulty.tier(effectiveTier)`.
    public var difficulty: Difficulty = .veteran
    public var levelSource: any LevelSource = KelvinStation()
    /// Title-screen attract mode: autopilot, invulnerable squad, no objectives, endless trickle.
    public var attract: Bool = false
    /// The player marine is AI driven (debug / tests / demo).
    public var autopilot: Bool = false
    /// Level-up cards are picked automatically (first card), the sim never waits for the UI.
    public var autoPickUpgrades: Bool = false
    /// Squad invulnerable.
    public var god: Bool = false
    /// Run the first-run coach «Учебная высадка» (the app: the first mission ever, or the pause «Обучение»).
    public var coach: Bool = false
    /// The revive line (coach.revive) may show once in this mission (app: profile.runs < 3).
    public var reviveLineArmed: Bool = false
    /// Debug: seconds of counted hold before the Матка's warning (overrides `difficulty.queen.at`; `-queen` → 0).
    public var queenAt: Float? = nil
    /// Debug / tests: her absolute health (not × hpMul; web `__dbg.queen(hp)`).
    public var queenHp: Float? = nil
    /// The mission (its plan is built for the station); nil = «Operation Cold Light» (`MissionTemplate.coldLight`).
    public var mission: MissionTemplate? = nil
    public init() {}
}

/// Public view of the Матка (web DIR.q + the HUD fields of QSTATE). `uid` stays after her death (uids are never reused).
public struct QueenState {
    public internal(set) var uid: Int32 = 0
    public internal(set) var spawned = false
    public internal(set) var alive = false
    public internal(set) var done = false
    public internal(set) var enraged = false
    /// Mission time of her spawn, seconds she lived (set at her death).
    public internal(set) var t0: Float = 0
    public internal(set) var killT: Float = 0
    /// Health 0…1 (boss bar = 1 − hpFraction).
    public internal(set) var hpFraction: Float = 1
    /// Seconds left of the warning ring before she climbs up, -1 = none.
    public internal(set) var warning: Float = -1
    public internal(set) var position = Vec2(0, 0)
    public init() {}
}

/// What the coach card shows (web CO). Steps 0…4: run, aim + fire, ability, dash, beacon.
public enum CoachTarget: Int {
    case moveStick, aimStick, ability, dash, objective
}

public struct CoachState {
    public internal(set) var active = false
    /// 0…4 while active, -1 otherwise.
    public internal(set) var step = -1
    public internal(set) var stepTime: Float = 0
    /// The control the card points at (nil = no card).
    public var target: CoachTarget? { active ? CoachTarget(rawValue: step) : nil }
    /// coach.revive («{call-sign} is down — …») for `reviveTime` s after the first bot went down (once per run).
    public internal(set) var reviveLine: GameText? = nil
    public internal(set) var reviveTime: Float = 0
    public init() {}
}

/// A practice group of the coach (runners at half HP climbing over one stretch of railing).
struct CoachGroup {
    var edge = 0
    var n = 0
    var rate: Float = 0
    var acc: Float = 0
}

/// Pending explosion (deferred so chain reactions ripple tick by tick).
struct Boom {
    var x: Float, z: Float, r: Float, dmg: Float
    var src: Int
    var kind: ExplosionKind
}

/// A burst of bugs pouring from an edge (or a vent) over time.
struct Burst {
    var edge: Int
    var n: Int
    var rate: Float
    /// Spawn accumulator: starts negative for a delayed pack (−rate × delay).
    var acc: Float
    var vent: Vec2?
}

public struct Grenade {
    public internal(set) var active = false
    public internal(set) var sx: Float = 0, sz: Float = 0, tx: Float = 0, tz: Float = 0
    /// Flight time so far / total flight time.
    public internal(set) var t: Float = 0, dur: Float = 1
    var own = 0
    public internal(set) var r: Float = 5
    var dmg: Float = 150
    var cluster = 0
    /// Frag grenade (true) or cluster bomblet.
    public internal(set) var big = true
    public var progress: Float { dur > 0 ? min(1, t / dur) : 1 }
}

public struct Napalm {
    public internal(set) var active = false
    public internal(set) var x: Float = 0, z: Float = 0, r: Float = 5
    /// Seconds left.
    public internal(set) var t: Float = 0
    var own = 0
}

public struct Turret {
    public internal(set) var active = false
    public internal(set) var x: Float = 0, z: Float = 0
    /// Seconds left.
    public internal(set) var t: Float = 0
    public internal(set) var angle: Float = 0
    var cd: Float = 0
    public internal(set) var owner = 0
    var think: Float = 0
    var target = -1
    var tuid: Int32 = 0
    /// Set to 1 on each shot (laser flash), the renderer may reset it.
    public internal(set) var laser: Float = 0
}

public struct Medkit {
    public internal(set) var active = false
    public internal(set) var x: Float = 0, z: Float = 0
    /// Seconds before it disappears.
    public internal(set) var t: Float = 0
}

/// A drop telegraph of the overhead (Stage 1 R2): where a bug up on a route will land and when. The renderer draws the
/// ring (also the telegraph `.dropZone`) and the dust column from `from` down to it; the bots step out of it.
public struct DropZone {
    public internal(set) var active = false
    /// The landing point (deck) and the ring's final radius.
    public internal(set) var x: Float = 0, z: Float = 0
    public internal(set) var r: Float = DROP_RING
    /// Seconds until the landing / the whole warning.
    public internal(set) var t: Float = 0, warn: Float = 0.9
    /// The bug (uid) and the marine it is aimed at.
    public internal(set) var uid: Int32 = 0
    public internal(set) var marine: Int = -1
    /// Where it lets go from (world x, absolute y, z).
    public internal(set) var from = SIMD3<Float>(0, 0, 0)
    /// Stage 1 R4: a Dropper's drop (it pins whoever it lands on).
    public internal(set) var dropper = false
    /// The pool slot of its ring telegraph (-1 none: simOnly).
    var tele = -1
    /// 0…1 over the warning.
    public var progress: Float { warn > 0 ? min(1, max(0, 1 - t / warn)) : 1 }
    /// The ring's radius now (closing DROP_RING0 → r).
    public var radius: Float { DROP_RING0 + (r - DROP_RING0) * progress }
}

/// What the overhead did in a mission (debug logs, tests, calibration rows).
public struct OverheadStats: Equatable {
    /// Route packs queued by the director (or a debug call), bugs spawned onto the routes.
    public internal(set) var packs = 0, spawns = 0
    /// Drop telegraphs started, drops landed, landings on a marine, marine downs by a drop, squad HP lost to drops.
    public internal(set) var drops = 0, landed = 0, hits = 0, downs = 0
    public internal(set) var hurt: Float = 0
    /// Bugs killed while up, knocked down (fire / frost / blast), shattered by their fall, hopped down to the deck.
    public internal(set) var kills = 0, knockdowns = 0, shattered = 0, hops = 0
    /// Most bugs up at once, most drop telegraphs at once.
    public internal(set) var maxUp = 0, maxZones = 0
    // ---- Stage 1 R4 «Overhead bugs» (GameOverheadBugs.swift)
    /// Droppers sent up; pins; pins ended by a dash, by the squad's fire (15 damage on the Dropper, or killing it), by
    /// running out, by the marine going down; the seconds pins held; squad HP lost to Droppers (landings and gnaws) and the
    /// marine downs they caused.
    public internal(set) var droppers = 0, pins = 0, pinDash = 0, pinFire = 0, pinTimeout = 0, pinDown = 0, dropperDowns = 0
    /// Droppers' drop telegraphs started, their landings, Droppers killed up there, knocked down, hopped down.
    public internal(set) var dropperDrops = 0, dropperLanded = 0, dropperKills = 0, dropperKnocks = 0, dropperHops = 0
    public internal(set) var pinTime: Float = 0, dropperHurt: Float = 0
    /// Spitters that took a perch and their spits from there; duct rattles, grilles shot shut, bugs lost at a shut duct.
    public internal(set) var perched = 0, perchSpits = 0, rattles = 0, seals = 0, ductLost = 0
    public init() {}
}

/// A pack pouring onto the overhead from one entry (GameOverhead), its own queue: it spawns with or without the director.
struct RouteBurst {
    var entry: Int
    var n: Int
    var rate: Float
    /// Spawn accumulator: starts negative for a delayed pack (−rate × delay).
    var acc: Float
    /// The bug type (the director sends runners; package R4 adds the Dropper, the perched spitter).
    var type: UInt8 = T_RUN
    /// Stage 1 R4: a pack bound for a duct mouth has had its rattle (the grille shakes once, before its first bug).
    var rattled = false
}

/// The overhead's runtime state (GameOverhead.swift); reset with the world.
struct OverheadState {
    var zones = [DropZone](repeating: DropZone(), count: 8)
    var queue: [RouteBurst] = []
    /// Sim time of the last drop telegraph started.
    var lastDrop: Float = -99
    /// Route bugs spawned since the last hash rebuild (the sentinel bucket counts the rest).
    var tickSpawns = 0
    /// The anti-camping clock (design §1.1.6): the spot the squad lingers at and for how long.
    var campX: Float = 0, campZ: Float = 0, campT: Float = 0
    /// Deck circles (x, z, r) no drop lands in — the seam for package R6's lit deck («never over lit deck»).
    var noDrop: [SIMD3<Float>] = []
    var stats = OverheadStats()
    /// Debug / demo: the bots hold their fire.
    var holdFire = false
    // ---- Stage 1 R4 «Overhead bugs» (GameOverheadBugs.swift; built by resetOverheadBugs)
    /// The duct mouths (one per `OverheadGraph.ducts` node) and each route node's duct index (−1 none).
    var ducts: [DuctState] = []
    var ductOf: [Int] = []
    /// The perch points (`OverheadGraph.perches` nodes), the uid perched on or bound for each (0 free), and each point's
    /// route distance to every node (a perch-bound spitter's way there).
    var perchUid: [Int32] = []
    var perchDist: [[Float]] = []
    /// The director's Dropper / perch channel clocks (Difficulty.dropperGap / perchGap).
    var dropperT: Float = 0, perchT: Float = 0
    /// First sightings shown this mission (the perched spitter, the rattling duct).
    var tipPerch = false, tipDuct = false
    /// Demo / tests: every route bug goes for this marine while it stands (-1: the usual rule).
    var focus = -1
}

/// Projectiles (pulse bolts, minigun & turret rounds) as SoA.
public final class Projectiles {
    public static let capacity = 700
    public internal(set) var count = 0
    let x: UnsafeMutablePointer<Float>, z: UnsafeMutablePointer<Float>
    let dx: UnsafeMutablePointer<Float>, dz: UnsafeMutablePointer<Float>
    let spd: UnsafeMutablePointer<Float>, life: UnsafeMutablePointer<Float>, dmg: UnsafeMutablePointer<Float>
    let pierce: UnsafeMutablePointer<UInt8>
    let own: UnsafeMutablePointer<Int8>
    /// Colour index: 0 red pulse, 1 minigun, 2 turret.
    let col: UnsafeMutablePointer<UInt8>
    let last: UnsafeMutablePointer<Int32>
    /// bit 0: player shot, bit 1: already counted as a hit, bit 2: aimed up at the overhead (Stage 1 R2: it strikes only
    /// bugs up on the routes, at their footprint; a shot at the deck passes under them).
    let flags: UnsafeMutablePointer<UInt8>

    init() {
        let n = Projectiles.capacity
        func f() -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
        x = f(); z = f(); dx = f(); dz = f(); spd = f(); life = f(); dmg = f()
        pierce = .allocate(capacity: n); pierce.initialize(repeating: 0, count: n)
        own = .allocate(capacity: n); own.initialize(repeating: 0, count: n)
        col = .allocate(capacity: n); col.initialize(repeating: 0, count: n)
        last = .allocate(capacity: n); last.initialize(repeating: 0, count: n)
        flags = .allocate(capacity: n); flags.initialize(repeating: 0, count: n)
    }
    deinit {
        x.deallocate(); z.deallocate(); dx.deallocate(); dz.deallocate(); spd.deallocate(); life.deallocate(); dmg.deallocate()
        pierce.deallocate(); own.deallocate(); col.deallocate(); last.deallocate(); flags.deallocate()
    }
    func remove(_ k: Int) {
        count -= 1
        let l = count
        if k != l {
            x[k] = x[l]; z[k] = z[l]; dx[k] = dx[l]; dz[k] = dz[l]; spd[k] = spd[l]; life[k] = life[l]; dmg[k] = dmg[l]
            pierce[k] = pierce[l]; own[k] = own[l]; col[k] = col[l]; last[k] = last[l]; flags[k] = flags[l]
        }
    }
    // read-only render access
    @inline(__always) public func position(_ k: Int) -> Vec2 { Vec2(x[k], z[k]) }
    @inline(__always) public func direction(_ k: Int) -> Vec2 { Vec2(dx[k], dz[k]) }
    @inline(__always) public func speed(_ k: Int) -> Float { spd[k] }
    /// 0 red pulse (assault), 1 minigun, 2 turret.
    @inline(__always) public func colorIndex(_ k: Int) -> Int { Int(col[k]) }
    @inline(__always) public func owner(_ k: Int) -> Int { Int(own[k]) }
    /// Aimed up at a bug on the overhead (the renderer tilts its tracer up).
    @inline(__always) public func aimedUp(_ k: Int) -> Bool { (flags[k] & 4) != 0 }
}

/// Spitter acid globs in flight (SoA, capacity 64).
public final class AcidGlobs {
    public static let capacity = 64
    public internal(set) var count = 0
    var x0 = [Float](repeating: 0, count: 64), z0 = [Float](repeating: 0, count: 64)
    var x1 = [Float](repeating: 0, count: 64), z1 = [Float](repeating: 0, count: 64)
    var t = [Float](repeating: 0, count: 64), dur = [Float](repeating: 0, count: 64)
    /// Stage 1 R4: how far above the deck's throw point a glob starts (a perched spitter's, m; 0 = a deck spitter's).
    var h0 = [Float](repeating: 0, count: 64)
    /// The lamp a glob was spat at (Stage 1 R6: it breaks it on landing), −1 a marine.
    var lamp = [Int](repeating: -1, count: 64)
    public func from(_ k: Int) -> Vec2 { Vec2(x0[k], z0[k]) }
    /// Stage 1 R4: the glob's start height above the deck's throw (a perched spitter spits from up on the overhead).
    public func launchHeight(_ k: Int) -> Float { h0[k] }
    public func to(_ k: Int) -> Vec2 { Vec2(x1[k], z1[k]) }
    /// Flight progress 0..1 (lands at 1).
    public func progress(_ k: Int) -> Float { dur[k] > 0 ? min(1, t[k] / dur[k]) : 1 }
    /// Seconds until impact.
    public func timeLeft(_ k: Int) -> Float { dur[k] - t[k] }
}

public final class Game {
    // ---------- configuration ----------
    public let seed: UInt32
    public let playerClass: MarineClass
    public let config: GameConfig
    public let level: Level
    /// The tier of this mission (fixed for the mission).
    public let difficulty: Difficulty
    /// The lift-pulse hint of this tier (built once).
    /// Gameplay cap on live bugs (only an explicit quality choice changes it).
    public internal(set) var bugCap: Int
    var rng: SeededRNG

    // ---------- flags ----------
    public let attract: Bool
    /// The player marine is AI driven.
    public var autopilot: Bool
    public var autoPickUpgrades: Bool
    /// Squad invulnerable (debug god mode or attract mode).
    public var godMode: Bool
    /// Bench mode: simulation without effects / director / XP.
    var simOnly = false
    /// Bench combat pass: kills and effects on, director off.
    var benchCombat = false
    /// Director disabled (debug).
    public var directorEnabled = true

    // ---------- world ----------
    public let bugs: Swarm
    let hash: SpatialHash
    let swarmFlow = FlowField()   // toward the nearest standing marine (bugs)
    let squadFlow = FlowField()   // toward the player (bots regrouping)
    let objFlow = FlowField()     // toward the current objective (autopilot)
    let reviveFlow = FlowField()  // toward downed marines (rescuers)
    let flowQueue: UnsafeMutablePointer<Int>
    var flowSrc: [Float] = []
    var flowTimer: Float = 0
    var objFlowKey: (Int, Int) = (Int.min, Int.min)
    public private(set) var marines: [Marine] = []
    var pyroIdx = -1, cryoIdx = -1
    public let projectiles = Projectiles()
    public let globs = AcidGlobs()
    var booms: ContiguousArray<Boom> = []
    public internal(set) var grenades = [Grenade](repeating: Grenade(), count: 12)
    public internal(set) var napalms = [Napalm](repeating: Napalm(), count: 3)
    public internal(set) var turret = Turret()
    public internal(set) var medkits = [Medkit](repeating: Medkit(), count: 6)
    public internal(set) var telegraphs = [Telegraph](repeating: Telegraph(), count: TELE_POOL)

    // per-tick scratch (marine positions for the swarm loop)
    let mX: UnsafeMutablePointer<Float>, mZ: UnsafeMutablePointer<Float>
    let mUp: UnsafeMutablePointer<UInt8>
    /// Bugs pressing on each marine (slows them).
    let crowd: UnsafeMutablePointer<Float>
    /// Per-tick scratch: burn multiplier per igniter (5 slots).
    let burnMulScratch: UnsafeMutablePointer<Float>
    /// Live count per bug type (caps on specials; Stage 1 R4: the Dropper's cap).
    var typeAlive: [Int] = [0, 0, 0, 0, 0]

    // ---------- run state (GS) ----------
    public internal(set) var phase: GamePhase = .playing
    /// Mission time (s).
    public internal(set) var time: Float = 0
    /// Simulation clock (s), also runs in attract mode.
    public internal(set) var simTime: Float = 0
    public internal(set) var tickCount: Int = 0
    public internal(set) var kills = 0
    public internal(set) var playerKills = 0
    public internal(set) var shots: Float = 0
    public internal(set) var hits: Float = 0
    public internal(set) var combo = 0
    var comboT: Float = 0
    public internal(set) var bestCombo = 0
    public internal(set) var xpLevel = 1
    public internal(set) var xp = 0
    public internal(set) var xpNext = 40
    /// Wave pacing: the fraction of XP (× xpK) not yet counted.
    var xpCarry: Float = 0
    public internal(set) var pendingLevels = 0
    /// Upgrade id -> times taken.
    public internal(set) var upgradeCounts: [UpgradeID: Int] = [:]
    /// Special bug types already introduced (tip toast on first sighting).
    var seen: [Bool] = [true, false, false, false, false]
    /// Current level-up offer.
    public internal(set) var offer: [Upgrade] = []

    // ---------- mission plan (Mission.swift, GameMission.swift) ----------
    /// This mission's plan (classic: «Operation Cold Light» for the station).
    public let mission: MissionPlan
    /// Index of the current step (the last one stays current after the mission is won).
    public internal(set) var missionStep = 0
    /// The current step's phase: on the way (between its rings) or active (a ring charging, holding, fighting, riding).
    public internal(set) var stepPhase: StepPhase = .approach
    /// Seconds in the current phase.
    public internal(set) var stepTime: Float = 0
    /// How the wave director treats the current phase.
    var posture: DirectorPosture = .travel
    /// The current approach has a travel allowance (the pressure clock waits until it is used up).
    var approachAllowance = false
    /// The switches of the current SWITCH step and the one being thrown (-1 none).
    public internal(set) var switches: [SwitchState] = []
    public internal(set) var activeSwitch = -1

    // ---------- director (DIR) ----------
    /// The coarse stage (set by the plan's phases).
    public internal(set) var stage: MissionStage = .beacons
    /// The station's beacons (RING steps charge them).
    public internal(set) var beacons: [BeaconState] = []
    /// Index of the beacon being charged, -1 none.
    public internal(set) var activeBeacon = -1
    /// Objective rings completed (beacons, switches): the director's escalation steps (classic: beacons lit).
    public internal(set) var beaconsDone = 0
    /// Hold countdown (s) of the current HOLD step (classic: the lift's) and its length.
    public internal(set) var liftT: Float = LIFT_TIME
    public internal(set) var liftDur: Float = LIFT_TIME
    var hordeT: Float = 50
    var waveT: Float = 0
    var trickle: Float = 0
    public internal(set) var hpMul: Float = 1
    public internal(set) var dmgMul: Float = 1
    var queue: [Burst] = []
    public internal(set) var extractT: Float = 0
    public internal(set) var hordes = 0
    var pulseT: Float = 5
    // ---------- wave pacing (GameWaves.swift) ----------
    /// The beat outside beacon defences and the hold: 0 lull, 1 build-up, 2 peak; seconds left of it.
    public internal(set) var beat = 0
    var beatT: Float = 12
    /// Pushes of the hive fired in this beacon defence (0…3), seconds of forced quiet after a push / horde.
    var beaconPushes = 0
    var lullT: Float = 0

    // ---------- v1.1: player downs, AFK (GS) ----------
    /// Downs of the PLAYER this mission (score «Без падений»).
    public internal(set) var downs = 0
    /// Source of the last hit the player took / of the hit that downed the player.
    public internal(set) var lastHit: DamageSource = .environment
    public internal(set) var downBy: DamageSource = .environment
    /// Seconds without any player input (never counts on autopilot).
    public internal(set) var afkTime: Float = 0

    // ---------- v1.1: hive pressure, coach hooks (DIR) ----------
    /// Hive pressure clock (s of loitering with no beacon running / on the way to the lift).
    public internal(set) var pressure: Float = 0
    /// Trickle / horde-clock multiplier from the pressure past its grace (1…4).
    public internal(set) var idleMul: Float = 1
    /// The coach holds the swarm back (no trickle, no hordes, pressure frozen).
    public internal(set) var calm = false
    /// × the next beacon horde (coach: 0.65 until the first beacon starts).
    public internal(set) var beaconHordeMul: Float = 1
    /// Part of the swarm hunts the player (web HUNT[0] pressure, HUNT[1] AFK), set once per tick.
    var huntPressure = false, huntAfk = false
    var heartAt: Float = -9
    /// Travel allowance of the walk to the lift (s): the pressure clock only runs once it is used up. Set when the
    /// objective flow first points at the lift (the walk at full speed × 1.3 + 5 s); -1 = not measured yet.
    public internal(set) var liftAllowance: Float = -1

    // ---------- v1.1: the Матка ----------
    public internal(set) var queen = QueenState()
    var qWarn: Float = -1, qEdge = -1, qSlot = -1
    var qBrood: Float = 0, qVolley: Float = 0, qRam: Float = 0, qMeleeCd: Float = 0
    var qArmed = false

    // ---------- v1.1: the coach ----------
    public internal(set) var coach = CoachState()
    var coachStartX: Float = 0, coachStartZ: Float = 0, coachFire: Float = 0
    var coachGroups = [CoachGroup](repeating: CoachGroup(), count: 2)
    var coachGroupCount = 0
    var coachReviveArmed = false
    var coachSeenSent = false

    // ---------- Stage 1 R2: the overhead (GameOverhead.swift) ----------
    var oh = OverheadState()

    // ---------- Stage 1 R6: interactive props — valves, light circuits, lockers (GameProps.swift) ----------
    var props = PropsState()

    // ---------- v1.1: calibration ledger (fixed arrays, index = DamageSource.rawValue + 1) ----------
    /// Damage taken by the whole squad per source.
    public internal(set) var hurtBy = [Float](repeating: 0, count: 6)
    /// Squad downs (all four marines) by the source of each marine's last hit.
    public internal(set) var squadDownBy = [Int](repeating: 0, count: 6)
    var marineLastSrc = [Int](repeating: -1, count: 4)

    // ---------- input ----------
    var inMove = Vec2(0, 0)
    var inAim: Float? = nil
    var inFire = false
    var inAssist: Float = 0
    var inAbility = false
    var inAbilityTarget: Vec2? = nil
    var inDash = false
    /// Visible ground area for aim assist (convex quad, world XZ); nil = everything counts as visible.
    var viewQuad: [Vec2]? = nil

    // ---------- output ----------
    /// Events since the last drain (capped: the oldest are dropped if nobody drains).
    public internal(set) var events: ContiguousArray<GameEvent> = []
    static let maxBufferedEvents = 16384

    // ================================================================
    public init(seed: UInt32 = 1, playerClass: MarineClass = .assault, config: GameConfig = GameConfig(), level: Level? = nil) {
        self.seed = seed
        self.playerClass = playerClass
        self.config = config
        let lv = level ?? Level(source: config.levelSource, seed: seed)
        self.level = lv
        self.mission = (config.mission ?? MissionTemplate.coldLight).build(lv)
        self.difficulty = config.difficulty
        self.bugCap = config.bugCap ?? (config.difficulty.waves ? config.quality.bugCap : config.quality.legacyCap)
        self.rng = SeededRNG(seed: seed == 0 ? 0x9E37_79B9 : seed)
        self.attract = config.attract
        self.autopilot = config.autopilot || config.attract
        self.autoPickUpgrades = config.autoPickUpgrades
        self.godMode = config.god || config.attract
        bugs = Swarm(capacity: MAX_BUGS)
        hash = SpatialHash(capacity: MAX_BUGS)
        flowQueue = .allocate(capacity: GRID * GRID); flowQueue.initialize(repeating: 0, count: GRID * GRID)
        mX = .allocate(capacity: 4); mX.initialize(repeating: 0, count: 4)
        mZ = .allocate(capacity: 4); mZ.initialize(repeating: 0, count: 4)
        mUp = .allocate(capacity: 4); mUp.initialize(repeating: 0, count: 4)
        crowd = .allocate(capacity: 4); crowd.initialize(repeating: 0, count: 4)
        burnMulScratch = .allocate(capacity: 5); burnMulScratch.initialize(repeating: 1, count: 5)
        events.reserveCapacity(1024)
        booms.reserveCapacity(64)
        flowSrc.reserveCapacity(16)
        resetWorld()
    }

    deinit {
        flowQueue.deallocate(); mX.deallocate(); mZ.deallocate(); mUp.deallocate(); crowd.deallocate(); burnMulScratch.deallocate()
    }

    // ---------- game flow (resetWorld of 12-main.js) ----------
    func resetWorld() {
        bugs.clear(); hash.clear(); globs.count = 0; booms.removeAll(keepingCapacity: true)
        projectiles.count = 0
        for k in grenades.indices { grenades[k].active = false }
        for k in napalms.indices { napalms[k].active = false }
        for k in medkits.indices { medkits[k].active = false }
        for k in telegraphs.indices { telegraphs[k].active = false }
        turret.active = false
        oh = OverheadState()
        resetOverheadBugs()
        setupSquad()
        resetDirector()
        // (after the director: a DARK plan starts its circuits off; lit beacons light their decks)
        resetProps()
        phase = .playing
        time = 0; kills = 0; playerKills = 0; shots = 0; hits = 0; combo = 0; comboT = 0; bestCombo = 0
        downs = 0; lastHit = .environment; downBy = .environment; afkTime = 0
        for k in 0..<6 { hurtBy[k] = 0; squadDownBy[k] = 0 }
        for k in 0..<4 { marineLastSrc[k] = -1 }
        xpLevel = 1; xp = 0; xpCarry = 0; xpNext = xpFor(1); pendingLevels = 0; upgradeCounts = [:]
        seen = [true, false, false, false, false]
        simTime = 0; flowTimer = 0; tickCount = 0
        updateFlows(); hash.rebuild(bugs)
        if attract {
            let P = marines[0]
            for _ in 0..<(difficulty.waves ? 70 : 160) {
                let e = pickEdge(P.x, P.z, 8, 30)
                if e >= 0 { _ = spawnBug(T_RUN, level.edgeX[e] - level.edgeNX[e] * 1.5, level.edgeZ[e] - level.edgeNZ[e] * 1.5) }
            }
        }
        coachBegin()
        if !attract && !coach.active && !simOnly, let b = mission.briefing {
            emit(.banner(title: stepLine(b.title, [.name(stationName)]), subtitle: stepLine(b.sub, [.name(stationName)]), teal: true))
        }
    }

    func setupSquad() {
        marines.removeAll()
        let others = MarineClass.allCases.filter { $0 != playerClass }
        marines.append(Marine(index: 0, cls: playerClass, name: .player, isPlayer: true, botDamage: difficulty.botDamage))
        // a squadmate's call-sign belongs to its class (Assault CUPCAKE, Pyro DONUT, Cryo SHADOW, Gunner MUFFIN)
        for (k, c) in others.enumerated() {
            let b = Marine(index: k + 1, cls: c, name: .callsign(c), isPlayer: false, botDamage: difficulty.botDamage)
            b.hp = 120; b.maxHp = 120
            marines.append(b)
        }
        pyroIdx = marines.firstIndex(where: { $0.cls == .pyro }) ?? -1
        cryoIdx = marines.firstIndex(where: { $0.cls == .cryo }) ?? -1
        let s = level.start
        let ox: [Float] = [0, -1.6, 1.6, 0], oz: [Float] = [0, 1.4, 1.4, 2.6]
        for (k, m) in marines.enumerated() {
            m.x = s.x + ox[k]; m.px = m.x
            m.z = s.y + oz[k]; m.pz = m.z
            m.aim = atan2f2(FWD_X, FWD_Z); m.ax = FWD_X; m.az = FWD_Z
        }
    }

    // ================================================================
    //  FIXED SIMULATION STEP (tick of 12-main.js)
    // ================================================================
    public func tick() {
        if phase != .playing { return }
        if events.count > Game.maxBufferedEvents { events.removeAll(keepingCapacity: true) }
        let dt = SIM_DT
        simTime += dt
        tickCount += 1
        bugs.compact()
        bugs.storePrevious()
        hash.rebuild(bugs)
        flowTimer -= dt
        if flowTimer <= 0 { flowTimer = 0.25; updateFlows() }
        processBooms()
        tickMarines(dt)
        simBugs(dt)
        if level.overhead != nil { overheadTick(dt) }
        updateProjectiles(dt)
        updateGlobs(dt)
        updateAbilities(dt)
        updateMedkits(dt)
        if !props.isEmpty { propsTick(dt) }
        if !simOnly && !benchCombat && directorEnabled { tickCoach(dt); tickDirector(dt) }
        updateTelegraphs(dt)
        if autoPickUpgrades {
            while pendingLevels > 0 && phase == .playing {
                let o = rollUpgrades()
                if o.isEmpty { pendingLevels = 0; break }
                chooseUpgrade(0)
            }
        }
    }

    /// Run `n` ticks.
    public func step(_ n: Int) { for _ in 0..<n { tick() } }

    // ---------- events ----------
    @inline(__always) func emit(_ e: GameEvent) { if !simOnly { events.append(e) } }
    /// `loud`: pass `m.isPlayer` exactly where the web passes it (nil = the web's undefined: full volume).
    @inline(__always) func sound(_ id: SoundID, _ x: Float, _ z: Float, _ loud: Bool? = nil) {
        if !simOnly { events.append(.sound(id, pos: Vec2(x, z), loud: loud)) }
    }
    @inline(__always) func haptic(_ k: HapticKind) { if !simOnly && !benchCombat && !attract { events.append(.haptic(k)) } }
    /// Text is only built when the game is not `simOnly` (calibration never makes any).
    func toast(_ text: @autoclosure () -> GameText, _ kind: ToastKind) { if !simOnly && !attract { events.append(.toast(text: text(), kind: kind)) } }
    func banner(_ title: @autoclosure () -> GameText, _ sub: @autoclosure () -> GameText, _ teal: Bool) {
        if !simOnly { events.append(.banner(title: title(), subtitle: sub(), teal: teal)) }
    }
    func hitStop(_ dur: Float, _ k: Float) { if !attract && !simOnly { events.append(.hitStop(duration: dur, scale: k)) } }
    func shake(_ a: Float) { if !simOnly && a > 0 { events.append(.shake(amount: a)) } }

    /// Hand every buffered event to `body` (in order) and clear the buffer.
    public func drainEvents(_ body: (GameEvent) -> Void) {
        for e in events { body(e) }
        events.removeAll(keepingCapacity: true)
    }
    public func clearEvents() { events.removeAll(keepingCapacity: true) }

    // ---------- telegraphs ----------
    func teleAlloc() -> Int {
        for k in 0..<telegraphs.count where !telegraphs[k].active { return k }
        return -1
    }
    /// Ring (pulsing warning or expanding shock ring). Returns its pool slot (-1: none).
    @discardableResult
    func teleRing(_ x: Float, _ z: Float, _ r: Float, _ cr: Float, _ cg: Float, _ cb: Float, _ life: Float, r1: Float? = nil, pulse: Bool = true, cause: TelegraphCause) -> Int {
        if simOnly { return -1 }
        let k = teleAlloc(); if k < 0 { return -1 }
        var e = Telegraph()
        e.active = true; e.shape = .ring; e.cause = cause; e.x = x; e.z = z; e.r0 = r; e.r1 = r1 ?? r
        e.r = cr; e.g = cg; e.b = cb; e.t = 0; e.life = life; e.pulse = pulse
        telegraphs[k] = e
        events.append(.telegraph(index: k, shape: .ring, cause: cause, pos: Vec2(x, z)))
        return k
    }
    /// Disc that fills up as the impact approaches (acid globs).
    func teleFill(_ x: Float, _ z: Float, _ r: Float, _ cr: Float, _ cg: Float, _ cb: Float, _ life: Float, cause: TelegraphCause) {
        if simOnly { return }
        let k = teleAlloc(); if k < 0 { return }
        var e = Telegraph()
        e.active = true; e.shape = .fill; e.cause = cause; e.x = x; e.z = z; e.r0 = r; e.r1 = r
        e.r = cr; e.g = cg; e.b = cb; e.t = 0; e.life = life; e.pulse = false
        telegraphs[k] = e
        events.append(.telegraph(index: k, shape: .fill, cause: cause, pos: Vec2(x, z)))
    }
    /// Brute charge lane.
    func teleLane(_ x: Float, _ z: Float, _ dx: Float, _ dz: Float, _ len: Float, _ w: Float, _ wind: Float, _ charge: Float) {
        if simOnly { return }
        let k = teleAlloc(); if k < 0 { return }
        var e = Telegraph()
        e.active = true; e.shape = .lane; e.cause = .bruteLane; e.x = x; e.z = z; e.dx = dx; e.dz = dz; e.len = len; e.w = w
        e.r = 1.0; e.g = 0.18; e.b = 0.1; e.t = 0; e.life = wind + charge; e.wind = wind; e.pulse = true
        telegraphs[k] = e
        events.append(.telegraph(index: k, shape: .lane, cause: .bruteLane, pos: Vec2(x, z)))
    }
    func updateTelegraphs(_ dt: Float) {
        for k in 0..<telegraphs.count where telegraphs[k].active {
            telegraphs[k].t += dt
            if telegraphs[k].t >= telegraphs[k].life { telegraphs[k].active = false }
        }
    }

    // ---------- flow fields ----------
    func updateFlows() {
        flowSrc.removeAll(keepingCapacity: true)
        var anyUp = false
        for m in marines where !m.downed { anyUp = true }
        for m in marines where !anyUp || !m.downed { flowSrc.append(m.x); flowSrc.append(m.z) }
        computeFlow(swarmFlow)
        flowSrc.removeAll(keepingCapacity: true)
        flowSrc.append(marines[0].x); flowSrc.append(marines[0].z)
        computeFlow(squadFlow)
        flowSrc.removeAll(keepingCapacity: true)
        for m in marines where m.downed { flowSrc.append(m.x); flowSrc.append(m.z) }
        if !flowSrc.isEmpty { computeFlow(reviveFlow) }
        let o = objectivePoint()
        let key = (Int(o.x.rounded()), Int(o.y.rounded()))
        if key != objFlowKey {
            objFlowKey = key
            flowSrc.removeAll(keepingCapacity: true)
            flowSrc.append(o.x); flowSrc.append(o.y)
            computeFlow(objFlow)
        }
    }
    private func computeFlow(_ f: FlowField) {
        let lv = level, q = flowQueue
        flowSrc.withUnsafeBufferPointer { buf in f.compute(level: lv, sources: buf, queue: q) }
    }

    /// Where the mission wants the squad (the plan's step: the next beacon or switch, the step's zone / the player).
    func objectivePoint() -> Vec2 {
        switch currentStep {
        case .ring?:
            let b = nextBeacon()
            if b >= 0 { return Vec2(beacons[b].x, beacons[b].z) }
        case .switches?:
            let s = nextSwitch()
            if s >= 0 { return switches[s].position }
        case .hold(let h)?: return zoneCenter(h.zone)
        case .boss(let b)?: return zoneCenter(b.zone)
        case .extract?: return Vec2(level.lift.x, level.lift.z)
        case nil: break
        }
        return Vec2(marines[0].x, marines[0].z)
    }
}
