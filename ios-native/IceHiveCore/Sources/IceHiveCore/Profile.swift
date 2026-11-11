import Foundation

// ================================================================
//  META — fighter profile, run score, ranks per class, tier medals and the
//  mission report model (v1.1 «Ставки», web 11c-meta.js). Pure data and typed
//  text: the app persists the profile (SettingsStore key `profile`), resolves
//  the GameText / NameRef values through its string catalog and lays the
//  report out; what the player reads is decided here so tests pin it.
// ================================================================

/// JS Math.round (half up, also for negatives).
@inline(__always) func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

/// Everything about one finished mission the meta layer needs (`Game.runSummary`).
public struct RunSummary {
    public var cls: MarineClass
    public var won: Bool
    /// Recalled from the pause menu (counts as a loss).
    public var surrendered: Bool
    public var time: Float
    public var playerKills: Int
    public var beaconsDone: Int
    public var queenSpawned: Bool
    public var queenDone: Bool
    /// Player downs and what downed the player last.
    public var downs: Int
    public var downBy: DamageSource
    /// 0 Новобранец, 1 Ветеран, 2 Кошмар (-1 the legacy row).
    public var tierIndex: Int
    public var tierMul: Float
    public var stage: MissionStage
    /// The swarm was converging (pressure past its grace) when the squad fell.
    public var pressureLoss: Bool
    public var shots: Int
    public var hits: Int
    public var accuracy: Int
    public var bestCombo: Int
    public var level: Int
    public var station: NameRef
    /// Beacons the mission's plan charges (the score line «beacons N/M»; «Operation Cold Light»: 3).
    public var beaconsTotal: Int

    public init(cls: MarineClass, won: Bool, surrendered: Bool, time: Float, playerKills: Int, beaconsDone: Int, queenSpawned: Bool, queenDone: Bool,
                downs: Int, downBy: DamageSource, tierIndex: Int, tierMul: Float, stage: MissionStage, pressureLoss: Bool,
                shots: Int, hits: Int, accuracy: Int, bestCombo: Int, level: Int, station: NameRef, beaconsTotal: Int = 3) {
        self.cls = cls; self.won = won; self.surrendered = surrendered; self.time = time; self.playerKills = playerKills
        self.beaconsDone = beaconsDone; self.queenSpawned = queenSpawned; self.queenDone = queenDone; self.downs = downs; self.downBy = downBy
        self.tierIndex = tierIndex; self.tierMul = tierMul; self.stage = stage; self.pressureLoss = pressureLoss
        self.shots = shots; self.hits = hits; self.accuracy = accuracy; self.bestCombo = bestCombo; self.level = level; self.station = station
        self.beaconsTotal = beaconsTotal
    }
}

// ---------- ranks (выслуга = score / 10, cumulative per class, never down) ----------
public enum Ranks {
    public static let thresholds: [Int] = [0, 300, 900, 1800, 3000, 4600, 6600, 9200, 12500, 16500]
    /// Rank `r`'s name (catalog rank.1 … rank.10).
    public static func name(_ r: Int) -> NameRef { .rank(r) }
    public static func rankOf(_ xp: Int) -> Int {
        var r = 0
        while r + 1 < thresholds.count && xp >= thresholds[r + 1] { r += 1 }
        return r
    }
    /// Rank bar fill 0…1 between the current and the next rank (1 at Майор).
    public static func fill(xp: Int) -> Float {
        let r = rankOf(xp), lo = thresholds[r], hi = r + 1 < thresholds.count ? thresholds[r + 1] : thresholds[r]
        return hi > lo ? clampf(Float(xp - lo) / Float(hi - lo), 0, 1) : 1
    }
}

// ---------- profile v1 ----------
public struct ClassRecord: Equatable {
    public var xp = 0, runs = 0, wins = 0, best = 0, bestWin = 0, lastT = 0, lossEarly = 0
    /// Tier medals Н·В·К (0 / 1).
    public var ev: [Int] = [0, 0, 0]
    public init() {}
}

