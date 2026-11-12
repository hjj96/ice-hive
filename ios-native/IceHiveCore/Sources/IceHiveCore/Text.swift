import Foundation

// ================================================================
//  TEXT — the core never builds prose. Every player-facing line it
//  produces is a `GameText`: a stable `TextID` (its raw value is the
//  key in the app's string catalog, App/Resources/Localizable.xcstrings)
//  plus typed arguments; names (call-signs, beacons, stations, bugs,
//  classes, tiers, ranks, upgrades, quality tiers) are `NameRef`s.
//  Numbers travel as Int (or tenths) and the app formats them with an
//  explicit locale, so the core stays Foundation-only, locale-free and
//  deterministic, and tests pin keys, not copy. Text is only built
//  when the game is not `simOnly` (calibration never makes any).
//
//  Every id declares its argument kinds (`signature`): "d" = an Int the
//  catalog formats with %lld (counts carry plural variants there),
//  "@" = anything the app turns into a string first (a name, nested
//  text, a grouped number, tenths, a clock). ios-native/ci/check_strings.py
//  reads the ids and signatures from this file and checks the catalog's
//  format specifiers against them; a debug build asserts every GameText
//  it makes matches its id.
// ================================================================

/// A name the app looks up in the catalog (`key`).
public enum NameRef: Hashable {
    /// The player in squad rows and on the nameplate.
    case player
    /// A squadmate's call-sign: bound to the class (Assault, Pyro, Cryo, Gunner each have their own).
    case callsign(MarineClass)
    /// Beacon 0…2 of a station.
    case beacon(Int)
    /// The hand-made station.
    case kelvin
    /// A generated station: letter 0…11 (`name.sector.letters`), number 1…99.
    case sector(letter: Int, number: Int)
    case bug(BugType)
    /// The boss of the lift hold.
    case queen
    /// Stage 2 B4: the boss of the Manifold.
    case threader
    case cls(MarineClass)
    case weapon(MarineClass)
    case ability(MarineClass)
    /// The ability's one-word label (round HUD button, coach card).
    case abilityShort(MarineClass)
    /// One line about the class (not on screen yet; kept for the class cards of the UI overhaul).
    case classDesc(MarineClass)
    /// Difficulty tier 0…2 (-1 = the hidden legacy row).
    case tier(Int)
    /// The tier's one line under the title selector.
    case tierLine(Int)
    /// The tier's one-letter medal pip.
    case tierAbbr(Int)
    /// Rank 0…9 (`Ranks`).
    case rank(Int)
    case upgrade(UpgradeID)
    case quality(QualityTier)

    /// Beacon key suffixes by index.
    public static let beaconKeys = ["alpha", "beta", "gamma"]
    /// Tier key suffixes by index (+ the legacy row).
    static func tierKey(_ i: Int) -> String { i < 0 ? "v10" : Difficulty.tier(i).id }

    /// Catalog key. `sector` is a format (`name.sector` = letter + number); its letters are `name.sector.letters`.
    public var key: String {
        switch self {
        case .player: return "name.you"
        case .callsign(let c): return "name.callsign." + c.id
        case .beacon(let k): return "name.beacon." + NameRef.beaconKeys[max(0, min(NameRef.beaconKeys.count - 1, k))]
        case .kelvin: return "name.station.kelvin"
        case .sector: return "name.sector"
        case .bug(let t): return "name.bug." + t.id
        case .queen: return "name.bug.queen"
        case .threader: return "name.bug.threader"
        case .cls(let c): return "class." + c.id + ".name"
        case .weapon(let c): return "class." + c.id + ".weapon"
        case .ability(let c): return "class." + c.id + ".ability"
        case .abilityShort(let c): return "class." + c.id + ".ability_short"
        case .classDesc(let c): return "class." + c.id + ".desc"
        case .tier(let i): return "tier." + NameRef.tierKey(i) + ".name"
        case .tierLine(let i): return "tier." + NameRef.tierKey(i) + ".line"
        case .tierAbbr(let i): return "tier." + NameRef.tierKey(i) + ".abbr"
        case .rank(let r): return "rank.\(max(0, min(Ranks.thresholds.count - 1, r)) + 1)"
        case .upgrade(let u): return "upg." + u.rawValue + ".name"
        case .quality(let q): return "quality." + q.rawValue
        }
    }

