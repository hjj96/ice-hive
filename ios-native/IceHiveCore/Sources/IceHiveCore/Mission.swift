import Foundation

// ================================================================
//  MISSION PLAN — a mission's objectives as data (R1 «Mission modules»;
//  design §1.6, tech §3 «a data-driven mission script», §6). A plan is an
//  ordered list of steps, each one a reusable objective module:
//    RING     charge a set of beacon rings, in any order (the hive defends
//             each one: an opening horde, pushes at 30 / 62 / 90 % charge)
//    SWITCH   short rings (3–6 s) on breakers, valves, doors, cranes, in any
//             order (R6 hangs its props on them)
//    HOLD     reach a zone, then hold it for N s (the lift: its shock pulse;
//             a boss can come into the hold and lock it until she dies)
//    BOSS     a boss fight as a step of its own (her arena: a zone)
//    EXTRACT  reach the lift and ride it out
//  Every step carries its director settings (stage multipliers, opening
//  horde, travel allowance), its HUD text ids and its calibration stage
//  names; the runtime that plays a plan is GameMission.swift. «Operation
//  Cold Light» (RING ×3 → HOLD at the lift with the tier's Queen → EXTRACT)
//  is `MissionTemplate.coldLight`: it replays the old hard-coded stage
//  machine bit for bit (calib.jsonl byte-identical). Plain data, no
//  allocations per tick; the plan never changes during a mission.
// ================================================================

/// The reusable objective modules (design §1.6). ESCORT, DESTROY and RIDE come with later packages: a new case
/// here makes every switch over the modules in GameMission.swift ask for its behaviour.
public enum MissionModule: String, CaseIterable {
    case ring
    case switches = "switch"
    case hold
    case boss
    case extract
}

/// The two phases of every step. `approach`: on the way to the step's zone, or between its rings (the hive pressure
/// clock runs, the travel beat paces the swarm). `active`: a ring charging, the zone held, the boss fight, the ride.
public enum StepPhase: Int {
    case approach, active
}

/// One number per pacing: the legacy stream (v1.0 / v1.1) and the wave pacing (`Difficulty.waves`).
public struct PacingValue: Equatable {
    public var legacy: Float
    public var waves: Float
    public init(legacy: Float, waves: Float) { self.legacy = legacy; self.waves = waves }
    @inline(__always) public func value(_ d: Difficulty) -> Float { d.waves ? waves : legacy }
}

/// Where a HOLD or a BOSS step happens: the station's lift (its deck disc), or a circle on a deck.
public enum MissionZone: Equatable {
    case lift
    case circle(x: Float, z: Float, r: Float)
}

/// A banner the core raises (title + subtitle ids; the arguments come from the step, see `GameText.objective`).
public struct BannerText: Equatable {
    public var title: TextID
    public var sub: TextID
    public init(title: TextID, sub: TextID) { self.title = title; self.sub = sub }
}

/// Calibration stage names of a step's two phases (rows' `stage`, `stageAt`, `downSt`, `idleSt`).
public struct StepNames: Equatable {
    public var approach: String
    public var active: String
    public init(approach: String, active: String) { self.approach = approach; self.active = active }
}

// ---------------------------------------------------------------- the modules

/// RING: charge beacon rings in any order. A marine standing in a ring starts it (the hive answers with an opening
/// horde); it charges while a standing marine is inside, slower while bugs crowd it; each beacon done patches the squad
/// up and gives a breather. The numbers of the defence are the classic beacon's (GameDirector / GameWaves).
public struct RingStep: Equatable {
    /// Indices into the station's beacons (`LevelLayout.beacons`, `Game.beacons`).
    public var sites: [Int]
    public var radius: Float = BEACON_R
    /// Seconds of charge with a marine inside and the ring clear.
    public var chargeTime: Float = BEACON_TIME
    /// Bugs inside the ring (radius − 0.5 m) that contest it, and the charge rate while contested.
    public var contestedAt: Int = 6
    public var contestedRate: Float = 0.3
    /// Trickle / wave volume while a ring charges (between rings × 1).
    public var stageMul = PacingValue(legacy: 2.0, waves: 1.25)
    /// HUD lines: between rings («Light the beacons 1/3»: done, total), the hive waking / converging, a ring charging
    /// («Hold beacon ALPHA»: its name).
    public var lineText: TextID = .objLightBeacons
    public var wakingText: TextID = .objWakingBeacon
    public var convergeText: TextID = .objConvergeBeacon
    public var chargeText: TextID = .objHoldBeacon
    /// The stage name (rows also mark b1…b3 when a ring starts, c1…c3 when one is done, «trav» between them).
    public var names = StepNames(approach: "beacons", active: "beacons")
    /// The report strip's label of each beacon (nil: the classic strip — see `MissionPlan.ownStrip`).
    public var stripText: TextID? = nil