public struct Profile: Equatable {
    public var runs = 0, wins = 0, earned = 0, recTip = 0
    /// Always all four classes.
    public var cls: [MarineClass: ClassRecord]
    /// Anything bigger is not ours: boot with defaults.
    public static let maxBytes = 8192
    static let clamp = 1_000_000_000

    public init() {
        var c: [MarineClass: ClassRecord] = [:]
        for k in MarineClass.allCases { c[k] = ClassRecord() }
        cls = c
    }

    public static func fresh() -> Profile { Profile() }

    public func record(_ c: MarineClass) -> ClassRecord { cls[c] ?? ClassRecord() }

    /// A JSON number (not a boolean) that is finite and ≥ 0 → min(round(v), 1e9); else nil.
    static func num(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite && d >= 0 else { return nil }
        return Int(min(jsRound(d), Double(clamp)))
    }
    /// JSON `true` / `false` (JSONSerialization hands them over as NSNumber too).
    static func isBool(_ n: NSNumber) -> Bool {
        #if canImport(ObjectiveC)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return String(cString: n.objCType) == "c"
        #endif
    }

    /// Web sanitizeProfile: a dictionary with v == 1, else nil. Unknown keys are dropped, broken fields fall back to 0.
    public static func sanitize(_ json: Any?) -> Profile? {
        guard let p = json as? [String: Any], let v = p["v"] as? NSNumber, !isBool(v), v.doubleValue == 1 else { return nil }
        var d = Profile()
        d.runs = num(p["runs"]) ?? 0; d.wins = num(p["wins"]) ?? 0; d.earned = num(p["earned"]) ?? 0; d.recTip = num(p["recTip"]) ?? 0
        let cs = p["cls"] as? [String: Any]
        for c in MarineClass.allCases {
            guard let s = cs?[c.id] as? [String: Any] else { continue }
            var r = ClassRecord()
            r.xp = num(s["xp"]) ?? 0; r.runs = num(s["runs"]) ?? 0; r.wins = num(s["wins"]) ?? 0; r.best = num(s["best"]) ?? 0
            r.bestWin = num(s["bestWin"]) ?? 0; r.lastT = num(s["lastT"]) ?? 0; r.lossEarly = num(s["lossEarly"]) ?? 0
            if let ev = s["ev"] as? [Any] {
                for i in 0..<3 { r.ev[i] = (i < ev.count ? (num(ev[i]) ?? 0) : 0) > 0 ? 1 : 0 }
            }
            d.cls[c] = r
        }
        return d
    }

