import Foundation

// ================================================================
//  TUNING TABLES — bug types, classes, quality caps, difficulty
//  (numbers are 1:1 from 01-core.js / 06-marines.js / 08-director.js)
// ================================================================

public enum BugType: Int, CaseIterable {
    /// Stage 1 R4: the Dropper (design §1.1.3) — the overhead's own bug: it rides the routes, perches above the squad,
    /// drops after a 0.9 s telegraph and pins a marine. Never part of the director's deck draw (`pickType`).
    case runner = 0, spitter = 1, brute = 2, boomer = 3, dropper = 4

    public var spec: BugSpec { BUG_SPECS[rawValue] }
    public var id: String { spec.id }
}

public struct BugSpec {
    /// Stable id (catalog: name.bug.<id>).
    public let id: String
    public let hp: Float
    public let speed: Float
    public let radius: Float
    public let dmg: Float
    public let atkCd: Float
    public let xp: Int
    public let scale: Float
    public let mass: Float
}

public let BUG_SPECS: [BugSpec] = [
    BugSpec(id: "runner", hp: 15, speed: 4.5, radius: 0.27, dmg: 5, atkCd: 0.8, xp: 1, scale: 0.8, mass: 1),
    BugSpec(id: "spitter", hp: 44, speed: 3.0, radius: 0.36, dmg: 8, atkCd: 1.2, xp: 3, scale: 1.02, mass: 1.6),
    BugSpec(id: "brute", hp: 360, speed: 2.6, radius: 0.85, dmg: 16, atkCd: 1.3, xp: 10, scale: 2.0, mass: 7),
    BugSpec(id: "boomer", hp: 55, speed: 3.6, radius: 0.44, dmg: 24, atkCd: 1.0, xp: 3, scale: 1.15, mass: 2),
    // Stage 1 R4 (design §1.1.3, Veteran): HP 30 × hpMul (two rifle bolts early, three late), 4.0 m/s on the deck (5.5 on
    // the routes: DROPPER_ROUTE_K), bite 6 (× the tier's bite factor), XP 3
    BugSpec(id: "dropper", hp: 30, speed: 4.0, radius: 0.34, dmg: 6, atkCd: 0.7, xp: 3, scale: 1.0, mass: 1.4),
]
// (first-sighting tips: GameText.bugTip)

// raw type / state codes used in the SoA arrays
let T_RUN: UInt8 = 0, T_SPIT: UInt8 = 1, T_BRUTE: UInt8 = 2, T_BOOM: UInt8 = 3, T_DROP: UInt8 = 4
/// Bug types the per-type tables hold (BugType.allCases.count).
let BUG_TYPES = 5

/// Bug behaviour state (raw values are what `Swarm.state` stores).
public enum BugState: UInt8 {
    /// `leap`: a runner's pounce (wave pacing) — airborne for `LEAP_T` s, its height arcs over the deck.
    case move = 0, climb = 1, wind = 2, charge = 3, swell = 4, leap = 5
    // ---- the overhead (Stage 1 R2, GameOverhead.swift). In these states `Swarm.heights` is the ABSOLUTE world height
    // (every other state: the offset from the floor under the bug): a route over the void has no floor under it.
    /// On an overhead route, riding on top of it (moving or waiting above its marine).
    case high = 6
    /// Climbing a riser (an abyss column, a deck post, a mast) up to its route, nose up.
    case riser = 7
    /// The drop's telegraph (tech.md «dropWind», design «coil»): committed to a landing point, the closing `.dropZone`
    /// ring on the deck under it (`Game.dropZones`); `DROP_T` before the landing it lets go.
    case coil = 8
    /// The drop in flight onto its fixed landing point (it does not home: a step or a dash out of the ring saves you).
    case drop = 9
    /// Knocked off a route (fire, frost, a blast) or hopping down: it falls without attacking — a frozen one shatters.
    case fall = 10
    // ---- Stage 1 R4 «Overhead bugs» (GameOverhead.swift / GameOverheadBugs.swift); `heights` stays absolute
    /// The Dropper holds a marine it landed on (the PIN, design §1.1.3): on the deck beside the marine (within every deck
    /// weapon's reach), gnawing; a dash, 15 damage taken, the pin's time running out or the marine going down ends it.
    case pin = 11
    /// A spitter perched on the overhead (design §1.1.3 «perched spitters»): still at a perch point against the void,
    /// spitting from height — longer range (14 m), slower wind-up (0.65 s) and glob (1.1 s flight).
    case perch = 12
    // ---- Stage 2 B1, the boss framework (GameBoss.swift / GameBossBody.swift); `heights` stays absolute
    /// A part of a boss's chain body: placed by the boss every tick along its head's path (the swarm's own AI never moves
    /// it), its hits routed to the boss bar.
    case boss = 13
}
let S_MOVE: UInt8 = 0, S_CLIMB: UInt8 = 1, S_WIND: UInt8 = 2, S_CHARGE: UInt8 = 3, S_SWELL: UInt8 = 4, S_LEAP: UInt8 = 5
let S_HIGH: UInt8 = 6, S_RISER: UInt8 = 7, S_COIL: UInt8 = 8, S_DROP: UInt8 = 9, S_FALL: UInt8 = 10
let S_PIN: UInt8 = 11, S_PERCH: UInt8 = 12, S_BOSS: UInt8 = 13
/// Seconds a runner's leap lasts (its state timer counts it down; height peaks halfway).
public let LEAP_T: Float = 0.36