    /// ASCII id for logs and debug dumps («kelvin-9», «sector-3-17»).
    public var logID: String {
        switch self {
        case .kelvin: return "kelvin-9"
        case .sector(let l, let n): return "sector-\(l)-\(n)"
        default: return key
        }
    }

    /// Every name the game can show (the app's catalog audit and warm-ups).
    public static var all: [NameRef] {
        var out: [NameRef] = [.player, .kelvin, .sector(letter: 0, number: 1), .queen, .threader]
        for c in MarineClass.allCases {
            out += [.callsign(c), .cls(c), .weapon(c), .ability(c), .abilityShort(c), .classDesc(c)]
        }
        for k in 0..<NameRef.beaconKeys.count { out.append(.beacon(k)) }
        for t in BugType.allCases { out.append(.bug(t)) }
        for i in -1..<Difficulty.tiers.count { out += [.tier(i), .tierLine(i), .tierAbbr(i)] }
        for r in 0..<Ranks.thresholds.count { out.append(.rank(r)) }
        for u in UpgradeID.allCases { out.append(.upgrade(u)) }
        for q in QualityTier.allCases { out.append(.quality(q)) }
        return out
    }
}

/// One argument of a `GameText`.
public enum TextArg: Hashable {
    /// A count or a plain integer (catalog: %lld, plural variants where it counts something).
    case int(Int)
    /// A number with thousands grouping (score, service XP).
    case num(Int)
    /// Tenths (8 = 0.8): multipliers, fractional per-second rates.
    case tenths(Int)
    /// Whole seconds shown as m:ss.
    case clock(Int)
    case name(NameRef)
    /// Nested text (a line built from other lines).
    case text(GameText)

    /// m:ss of `s` seconds (floored, ≥ 0), like `formatTime`.
    public static func time(_ s: Float) -> TextArg { .clock(max(0, Int(s.isFinite ? s.rounded(.down) : 0))) }

    /// Signature character: "d" for `int`, "@" for everything the app formats into a string first.
    public var kind: Character {
        if case .int = self { return "d" }
        return "@"
    }
}

/// A line of player-facing text: catalog key + typed arguments.
public struct GameText: Hashable, CustomStringConvertible {
    public let id: TextID
    public let args: [TextArg]

    public init(_ id: TextID, _ args: [TextArg] = []) {
        self.id = id
        self.args = args
        assert(String(args.map { $0.kind }) == id.signature,
               "GameText \(id.rawValue): arguments \(args) do not match its signature '\(id.signature)'")
    }

    /// `obj.hold_beacon(name.beacon.alpha)` (logs, test failures).
    public var description: String {
        if args.isEmpty { return id.rawValue }
        return id.rawValue + "(" + args.map { a -> String in
            switch a {
            case .int(let v): return "\(v)"
            case .num(let v): return "#\(v)"
            case .tenths(let v): return "\(v)/10"
            case .clock(let v): return "\(v)s"
            case .name(let n): return n.key
            case .text(let t): return t.description
            }
        }.joined(separator: ",") + ")"
    }
}

