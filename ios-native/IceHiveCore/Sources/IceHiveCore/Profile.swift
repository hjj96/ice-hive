import Foundation

// ================================================================
//  META — fighter profile, run score, ranks per class, tier medals and the
//  mission report model (v1.1 «Ставки», web 11c-meta.js). Pure data and texts:
//  the app persists the profile (SettingsStore key `profile`) and lays the
//  report out; every string the player reads is built here so tests pin it.
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
    public var tierName: String
    public var stage: MissionStage
    /// The swarm was converging (pressure past its grace) when the squad fell.
    public var pressureLoss: Bool
    public var shots: Int
    public var hits: Int
    public var accuracy: Int
    public var bestCombo: Int
    public var level: Int
    public var station: String

    public init(cls: MarineClass, won: Bool, surrendered: Bool, time: Float, playerKills: Int, beaconsDone: Int, queenSpawned: Bool, queenDone: Bool,
                downs: Int, downBy: DamageSource, tierIndex: Int, tierMul: Float, tierName: String, stage: MissionStage, pressureLoss: Bool,
                shots: Int, hits: Int, accuracy: Int, bestCombo: Int, level: Int, station: String) {
        self.cls = cls; self.won = won; self.surrendered = surrendered; self.time = time; self.playerKills = playerKills
        self.beaconsDone = beaconsDone; self.queenSpawned = queenSpawned; self.queenDone = queenDone; self.downs = downs; self.downBy = downBy
        self.tierIndex = tierIndex; self.tierMul = tierMul; self.tierName = tierName; self.stage = stage; self.pressureLoss = pressureLoss
        self.shots = shots; self.hits = hits; self.accuracy = accuracy; self.bestCombo = bestCombo; self.level = level; self.station = station
    }
}

// ---------- ranks (выслуга = score / 10, cumulative per class, never down) ----------
public enum Ranks {
    public static let thresholds: [Int] = [0, 300, 900, 1800, 3000, 4600, 6600, 9200, 12500, 16500]
    public static let names: [String] = ["Рядовой", "Ефрейтор", "Мл. сержант", "Сержант", "Ст. сержант", "Старшина", "Прапорщик", "Лейтенант", "Капитан", "Майор"]
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
    public let label: String
    public let value: Int
}

public struct RunScore: Equatable {
    public let parts: [ScorePart]
    public let raw: Int
    /// round(raw × tier multiplier).
    public let total: Int

