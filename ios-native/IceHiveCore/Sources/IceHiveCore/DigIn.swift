import Foundation

// ================================================================
//  DIG IN (Stage 2 D1; design §1.6 «Dig In», R1's handoff to R10) — an
//  endless holdout at the Lift: the squad rides the lift down to the
//  bottom of Kelvin-9 and holds its deck wave after wave until it falls.
//  A HOLD step (Mission.swift) whose time is ∞ and which carries
//  `HoldStep.waves` (`HoldoutWaves` below): the runtime is
//  GameHoldout.swift, beside GameMission's HOLD.
//    waves     lull (the squad regroups, the trickle nearly stops) →
//              build-up (the trickle rises) → peak (the wave's horde
//              over the lift's rim, from the decks around it and down
//              the overhead's routes); held when the swarm is cleared
//              (or the peak ran its time out). Each wave held is an
//              escalation step of the director and grows the next
//              wave's horde.
//    the Queen leads every fifth wave (B1's framework, her own arrival
//              rule `BossArrival.waves`): that wave is held only once
//              she is dead.
//    banking   every fifth wave held banks the score (kills, waves held,
//              Queens killed): a banked score survives the fall, the
//              rest is lost with the squad.
//  Its calibration preset is `holdout` (calib-holdout.jsonl, its own CI
//  step): waves held per tier in bands, an AFK band — gated, so a later
//  change to the director cannot move them silently.
// ================================================================

/// An endless HOLD fought in waves (`HoldStep.waves`; its `time` is ∞): the wave director, the escalation, the bank and the
/// score of a holdout. Plain numbers (the runtime is GameHoldout.swift).
public struct HoldoutWaves: Equatable {
    /// Seconds of the lull after a wave is held (the hive's trickle × `lullMul`: the squad regroups, revives) and of the
    /// build-up before the next wave's peak (the trickle rising from `lullMul` to `peakMul`).
    public var lull: Float = 9
    public var build: Float = 6
    public var lullMul: Float = 0.15
    /// × the hold's trickle from the peak until the wave is held.
    public var peakMul: Float = 1
    /// Wave n's horde at its peak: `base` + `grow` × (n − 1) in the wave pacing's units (× the tier's horde and population
    /// scale, × the plan's stream), at most `maxHorde`; × `queenHordeK` on a wave the Queen leads (she is the horde).
    public var base: Float = 40
    public var grow: Float = 9
    public var maxHorde: Float = 240
    public var queenHordeK: Float = 0.5
    /// The horde's spawn rate (startHorde's: × 0.28 per side on the wave pacing).
    public var hordeRate: Float = 50
    /// A wave is held once its peak has run `peakMin` s and the live swarm is down to `clearK` × its horde (at least
    /// `clearMin` bugs), or after `peakMax` s whatever is left; a wave the Queen leads only once she is dead (then when the
    /// swarm is down, or `peakMin` s after her death).
    public var peakMin: Float = 8
    public var peakMax: Float = 40
    public var clearK: Float = 0.15
    public var clearMin: Int = 10
    /// Each `escalateEvery`-th wave held is an escalation step of the director (bug health +6 %, damage +3 %, the specials and
    /// their caps — what a beacon lit is in the classic mission); 0 = none.
    public var escalateEvery: Int = 1
    /// The score banks when every `bankEvery`-th wave is held (5, 10, 15 …): a banked score survives the fall.
    public var bankEvery: Int = 5
    /// The squad patches up at a bank (the tier's beacon breather: a quarter of the armour on Recruit).
    public var bankHeal = true
    /// Score of each wave held and of each Queen killed (the player's own kills count one each, as in every mission).
    public var waveScore: Int = 250
    public var queenScore: Int = 1000
    /// The Queen's banners in a holdout (nil: her row's — the classic hold's «no lift while she lives»).
    public var queenBanner: BannerText? = nil
    public var queenDeathBanner: BannerText? = nil
    public init() {}

    /// Wave `n`'s horde in the wave pacing's units (before the tier), the Queen's waves × `queenHordeK`.
    public func horde(_ n: Int, queen: Bool) -> Float {
        let s = minf(maxHorde, base + grow * Float(max(0, n - 1)))
        return queen ? s * queenHordeK : s
    }

    /// Wave `n` banks the score when it is held.
    public func banks(_ n: Int) -> Bool { bankEvery > 0 && n > 0 && n % bankEvery == 0 }
}

/// The phase of a holdout's current wave.
public enum HoldoutPhase: Int {
    /// The squad regroups after a wave held.
    case lull
    /// The trickle rises toward the wave's peak.
    case build
    /// The wave's horde came: until the wave is held.
    case peak
}

/// A holdout's state (`Game.holdout`; the HUD, the report, the demos and calibration read it). Plain scalars: no allocation.
public struct HoldoutState: Equatable {
    /// The wave being fought, or the next one in a lull (1…; 0 before the hold started).
    public internal(set) var wave = 0
    /// Waves held.
    public internal(set) var held = 0
    public internal(set) var phase: HoldoutPhase = .lull
    /// Seconds in the phase.
    public internal(set) var t: Float = 0
    /// The current wave's horde (bugs, after the tier and the stream) and the live swarm it is held at.
    public internal(set) var horde = 0
    public internal(set) var clearAt = 0
    /// Score of the waves held and the Queens killed (the player's kills come on top: `Game.holdoutScore`).
    public internal(set) var points = 0
    /// Queens killed.
    public internal(set) var queensKilled = 0
    /// The score banked at the last bank (`Game.holdoutScore` then), that bank's wave (0: none yet) and the banks so far.
    public internal(set) var banked = 0
    public internal(set) var bankWave = 0
    public internal(set) var banks = 0
    /// The wave whose Queen came (or is coming): she leads each of her waves once.
    var queenWave = 0
    /// Seconds since this wave's Queen died (−1: none dead and not yet counted).
    var queenDeadT: Float = -1
    /// The first-sighting tip of the bank has been raised this mission.
    var tipShown = false
    public init() {}
}