/// Stable ids of every line the core builds. The raw value is the catalog key; `signature` the argument kinds.
public enum TextID: String, CaseIterable {
    // ---- objective line (top centre; the app uppercases it)
    case objHoldBeacon = "obj.hold_beacon"
    case objConvergeBeacon = "obj.converge_beacon"
    case objWakingBeacon = "obj.waking_beacon"
    case objLightBeacons = "obj.light_beacons"
    case objConvergeLift = "obj.converge_lift"
    case objWakingLift = "obj.waking_lift"
    case objLiftCalled = "obj.lift_called"
    case objLiftLocked = "obj.lift_locked"
    case objKillQueen = "obj.kill_queen"
    case objHoldLift = "obj.hold_lift"
    case objExtract = "obj.extract"
    // ---- objective lines of the mission modules beyond the classic ones (Mission.swift)
    case objSwitches = "obj.switches"
    case objHoldRing = "obj.hold_ring"
    case objReach = "obj.reach"
    case objHoldArea = "obj.hold_area"
    case objKillBoss = "obj.kill_boss"
    case objWakingMove = "obj.waking_move"
    case objConvergeMove = "obj.converge_move"
    // ---- objective lines of the missions on Kelvin-9 (R7: Breaker Run, Vent Purge — MissionsKelvin.swift)
    case objRestorePower = "obj.restore_power"
    case objHoldBreaker = "obj.hold_breaker"
    case objToGenerator = "obj.to_generator"
    case objHoldGenerator = "obj.hold_generator"
    case objSealVents = "obj.seal_vents"
    case objHoldSeal = "obj.hold_seal"
    // ---- objective lines of the Manifold (Stage 2 B4 — Manifold.swift)
    case objRestartPumps = "obj.restart_pumps"
    case objHoldPump = "obj.hold_pump"
    // ---- mission names (the title's mission choice)
    case missionColdLight = "mission.cold_light"
    case missionBreakerRun = "mission.breaker_run"
    case missionVentPurge = "mission.vent_purge"
    case missionManifold = "mission.manifold"
    // ---- context hints (between the stick rings)
    case hintPlayerDown = "hint.player_down"
    case hintReviveNear = "hint.revive_near"
    case hintBackToRing = "hint.back_to_ring"
    case hintRingContested = "hint.ring_contested"
    case hintStepInRing = "hint.step_in_ring"
    case hintToPlatform = "hint.to_platform"
    case hintPulse = "hint.pulse"
    case hintPulseFalloff = "hint.pulse_falloff"
    case hintPinned = "hint.pinned"
    // R7: a draining switch ring, Breaker Run's generator held
    case hintBackToSwitch = "hint.back_to_switch"
    case hintBackToGenerator = "hint.back_to_generator"
    // ---- first-run coach card
    case coachMove = "coach.move"
    case coachMoveKeys = "coach.move.keys"
    case coachAim = "coach.aim"
    case coachAimKeys = "coach.aim.keys"
    case coachAbility = "coach.ability"
    case coachAbilityKeys = "coach.ability.keys"
    case coachDash = "coach.dash"
    case coachDashKeys = "coach.dash.keys"
    case coachBeacon = "coach.beacon"
    case coachCounter = "coach.counter"
    case coachSkip = "coach.skip"
    case coachRevive = "coach.revive"
    // ---- toasts (right column)
    case toastPlayerDown = "toast.player_down"
    case toastMateDown = "toast.mate_down"
    case toastPlayerUp = "toast.player_up"
    case toastMateUp = "toast.mate_up"
    case toastMedkit = "toast.medkit"
    case toastTipSpitter = "toast.tip.spitter"
    case toastTipBrute = "toast.tip.brute"
    case toastTipBoomer = "toast.tip.boomer"
    case toastUpgrade = "toast.upgrade"
    // ---- the overhead's bugs (Stage 1 R4): squad radio and first-sighting tips
    case toastMatePinned = "toast.mate_pinned"
    case toastPinFreed = "toast.pin_freed"
    case toastTipDropper = "toast.tip.dropper"
    case toastTipPerch = "toast.tip.perch"
    case toastTipDuct = "toast.tip.duct"
    // ---- interactive props (Stage 1 R6): squad radio barks and first-sighting tips
    case toastLightsCut = "toast.lights_cut"
    case toastLightsUp = "toast.lights_up"
    case toastLocker = "toast.locker"
    case toastTipValve = "toast.tip.valve"
    case toastTipBreaker = "toast.tip.breaker"
    case toastTipLocker = "toast.tip.locker"
    // ---- R7 missions: squad radio
    case toastVentSealed = "toast.vent_sealed"
    // ---- Stage 2 B4: squad radio against the Threader
    case toastThreaderPipes = "toast.threader_pipes"
    case toastThreaderLight = "toast.threader_light"
    case toastThreaderCoil = "toast.threader_coil"
    case toastThreaderNode = "toast.threader_node"
    // ---- banners (title + subtitle) and horde titles
    case bannerDrop = "banner.drop"
    case bannerDropSub = "banner.drop.sub"
    case bannerHorde = "banner.horde"
    case bannerHordeSub = "banner.horde.sub"
    case bannerDefend = "banner.defend"
    case bannerDefendSub = "banner.defend.sub"
    case bannerHordeLiftSub = "banner.horde_lift.sub"
    case bannerLiftCalled = "banner.lift_called"
    case bannerLiftCalledSub = "banner.lift_called.sub"
    case bannerBeaconOnline = "banner.beacon_online"
    case bannerBeaconOnlineSub = "banner.beacon_online.sub"
    case bannerHold = "banner.hold"
    case bannerHoldSub = "banner.hold.sub"
    case bannerExtract = "banner.extract"
    case bannerExtractSub = "banner.extract.sub"
    case bannerQueen = "banner.queen"
    case bannerQueenSub = "banner.queen.sub"
    case bannerQueenRage = "banner.queen_rage"
    case bannerQueenDead = "banner.queen_dead"
    case bannerQueenDeadSub = "banner.queen_dead.sub"
    // ---- R7 missions: the drop banners, the generator
    case bannerBreakerRun = "banner.breaker_run"
    case bannerBreakerRunSub = "banner.breaker_run.sub"
    case bannerBreakersLive = "banner.breakers_live"
    case bannerBreakersLiveSub = "banner.breakers_live.sub"
    case bannerGenerator = "banner.generator"
    case bannerGeneratorSub = "banner.generator.sub"
    case bannerVentPurge = "banner.vent_purge"
    case bannerVentPurgeSub = "banner.vent_purge.sub"
    // ---- Stage 2 B4: the Manifold's drop banner, the Threader's arrival and death
    case bannerManifold = "banner.manifold"
    case bannerManifoldSub = "banner.manifold.sub"
    case bannerThreader = "banner.threader"
    case bannerThreaderSub = "banner.threader.sub"
    case bannerThreaderDead = "banner.threader_dead"
    case bannerThreaderDeadSub = "banner.threader_dead.sub"
    // ---- run score lines
    case scoreKills = "score.kills"
    case scoreBeacons = "score.beacons"
    case scoreQueen = "score.queen"
    case scoreExtract = "score.extract"
    case scoreSpeed = "score.speed"
    case scoreNoDowns = "score.no_downs"
    case scoreLights = "score.lights"
    case scoreBreakers = "score.breakers"
    case scoreVents = "score.vents"
    case scorePumps = "score.pumps"
    case scoreThreader = "score.threader"
    // ---- mission report
    case reportTag = "report.tag"
    case reportTitleWon = "report.title.won"
    case reportTitleLost = "report.title.lost"
    case reportSubWon = "report.sub.won"
    case reportSubRecalled = "report.sub.recalled"
    case reportSubLost = "report.sub.lost"
    case reportStripBeacon = "report.strip.beacon"
    case reportStripLift = "report.strip.lift"
    case reportStripQueen = "report.strip.queen"
    case reportStripExtract = "report.strip.extract"
    case reportStripBreaker = "report.strip.breaker"
    case reportStripVent = "report.strip.vent"
    case reportStripGenerator = "report.strip.generator"
    case reportStripPump = "report.strip.pump"
    case reportStripThreader = "report.strip.threader"
    case reportScore = "report.score"
    case reportRecord = "report.record"
    case reportBest = "report.best"
    case reportTierLine = "report.tier_line"
    case reportMiniTime = "report.mini.time"
    case reportMiniCombo = "report.mini.combo"
    case reportMiniAccuracy = "report.mini.accuracy"
    case reportMiniLevel = "report.mini.level"
    case reportRankTitle = "report.rank_title"
    case reportXP = "report.xp"
    case reportRankUp = "report.rank_up"
    case reportMedal = "report.medal"
    case reportChip = "report.chip"
    case reportAgain = "report.btn.again"
    case reportNewStation = "report.btn.new_station"
    case reportChangeClass = "report.btn.change_class"
    // ---- report tips and the next goal
    case tipLossRunner = "tip.loss.runner"
    case tipLossSpitter = "tip.loss.spitter"
    case tipLossBrute = "tip.loss.brute"
    case tipLossBoomer = "tip.loss.boomer"
    case tipLossQueen = "tip.loss.queen"
    case tipLossDropper = "tip.loss.dropper"
    case tipLossThreader = "tip.loss.threader"
    case tipPressure = "tip.pressure"
    case tipPromo = "tip.promo"
    case tipLonger = "tip.longer"
    case goalFirstWinAssault = "goal.first_win.assault"
    case goalFirstWinPyro = "goal.first_win.pyro"
    case goalFirstWinCryo = "goal.first_win.cryo"
    case goalFirstWinGunner = "goal.first_win.gunner"
    case goalMedalAssault = "goal.medal.assault"
    case goalMedalPyro = "goal.medal.pyro"
    case goalMedalCryo = "goal.medal.cryo"
    case goalMedalGunner = "goal.medal.gunner"
    case goalRank = "goal.rank"
    case goalBest = "goal.best"
    // ---- title profile line and class-card rank chip
    case titleProfile = "title.profile"
    case titleProfileRuns = "title.profile_runs"
    case titleRuns = "title.runs"
    case titleWins = "title.wins"
    case titleRankChip = "title.rank_chip"
    // ---- value formats of report lines
    case fmtPlus = "fmt.plus"
    case fmtMinus = "fmt.minus"
    case fmtMul = "fmt.mul"
    case fmtCombo = "fmt.combo"
    case fmtPercent = "fmt.percent"
    case fmtInt = "fmt.int"
    case fmtClock = "fmt.clock"
    // ---- upgrade card descriptions (names are NameRef.upgrade)
    case upgDmg = "upg.dmg.desc"
    case upgRof = "upg.rof.desc"
    case upgPierce = "upg.pierce.desc"
    case upgRange = "upg.range.desc"
    case upgArad = "upg.arad.desc"
    case upgAcd = "upg.acd.desc"
    case upgSpd = "upg.spd.desc"
    case upgHp = "upg.hp.desc"
    case upgRegen = "upg.regen.desc"
    case upgDash = "upg.dash.desc"
    case upgSquad = "upg.squad.desc"
    case upgCluster = "upg.cluster.desc"
    case upgExplosive = "upg.explosive.desc"
    case upgBurn = "upg.burn.desc"
    case upgCone = "upg.cone.desc"
    case upgShatter = "upg.shatter.desc"
    case upgChill = "upg.chill.desc"
    case upgTurret = "upg.turret.desc"
    case upgCool = "upg.cool.desc"