    public static func make(_ run: RunSummary) -> RunScore {
        var parts = [ScorePart(label: "Ваши убийства", value: run.playerKills),
                     ScorePart(label: "Маяки \(run.beaconsDone)/3", value: run.beaconsDone * 500)]
        if run.queenSpawned && run.queenDone { parts.append(ScorePart(label: "Матка убита", value: 1000)) }
        if run.won {
            parts.append(ScorePart(label: "Эвакуация", value: 1500))
            parts.append(ScorePart(label: "Скорость · " + formatTime(run.time), value: max(0, Int(jsRound((480 - Double(run.time)) * 5)))))
            if run.downs == 0 { parts.append(ScorePart(label: "Без падений", value: 500)) }
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
    /// Thousands grouped with U+00A0 (web fmtN).
    public static func fmtN(_ v: Int) -> String {
        let neg = v < 0
        var digits = String(neg ? -v : v)
        var out = ""
        while digits.count > 3 {
            out = "\u{00A0}" + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return (neg ? "-" : "") + digits + out
    }
    /// «×0,8» / «×1,0» / «×1,5».
    public static func fmtMul(_ m: Float) -> String {
        let t = Int(jsRound(Double(m) * 10))
        return "×\(t / 10),\(t % 10)"
    }
    public static let lossTips: [String] = [
        "Бегуны берут числом — держитесь у союзников и стреляйте на ходу",
        "Плевун: уходите из светящихся кругов кислоты",
        "Громила: красная полоса — его таран, уходите рывком вбок",
        "Взрывун: убивайте издалека, не давайте раздуться рядом",
        "Матка: уходите с полосы тарана и из кислоты, сначала бейте выводок",
    ]
    public static let pressTip = "Пока маяк не запущен, улей стягивает рой — не задерживайтесь"
    public static let promo = "Дальше — «Ветеран»: так задумано. Сложность меняется на главном экране"
    public static let chip = "Попробуйте «Новобранец»"
    public static let goalPrefix = "▸ "
    public static let tierAbbr = ["Н", "В", "К"]
    /// «на «Ветеране»».
    public static let tierLoc = ["Новобранце", "Ветеране", "Кошмаре"]
    /// «эвакуироваться штурмовиком».
    public static func insCase(_ c: MarineClass) -> String {
        switch c {
        case .assault: return "штурмовиком"
        case .pyro: return "огнемётчиком"
        case .cryo: return "криотехником"
        case .gunner: return "пулемётчиком"
        }
    }

    /// Why it went wrong (nil on a win, a surrender, or a hit from nowhere).
    public static func lossTip(run: RunSummary, result: RunResult) -> String? {
        if result.won || result.surrendered { return nil }
        if result.pressureLoss { return pressTip }
        let k = run.downBy.rawValue
        return k >= 0 && k < lossTips.count ? lossTips[k] : nil
    }

    /// «Продержались на m:ss дольше прошлой попытки» (a loss longer than the previous loss by more than 5 s).
    public static func longerLine(run: RunSummary, result: RunResult) -> String? {
        if run.won || run.surrendered || result.prev.lastT <= 0 || run.time <= Float(result.prev.lastT) + 5 { return nil }
        return "Продержались на " + formatTime(run.time - Float(result.prev.lastT)) + " дольше прошлой попытки"
    }

    /// The one goal under the report: the nearest thing the player has not reached yet (`profile` after the commit).
    public static func nextGoal(profile: Profile, cls: MarineClass, result: RunResult) -> String {
        let c = profile.record(cls), r = Ranks.rankOf(c.xp), ins = insCase(cls)
        if c.wins == 0 { return "Цель: эвакуироваться " + ins + " (+1\u{00A0}500 очков)" }
        let T = Ranks.thresholds
        let left = r + 1 < T.count ? T[r + 1] - c.xp : 0
        let n = left > 0 ? max(1, Int((Double(left) / Double(max(150, result.xp))).rounded(.up))) : 0
        let t = result.tier >= 0 ? result.tier : 1
        // a medal on this tier first, then the next tier when the next rank is still far away
        var mt = -1
        if c.ev[t] == 0 { mt = t } else if t < 2 && c.ev[t + 1] == 0 && (left == 0 || n > 2) { mt = t + 1 }
        if mt >= 0 { return "Нашивка: эвакуируйтесь " + ins + " на «" + tierLoc[mt] + "»" }
        if left > 0 { return "До звания «" + Ranks.names[r + 1] + "» — " + fmtN(left) + " выслуги" }
        return "Побейте свой рекорд: " + fmtN(c.best)
    }

    /// Title line: «Штурмовик · Сержант · рекорд 9 120», else «Вылетов: N · эвакуаций: M», nil on a fresh profile.
    public static func titleProfileLine(profile: Profile, cls: MarineClass) -> String? {
        let c = profile.record(cls)
        if c.runs > 0 { return cls.spec.name + " · " + Ranks.names[Ranks.rankOf(c.xp)] + " · рекорд " + fmtN(c.best) }
        if profile.runs > 0 { return "Вылетов: \(profile.runs) · эвакуаций: \(profile.wins)" }
        return nil
    }

    /// Class card chip «ЗВ. N» (nil until the class has a run).
    public static func rankChip(profile: Profile, cls: MarineClass) -> String? {
        let c = profile.record(cls)
        return c.runs > 0 ? "ЗВ. \(Ranks.rankOf(c.xp) + 1)" : nil
    }

    /// Report subtitles (won / surrendered / lost).
    public static func subtitle(won: Bool, surrendered: Bool, station: String) -> String {
        if won { return "Отряд поднялся над бездной. " + station + " остаётся рою — но вы живы." }
        return surrendered ? "Отряд отозван. Маяки погасли один за другим." : "Последний фонарь погас. Связь с отрядом потеряна."
    }
}

// ---------- mission report model (web buildReport; the app lays it out) ----------
public struct ReportLine: Equatable {
    public let label: String
    public let value: String
}

public struct ReportStripItem: Equatable {
    public let label: String
    public let on: Bool
}

public struct ReportTip: Equatable {
    public let text: String
    /// Green («дольше», promo) vs red (loss cause).
    public let good: Bool
}

public enum ReportButton: Int {
    /// «Ещё раз» (same class, same station, tier re-evaluated).
    case again
    /// «Новая станция» (only with the stations flag).
    case newStation
    /// «Сменить класс» (title).
    case changeClass

    public var title: String {
        switch self {
        case .again: return "Ещё раз"
        case .newStation: return "Новая станция"
        case .changeClass: return "Сменить класс"
        }
    }
}

public struct MissionReport {
    // column A
    /// «Отчёт миссии · Кельвин-9».
    public let tag: String
    /// «Эвакуация успешна» (teal) / «Рой победил» (red).
    public let title: String
    public let won: Bool
    public let surrendered: Bool
    public let subtitle: String
    /// МАЯК · МАЯК · МАЯК · ЛИФТ · МАТКА · ЭВАКУАЦИЯ (on = teal on a win, amber on a loss).
    public let strip: [ReportStripItem]
    public let scoreLabel: String
    public let scoreTotal: String
    /// «Новый рекорд» (amber chip) when `record`, else «рекорд N» (nil on the first run of the class).
    public let scoreNote: String?
    public let record: Bool
    /// «{label}» + «+N».
    public let parts: [ReportLine]
    /// «Ветеран · ×1,0 очков» and its delta «+N» / «−N» / "".
    public let tierLine: String
    public let tierDelta: String
    /// Время / Комбо / Точность / Уровень.
    public let mini: [ReportLine]
    // column B
    /// «Штурмовик · Сержант» (the app uppercases).
    public let rankTitle: String
    /// «+487 выслуги».
    public let xpLine: String
    public let rankFill: Float
    /// «Новое звание: Ефрейтор».
    public let rankUp: String?
    /// «Новая нашивка: Штурмовик · Новобранец».
    public let medal: String?
    /// Loss cause (red), «дольше» (green), promo (green), in this order.
    public let tips: [ReportTip]
    /// «Попробуйте «Новобранец»» (sets the tier to 0 and restarts the class).
    public let chip: String?
    /// The next goal (draw `MetaText.goalPrefix` before it in amber).
    public let goal: String
    public let buttons: [ReportButton]
    public let primary: ReportButton

    public static func make(run: RunSummary, result: RunResult, profile: Profile, stats: MissionStats, newStationShown: Bool) -> MissionReport {
        let won = run.won, sur = run.surrendered && !won
        let d = run.beaconsDone
        let lift = won || run.stage == .hold || run.stage == .extract
        let on = [d > 0, d > 1, d > 2, lift, won || (run.queenSpawned && run.queenDone), won]
        let names = ["Маяк", "Маяк", "Маяк", "Лифт", "Матка", "Эвакуация"]
        let strip = (0..<6).map { ReportStripItem(label: names[$0], on: on[$0]) }
        let sc = result.score
        let note: String? = result.record ? "Новый рекорд" : (result.first ? nil : "рекорд " + MetaText.fmtN(result.prev.best))
        let parts = sc.parts.map { ReportLine(label: $0.label, value: "+" + MetaText.fmtN($0.value)) }
        let dt = sc.total - sc.raw
        let delta = dt == 0 ? "" : (dt > 0 ? "+" : "\u{2212}") + MetaText.fmtN(abs(dt))
        let mini = [ReportLine(label: "Время", value: formatTime(stats.time)), ReportLine(label: "Комбо", value: "×\(stats.bestCombo)"),
                    ReportLine(label: "Точность", value: "\(stats.accuracy)%"), ReportLine(label: "Уровень", value: "\(stats.level)")]
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
        return MissionReport(
            tag: "Отчёт миссии · " + run.station,
            title: won ? "Эвакуация успешна" : "Рой победил", won: won, surrendered: sur,
            subtitle: MetaText.subtitle(won: won, surrendered: sur, station: run.station),
            strip: strip, scoreLabel: "Очки", scoreTotal: MetaText.fmtN(sc.total), scoreNote: note, record: result.record,
            parts: parts, tierLine: run.tierName + " · " + MetaText.fmtMul(run.tierMul) + " очков", tierDelta: delta, mini: mini,
            rankTitle: run.cls.spec.name + " · " + Ranks.names[r1], xpLine: "+" + MetaText.fmtN(result.xp) + " выслуги",
            rankFill: Ranks.fill(xp: c.xp), rankUp: result.rankUp ? "Новое звание: " + Ranks.names[r1] : nil,
            medal: result.medal ? "Новая нашивка: " + run.cls.spec.name + " · " + run.tierName : nil,
            tips: tips, chip: result.recTip ? MetaText.chip : nil,
            goal: MetaText.nextGoal(profile: profile, cls: run.cls, result: result),
            buttons: buttons, primary: newGo ? .newStation : .again)
    }
}