    public init(sites: [Int]) { self.sites = sites }
}

/// What a switch ring sits on (presentation; a `.breaker` switch standing on a light circuit's breaker brings that
/// circuit back when it is thrown — R6, GameProps.swift; a `.seal` switch shuts its vent for good when it is thrown:
/// no pack pours out of it again — R7's Vent Purge).
public enum SwitchKind: String, CaseIterable {
    case breaker, valve, door, crane, panel, seal
}

/// One switch: a short ring on the deck (it is not a prop in the walk grid).
public struct SwitchSite: Equatable {
    public var x: Float, z: Float
    public var radius: Float
    /// Seconds of standing in the ring (design: 3–6 s).
    public var time: Float
    public var kind: SwitchKind
    /// A seal's vent: an index into the station's `vents` (−1 none). Thrown, the vent is shut for good; while the step
    /// runs and it is open, it may pour packs (`SwitchStep.pour`).
    public var vent: Int
    /// A seal's duct mouth up on the overhead: an index into `Game.ducts` (package R4's duct mouths, −1 none). Thrown, it is
    /// shut for good (design §1.4: «for good in Vent Purge»); while the step runs and it is open, its pours climb out of it
    /// onto the routes (R4's rattle first).
    public var duct: Int
    public init(x: Float, z: Float, radius: Float = 2.2, time: Float = 4, kind: SwitchKind = .panel, vent: Int = -1, duct: Int = -1) {
        self.x = x; self.z = z; self.radius = radius; self.time = time; self.kind = kind; self.vent = vent; self.duct = duct
    }
}

/// A switch of the current SWITCH step (public view for the renderer and R6's props).
public struct SwitchState: Equatable {
    public let site: SwitchSite
    /// 0 waiting, 1 being thrown, 2 thrown.
    public internal(set) var state = 0
    public internal(set) var progress: Float = 0
    /// The hive's pushes at this switch so far (`SwitchStep.pushes`).
    public internal(set) var pushes = 0
    public var position: Vec2 { Vec2(site.x, site.z) }
    public init(site: SwitchSite) { self.site = site }
}