// ---------- the overhead's drop (design.md §1.1.4 drop language, §1.1.6 fairness; tech.md §2.3) ----------
/// The flight of a drop (s): it lets go DROP_T before landing; the warning before that is the coil.
public let DROP_T: Float = 0.3
/// The landing ring: it closes from DROP_RING0 to DROP_RING (m); a marine inside DROP_RING at the landing is hit.
public let DROP_RING0: Float = 2.0
public let DROP_RING: Float = 1.4
/// A drop is aimed at a marine DROP_MIN…DROP_MAX m away in plan (the drop windows of the routes use the same band).
public let DROP_MIN: Float = 1.5
public let DROP_MAX: Float = 6.5
/// Fairness: no drop is aimed at a marine for DROP_GRACE s after its dash or revive, and at most DROP_PER_MARINE drops
/// start on one marine within DROP_WINDOW s.
public let DROP_GRACE: Float = 2
public let DROP_WINDOW: Float = 3
public let DROP_PER_MARINE = 2
/// Footprint hits: bullets strike a bug up on a route at its plan position with its radius × FOOTPRINT_K (the core stays
/// 2-D); blasts reach the overhead at BLAST_UP × their radius; a burning bug loses its grip after GRIP_T s.
public let FOOTPRINT_K: Float = 1.3
public let BLAST_UP: Float = 0.6
public let GRIP_T: Float = 0.8
/// A bug that found no drop for this long hops down to the deck (s).
public let ROUTE_PATIENCE: Float = 10
/// The bots and the turret start answering a drop telegraph this long into its coil (s): a human reaction time.
public let BOT_REACT: Float = 0.35

// ---------- Stage 1 R4 «Overhead bugs» (design §1.1.3–1.1.5) ----------
/// The Dropper on the routes: × its deck speed (5.5 m/s on racks, trays, catwalks and ducts against 4.0 on the deck);
/// on a cable it is slow (× DROPPER_CABLE_K: cables are the runners' fast lanes).
public let DROPPER_ROUTE_K: Float = 1.375
public let DROPPER_CABLE_K: Float = 0.8
/// A Dropper landing on a marine: 14 × the damage multiplier (design: «On a hit: 14 × the damage multiplier»), then the pin.
public let DROPPER_LAND: Float = 14
/// A Dropper waits up there this long for a drop before it hops down (an ambusher: longer than a runner's ROUTE_PATIENCE).
public let DROPPER_PATIENCE: Float = 20
/// The pin breaks once the pinning Dropper has taken this much damage since it landed (design: «any hit of 15 or more
/// frees the marine» — counted over the pin, so the squad's fire, whatever the weapon, gets it off).
public let PIN_BREAK: Float = 15
/// Seconds between the pinning Dropper's gnaws (each `pinGnaw` × PIN_BITE_T × the damage multiplier).
public let PIN_BITE_T: Float = 0.4
/// How far from the marine's centre the pinning Dropper holds on (m): beside the marine, never over its head and shoulders
/// (the class colour stays readable from the 57° camera).
public let PIN_REACH: Float = 0.62
/// A pinned bot (or the calibration autopilot) dashes out this long after the pin started, when its dash is ready.
public let PIN_REACT: Float = 0.45
/// The calibration autopilot (the player's seat) starts reading a Dropper's drop ring this far into its warning (s), spread
/// over the drops: on Veteran's 0.9 s about half come too late to step out cleanly — a person, not a perfect dodger (the
/// squad bots sidestep every ring, design §1.1.5).
public let AUTOPILOT_DROP_REACT: ClosedRange<Float> = 0.3...0.9
/// Perched spitters: range, wind-up and glob flight from a perch (the deck spitter: 11 m, 0.5 s, 0.95 s); at most
/// PERCH_MAX perched within PERCH_SPACING m; a perch with no marine in range for PERCH_LEAVE s is left.
public let PERCH_RANGE: Float = 14
public let PERCH_WIND: Float = 0.65
public let PERCH_GLOB: Float = 1.1
public let PERCH_SPACING: Float = 20
public let PERCH_MAX = 2
public let PERCH_LEAVE: Float = 8
/// Duct mouths (design §1.1.3): the grille rattles DUCT_RATTLE s before a pack pours out; DUCT_HP of damage shoots it
/// shut for DUCT_SHUT s (then the hive chews through); rounds aimed up strike it within DUCT_R m of the mouth (plan).
public let DUCT_HP: Float = 120
public let DUCT_RATTLE: Float = 2
public let DUCT_SHUT: Float = 45
public let DUCT_R: Float = 0.6