    /// Web loadProfile: the stored value when it is ours, else a fresh profile built from a v1.0 `best` record
    /// (native 2.0 or Capacitor 1.x): one finished mission, an evacuation counts as a win (→ Ветеран).
    /// The migrated profile is not written until the next commit.
    public static func load(raw: String?, legacyBest: (kills: Int, win: Int)?) -> Profile {
        if let r = raw, r.utf16.count <= maxBytes, let data = r.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), let p = sanitize(any) {
            return p
        }
        var d = Profile()
        if let b = legacyBest, b.kills > 0 || b.win > 0 { d.runs = 1; d.wins = b.win > 0 ? 1 : 0 }
        return d
    }

    /// Compact JSON in the web key order.
    public func encoded() -> String {
        var s = "{\"v\":1,\"runs\":\(runs),\"wins\":\(wins),\"earned\":\(earned),\"recTip\":\(recTip),\"cls\":{"
        for (k, c) in MarineClass.allCases.enumerated() {
            let r = record(c)
            if k > 0 { s += "," }
            s += "\"\(c.id)\":{\"xp\":\(r.xp),\"runs\":\(r.runs),\"wins\":\(r.wins),\"best\":\(r.best),\"bestWin\":\(r.bestWin),"
            s += "\"ev\":[\(r.ev[0]),\(r.ev[1]),\(r.ev[2])],\"lastT\":\(r.lastT),\"lossEarly\":\(r.lossEarly)}"
        }
        return s + "}}"
    }

    /// Web commitRun: once per mission end (surrender counts as a loss). `diffPicked`: the player chose a tier on the title.
    @discardableResult
    public mutating func commit(_ run: RunSummary, diffPicked: Bool) -> RunResult {
        let sc = RunScore.make(run)
        var c = record(run.cls)
        let tier = run.tierIndex
        let xp = Int(jsRound(Double(sc.total) / 10))
        let prev = RunResult.Prev(best: c.best, runs: c.runs, lastT: c.lastT, wins: c.wins, bestWin: c.bestWin)
        let rank0 = Ranks.rankOf(c.xp)
        let cap = Profile.clamp
        c.xp = min(cap, c.xp + xp); c.runs = min(cap, c.runs + 1)
        let medal = run.won && tier >= 0 && tier < 3 && c.ev[tier] == 0
        if run.won {
            c.wins = min(cap, c.wins + 1)
            if tier >= 0 && tier < 3 { c.ev[tier] = 1 }
            if c.bestWin == 0 || run.time < Float(c.bestWin) { c.bestWin = Int(jsRound(Double(run.time))) }
        }
        c.best = max(c.best, sc.total)
        c.lastT = run.won ? 0 : Int(jsRound(Double(run.time)))   // «дольше прошлой попытки» compares a loss with the previous loss only
        // two losses in a row before beacon 2 on Ветеран → a one-time «Попробуйте «Новобранец»» chip
        c.lossEarly = (!run.won && tier == 1 && run.beaconsDone < 2) ? min(9, c.lossEarly + 1) : 0
        cls[run.cls] = c
        runs = min(cap, runs + 1)
        if run.won { wins = min(cap, wins + 1) }
        earned = min(cap, earned + sc.total)
        let recTipNow = !run.won && tier == 1 && c.lossEarly >= 2 && recTip == 0
        if recTipNow { recTip = 1 }
        let rank1 = Ranks.rankOf(c.xp)
        return RunResult(won: run.won, surrendered: run.surrendered, score: sc, xp: xp, tier: tier, rank0: rank0, rank1: rank1, prev: prev,
                         medal: medal, recTip: recTipNow, record: prev.runs > 0 && sc.total > prev.best, first: prev.runs == 0,
                         promo: run.won && wins == 1 && !diffPicked && tier == 0, pressureLoss: run.pressureLoss)
    }
}

/// Web effectiveTier: the player's pick, else Новобранец until the first evacuation, then Ветеран.
public func effectiveTier(diffPick: Int?, profile: Profile) -> Int {
    if let d = diffPick { return max(0, min(2, d)) }
    return profile.wins > 0 ? 1 : 0
}

// ---------- score: only what the player controls (never squad kills or idle time) ----------
public struct ScorePart: Equatable {
    public let label: GameText
    public let value: Int
}

public struct RunScore: Equatable {
    public let parts: [ScorePart]
    public let raw: Int
    /// round(raw × tier multiplier).
    public let total: Int

    public static func make(_ run: RunSummary) -> RunScore {
        var parts = [ScorePart(label: GameText(.scoreKills), value: run.playerKills),
                     ScorePart(label: GameText(.scoreBeacons, [.int(run.beaconsDone), .int(run.beaconsTotal)]), value: run.beaconsDone * 500)]
        if run.queenSpawned && run.queenDone { parts.append(ScorePart(label: GameText(.scoreQueen), value: 1000)) }
        if run.won {
            parts.append(ScorePart(label: GameText(.scoreExtract), value: 1500))
            parts.append(ScorePart(label: GameText(.scoreSpeed, [.time(run.time)]), value: max(0, Int(jsRound((480 - Double(run.time)) * 5)))))
            if run.downs == 0 { parts.append(ScorePart(label: GameText(.scoreNoDowns), value: 500)) }
        }
        var raw = 0
        for p in parts { raw += p.value }
        let mul = (Double(run.tierMul) * 100).rounded() / 100
        return RunScore(parts: parts, raw: raw, total: Int(jsRound(Double(raw) * mul)))
    }
}