/// SWITCH: throw short rings in any order. A marine standing in one starts it (the hive sends a surge at it); it fills
/// while a standing marine is inside.
public struct SwitchStep: Equatable {
    public var sites: [SwitchSite]
    /// How many must be thrown (nil = all).
    public var required: Int? = nil
    /// Each switch thrown is one escalation step of the director, like a beacon (bug health and damage, specials, horde
    /// sizes). Off by default: a few seconds of work should not age the mission like a beacon defence does (the module
    /// drills showed two quick switches before a ring leave the squad facing a third-beacon defence before it levels).
    public var escalates = false
    /// The surge that answers a switch starting (× the tier's horde, × its population scale on the wave pacing); 0 = none.
    public var alarm = PacingValue(legacy: 40, waves: 10)
    /// The hive pushes again at these marks of a switch's progress (0…1): a surge of `alarm` × `pushK` from two sides at the
    /// switch, the last one from three (R7: a mission's main switches are defended like small beacons). Empty = none.
    public var pushes: [Float] = []
    public var pushK: Float = 1
    /// The progress drains while nobody stands in the ring: `drains` × the fill rate (R6's breaker ring drains too). 0 = it
    /// keeps what it has.
    public var drains: Float = 0
    /// Trickle / wave volume while a switch is being thrown (between switches × 1).
    public var stageMul = PacingValue(legacy: 2.0, waves: 1.25)
    /// HUD lines: between switches (done, total), the hive waking / converging, a switch being thrown.
    public var lineText: TextID = .objSwitches
    public var wakingText: TextID = .objWakingMove
    public var convergeText: TextID = .objConvergeMove
    public var throwText: TextID = .objHoldRing
    public var names = StepNames(approach: "switch", active: "switch")
    /// Each switch thrown thins the hive's stream for the rest of the mission: the trickle, the packs, the surges and the
    /// hordes × (1 − thins) (R7's Vent Purge: «each seal thins the spawns»). 0 = none.
    public var thins: Float = 0
    /// The open vents of the step's seals pour packs while the step runs: every `pourGap` s (± 2 s) one of them, picked at
    /// random, pours `pour` bugs (× the tier's horde, × its population scale on the wave pacing, × the stream). nil = none.
    public var pour: PacingValue? = nil
    public var pourGap: Float = 10
    /// Banner when the step begins (not as the first step: the plan's briefing is the drop banner) — nil none.
    public var banner: BannerText? = nil
    /// Toast when a switch is thrown (nil none).
    public var doneToast: TextID? = nil
    /// The report: the strip's label of each switch needed (nil: the classic strip), the score line (thrown, needed) and
    /// the score of each switch thrown.
    public var stripText: TextID? = nil
    public var scoreText: TextID? = nil
    public var score: Int = 0

    public init(sites: [SwitchSite], required: Int? = nil) { self.sites = sites; self.required = required }
    /// The number that completes the step (clamped to the sites).
    public var needed: Int { max(0, min(sites.count, required ?? sites.count)) }
}

/// The bosses a step can bring (R8's framework adds its own; the Queen is a scaled brute today, GameQueen.swift).
public enum BossKind: String, CaseIterable {
    case queen

    /// Her name in the objective line and the boss bar.
    public var name: NameRef {
        switch self {
        case .queen: return .queen
        }
    }
}

/// A boss that comes into a HOLD: `at` s into the counted hold (nil = the tier's `queen.at`; the debug `queenAt` wins
/// over both); `locks`: the hold cannot end while she lives — or before she came.
public struct BossRider: Equatable {
    public var kind: BossKind
    public var at: Float?
    public var locks: Bool
    public init(_ kind: BossKind, at: Float? = nil, locks: Bool = true) { self.kind = kind; self.at = at; self.locks = locks }
}

/// HOLD: reach the zone (the player standing in it starts the hold), then hold it: the countdown runs while any standing
/// marine is inside. The lift adds its shock pulse; a boss rider comes in and locks the hold.
public struct HoldStep: Equatable {
    public var zone: MissionZone
    /// Seconds of counted hold (∞: a holdout that only ends with the squad — no countdown on the HUD, no progress bar).
    public var time: Float
    /// The lift's shock pulse (the tier's pulseDamage / pulseInterval) while a marine stands in the zone.
    public var pulse: Bool
    public var boss: BossRider?
    /// The hold ends only with the player in the zone (the lift leaves with the player on it).
    public var releaseWithPlayer: Bool
    /// Trickle / wave volume on the way to the zone and while holding it.
    public var approachMul = PacingValue(legacy: 1.6, waves: 1.2)
    public var stageMul = PacingValue(legacy: 3.2, waves: 2.0)
    /// The opening horde when the hold starts, and the seconds to the first hold horde after it.
    public var openHorde = PacingValue(legacy: 480, waves: 105)
    public var firstHorde = PacingValue(legacy: 3, waves: 16)
    /// × the hold's periodic hordes (every 18–24 s on the wave pacing).
    public var hordeK: Float = 1
    /// The walk to the zone is the objective: the pressure clock waits for the travel allowance (path at full speed
    /// × 1.3 + 5 s).
    public var travelAllowance = true
    /// The station's dark light circuits come back one by one over the hold (R7's Breaker Run: the main generator spins
    /// up): the nearest to the zone first, at even shares of the countdown, the last one before it runs out.
    public var relights = false
    /// The report strip's label of the hold (nil: the classic strip; the boss rider adds her own item).
    public var stripText: TextID? = nil
    /// A deck hold's hint while the player is out of its zone (nil: none; the lift has its own hints).
    public var outHint: TextID? = nil
    /// The subtitle of the hold's periodic hordes (the lift: «They're climbing onto the platform»; a deck: the generic one).
    public var hordeSub: TextID
    /// Banner when the step begins (the lift: «Lift inbound»), and when the hold starts (also the opening horde's).
    public var callBanner: BannerText?
    public var holdBanner: BannerText?
    /// HUD lines: on the way (and the hive waking / converging), holding (the countdown), a boss in the hold (her name),
    /// the countdown out while she lives.
    public var approachText: TextID
    public var wakingText: TextID
    public var convergeText: TextID
    public var holdText: TextID
    public var bossText: TextID
    public var lockedText: TextID
    public var names: StepNames