/// What a bug feels on the wave pacing (`Swarm.moods`): calm, a hesitation before a surge, a feint (backing off), a surge
/// (a sudden burst of speed), flight from a blast, the panic of a burning bug.
public enum BugMood: UInt8 {
    case calm = 0, hesitate = 1, feint = 2, surge = 3, flee = 4, panic = 5
}
let M_CALM: UInt8 = 0, M_HESITATE: UInt8 = 1, M_FEINT: UInt8 = 2, M_SURGE: UInt8 = 3, M_FLEE: UInt8 = 4, M_PANIC: UInt8 = 5

// ---------- classes ----------
public enum MarineClass: Int, CaseIterable {
    case assault = 0, pyro = 1, cryo = 2, gunner = 3

    public var spec: ClassSpec { CLASS_SPECS[rawValue] }
    public var id: String { spec.id }

    public init?(id: String) {
        guard let k = CLASS_SPECS.firstIndex(where: { $0.id == id }) else { return nil }
        self.init(rawValue: k)
    }
}

/// Weapon / ability tuning of one class. Fields that a class does not use are 0.
public struct ClassSpec {
    /// Stable id (catalog: class.<id>.name / .weapon / .ability / .ability_short / .desc).
    public let id: String
    /// Laser / visor colour 0xRRGGBB.
    public let laser: UInt32
    /// Armour trim colour 0xRRGGBB.
    public let trim: UInt32
    // projectile weapons
    public var rof: Float = 0
    public var dmg: Float = 0
    public var pspeed: Float = 0
    public var pierce: Int = 0
    public var spread: Float = 0
    public var range: Float = 0
    public var mag: Int = 0
    public var reload: Float = 0
    public var spinTime: Float = 0
    // continuous weapons
    public var dps: Float = 0
    public var cone: Float = 0
    public var burn: Float = 0
    public var burnDps: Float = 0
    public var chill: Float = 0
    public var heatTime: Float = 0
    public var energyTime: Float = 0
    // ability cooldown (s)
    public var abCd: Float = 0
}

public let CLASS_SPECS: [ClassSpec] = {
    var assault = ClassSpec(id: "assault", laser: 0xff2a22, trim: 0xb8322a)
    assault.rof = 9; assault.dmg = 17; assault.pspeed = 74; assault.pierce = 1; assault.spread = 0.035; assault.range = 24
    assault.mag = 40; assault.reload = 1.3; assault.abCd = 8
    var pyro = ClassSpec(id: "pyro", laser: 0xffa214, trim: 0xd29a1c)
    pyro.dps = 80; pyro.range = 7.4; pyro.cone = 0.36; pyro.burn = 4; pyro.burnDps = 11; pyro.heatTime = 6.5; pyro.abCd = 12
    var cryo = ClassSpec(id: "cryo", laser: 0x30b4ff, trim: 0x3a9ccc)
    cryo.dps = 34; cryo.range = 11.5; cryo.chill = 2.4; cryo.energyTime = 7.5; cryo.abCd = 13
    var gunner = ClassSpec(id: "gunner", laser: 0x3cff58, trim: 0x4fa83c)
    gunner.rof = 22; gunner.dmg = 9.5; gunner.pspeed = 95; gunner.pierce = 0; gunner.spread = 0.075; gunner.range = 26
    gunner.heatTime = 7; gunner.spinTime = 0.55; gunner.abCd = 18
    return [assault, pyro, cryo, gunner]
}()

// (call-signs are bound to the class: NameRef.callsign(cls); the player is NameRef.player)