/// Dig In's numbers and its plan.
public enum DigIn {
    /// The Queen leads wave `queenFirst`, then every `queenEvery`-th (her arrival rule: `BossArrival.waves`).
    public static let queenFirst = 5
    public static let queenEvery = 5
    /// The squad starts on the lift's deck, this far from its centre toward the stairs (m): the hold starts on the first tick.
    public static let startOffset: Float = 3
    /// The hive's stream on Recruit, Veteran, Nightmare for the whole mission (the plan's `tierStream`).
    public static let tierStream: [Float] = [1, 1, 1]
    /// Seconds a calibration run may last (an endless hold: a squad still standing then is counted with its waves held).
    public static let calibMaxs: Float = 1800

    /// The wave director's numbers (`HoldoutWaves`).
    public static var waves: HoldoutWaves {
        var w = HoldoutWaves()
        w.queenBanner = BannerText(title: .bannerQueen, sub: .bannerQueenWaveSub)
        w.queenDeathBanner = BannerText(title: .bannerQueenDead, sub: .bannerQueenWaveDeadSub)
        return w
    }

    /// HOLD the lift, endless (its shock pulse; the Queen by her own arrival rule, never locking a hold that never ends), in
    /// waves; no opening horde and no countdown banner — the waves bring their own.
    public static func plan(_ lv: Level) -> MissionPlan {
        var hold = HoldStep(zone: .lift, time: .infinity, pulse: true,
                            boss: BossRider(.queen, arrival: .waves(first: queenFirst, every: queenEvery), locks: false))
        hold.waves = waves
        // (the hold's own trickle: the waves are its peaks — the classic 100 s hold runs × 2.0 throughout)
        hold.stageMul = PacingValue(legacy: 2.0, waves: 1.2)
        hold.openHorde = PacingValue(legacy: 0, waves: 0)
        hold.callBanner = nil
        hold.holdBanner = nil
        hold.travelAllowance = false
        var plan = MissionPlan(id: "dig-in", steps: [.hold(hold)], briefing: BannerText(title: .bannerDigIn, sub: .bannerDigInSub))
        plan.tierStream = tierStream
        return plan
    }
}

/// «Dig In»'s station: Kelvin-9 Mk II as the classic mission has it (R5's overhead routes and R6's props laid), the squad
/// set down on the lift's deck at the bottom of the stairs instead of the landing pad.
public struct DigInStation: LevelSource {
    public init() {}
    public func makeLayout(seed: UInt32) -> LevelLayout {
        var L = KelvinStation.mk2.makeLayout(seed: seed)
        L.start = Vec2(L.lift.x, L.lift.z + DigIn.startOffset)
        return L
    }
}

extension MissionTemplate {
    /// The endless missions (Stage 2 D1: Dig In), after the boss missions in the title's mission choice.
    public static var holdouts: [MissionTemplate] { [digIn] }

    /// Dig In's bands (gated): the median waves held of the autopilot runs — Recruit 17–29, Veteran 9–15, Nightmare 3–6 (run
    /// 43544003329: 23 / 12 / 4; the Queen's waves are the walls the runs fall at — Recruit at 20 and 25, Veteran at 10 and
    /// 15, Nightmare at 5 — so a band spans a wall each way of the measured median, and a change that moves the runs a whole
    /// wall leaves it). The AFK first player down: Veteran ≤ 200 s, Recruit ≤ 270 s — an idle player stands on the lift's deck
    /// in its pulse among the bots (the classic's idle player stands alone on the landing pad: 120 s there), and is still down
    /// before an idle squad's first bank (≈ 200 s on Veteran).
    static let digInBands = [CalibBand(tier: 0, wavesLo: 17, wavesHi: 29), CalibBand(tier: 1, wavesLo: 9, wavesHi: 15),
                             CalibBand(tier: 2, wavesLo: 3, wavesHi: 6)]
    static let digInAFK = [AFKBand(tier: 1, firstDownMax: 200), AFKBand(tier: 0, firstDownMax: 270)]

    /// «Dig In» (design §1.6): HOLD the lift in waves until the squad falls; the score banks at waves 5 and 10 (and every
    /// fifth after). Its preset is `holdout` (calib-holdout.jsonl): 8 runs per class on Recruit and Nightmare, 16 on Veteran
    /// (up to `DigIn.calibMaxs` s each), one AFK run per class on Veteran and Recruit, seeds from its own base.
    public static let digIn = MissionTemplate(id: "dig-in", name: .missionDigIn, station: DigInStation(),
                                              calib: MissionCalib(tiers: [0, 1, 2], runs: 8, tierRuns: [1: 16], seedBase: 600_000,
                                                                  bands: digInBands, afk: digInAFK, gated: true, preset: "holdout",
                                                                  maxs: DigIn.calibMaxs)) { DigIn.plan($0) }
}