    /// The defaults follow the zone: the lift keeps the classic lines and banners, a deck zone gets the generic ones.
    public init(zone: MissionZone, time: Float, pulse: Bool = false, boss: BossRider? = nil, releaseWithPlayer: Bool = false) {
        self.zone = zone; self.time = time; self.pulse = pulse; self.boss = boss; self.releaseWithPlayer = releaseWithPlayer
        hordeSub = zone == .lift ? .bannerHordeLiftSub : .bannerHordeSub
        if zone == .lift {
            callBanner = BannerText(title: .bannerLiftCalled, sub: .bannerLiftCalledSub)
            holdBanner = BannerText(title: .bannerHold, sub: .bannerHoldSub)
            approachText = .objLiftCalled; wakingText = .objWakingLift; convergeText = .objConvergeLift
            holdText = .objHoldLift; bossText = .objKillQueen; lockedText = .objLiftLocked
            names = StepNames(approach: "toLift", active: "hold")
        } else {
            callBanner = nil
            holdBanner = nil
            approachText = .objReach; wakingText = .objWakingMove; convergeText = .objConvergeMove
            holdText = .objHoldArea; bossText = .objKillBoss; lockedText = .objKillBoss
            names = StepNames(approach: "toHold", active: "hold")
        }
    }
}

/// BOSS: reach the arena; `delay` s after the player stepped in, the boss's warning (2 s), then the boss. The step
/// ends when she dies (a tier without a boss — the legacy row — skips the step).
public struct BossStep: Equatable {
    public var boss: BossKind
    public var zone: MissionZone
    /// Seconds in the arena before her warning (the debug `queenAt` wins).
    public var delay: Float
    public var approachMul = PacingValue(legacy: 1.6, waves: 1.2)
    public var stageMul = PacingValue(legacy: 3.2, waves: 2.0)
    public var travelAllowance = true
    public var approachText: TextID = .objReach
    public var wakingText: TextID = .objWakingMove
    public var convergeText: TextID = .objConvergeMove
    /// The fight (and the warning before it): her name.
    public var fightText: TextID = .objKillBoss
    public var names = StepNames(approach: "toBoss", active: "boss")
    /// The report strip's label (nil: the classic strip).
    public var stripText: TextID? = nil

    public init(_ boss: BossKind = .queen, zone: MissionZone, delay: Float = 3) { self.boss = boss; self.zone = zone; self.delay = delay }
}

/// EXTRACT: reach the lift (the player standing on it), then ride it out for `duration` s; the mission is won when the
/// last step ends. Marines on the lift stand still while it rises, bugs on it fall off.
public struct ExtractStep: Equatable {
    public var duration: Float = 4.6
    public var approachMul = PacingValue(legacy: 1.6, waves: 1.2)
    public var travelAllowance = true
    public var approachText: TextID = .objLiftCalled
    public var wakingText: TextID = .objWakingLift
    public var convergeText: TextID = .objConvergeLift
    public var rideText: TextID = .objExtract
    public var names = StepNames(approach: "toLift", active: "extract")
    /// The report strip's label (nil: the classic strip).
    public var stripText: TextID? = nil

    public init() {}
}