// ---------- quality tiers (only the gameplay cap matters to the core) ----------
public enum QualityTier: String, CaseIterable {
    case low, med, high
    /// Live-bug cap of the tier on the wave pacing (native-vx-feel: fewer bugs, each one matters — High 350,
    /// Medium 250, Low 220; the director's own peaks stay near 250–300).
    public var bugCap: Int {
        switch self {
        case .low: return 220
        case .med: return 250
        case .high: return 350
        }
    }
    /// The v1.0 / v1.1 caps (web QUALITY[q].cap) — the legacy pacing (`Difficulty.waves == false`) keeps them.
    public var legacyCap: Int {
        switch self {
        case .low: return 700
        case .med: return 1400
        case .high: return 2500
        }
    }
}

// ---------- mission timing ----------
public let BEACON_TIME: Float = 60
public let LIFT_TIME: Float = 100
public let BEACON_R: Float = 4.6
/// Bots keep their targets across kills and fire continuously, so their base damage is lower than the player's.
public let BOT_DMG: Float = 0.6
/// Specials are capped so a single horde can never be a wall of brutes or a carpet of boomers.
let SPECIAL_CAP: [Int] = [0, 30, 12, 18, 0]
/// The live caps of specials on the wave pacing (brutes + 1 per beacon done), × the tier's specCap. (The Dropper is never
/// drawn by `pickType`: its own cap is `Difficulty.dropperCap`.)
let WAVE_SPECIAL_CAP: [Int] = [0, 14, 5, 10, 0]

// ================================================================
//  DIFFICULTY — the v1.1 «Ставки» tiers (web 01-core.js DIFF / TH, calibrated rows of
//  origin/v1.1/a-threat 8e95162). Every field multiplies or replaces a v1.0 constant
//  where it acts (director, swarm, marines, the bosses: a BossSpec row per boss — Boss.swift,
//  the Queen's built in GameQueen.swift). `legacyV10` is a hidden row that
//  reproduces v1.0 exactly (no Матка, no pressure, no stall clock, runners scale with HP):
//  the calibration port check and the v1.0 regression test run on it.
//  Native deviations from the web numbers are only allowed through the calibration
//  protocol (ios-native/README.md «v1.1 Ставки»); each one is noted next to its field.
// ================================================================

/// Mission source of the Матка's damage: SRC_QUEEN in the web damage-source table.
public let SRC_QUEEN = 4

/// Who dealt a hit to a marine (web hurtMarine `src`): the bug type, the Матка, or anything else.
public enum DamageSource: Int, CaseIterable {
    /// Stage 1 R4: `dropper` (its landing and its gnaw). The calibration ledger keeps its six slots (`ledger`): a Dropper's
    /// damage counts in the runner's slot there (the classic rows keep their bytes), and the overhead's own numbers
    /// (`CalibOverhead`) count it apart. Stage 2 B4: `threader` (its slam, crush, rime, steam, crash and charge) — in the
    /// boss's slot of the ledger (the Queen's: the classic rows keep their bytes), its own loss tip.
    case environment = -1, runner = 0, spitter = 1, brute = 2, boomer = 3, queen = 4, dropper = 5, threader = 6

    init(bugType ty: UInt8) {
        switch ty {
        case T_RUN: self = .runner
        case T_SPIT: self = .spitter
        case T_BRUTE: self = .brute
        case T_BOOM: self = .boomer
        case T_DROP: self = .dropper
        default: self = .environment
        }
    }

    /// Slot in the six-slot calibration ledgers (`hurtBy`, `squadDownBy`: environment, runner, spitter, brute, boomer, the boss —
    /// the Матка, the Threader).
    var ledger: Int {
        switch self {
        case .dropper: return DamageSource.runner.rawValue + 1
        case .threader: return DamageSource.queen.rawValue + 1
        default: return rawValue + 1
        }
    }
}