    /// Argument kinds in order ("d" = Int → %lld, "@" = string): one `case … : return "…"` line per signature
    /// (ci/check_strings.py parses exactly this shape).
    public var signature: String {
        switch self {
        case .objHoldBeacon, .objHoldLift, .objHoldArea, .objKillBoss, .coachAbility, .coachAbilityKeys, .coachRevive: return "@"
        case .objHoldGenerator, .bannerBreakerRunSub, .bannerVentPurgeSub: return "@"
        case .bannerManifoldSub, .tipLossThreader: return "@"
        case .toastMateDown, .toastMateUp, .toastTipSpitter, .toastTipBrute, .toastTipBoomer, .toastUpgrade: return "@"
        case .toastMatePinned, .toastPinFreed, .toastTipDropper, .toastTipPerch, .tipLossDropper: return "@"
        case .bannerDropSub, .bannerDefendSub, .scoreSpeed, .reportTag, .reportSubWon, .reportBest, .reportXP, .reportRankUp: return "@"
        case .reportChip, .tipLossSpitter, .tipLossBrute, .tipLossBoomer, .tipLossQueen, .tipPromo, .tipLonger: return "@"
        case .goalFirstWinAssault, .goalFirstWinPyro, .goalFirstWinCryo, .goalFirstWinGunner: return "@"
        case .goalMedalAssault, .goalMedalPyro, .goalMedalCryo, .goalMedalGunner, .goalBest: return "@"
        case .fmtPlus, .fmtMinus, .fmtMul, .fmtClock, .upgRegen: return "@"
        case .reportTierLine, .reportRankTitle, .reportMedal, .goalRank, .titleProfileRuns: return "@@"
        case .titleProfile: return "@@@"
        case .hintPulse, .hintPulseFalloff, .toastMedkit, .bannerHoldSub, .titleRuns, .titleWins, .titleRankChip: return "d"
        case .bannerGeneratorSub: return "d"
        case .fmtCombo, .fmtPercent, .fmtInt: return "d"
        case .upgDmg, .upgRof, .upgRange, .upgArad, .upgAcd, .upgSpd, .upgHp, .upgDash, .upgSquad, .upgCluster: return "d"
        case .upgBurn, .upgCone, .upgShatter, .upgChill, .upgCool: return "d"
        case .objLightBeacons, .objSwitches, .coachCounter, .bannerBeaconOnlineSub, .scoreBeacons, .scoreLights, .upgTurret: return "dd"
        case .objRestorePower, .objSealVents, .scoreBreakers, .scoreVents: return "dd"
        case .objRestartPumps, .scorePumps: return "dd"
        default: return ""
        }
    }
}