/// One step of a plan.
public enum MissionStep: Equatable {
    case ring(RingStep)
    case switches(SwitchStep)
    case hold(HoldStep)
    case boss(BossStep)
    case extract(ExtractStep)

    public var module: MissionModule {
        switch self {
        case .ring: return .ring
        case .switches: return .switches
        case .hold: return .hold
        case .boss: return .boss
        case .extract: return .extract
        }
    }

    /// The step's report strip label (nil: it keeps the classic strip).
    public var stripText: TextID? {
        switch self {
        case .ring(let r): return r.stripText
        case .switches(let s): return s.stripText
        case .hold(let h): return h.stripText
        case .boss(let b): return b.stripText
        case .extract(let e): return e.stripText
        }
    }
}

/// Mission modifiers (design §1.6). DARK (R6): every light circuit of the station starts off — the squad takes the light
/// back breaker by breaker (GameProps.swift). Data for the packages that give the others behaviour (HEAVY OVERHEAD:
/// R2 / R5, TIMED and STORM later).
public enum MissionModifier: String, CaseIterable {
    case dark, storm, timed, heavyOverhead
}

/// A mission: its steps in order (at least one), its modifiers, the briefing banner at the drop.
public struct MissionPlan: Equatable {
    public var id: String
    public var steps: [MissionStep]
    public var modifiers: Set<MissionModifier>
    /// The drop banner (nil = none): its subtitle takes the station name when its id asks for one.
    public var briefing: BannerText?
    /// The hive's stream on Recruit, Veteran, Nightmare (× the trickle, the packs, the surges and the hordes for the whole
    /// mission; nil = 1 on every tier): a mission's own tier scaling on top of the tier's numbers.
    public var tierStream: [Float]? = nil

    public init(id: String, steps: [MissionStep], modifiers: Set<MissionModifier> = [], briefing: BannerText? = nil) {
        self.id = id; self.steps = steps; self.modifiers = modifiers; self.briefing = briefing
    }

    /// Beacons the plan's RING steps charge (the report's «beacons N/M»).
    public var ringSiteCount: Int {
        var n = 0
        for s in steps { if case .ring(let r) = s { n += r.sites.count } }
        return n
    }

    /// Switches the plan's SWITCH steps need (the report's switch score line).
    public var switchCount: Int {
        var n = 0
        for s in steps { if case .switches(let w) = s { n += w.needed } }
        return n
    }

    /// The plan draws its own report strip (a step names its strip label: R7's missions); else the report keeps the classic
    /// strip, BEACON ×3 · LIFT · QUEEN · EXTRACTION.
    public var ownStrip: Bool { steps.contains { $0.stripText != nil } }
}

// ---------------------------------------------------------------- templates and their calibration

/// A win-rate band of a template's calibration rows (autopilot, medium graphics) on one tier, and optionally a ceiling on
/// the squad downs per run (the classic Recruit band: ≤ 0.5).
public struct CalibBand: Equatable {
    public var tier: Int
    public var winLo: Float?
    public var winHi: Float?
    public var downsHi: Float?
    public init(tier: Int, winLo: Float? = nil, winHi: Float? = nil, downsHi: Float? = nil) {
        self.tier = tier; self.winLo = winLo; self.winHi = winHi; self.downsHi = downsHi
    }
}

/// An AFK band of a template: one AFK run per class on `tier` (420 s, nobody touches the screen), the player's first down
/// within `firstDownMax` s in every run (the classic bands: Veteran 120 s, Recruit 270 s).
public struct AFKBand: Equatable {
    public var tier: Int
    public var firstDownMax: Float
    public init(tier: Int, firstDownMax: Float) { self.tier = tier; self.firstDownMax = firstDownMax }
}