public struct Difficulty: Equatable {
    /// Position in `tiers` (0 Новобранец, 1 Ветеран, 2 Кошмар), -1 = the hidden legacy row.
    public var index: Int = -1
    public var id: String = "v10"
    /// Score multiplier of the mission report (web mul).
    public var scoreMul: Float = 1
    /// × bug HP multiplier (DIR.hpMul).
    public var hp: Float = 1
    /// × bug damage multiplier (DIR.dmgMul).
    public var dmg: Float = 1
    /// × trickle rate (not in attract mode, which uses 3).
    public var trickle: Float = 1
    /// × every horde (startHorde, beacon waves).
    public var horde: Float = 1
    /// Beacon horde size = 270 + step · beacons done.
    public var beaconHordeStep: Float = 50
    /// Special-bug draw: rnd() / specials (spitter / brute / boomer).
    public var specials: Float = 1
    /// × special caps (float, not rounded: web `typeAlive ≥ (cap + 2·done) · specCap`).
    public var specialCap: Float = 1
    /// Bot base damage (× weapon damage) = BOT_DMG × the tier's bot factor.
    public var botDamage: Float = BOT_DMG
    /// Bots grow with every player upgrade: × damage.
    public var botGrow: Float = 1.04
    /// Passive regen: `regen` HP/s after `regenDelay` s without damage, up to `regenCap` · maxHp.
    public var regen: Float = 4
    public var regenDelay: Float = 3.5
    public var regenCap: Float = 1
    /// Share of max HP restored when a beacon completes.
    public var beaconHeal: Float = 0.25
    /// Share of max HP after a revive.
    public var reviveHp: Float = 0.45
    /// Chance that a brute drops a medkit (never the Матка).
    public var medkitChance: Float = 0.35
    /// Minimum distance of trickle spawn edges from the squad.
    public var trickleMinDist: Float = 12
    /// Lift shock pulse: × damage (0 = no pulse), interval (s), linear falloff toward the rim (0 = flat).
    public var pulseDamage: Float = 1
    public var pulseInterval: Float = 5
    public var pulseFalloff: Float = 0
    /// Stall clock: after this mission time brutes join without objective progress (∞ = never).
    public var stallTime: Float = .infinity
    /// Hive pressure grace (s of loitering before the swarm converges; ∞ = no pressure).
    public var pressureGrace: Float = .infinity
    /// Flat runner HP (one-shot fodder, × 0.88…1.12); 0 = v1.0 scaling (18 × hpMul × k).
    public var runnerHp: Float = 0
    /// The Матка, the boss of the lift hold (Stage 2 B1: a BossSpec row — `BossSpec.queen(…)`, GameQueen.swift: her warning
    /// `at` s into the counted hold (∞: none), health × the HP multiplier, speed, ram / volley / brood clocks, brood size, the
    /// horde of her rage, × the trickle while she lives).
    public var queen: BossSpec = .queenNone
    /// Stage 2 B4: the Threader, the boss of the Manifold (`BossSpec.threader(…)`, GameThreader.swift: health × the HP
    /// multiplier at its spawn, its moves' clocks, the ticks it sheds, × the arena's stream while it lives).
    public var threader: BossSpec = .threaderNone
    /// native-vx-feel: the wave pacing — real lulls and peaks instead of a constant stream, packs climbing over the
    /// rails and out of vents from several sides, a smaller swarm of smarter bugs (favourite targets, flanking arcs,
    /// hesitation, feints and surges, runner leaps, flight from blasts, panic on fire). false = the v1.0 / v1.1 stream.
    public var waves: Bool = false
    /// Wave pacing: × every spawn volume of the wave director (trickle, packs, surges, hordes).
    public var popK: Float = 1
    /// Wave pacing: × the share of spitters, brutes and boomers in the draw (fewer runners, more bugs that matter).
    public var mix: Float = 1
    /// Wave pacing: × the bite damage of runners and spitters.
    public var bite: Float = 1
    /// Wave pacing: × the XP of a kill (fewer kills, the same rhythm of level-ups).
    public var xpK: Float = 1
    // ---- the overhead (Stage 1 R2; GameOverhead.swift). Caps follow the tier, never the graphics tier, so every graphics
    // tier plays the same. Stage 1 R5 turns it on for the classic mission (tech.md §2.3: 0.15 / 0.20 / 0.25 of the packs up):
    // it acts only on a station with routes (the classic mission's «Кельвин-9» Mk II, the generated stations) — on a
    // station without them the director never sends a pack up and draws no extra random number.
    /// Share of the director's packs sent up an overhead route (the third way in, design §1.1.6); needs a station with
    /// routes and the wave pacing.
    public var routes: Float = 0
    /// Bugs up on the overhead at once, at most (design: ≤ 18).
    public var routeCap: Int = 18
    /// Drop telegraphs (coiling or in flight) at once, at most (design: ≤ 3 on screen).
    public var dropCap: Int = 3
    /// The warning of a drop, from its ring appearing to the landing (s; the coil is dropWarn − DROP_T; design: ≥ 0.9 s,
    /// Recruit + 0.3 s).
    public var dropWarn: Float = 0.9
    /// × a runner's bite when it lands a drop on a marine.
    public var dropK: Float = 1.4
    /// Seconds between two drop telegraphs starting (the whole squad).
    public var dropGap: Float = 0.8
    // ---- Stage 1 R4 «Overhead bugs», on for every tier since R5 (only on a station with routes).
    /// Live Droppers at most (design: 4 / 5 / 6).
    public var dropperCap: Int = 5
    /// Seconds a Dropper's pin holds a marine at most (design: 1.2 s, Recruit 0.8 s; the owner approved up to 1.2 s).
    public var pinT: Float = 1.2
    /// The pinning Dropper's gnaw (HP per second × the damage multiplier).
    public var pinGnaw: Float = 5
    /// The director's Dropper channel: one Dropper onto the routes every `dropperGap` s (± 30 %) while the overhead channel is
    /// open, under `dropperCap`; anti-camping then draws Droppers instead of runners. 0 = off.
    public var dropperGap: Float = 0
    /// The director's perch channel: one spitter onto the routes every `perchGap` s (± 30 %) when a free perch point is near
    /// the squad; it climbs to the perch and spits from there. 0 = off.
    public var perchGap: Float = 0