// ---------------------------------------------------------------- builders shared by the game and the app's warm-ups
extension GameText {
    /// First sighting of a special bug (toast); nil for runners.
    public static func bugTip(_ t: BugType) -> GameText? {
        switch t {
        case .runner: return nil
        case .spitter: return GameText(.toastTipSpitter, [.name(.bug(t))])
        case .brute: return GameText(.toastTipBrute, [.name(.bug(t))])
        case .boomer: return GameText(.toastTipBoomer, [.name(.bug(t))])
        case .dropper: return GameText(.toastTipDropper, [.name(.bug(t))])
        }
    }

    /// Stage 1 R4: the first perched spitter of a mission (toast) and the first rattling duct mouth.
    public static let perchTip = GameText(.toastTipPerch, [.name(.bug(.spitter))])
    public static let ductTip = GameText(.toastTipDuct)
    /// «{call-sign} pinned» (a squadmate under a Dropper) / «{call-sign}: got it off you» (the squad freed the player).
    public static func matePinned(_ name: NameRef) -> GameText { GameText(.toastMatePinned, [.name(name)]) }
    public static func pinFreed(_ name: NameRef) -> GameText { GameText(.toastPinFreed, [.name(name)]) }

    /// «{name} down» / «You're down» toast of a marine going down.
    public static func downToast(_ name: NameRef) -> GameText {
        name == .player ? GameText(.toastPlayerDown) : GameText(.toastMateDown, [.name(name)])
    }

    /// «{name} back up» / «You're back up» toast of a revive.
    public static func upToast(_ name: NameRef) -> GameText {
        name == .player ? GameText(.toastPlayerUp) : GameText(.toastMateUp, [.name(name)])
    }

    /// Medkit pickup toast.
    public static func medkitToast(_ amount: Int) -> GameText { GameText(.toastMedkit, [.int(amount)]) }

    /// The default horde banner.
    public static let hordeTitle = GameText(.bannerHorde)
    public static let hordeSubtitle = GameText(.bannerHordeSub)
}