/// A template's calibration preset (`icehive-calib --preset <id>`): runs per class on each tier (`tierRuns` overrides
/// `runs` per tier), seeds from its own base, its bands; `gated` templates are the CI's mission gate (`--preset missions`,
/// its own step and rows: the classic `gate` rows and calib.jsonl stay as they were).
public struct MissionCalib {
    public var tiers: [Int]
    public var runs: Int
    public var tierRuns: [Int: Int]
    public var seedBase: UInt32
    public var bands: [CalibBand]
    public var afk: [AFKBand]
    public var gated: Bool
    public init(tiers: [Int] = [0, 1], runs: Int = 2, tierRuns: [Int: Int] = [:], seedBase: UInt32, bands: [CalibBand],
                afk: [AFKBand] = [], gated: Bool = false) {
        self.tiers = tiers; self.runs = runs; self.tierRuns = tierRuns; self.seedBase = seedBase; self.bands = bands; self.afk = afk
        self.gated = gated
    }
    /// Runs per class on `tier`.
    public func runs(_ tier: Int) -> Int { tierRuns[tier] ?? runs }
}

/// A named plan builder (the plan of a station: its beacons, its lift, its decks), the station it is played on and its
/// calibration preset.
public struct MissionTemplate {
    public let id: String
    /// The mission's name (the title's mission choice, logs); nil for the drills.
    public let name: TextID?
    /// The station the mission is played on (nil: the station given — the classic «Кельвин-9» in the app, a generated
    /// station in calibration). R7's missions lay Kelvin-9's interactive props (`KelvinStation.missions`).
    public let station: LevelSource?
    public let calib: MissionCalib?
    public let build: (Level) -> MissionPlan

    public init(id: String, name: TextID? = nil, station: LevelSource? = nil, calib: MissionCalib? = nil, build: @escaping (Level) -> MissionPlan) {
        self.id = id; self.name = name; self.station = station; self.calib = calib; self.build = build
    }

    /// The level this mission plays (its own station, else `fallback`).
    public func level(seed: UInt32 = 0, fallback: LevelSource = KelvinStation()) -> Level { Level(source: station ?? fallback, seed: seed) }

    /// A fixed plan (tests, demos).
    public static func custom(_ plan: MissionPlan) -> MissionTemplate { MissionTemplate(id: plan.id) { _ in plan } }

    /// «Operation Cold Light», the classic mission: RING every beacon → HOLD the lift 100 s (its shock pulse, the tier's
    /// Queen 35 / 35 / 30 s in, locked while she lives, the lift leaves with the player on it) → EXTRACT. Its
    /// calibration preset is the classic `gate`.
    public static let coldLight = MissionTemplate(id: "cold-light", name: .missionColdLight) { level in
        MissionPlan(id: "cold-light", steps: [
            .ring(RingStep(sites: Array(level.layout.beacons.indices))),
            .hold(HoldStep(zone: .lift, time: LIFT_TIME, pulse: true, boss: BossRider(.queen), releaseWithPlayer: true)),
            .extract(ExtractStep()),
        ], briefing: BannerText(title: .bannerDrop, sub: .bannerDropSub))
    }

    /// Module drills: one small plan per module (and one with all of them in a row), built from the station's own
    /// decks — the core tests play each on autopilot, `icehive-calib --preset drills` gives their rows (reported, not
    /// gated). They are the examples a new mission starts from.
    public static let drills: [MissionTemplate] = {
        let bands = [CalibBand(tier: 0, winLo: 90), CalibBand(tier: 1, winLo: 70)]
        func calib(_ k: UInt32) -> MissionCalib { MissionCalib(seedBase: 200_000 + 1000 * k, bands: bands) }
        return [
            MissionTemplate(id: "drill-ring", calib: calib(0)) { lv in
                MissionPlan(id: "drill-ring", steps: [.ring(RingStep(sites: [DrillSpots(lv).beacon]))])
            },
            MissionTemplate(id: "drill-switch", calib: calib(1)) { lv in
                MissionPlan(id: "drill-switch", steps: [.switches(DrillSpots(lv).switchStep)])
            },
            MissionTemplate(id: "drill-hold", calib: calib(2)) { lv in
                MissionPlan(id: "drill-hold", steps: [.hold(DrillSpots(lv).holdStep)])
            },
            MissionTemplate(id: "drill-boss", calib: calib(3)) { _ in
                MissionPlan(id: "drill-boss", steps: [.boss(BossStep(.queen, zone: .lift))])
            },
            MissionTemplate(id: "drill-extract", calib: calib(4)) { _ in
                MissionPlan(id: "drill-extract", steps: [.extract(ExtractStep())])
            },
            MissionTemplate(id: "drill-all", calib: calib(5)) { lv in
                // (the chain: a shorter hold, and 8 s in the arena to patch up before her warning — right after the hold the
                // squad met her worn down: 62.5 % on Veteran with the drills' own 40 s hold and 3 s delay)
                let d = DrillSpots(lv)
                var hold = d.holdStep
                hold.time = 25
                return MissionPlan(id: "drill-all", steps: [.switches(d.switchStep), .ring(RingStep(sites: [d.beacon])), .hold(hold),
                                                            .boss(BossStep(.queen, zone: .lift, delay: 8)), .extract(ExtractStep())])
            },
        ]
    }()