    public init() {}

    /// Новобранец — the first mission ever and anyone who picks it.
    public static let recruit: Difficulty = {
        var d = Difficulty(); d.index = 0; d.id = "rec"; d.scoreMul = 0.8
        d.hp = 1.0; d.dmg = 0.9; d.trickle = 1.09; d.horde = 1.07; d.beaconHordeStep = 50; d.specials = 1; d.specialCap = 1
        d.botDamage = BOT_DMG * 1.0; d.botGrow = 1.04; d.regen = 4; d.regenDelay = 3.5; d.regenCap = 1
        d.beaconHeal = 0.25; d.reviveHp = 0.45; d.medkitChance = 0.35; d.trickleMinDist = 12
        d.pulseDamage = 1.0; d.pulseInterval = 5; d.pulseFalloff = 0
        d.stallTime = 90; d.pressureGrace = 40; d.runnerHp = 15
        d.queen = .queen(at: 35, hp: 2500, speed: 1.5, ramT: 9, volleyT: 6, broodT: 8, broodN: 6, horde: 80, trickle: 0.4)
        d.waves = true; d.popK = 2.3; d.mix = 1.8; d.bite = 1.8; d.xpK = 1.6; d.runnerHp = 22
        d.routes = 0.15; d.routeCap = 12; d.dropCap = 2; d.dropWarn = 1.2; d.dropK = 1.2; d.dropGap = 1.0
        d.dropperCap = 4; d.pinT = 0.8; d.pinGnaw = 5; d.dropperGap = 30; d.perchGap = 36
        d.threader = .threader(hp: 3200, shedMax: 5, coilT: 15, rimeT: 12, squeezeT: 20, chargeT: 7, trickle: 0.45)
        return d
    }()
    /// Ветеран — as designed; the default after the first evacuation.
    public static let veteran: Difficulty = {
        var d = Difficulty(); d.index = 1; d.id = "vet"; d.scoreMul = 1.0
        d.hp = 1.10; d.dmg = 1.20; d.trickle = 1.25; d.horde = 1.12; d.beaconHordeStep = 30; d.specials = 1.15; d.specialCap = 1.2
        d.botDamage = BOT_DMG * 0.85; d.botGrow = 1.025; d.regen = 4; d.regenDelay = 4; d.regenCap = 0.6
        d.beaconHeal = 0.20; d.reviveHp = 0.45; d.medkitChance = 0.35; d.trickleMinDist = 11
        d.pulseDamage = 1.0; d.pulseInterval = 6; d.pulseFalloff = 0.5
        d.stallTime = 60; d.pressureGrace = 25; d.runnerHp = 15
        d.queen = .queen(at: 35, hp: 3500, speed: 1.5, ramT: 9, volleyT: 6, broodT: 8, broodN: 6, horde: 80, trickle: 0.4)
        d.waves = true; d.popK = 2.5; d.mix = 1.8; d.bite = 2.25; d.xpK = 1.6; d.runnerHp = 22
        d.routes = 0.2; d.routeCap = 15; d.dropCap = 3; d.dropWarn = 0.9; d.dropK = 1.4; d.dropGap = 0.8
        d.dropperCap = 5; d.pinT = 1.2; d.pinGnaw = 5; d.dropperGap = 22; d.perchGap = 28
        d.threader = .threader(hp: 4500, shedMax: 6, coilT: 13, rimeT: 11, squeezeT: 18, chargeT: 6, trickle: 0.8)
        return d
    }()
    /// Кошмар — the swarm is merciless, the squad weaker.
    public static let nightmare: Difficulty = {
        var d = Difficulty(); d.index = 2; d.id = "nm"; d.scoreMul = 1.5
        d.hp = 1.15; d.dmg = 1.25; d.trickle = 1.20; d.horde = 1.17; d.beaconHordeStep = 40; d.specials = 1.25; d.specialCap = 1.3
        d.botDamage = BOT_DMG * 0.80; d.botGrow = 1.02; d.regen = 3; d.regenDelay = 5; d.regenCap = 0.5
        d.beaconHeal = 0.15; d.reviveHp = 0.35; d.medkitChance = 0.25; d.trickleMinDist = 10
        d.pulseDamage = 0.8; d.pulseInterval = 7; d.pulseFalloff = 0.6
        d.stallTime = 40; d.pressureGrace = 15; d.runnerHp = 15
        d.queen = .queen(at: 30, hp: 6000, speed: 1.6, ramT: 8, volleyT: 5, broodT: 7, broodN: 8, horde: 150, trickle: 0.6)
        d.waves = true; d.popK = 2.6; d.mix = 1.8; d.bite = 2.5; d.xpK = 1.6; d.runnerHp = 22
        d.routes = 0.2; d.routeCap = 18; d.dropCap = 3; d.dropWarn = 0.9; d.dropK = 1.5; d.dropGap = 0.6
        d.dropperCap = 6; d.pinT = 1.2; d.pinGnaw = 5; d.dropperGap = 22; d.perchGap = 28
        d.threader = .threader(hp: 7500, shedMax: 6, coilT: 11, rimeT: 9, squeezeT: 16, chargeT: 5, trickle: 1.6)
        return d
    }()
    /// v1.0 exactly (hidden; calibration port check and the v1.0 regression test).
    public static let legacyV10: Difficulty = Difficulty()