public struct RunResult {
    public struct Prev: Equatable { public let best, runs, lastT, wins, bestWin: Int }
    public let won: Bool
    public let surrendered: Bool
    public let score: RunScore
    /// Выслуга earned (round(total / 10)).
    public let xp: Int
    public let tier: Int
    public let rank0: Int, rank1: Int
    /// The class record before this run.
    public let prev: Prev
    /// First evacuation of this class on this tier.
    public let medal: Bool
    /// Show the one-time «Попробуйте «Новобранец»» chip.
    public let recTip: Bool
    /// A new best score (not on the first run of the class).
    public let record: Bool
    public let first: Bool
    /// First evacuation ever, on Новобранец, without a tier pick: say why the next mission is harder.
    public let promo: Bool
    public let pressureLoss: Bool
    public var rankUp: Bool { rank1 > rank0 }
}

// ---------- texts ----------
public enum MetaText {
    /// Loss causes by DamageSource (runner, spitter, brute, boomer, the Queen, the Dropper).
    public static let lossTips: [GameText] = [
        GameText(.tipLossRunner),
        GameText(.tipLossSpitter, [.name(.bug(.spitter))]),
        GameText(.tipLossBrute, [.name(.bug(.brute))]),
        GameText(.tipLossBoomer, [.name(.bug(.boomer))]),
        GameText(.tipLossQueen, [.name(.queen)]),
        GameText(.tipLossDropper, [.name(.bug(.dropper))]),
    ]
    public static let pressTip = GameText(.tipPressure)
    /// After the first evacuation on Recruit: the next mission is Veteran, as designed.
    public static let promo = GameText(.tipPromo, [.name(.tier(1))])
    /// The one-time chip that sets the tier to Recruit.
    public static let chip = GameText(.reportChip, [.name(.tier(0))])
    /// Medal pips on the class cards (one letter per tier).
    public static let tierAbbr: [NameRef] = [.tierAbbr(0), .tierAbbr(1), .tierAbbr(2)]

    /// Why it went wrong (nil on a win, a surrender, or a hit from nowhere).
    public static func lossTip(run: RunSummary, result: RunResult) -> GameText? {
        if result.won || result.surrendered { return nil }
        if result.pressureLoss { return pressTip }
        let k = run.downBy.rawValue
        return k >= 0 && k < lossTips.count ? lossTips[k] : nil
    }

    /// tip.longer: lasted m:ss longer than the last attempt (a loss longer than the previous loss by more than 5 s).
    public static func longerLine(run: RunSummary, result: RunResult) -> GameText? {
        if run.won || run.surrendered || result.prev.lastT <= 0 || run.time <= Float(result.prev.lastT) + 5 { return nil }
        return GameText(.tipLonger, [.time(run.time - Float(result.prev.lastT))])
    }

    /// First evacuation of a class: «extract as {class}» (one key per class: other languages decline the class name).
    public static func firstWinGoal(_ c: MarineClass) -> TextID {
        switch c {
        case .assault: return .goalFirstWinAssault
        case .pyro: return .goalFirstWinPyro
        case .cryo: return .goalFirstWinCryo
        case .gunner: return .goalFirstWinGunner
        }
    }

    /// A tier medal of a class: «extract as {class} on {tier}» (one key per class).
    public static func medalGoal(_ c: MarineClass) -> TextID {
        switch c {
        case .assault: return .goalMedalAssault
        case .pyro: return .goalMedalPyro
        case .cryo: return .goalMedalCryo
        case .gunner: return .goalMedalGunner
        }
    }

    /// The one goal under the report: the nearest thing the player has not reached yet (`profile` after the commit).
    public static func nextGoal(profile: Profile, cls: MarineClass, result: RunResult) -> GameText {
        let c = profile.record(cls), r = Ranks.rankOf(c.xp)
        if c.wins == 0 { return GameText(firstWinGoal(cls), [.num(1500)]) }
        let T = Ranks.thresholds
        let left = r + 1 < T.count ? T[r + 1] - c.xp : 0
        let n = left > 0 ? max(1, Int((Double(left) / Double(max(150, result.xp))).rounded(.up))) : 0
        let t = result.tier >= 0 ? result.tier : 1
        // a medal on this tier first, then the next tier when the next rank is still far away
        var mt = -1
        if c.ev[t] == 0 { mt = t } else if t < 2 && c.ev[t + 1] == 0 && (left == 0 || n > 2) { mt = t + 1 }
        if mt >= 0 { return GameText(medalGoal(cls), [.name(.tier(mt))]) }
        if left > 0 { return GameText(.goalRank, [.name(.rank(r + 1)), .num(left)]) }
        return GameText(.goalBest, [.num(c.best)])
    }

