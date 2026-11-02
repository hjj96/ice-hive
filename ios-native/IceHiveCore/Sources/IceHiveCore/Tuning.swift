import Foundation

// ================================================================
//  TUNING TABLES — bug types, classes, quality caps, difficulty
//  (numbers are 1:1 from 01-core.js / 06-marines.js / 08-director.js)
// ================================================================

public enum BugType: Int, CaseIterable {
    case runner = 0, spitter = 1, brute = 2, boomer = 3

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
]
// (first-sighting tips: GameText.bugTip)

// raw type / state codes used in the SoA arrays
let T_RUN: UInt8 = 0, T_SPIT: UInt8 = 1, T_BRUTE: UInt8 = 2, T_BOOM: UInt8 = 3

/// Bug behaviour state (raw values are what `Swarm.state` stores).
public enum BugState: UInt8 {
    case move = 0, climb = 1, wind = 2, charge = 3, swell = 4
}
let S_MOVE: UInt8 = 0, S_CLIMB: UInt8 = 1, S_WIND: UInt8 = 2, S_CHARGE: UInt8 = 3, S_SWELL: UInt8 = 4

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
    /// Live-bug cap of the tier (web: QUALITY[q].cap).
    public var bugCap: Int {
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
let SPECIAL_CAP: [Int] = [0, 30, 12, 18]

// ================================================================
//  DIFFICULTY — the v1.1 «Ставки» tiers (web 01-core.js DIFF / TH, calibrated rows of
//  origin/v1.1/a-threat 8e95162). Every field multiplies or replaces a v1.0 constant
//  where it acts (director, swarm, marines, the Матка). `legacyV10` is a hidden row that
//  reproduces v1.0 exactly (no Матка, no pressure, no stall clock, runners scale with HP):
//  the calibration port check and the v1.0 regression test run on it.
//  Native deviations from the web numbers are only allowed through the calibration
//  protocol (ios-native/README.md «v1.1 Ставки»); each one is noted next to its field.
// ================================================================

/// The Матка (boss of the lift hold) per tier (web TH.q*).
public struct QueenTuning: Equatable {
    /// Seconds of counted hold (liftDur − liftT) before her 2 s warning; ∞ = she never comes.
    public var at: Float
    /// Health (× the director's HP multiplier at her spawn).
    public var hp: Float
    public var speed: Float
    /// Seconds between rams (× 0.75 enraged), acid volleys (× 0.75), broods (× 0.7).
    public var ramT: Float, volleyT: Float, broodT: Float
    /// Runners per brood.
    public var broodN: Int
    /// Horde size when she enrages (× hordeScale, then × the tier's horde inside startHorde).
    public var horde: Float
    /// Trickle multiplier while she lives (she is the horde).
    public var trickle: Float

    public init(at: Float, hp: Float, speed: Float, ramT: Float, volleyT: Float, broodT: Float, broodN: Int, horde: Float, trickle: Float) {
        self.at = at; self.hp = hp; self.speed = speed; self.ramT = ramT; self.volleyT = volleyT; self.broodT = broodT
        self.broodN = broodN; self.horde = horde; self.trickle = trickle
    }

    /// No Матка (legacy v1.0 row).
    public static let none = QueenTuning(at: .infinity, hp: 0, speed: 0, ramT: 0, volleyT: 0, broodT: 0, broodN: 0, horde: 0, trickle: 1)
}

/// Mission source of the Матка's damage: SRC_QUEEN in the web damage-source table.
public let SRC_QUEEN = 4

/// Who dealt a hit to a marine (web hurtMarine `src`): the bug type, the Матка, or anything else.
public enum DamageSource: Int, CaseIterable {
    case environment = -1, runner = 0, spitter = 1, brute = 2, boomer = 3, queen = 4

    init(bugType ty: UInt8) { self = DamageSource(rawValue: Int(ty)) ?? .environment }
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
    public var queen: QueenTuning = .none

    public init() {}

    /// Новобранец — the first mission ever and anyone who picks it.
    public static let recruit: Difficulty = {
        var d = Difficulty(); d.index = 0; d.id = "rec"; d.scoreMul = 0.8
        d.hp = 1.0; d.dmg = 0.9; d.trickle = 1.09; d.horde = 1.07; d.beaconHordeStep = 50; d.specials = 1; d.specialCap = 1
        d.botDamage = BOT_DMG * 1.0; d.botGrow = 1.04; d.regen = 4; d.regenDelay = 3.5; d.regenCap = 1
        d.beaconHeal = 0.25; d.reviveHp = 0.45; d.medkitChance = 0.35; d.trickleMinDist = 12
        d.pulseDamage = 1.0; d.pulseInterval = 5; d.pulseFalloff = 0
        d.stallTime = 90; d.pressureGrace = 40; d.runnerHp = 15
        d.queen = QueenTuning(at: 35, hp: 2500, speed: 1.5, ramT: 9, volleyT: 6, broodT: 8, broodN: 6, horde: 80, trickle: 0.4)
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
        d.queen = QueenTuning(at: 35, hp: 3500, speed: 1.5, ramT: 9, volleyT: 6, broodT: 8, broodN: 6, horde: 80, trickle: 0.4)
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
        d.queen = QueenTuning(at: 30, hp: 6000, speed: 1.6, ramT: 8, volleyT: 5, broodT: 7, broodN: 8, horde: 150, trickle: 0.6)
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
                                                "runHp", "qAt", "qHp", "qSpd", "qRamT", "qVolleyT", "qBroodT", "qBroodN", "qHorde", "qTrickle", "mul"]

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
            case "qRamT": queen.ramT = v
            case "qVolleyT": queen.volleyT = v
            case "qBroodT": queen.broodT = v
            case "qBroodN": queen.broodN = Int(v0.rounded())
            case "qHorde": queen.horde = v
            case "qTrickle": queen.trickle = v
            case "mul": scoreMul = v
            default: unknown.append(k)
            }
        }
        return unknown
    }

    /// The tier has a Матка (the lift waits for her).
    public var hasQueen: Bool { queen.at.isFinite }
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