    /// The three tiers of the title selector.
    public static let tiers: [Difficulty] = [.recruit, .veteran, .nightmare]

    /// Tier by index, clamped to 0…2 (web setTier).
    public static func tier(_ i: Int) -> Difficulty { tiers[max(0, min(tiers.count - 1, i))] }

    /// Web field names of `override` (calibration `--th`), in the web DIFF order.
    public static let overrideKeys: [String] = ["hp", "dmg", "trickle", "horde", "step", "spec", "specCap", "bot", "botGrow", "regen", "regenT",
                                                "regenCap", "heal", "revive", "medkit", "edge", "pulse", "pulseT", "pulseFall", "stall", "grace",
                                                "runHp", "qAt", "qHp", "qSpd", "qRamT", "qVolleyT", "qBroodT", "qBroodN", "qHorde", "qTrickle", "mul",
                                                "waves", "popK", "mix", "bite", "xpK",
                                                "routes", "routeCap", "dropCap", "dropWarn", "dropK", "dropGap",
                                                "dropperCap", "pinT", "pinGnaw", "dropperGap", "perchGap"]

    /// Set fields by their web names (`trickle`, `qHp`, …; `bot` is the factor on BOT_DMG like the web row).
    /// Returns the keys it did not know (the caller treats them as an error).
    @discardableResult
    public mutating func override(_ fields: [String: Double]) -> [String] {
        var unknown: [String] = []
        for (k, v0) in fields.sorted(by: { $0.key < $1.key }) {
            let v = Float(v0)
            switch k {
            case "hp": hp = v
            case "dmg": dmg = v
            case "trickle": trickle = v
            case "horde": horde = v
            case "step": beaconHordeStep = v
            case "spec": specials = v
            case "specCap": specialCap = v
            case "bot": botDamage = BOT_DMG * v
            case "botGrow": botGrow = v
            case "regen": regen = v
            case "regenT": regenDelay = v
            case "regenCap": regenCap = v
            case "heal": beaconHeal = v
            case "revive": reviveHp = v
            case "medkit": medkitChance = v
            case "edge": trickleMinDist = v
            case "pulse": pulseDamage = v
            case "pulseT": pulseInterval = v
            case "pulseFall": pulseFalloff = v
            case "stall": stallTime = v
            case "grace": pressureGrace = v
            case "runHp": runnerHp = v
            case "qAt": queen.at = v
            case "qHp": queen.hp = v
            case "qSpd": queen.speed = v
            case "qRamT": queen.setMove("ram") { $0.cooldown = v }
            case "qVolleyT": queen.setMove("volley") { $0.cooldown = v }
            case "qBroodT": queen.setMove("brood") { $0.cooldown = v }
            case "qBroodN": queen.setMove("brood") { $0.count = Int(v0.rounded()) }
            case "qHorde": if queen.phases.count > 1 { queen.phases[1].horde = v }
            case "qTrickle": queen.trickle = v
            case "mul": scoreMul = v
            case "waves": waves = v != 0
            case "popK": popK = v
            case "mix": mix = v
            case "bite": bite = v
            case "xpK": xpK = v
            case "routes": routes = v
            case "routeCap": routeCap = max(0, Int(v0.rounded()))
            case "dropCap": dropCap = max(0, Int(v0.rounded()))
            case "dropWarn": dropWarn = max(DROP_T + 0.05, v)
            case "dropK": dropK = v
            case "dropGap": dropGap = v
            case "dropperCap": dropperCap = max(0, Int(v0.rounded()))
            case "pinT": pinT = max(0, min(1.2, v))
            case "pinGnaw": pinGnaw = max(0, v)
            case "dropperGap": dropperGap = max(0, v)
            case "perchGap": perchGap = max(0, v)
            default: unknown.append(k)
            }
        }
        return unknown
    }