    /// The missions a player can start (the classic first; R7: Breaker Run, Vent Purge — MissionsKelvin.swift).
    public static var playable: [MissionTemplate] { [coldLight] + missions }

    /// Every template (the classic first).
    public static var all: [MissionTemplate] { [coldLight] + missions + drills }

    public static func named(_ id: String) -> MissionTemplate? { all.first { $0.id == id } }
}

/// Where the drills put their rings and zones on a station: open deck spots around the landing pad (deterministic scans
/// of the walk grid) — three switches 8–26 m out and 8 m apart, a hold 14–40 m out (a real walk: Kelvin-9's hub) — and
/// the beacon nearest to the pad.
struct DrillSpots {
    let beacon: Int
    let switches: [Vec2]
    let hold: Vec2

    init(_ level: Level) {
        let s = level.start
        var best = 0
        var bd: Float = .infinity
        for (k, b) in level.layout.beacons.enumerated() {
            let d = hypotf2(b.x - s.x, b.z - s.y)
            if d < bd { bd = d; best = k }
        }
        beacon = best
        var sw: [Vec2] = []
        for (a, b) in [(Float(8), Float(20)), (8, 22), (10, 26)] {
            sw.append(level.openSpot(near: s, from: a, to: b, clearance: 2.4, avoid: sw, avoidR: 8) ?? s)
        }
        switches = sw
        hold = level.openSpot(near: s, from: 14, to: 40, clearance: 3.6) ?? s
    }

    var switchStep: SwitchStep {
        let kinds: [SwitchKind] = [.breaker, .valve, .door]
        return SwitchStep(sites: switches.enumerated().map { SwitchSite(x: $0.element.x, z: $0.element.y, time: 5, kind: kinds[$0.offset % 3]) })
    }

    var holdStep: HoldStep {
        var h = HoldStep(zone: .circle(x: hold.x, z: hold.y, r: 3.5), time: 40)
        h.openHorde = PacingValue(legacy: 240, waves: 50)
        h.firstHorde = PacingValue(legacy: 12, waves: 20)
        return h
    }
}

extension Level {
    /// A deck spot `from`…`to` m from `p` where a disc of radius `clearance` is open floor (centre, 8 points on its rim
    /// and 8 halfway), at least `avoidR` from every `avoid` point: the first one of a scan ring by ring (1 m), angle by
    /// angle (15°).
    func openSpot(near p: Vec2, from: Float, to: Float, clearance: Float, avoid: [Vec2] = [], avoidR: Float = 0) -> Vec2? {
        var r = from
        while r <= to {
            for a in 0..<24 {
                let ang = Float(a) * TAU / 24
                let c = Vec2(p.x + cosf2(ang) * r, p.y + sinf2(ang) * r)
                if avoid.contains(where: { hypotf2(c.x - $0.x, c.y - $0.y) < avoidR }) { continue }
                if !walkable(c.x, c.y) { continue }
                var ok = true
                for k in 0..<8 where ok {
                    let b = Float(k) * TAU / 8, dx = cosf2(b), dz = sinf2(b)
                    ok = walkable(c.x + dx * clearance, c.y + dz * clearance) && walkable(c.x + dx * clearance * 0.5, c.y + dz * clearance * 0.5)
                }
                if ok { return c }
            }
            r += 1
        }
        return nil
    }
}