    /// Title line: class · rank · best score, else «N sorties · M extractions», nil on a fresh profile.
    public static func titleProfileLine(profile: Profile, cls: MarineClass) -> GameText? {
        let c = profile.record(cls)
        if c.runs > 0 { return GameText(.titleProfile, [.name(.cls(cls)), .name(.rank(Ranks.rankOf(c.xp))), .num(c.best)]) }
        if profile.runs > 0 {
            return GameText(.titleProfileRuns, [.text(GameText(.titleRuns, [.int(profile.runs)])), .text(GameText(.titleWins, [.int(profile.wins)]))])
        }
        return nil
    }

    /// Class card rank chip (rank number 1…10; nil until the class has a run).
    public static func rankChip(profile: Profile, cls: MarineClass) -> GameText? {
        let c = profile.record(cls)
        return c.runs > 0 ? GameText(.titleRankChip, [.int(Ranks.rankOf(c.xp) + 1)]) : nil
    }

    /// Report subtitles (won / surrendered / lost).
    public static func subtitle(won: Bool, surrendered: Bool, station: NameRef) -> GameText {
        if won { return GameText(.reportSubWon, [.name(station)]) }
        return GameText(surrendered ? .reportSubRecalled : .reportSubLost)
    }
}

// ---------- mission report model (web buildReport; the app lays it out) ----------
public struct ReportLine: Equatable {
    public let label: GameText
    public let value: GameText
}

public struct ReportStripItem: Equatable {
    public let label: GameText
    public let on: Bool
}

public struct ReportTip: Equatable {
    public let text: GameText
    /// Green («дольше», promo) vs red (loss cause).
    public let good: Bool
}

public enum ReportButton: Int {
    /// Same class, same station, tier re-evaluated.
    case again
    /// Only with the stations flag.
    case newStation
    /// Back to the title.
    case changeClass

    public var title: GameText {
        switch self {
        case .again: return GameText(.reportAgain)
        case .newStation: return GameText(.reportNewStation)
        case .changeClass: return GameText(.reportChangeClass)
        }
    }
}

public struct MissionReport {
    // column A
    /// report.tag: «Mission report · {station}».
    public let tag: GameText
    /// report.title.won (teal) / report.title.lost (red).
    public let title: GameText
    public let won: Bool
    public let surrendered: Bool
    public let subtitle: GameText
    /// BEACON · BEACON · BEACON · LIFT · QUEEN · EXTRACTION (on = teal on a win, amber on a loss).
    public let strip: [ReportStripItem]
    public let scoreLabel: GameText
    /// The run's score (the app groups the digits).
    public let scoreTotal: Int
    /// report.record (amber chip) when `record`, else report.best (nil on the first run of the class).
    public let scoreNote: GameText?
    public let record: Bool
    /// Label + «+N».
    public let parts: [ReportLine]
    /// «{tier} · ×0.8 score» and its delta «+N» / «−N» (nil when the multiplier changed nothing).
    public let tierLine: GameText
    public let tierDelta: GameText?
    /// Time / Combo / Accuracy / Level.
    public let mini: [ReportLine]
    // column B
    /// «{class} · {rank}» (the app uppercases).
    public let rankTitle: GameText
    /// «+487 service XP».
    public let xpLine: GameText
    public let rankFill: Float
    /// «New rank: {rank}».
    public let rankUp: GameText?
    /// «New badge: {class} · {tier}» (the app draws the diamond before it).
    public let medal: GameText?
    /// Loss cause (red), «longer» (green), promo (green), in this order.
    public let tips: [ReportTip]
    /// report.chip «Try Recruit» (sets the tier to 0 and restarts the class).
    public let chip: GameText?
    /// The next goal (the app draws its amber pointer before it).
    public let goal: GameText
    public let buttons: [ReportButton]
    public let primary: ReportButton