    /// The tier has a Матка (the lift waits for her).
    public var hasQueen: Bool { queen.at.isFinite }

    /// The row of boss `kind` on this tier (a new boss adds its row and its case).
    public func boss(_ kind: BossKind) -> BossSpec {
        switch kind {
        case .queen: return queen
        case .threader: return threader
        }
    }
}

// ================================================================
//  UPGRADES (level-up cards)
// ================================================================
public enum UpgradeID: String, CaseIterable {
    case dmg, rof, pierce, range, arad, acd, spd, hp, regen, dash, squad, cluster, explosive, burn, cone, shatter, chill, turret, cool
}

public struct Upgrade {
    public let id: UpgradeID
    /// nil = every class; otherwise only these classes get the card.
    public let classes: [MarineClass]?

    /// Card title (catalog upg.<id>.name).
    public var name: NameRef { .upgrade(id) }

    /// Card description with its numbers as arguments (the same numbers `applyUpgrade` uses).
    public var desc: GameText {
        switch id {
        case .dmg: return GameText(.upgDmg, [.int(15)])
        case .rof: return GameText(.upgRof, [.int(12)])
        case .pierce: return GameText(.upgPierce)
        case .range: return GameText(.upgRange, [.int(18)])
        case .arad: return GameText(.upgArad, [.int(20)])
        case .acd: return GameText(.upgAcd, [.int(15)])
        case .spd: return GameText(.upgSpd, [.int(8)])
        case .hp: return GameText(.upgHp, [.int(20)])
        case .regen: return GameText(.upgRegen, [.tenths(15)])
        case .dash: return GameText(.upgDash, [.int(25)])
        case .squad: return GameText(.upgSquad, [.int(15)])
        case .cluster: return GameText(.upgCluster, [.int(3)])
        case .explosive: return GameText(.upgExplosive)
        case .burn: return GameText(.upgBurn, [.int(50)])
        case .cone: return GameText(.upgCone, [.int(25)])
        case .shatter: return GameText(.upgShatter, [.int(60)])
        case .chill: return GameText(.upgChill, [.int(35)])
        case .turret: return GameText(.upgTurret, [.int(5), .int(30)])
        case .cool: return GameText(.upgCool, [.int(35)])
        }
    }
}

public let UPGRADES: [Upgrade] = [
    Upgrade(id: .dmg, classes: nil),
    Upgrade(id: .rof, classes: nil),
    Upgrade(id: .pierce, classes: [.assault, .gunner]),
    Upgrade(id: .range, classes: [.pyro, .cryo]),
    Upgrade(id: .arad, classes: nil),
    Upgrade(id: .acd, classes: nil),
    Upgrade(id: .spd, classes: nil),
    Upgrade(id: .hp, classes: nil),
    Upgrade(id: .regen, classes: nil),
    Upgrade(id: .dash, classes: nil),
    Upgrade(id: .squad, classes: nil),
    Upgrade(id: .cluster, classes: [.assault]),
    Upgrade(id: .explosive, classes: [.assault]),
    Upgrade(id: .burn, classes: [.pyro]),
    Upgrade(id: .cone, classes: [.pyro]),
    Upgrade(id: .shatter, classes: [.cryo]),
    Upgrade(id: .chill, classes: [.cryo]),
    Upgrade(id: .turret, classes: [.gunner]),
    Upgrade(id: .cool, classes: [.gunner, .pyro, .cryo]),
]

/// XP needed to go from `level` to the next one.
public func xpFor(_ level: Int) -> Int {
    Int((40 * powf2(1.4, Float(level - 1)) + 12 * Float(level - 1)).rounded())
}