    public static func make(run: RunSummary, result: RunResult, profile: Profile, stats: MissionStats, newStationShown: Bool) -> MissionReport {
        let won = run.won, sur = run.surrendered && !won
        let d = run.beaconsDone
        let lift = won || run.stage == .hold || run.stage == .extract
        let on = [d > 0, d > 1, d > 2, lift, won || (run.queenSpawned && run.queenDone), won]
        let names: [TextID] = [.reportStripBeacon, .reportStripBeacon, .reportStripBeacon, .reportStripLift, .reportStripQueen, .reportStripExtract]
        let strip = (0..<6).map { ReportStripItem(label: GameText(names[$0]), on: on[$0]) }
        let sc = result.score
        let note: GameText? = result.record ? GameText(.reportRecord) : (result.first ? nil : GameText(.reportBest, [.num(result.prev.best)]))
        let parts = sc.parts.map { ReportLine(label: $0.label, value: GameText(.fmtPlus, [.num($0.value)])) }
        let dt = sc.total - sc.raw
        let delta: GameText? = dt == 0 ? nil : GameText(dt > 0 ? .fmtPlus : .fmtMinus, [.num(abs(dt))])
        let mini = [ReportLine(label: GameText(.reportMiniTime), value: GameText(.fmtClock, [.time(stats.time)])),
                    ReportLine(label: GameText(.reportMiniCombo), value: GameText(.fmtCombo, [.int(stats.bestCombo)])),
                    ReportLine(label: GameText(.reportMiniAccuracy), value: GameText(.fmtPercent, [.int(stats.accuracy)])),
                    ReportLine(label: GameText(.reportMiniLevel), value: GameText(.fmtInt, [.int(stats.level)]))]
        let c = profile.record(run.cls)
        let r1 = result.rank1
        var tips: [ReportTip] = []
        if let t = MetaText.lossTip(run: run, result: result) { tips.append(ReportTip(text: t, good: false)) }
        if let t = MetaText.longerLine(run: run, result: result) { tips.append(ReportTip(text: t, good: true)) }
        if result.promo { tips.append(ReportTip(text: MetaText.promo, good: true)) }
        let newGo = won && newStationShown
        var buttons: [ReportButton] = [.again]
        if newStationShown { buttons.append(.newStation) }
        buttons.append(.changeClass)
        let mul = GameText(.fmtMul, [.tenths(Int(jsRound(Double(run.tierMul) * 10)))])
        return MissionReport(
            tag: GameText(.reportTag, [.name(run.station)]),
            title: GameText(won ? .reportTitleWon : .reportTitleLost), won: won, surrendered: sur,
            subtitle: MetaText.subtitle(won: won, surrendered: sur, station: run.station),
            strip: strip, scoreLabel: GameText(.reportScore), scoreTotal: sc.total, scoreNote: note, record: result.record,
            parts: parts, tierLine: GameText(.reportTierLine, [.name(.tier(run.tierIndex)), .text(mul)]), tierDelta: delta, mini: mini,
            rankTitle: GameText(.reportRankTitle, [.name(.cls(run.cls)), .name(.rank(r1))]), xpLine: GameText(.reportXP, [.num(result.xp)]),
            rankFill: Ranks.fill(xp: c.xp), rankUp: result.rankUp ? GameText(.reportRankUp, [.name(.rank(r1))]) : nil,
            medal: result.medal ? GameText(.reportMedal, [.name(.cls(run.cls)), .name(.tier(run.tierIndex))]) : nil,
            tips: tips, chip: result.recTip ? MetaText.chip : nil,
            goal: MetaText.nextGoal(profile: profile, cls: run.cls, result: result),
            buttons: buttons, primary: newGo ? .newStation : .again)
    }
}
