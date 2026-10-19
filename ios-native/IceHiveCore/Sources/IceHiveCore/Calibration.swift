import Foundation
#if canImport(Dispatch) && !os(WASI)
import Dispatch
#endif

// ================================================================
//  CALIBRATION — headless balance runs of the v1.1 tiers (port of the web
//  harness/calib run.mjs / batch.mjs / agg.mjs of origin/v1.1/a-threat).
//  One run = one Game on «Кельвин-9» (or a generated station) with the
//  medium-quality cap, the first upgrade card picked at every level-up,
//  fixed SIM_DT ticks until the mission ends or `maxs` seconds pass. Rows use
//  the web run.mjs field names, so the web agg.mjs reads native rows and
//  `aggregate` reads web rows. The CLI is Sources/IceHiveCalib (icehive-calib),
//  CI runs `--preset gate --gate` (README «v1.1 Ставки» → calibration).
// ================================================================

/// How the player marine is driven.
public enum CalibMode: String, CaseIterable {
    /// The autopilot plays (perfect aim, kites poorly).
    case auto
    /// Autopilot that deals no damage and never uses its ability.
    case passive
    /// No input at all (maxs 420 by default).
    case afk
    /// Autopilot until the first beacon starts, then no input.
    case afkbeacon

    var index: Int { CalibMode.allCases.firstIndex(of: self) ?? 0 }
}

/// One calibration mission.
public struct CalibRun {
    public var tag: String
    public var cls: MarineClass
    /// 0 Новобранец, 1 Ветеран, 2 Кошмар, -1 the hidden legacy v1.0 row.
    public var tier: Int
    public var mode: CalibMode
    public var maxs: Float
    public var seed: UInt32
    /// 0 = «Кельвин-9», else a generated station seed.
    public var station: UInt32
    /// Tier row overrides by web field name (`--th`).
    public var th: [String: Double]
    public var quality: QualityTier

    public init(tag: String, cls: MarineClass, tier: Int, mode: CalibMode, maxs: Float? = nil, seed: UInt32, station: UInt32 = 0,
                th: [String: Double] = [:], quality: QualityTier = .med) {
        self.tag = tag; self.cls = cls; self.tier = tier; self.mode = mode
        self.maxs = maxs ?? (mode == .afk ? 420 : 600)
        self.seed = seed; self.station = station; self.th = th; self.quality = quality
    }

    /// The tier row of this run (overrides applied).
    public var difficulty: Difficulty {
        var d = tier >= 0 ? Difficulty.tier(tier) : Difficulty.legacyV10
        d.override(th)
        return d
    }
}

/// The Матка in one run (web W.queen).
public struct CalibQueen {
    public var spawnT: Float = 0
    public var liftT: Float = 0
    public var hp: Int = 0
    public var squadAtSpawn = ""
    public var killT: Float? = nil
    public var liftAtKill: Float? = nil
    public var squadAtKill: String? = nil
    public var downs = 0
}

/// One result row (web run.mjs '[R]' line).
public struct CalibRow {
    public var tag = "", cls = "assault", q = "med", mode = "auto"
    public var tierIx = 1
    public var seed: UInt32 = 0
    public var station: UInt32 = 0
    public var th: [String: Double] = [:]
    /// won | lost | playing (timed out).
    public var result = "playing"
    public var t: Float = 0
    public var tier = "vet"
    public var shots = 0, hits = 0, pKills = 0
    public var stage = "beacons"
    public var beacons = 0, kills = 0, level = 1
    /// First time (s) of each stage name and of b1…b3 (beacon k started) / c1…c3 (k beacons done).
    public var stageAt: [(String, Float)] = []
    /// Downs per marine (0 = the player).
    public var downs = [0, 0, 0, 0]
    public var pDowns = 0
    public var downBy = -1
    public var firstDown: Float = -1, pFirstDown: Float = -1
    public var holdDowns = 0
    public var minHp = [999, 999, 999, 999]
    public var pLowS: Float = 0, pHalfS: Float = 0
    public var pTakenPerMin = 0
    public var maxAlive = 0, avgAlive = 0, holdAliveMax = 0, deckMax = 0, nearMax = 0
    public var idleMax: Float = 1
    public var idleSt = ""
    public var pressAtHold: Float? = nil
    public var pressMax: Float = 0
    public var firstBrute: Float = -1
    /// Squad downs by stage key (b1…b3 defending, trav travelling, toLift, hold, extract).
    public var downSt: [(String, Int)] = []
    public var queen: CalibQueen? = nil
    /// Damage the squad took per source (index src + 1: environment, runner, spitter, brute, boomer, Матка).
    public var hurtBy = [Int](repeating: 0, count: 6)
    /// Squad downs per source of each marine's last hit.
    public var downBy4 = [Int](repeating: 0, count: 6)
    public var error: String? = nil

    public init() {}

    public var squadDowns: Int { downs.reduce(0, +) }
    public var won: Bool { result == "won" }
    public var lost: Bool { result == "lost" }
    func stageTime(_ k: String) -> Float? { stageAt.first { $0.0 == k }?.1 }
    public var reachedHold: Bool { stageTime("hold") != nil }
}

// ---------- JSON (web key order; numbers as the web prints them) ----------
private func jnum(_ v: Float, _ digits: Int = 1) -> String {
    if !v.isFinite { return "null" }
    let s = String(format: "%.\(digits)f", Double(v))
    if s.contains(".") {
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }
    return s
}
private func jstr(_ s: String) -> String {
    var o = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        default: if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
        }
    }
    return o + "\""
}
private func jints(_ a: [Int]) -> String { "[" + a.map(String.init).joined(separator: ",") + "]" }

extension CalibRow {
    /// One JSONL line (web run.mjs field names and order).
    public var json: String {
        if let e = error {
            return "{\"tag\":\(jstr(tag)),\"cls\":\(jstr(cls)),\"tierIx\":\(tierIx),\"mode\":\(jstr(mode)),\"error\":\(jstr(e))}"
        }
        var s = "{\"tag\":\(jstr(tag)),\"cls\":\(jstr(cls)),\"q\":\(jstr(q)),\"mode\":\(jstr(mode)),\"tierIx\":\(tierIx),\"seed\":\(seed),\"station\":\(station),"
        s += "\"th\":{" + th.keys.sorted().map { jstr($0) + ":" + jnum(Float(th[$0]!), 4) }.joined(separator: ",") + "},"
        s += "\"result\":\(jstr(result)),\"t\":\(jnum(t)),\"tier\":\(jstr(tier)),\"shots\":\(shots),\"hits\":\(hits),\"pKills\":\(pKills),"
        s += "\"stage\":\(jstr(stage)),\"beacons\":\(beacons),\"kills\":\(kills),\"level\":\(level),"
        s += "\"stageAt\":{" + stageAt.map { jstr($0.0) + ":" + jnum($0.1) }.joined(separator: ",") + "},"
        s += "\"downs\":\(jints(downs)),\"pDowns\":\(pDowns),\"downBy\":\(downBy),\"firstDown\":\(jnum(firstDown)),\"pFirstDown\":\(jnum(pFirstDown)),"
        s += "\"holdDowns\":\(holdDowns),\"minHp\":\(jints(minHp)),\"pLowS\":\(jnum(pLowS)),\"pHalfS\":\(jnum(pHalfS)),\"pTakenPerMin\":\(pTakenPerMin),"
        s += "\"maxAlive\":\(maxAlive),\"avgAlive\":\(avgAlive),\"holdAliveMax\":\(holdAliveMax),\"deckMax\":\(deckMax),\"nearMax\":\(nearMax),"
        s += "\"idleMax\":\(jnum(idleMax, 2)),\"idleSt\":\(jstr(idleSt)),\"pressAtHold\":\(pressAtHold.map { jnum($0) } ?? "null"),"
        s += "\"pressMax\":\(jnum(pressMax)),\"firstBrute\":\(jnum(firstBrute)),"
        s += "\"downSt\":{" + downSt.map { jstr($0.0) + ":\($0.1)" }.joined(separator: ",") + "},"
        if let q = queen {
            s += "\"queen\":{\"spawnT\":\(jnum(q.spawnT)),\"liftT\":\(jnum(q.liftT)),\"hp\":\(q.hp),\"squadAtSpawn\":\(jstr(q.squadAtSpawn)),"
            s += "\"killT\":\(q.killT.map { jnum($0) } ?? "null"),\"liftAtKill\":\(q.liftAtKill.map { jnum($0) } ?? "null"),"
            s += "\"squadAtKill\":\(q.squadAtKill.map { jstr($0) } ?? "null"),\"downs\":\(q.downs)},"
        } else {
            s += "\"queen\":null,"
        }
        s += "\"hurtBy\":\(jints(hurtBy)),\"downBy4\":\(jints(downBy4))}"
        return s
    }

    /// Back from a JSONL line (native or web rows): every field the aggregate reads. nil = not a row.
    public init?(json line: String) {
        guard let data = line.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let o = any as? [String: Any] else { return nil }
        func d(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let x = v as? Double { return x }
            if let x = v as? Int { return Double(x) }
            return nil
        }
        func f(_ k: String) -> Float? { d(o[k]).map { Float($0) } }
        func i(_ k: String) -> Int? { d(o[k]).map { Int($0) } }
        func ia(_ k: String) -> [Int]? { (o[k] as? [Any])?.compactMap { d($0).map { Int($0) } } }
        self.init()
        tag = o["tag"] as? String ?? ""
        cls = o["cls"] as? String ?? ""
        q = o["q"] as? String ?? "med"
        mode = o["mode"] as? String ?? "auto"
        tierIx = i("tierIx") ?? 1
        if let e = o["error"] as? String { error = e; return }
        seed = UInt32(clamping: i("seed") ?? 0)
        station = UInt32(clamping: i("station") ?? 0)
        if let t = o["th"] as? [String: Any] { for (k, v) in t { if let x = d(v) { th[k] = x } } }
        result = o["result"] as? String ?? "playing"
        t = f("t") ?? 0
        tier = o["tier"] as? String ?? ""
        shots = i("shots") ?? 0; hits = i("hits") ?? 0; pKills = i("pKills") ?? 0
        stage = o["stage"] as? String ?? ""
        beacons = i("beacons") ?? 0; kills = i("kills") ?? 0; level = i("level") ?? 1
        if let sa = o["stageAt"] as? [String: Any] { stageAt = sa.keys.sorted().compactMap { k in d(sa[k]).map { (k, Float($0)) } } }
        if let a = ia("downs"), a.count == 4 { downs = a }
        pDowns = i("pDowns") ?? 0; downBy = i("downBy") ?? -1
        firstDown = f("firstDown") ?? -1; pFirstDown = f("pFirstDown") ?? -1
        holdDowns = i("holdDowns") ?? 0
        if let a = ia("minHp"), a.count == 4 { minHp = a }
        pLowS = f("pLowS") ?? 0; pHalfS = f("pHalfS") ?? 0; pTakenPerMin = i("pTakenPerMin") ?? 0
        maxAlive = i("maxAlive") ?? 0; avgAlive = i("avgAlive") ?? 0; holdAliveMax = i("holdAliveMax") ?? 0
        deckMax = i("deckMax") ?? 0; nearMax = i("nearMax") ?? 0
        idleMax = f("idleMax") ?? 1; idleSt = o["idleSt"] as? String ?? ""
        pressAtHold = f("pressAtHold"); pressMax = f("pressMax") ?? 0; firstBrute = f("firstBrute") ?? -1
        if let ds = o["downSt"] as? [String: Any] { downSt = ds.keys.sorted().compactMap { k in d(ds[k]).map { (k, Int($0)) } } }
        if let qo = o["queen"] as? [String: Any] {
            var qq = CalibQueen()
            qq.spawnT = Float(d(qo["spawnT"]) ?? 0); qq.liftT = Float(d(qo["liftT"]) ?? 0); qq.hp = Int(d(qo["hp"]) ?? 0)
            qq.squadAtSpawn = qo["squadAtSpawn"] as? String ?? ""
            qq.killT = d(qo["killT"]).map { Float($0) }; qq.liftAtKill = d(qo["liftAtKill"]).map { Float($0) }
            qq.squadAtKill = qo["squadAtKill"] as? String; qq.downs = Int(d(qo["downs"]) ?? 0)
            queen = qq
        }
        if let a = ia("hurtBy"), a.count == 6 { hurtBy = a }
        if let a = ia("downBy4"), a.count == 6 { downBy4 = a }
    }
}

// ================================================================
//  RUNNER
// ================================================================
public enum Calibration {

    static let stageNames = ["beacons", "toLift", "hold", "extract"]

    /// Web `toFixed(1)` of a time.
    @inline(__always) static func r1(_ v: Float) -> Float { (v * 10).rounded() / 10 }

    static func squadString(_ g: Game) -> String {
        g.marines.map { $0.downed ? "D" : String(Int($0.hp.rounded())) }.joined(separator: "/")
    }

    /// Play one mission (web run.mjs). Deterministic for its config.
    public static func run(_ c: CalibRun, level: Level? = nil) -> CalibRow {
        var cfg = GameConfig()
        cfg.quality = c.quality
        cfg.difficulty = c.difficulty
        cfg.autopilot = c.mode != .afk
        cfg.autoPickUpgrades = true
        let lv = level ?? (c.station == 0 ? nil : Level(source: StationGenerator(), seed: c.station))
        let g = Game(seed: c.seed, playerClass: c.cls, config: cfg, level: lv)
        var row = CalibRow()
        row.tag = c.tag; row.cls = c.cls.id; row.q = c.quality.rawValue; row.mode = c.mode.rawValue
        row.tierIx = c.tier; row.seed = c.seed; row.station = c.station; row.th = c.th; row.tier = g.difficulty.id

        var stageAt: [(String, Float)] = []
        func mark(_ k: String, _ t: Float) { if !stageAt.contains(where: { $0.0 == k }) { stageAt.append((k, t)) } }
        var downSt: [(String, Int)] = []
        func addDown(_ k: String) {
            if let i = downSt.firstIndex(where: { $0.0 == k }) { downSt[i].1 += 1 } else { downSt.append((k, 1)) }
        }
        var wasDown = [false, false, false, false]
        var minHp: [Float] = [999, 999, 999, 999]
        var lowT: Float = 0, halfT: Float = 0, pTaken: Float = 0
        var aliveSum = 0, aliveN = 0
        var afkStop = false
        var qDowns0 = 0
        let P = g.marines[0]
        let L = g.level.lift
        var tick = 0
        while g.phase == .playing && g.time < c.maxs {
            if c.mode == .passive { P.mods.dmg = 0; P.abCd = 99; P.mods.explosive = 0 }
            if c.mode == .afkbeacon && !afkStop && g.activeBeacon >= 0 { afkStop = true; g.autopilot = false }
            let hp0 = P.hp
            g.tick()
            g.clearEvents()
            if !P.downed && P.hp < hp0 { pTaken += hp0 - P.hp } else if P.downed && hp0 > 0 { pTaken += hp0 }
            let st = stageNames[g.stage.rawValue], t = r1(g.time)
            mark(st, t)
            if g.activeBeacon >= 0 { mark("b\(g.beaconsDone + 1)", t) }
            if g.beaconsDone > 0 { mark("c\(g.beaconsDone)", t) }
            for k in 0..<4 {
                let m = g.marines[k]
                if m.downed && !wasDown[k] {
                    row.downs[k] += 1
                    if row.firstDown < 0 { row.firstDown = t }
                    if k == 0 && row.pFirstDown < 0 { row.pFirstDown = t }
                    if g.stage == .hold { row.holdDowns += 1 }
                    addDown(g.stage == .beacons ? (g.activeBeacon >= 0 ? "b\(g.beaconsDone + 1)" : "trav") : st)
                }
                wasDown[k] = m.downed
                if !m.downed && m.hp < minHp[k] { minHp[k] = m.hp }
            }
            if !P.downed && P.hp < P.maxHp * 0.3 { lowT += SIM_DT }
            if !P.downed && P.hp < P.maxHp * 0.5 { halfT += SIM_DT }
            if g.idleMul > row.idleMax {
                row.idleMax = g.idleMul
                row.idleSt = g.stage == .beacons ? (g.activeBeacon >= 0 ? "b\(g.beaconsDone + 1)" : "trav\(g.beaconsDone)") : st
            }
            if g.stage == .hold && row.pressAtHold == nil { row.pressAtHold = r1(g.pressure) }
            if g.pressure > row.pressMax { row.pressMax = g.pressure }
            if row.firstBrute < 0 && g.typeAlive[2] > 0 { row.firstBrute = t }
            // the Матка
            let Q = g.queen
            if Q.spawned && row.queen == nil {
                var qq = CalibQueen()
                qq.spawnT = t; qq.liftT = r1(g.liftT)
                let S = g.bugs
                var i = 0
                while i < S.count { if S.uid[i] == Q.uid { qq.hp = Int(S.hpMax[i].rounded()); break }; i += 1 }
                qq.squadAtSpawn = squadString(g)
                row.queen = qq
                qDowns0 = row.squadDowns
            }
            if row.queen != nil && Q.done && row.queen!.killT == nil && Q.killT > 0 {
                row.queen!.killT = r1(Q.killT); row.queen!.liftAtKill = r1(g.liftT); row.queen!.squadAtKill = squadString(g)
            }
            if row.queen != nil { row.queen!.downs = row.squadDowns - qDowns0 }
            if tick % 30 == 0 {
                let S = g.bugs
                var alive = 0, near = 0, deck = 0
                var i = 0
                let hold = g.stage == .hold
                while i < S.count {
                    if S.dead[i] == 0 {
                        alive += 1
                        let dx = S.x[i] - P.x, dz = S.z[i] - P.z
                        if dx * dx + dz * dz < 64 { near += 1 }
                        if hold {
                            let lx = S.x[i] - L.x, lz = S.z[i] - L.z
                            if lx * lx + lz * lz < L.r * L.r { deck += 1 }
                        }
                    }
                    i += 1
                }
                row.maxAlive = max(row.maxAlive, alive); row.nearMax = max(row.nearMax, near)
                aliveSum += alive; aliveN += 1
                if hold { row.holdAliveMax = max(row.holdAliveMax, alive); row.deckMax = max(row.deckMax, deck) }
            }
            tick += 1
        }
        row.result = g.phase == .won ? "won" : (g.phase == .lost ? "lost" : "playing")
        row.t = r1(g.time)
        row.shots = Int(g.shots.rounded()); row.hits = Int(g.hits.rounded()); row.pKills = g.playerKills
        row.stage = stageNames[g.stage.rawValue]; row.beacons = g.beaconsDone; row.kills = g.kills; row.level = g.xpLevel
        row.stageAt = stageAt
        row.pDowns = g.downs; row.downBy = g.downBy.rawValue
        row.minHp = minHp.map { Int($0.rounded()) }
        row.pLowS = r1(lowT); row.pHalfS = r1(halfT)
        row.pTakenPerMin = Int((pTaken / max(0.1, g.time / 60)).rounded())
        row.avgAlive = Int((Float(aliveSum) / Float(max(1, aliveN))).rounded())
        row.idleMax = (row.idleMax * 100).rounded() / 100
        row.pressMax = r1(row.pressMax)
        row.downSt = downSt
        row.hurtBy = g.hurtBy.map { Int($0.rounded()) }
        row.downBy4 = g.squadDownBy
        return row
    }

    /// Run every config, `jobs` at a time (independent Games, no shared mutable state). Rows come back in config order.
    public static func runAll(_ cs: [CalibRun], jobs: Int = 3, progress: ((Int, CalibRow) -> Void)? = nil) -> [CalibRow] {
        let n = cs.count
        if n == 0 { return [] }
        let out = UnsafeMutablePointer<CalibRow>.allocate(capacity: n)
        out.initialize(repeating: CalibRow(), count: n)
        defer { out.deinitialize(count: n); out.deallocate() }
        // one Kelvin level shared read-only? No: every Game owns its Level (flow fields are per level), build per run.
        #if canImport(Dispatch) && !os(WASI)
        let lock = NSLock()
        var done = 0
        let w = max(1, min(jobs, n))
        DispatchQueue.concurrentPerform(iterations: w) { k in
            var i = k
            while i < n {
                let r = run(cs[i])
                out[i] = r
                lock.lock(); done += 1; let d = done; lock.unlock()
                progress?(d, r)
                i += w
            }
        }
        #else
        for i in 0..<n { let r = run(cs[i]); out[i] = r; progress?(i + 1, r) }
        #endif
        return Array(UnsafeBufferPointer(start: out, count: n))
    }

    // ---------- presets (seed = seed0 + 10000·mode + 1000·tier + 100·class + k) ----------
    public static func seed(_ seed0: UInt32, mode: CalibMode, tier: Int, cls: MarineClass, k: Int) -> UInt32 {
        let ts = tier >= 0 ? tier : 3
        return seed0 &+ UInt32(10000 * mode.index + 1000 * ts + 100 * cls.rawValue + k)
    }

    public static func tierTag(_ tier: Int) -> String { tier >= 0 ? Difficulty.tier(tier).id : Difficulty.legacyV10.id }

    /// `n` runs per class of one tier + mode.
    public static func batch(tier: Int, mode: CalibMode, n: Int, classes: [MarineClass] = MarineClass.allCases, seed0: UInt32 = 1000,
                             tag: String? = nil, th: [String: Double] = [:], maxs: Float? = nil, station: UInt32 = 0) -> [CalibRun] {
        var out: [CalibRun] = []
        for k in 0..<n {
            for c in classes {
                let tg = (tag.map { $0 + "-" } ?? "") + tierTag(tier)
                out.append(CalibRun(tag: tg, cls: c, tier: tier, mode: mode, maxs: maxs, seed: seed(seed0, mode: mode, tier: tier, cls: c, k: k),
                                    station: station, th: th))
            }
        }
        return out
    }

    public static let presetNames = ["gate", "full", "stations", "legacy"]

    /// gate: CI (≈ 148 runs); full: tuning; stations: generated seeds 0–4; legacy: the v1.0 port check.
    public static func preset(_ name: String, seed0: UInt32 = 1000, th: [String: Double] = [:], tag: String? = nil) -> [CalibRun]? {
        switch name {
        case "gate":
            var out: [CalibRun] = batch(tier: 0, mode: .auto, n: 8, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 1, mode: .auto, n: 16, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 2, mode: .auto, n: 8, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 1, mode: .afk, n: 1, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 0, mode: .afk, n: 1, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 1, mode: .passive, n: 1, seed0: seed0, tag: tag, th: th)
            out += batch(tier: -1, mode: .auto, n: 2, seed0: seed0, tag: tag)
            return out
        case "full":
            var out: [CalibRun] = batch(tier: 0, mode: .auto, n: 40, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 1, mode: .auto, n: 40, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 2, mode: .auto, n: 40, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 1, mode: .afk, n: 2, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 0, mode: .afk, n: 2, seed0: seed0, tag: tag, th: th)
            out += batch(tier: 1, mode: .passive, n: 2, seed0: seed0, tag: tag, th: th)
            return out
        case "stations":
            var out: [CalibRun] = []
            for s in 0..<5 {
                out += batch(tier: 1, mode: .auto, n: 4, seed0: seed0, tag: (tag.map { $0 + "-" } ?? "") + "st\(s)", th: th, station: UInt32(s))
            }
            return out
        case "legacy":
            return batch(tier: -1, mode: .auto, n: 8, seed0: seed0, tag: tag)
        default:
            return nil
        }
    }

    // ================================================================
    //  AGGREGATE (agg.mjs) and GATE (spec §5.2)
    // ================================================================
    static func mean(_ a: [Float]) -> Float { a.isEmpty ? .nan : a.reduce(0, +) / Float(a.count) }
    static func median(_ a: [Float]) -> Float {
        if a.isEmpty { return .nan }
        let s = a.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    static func pct(_ a: Int, _ n: Int) -> Float { n > 0 ? 100 * Float(a) / Float(n) : .nan }

    /// Numbers of one group of rows (tag + mode).
    public struct Group {
        public let key: String
        public let n: Int
        public let winPct: Float
        public let downsPerRun: Float
        public let zeroDownPct: Float, someDownPct: Float, manyDownPct: Float
        public let playerDowns: Float
        public let playerMinHp: Float
        public let holdPct: Float
        public let queenReachedPct: Float
        /// Of the runs that reached her.
        public let queenKilledPct: Float
        public let queenKillMedian: Float
        public let idleMedian: Float, idleMax: Float
        public let firstPlayerDownMedian: Float
        public let firstPlayerDownMax: Float
        /// Runs without a player down.
        public let noPlayerDown: Int
        public let winTime: Float, lossTime: Float
        public let perClass: [(String, Int, Int)]
        public let downsByStage: [(String, Float)]
        /// Share of the squad's damage per source (environment, runner, spitter, brute, boomer, Матка), %.
        public let hurtShares: [Float]
    }

    public static func group(_ key: String, _ rs: [CalibRow]) -> Group {
        let n = rs.count
        let won = rs.filter { $0.won }, lost = rs.filter { $0.lost }
        let dn = rs.map { $0.squadDowns }
        var per: [(String, Int, Int)] = []
        for r in rs {
            if let i = per.firstIndex(where: { $0.0 == r.cls }) { per[i].2 += 1; if r.won { per[i].1 += 1 } }
            else { per.append((r.cls, r.won ? 1 : 0, 1)) }
        }
        var ds: [(String, Int)] = []
        for r in rs { for (s, v) in r.downSt { if let i = ds.firstIndex(where: { $0.0 == s }) { ds[i].1 += v } else { ds.append((s, v)) } } }
        let qr = rs.filter { $0.queen != nil }, qk = qr.filter { $0.queen!.killT != nil }
        let pd1 = rs.map { $0.pFirstDown }.filter { $0 >= 0 }
        var hurt = [Float](repeating: 0, count: 6)
        for r in rs { for k in 0..<6 { hurt[k] += Float(r.hurtBy[k]) } }
        let ht = hurt.reduce(0, +)
        return Group(key: key, n: n, winPct: pct(won.count, n), downsPerRun: mean(dn.map { Float($0) }),
                     zeroDownPct: pct(dn.filter { $0 == 0 }.count, n), someDownPct: pct(dn.filter { $0 >= 1 && $0 <= 3 }.count, n),
                     manyDownPct: pct(dn.filter { $0 >= 4 }.count, n), playerDowns: mean(rs.map { Float($0.downs[0]) }),
                     playerMinHp: median(rs.map { Float($0.minHp[0]) }), holdPct: pct(rs.filter { $0.reachedHold }.count, n),
                     queenReachedPct: pct(qr.count, n), queenKilledPct: pct(qk.count, qr.count),
                     queenKillMedian: median(qk.map { $0.queen!.killT! }),
                     idleMedian: median(rs.map { $0.idleMax }), idleMax: rs.map { $0.idleMax }.max() ?? .nan,
                     firstPlayerDownMedian: median(pd1), firstPlayerDownMax: pd1.max() ?? .nan, noPlayerDown: n - pd1.count,
                     winTime: mean(won.map { $0.t }), lossTime: mean(lost.map { $0.t }), perClass: per,
                     downsByStage: ds.map { ($0.0, Float($0.1) / Float(max(1, n))) },
                     hurtShares: hurt.map { ht > 0 ? 100 * $0 / ht : 0 })
    }

    /// Rows grouped by tag + mode, sorted by key.
    public static func groups(_ rows: [CalibRow]) -> [Group] {
        var g: [String: [CalibRow]] = [:]
        var order: [String] = []
        for r in rows where r.error == nil {
            let k = r.tag + " " + r.mode
            if g[k] == nil { order.append(k) }
            g[k, default: []].append(r)
        }
        return order.sorted().map { group($0, g[$0]!) }
    }

    static func fmt(_ v: Float, _ d: Int = 0) -> String { v.isNaN ? "-" : String(format: "%.\(d)f", Double(v)) }
    /// A band limit as written in the spec (0.5, 1.3, 70).
    static func bnum(_ v: Float) -> String { v == v.rounded() ? fmt(v) : fmt(v, 1) }
    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

    /// agg.mjs table (+ the damage shares per source).
    public static func aggregate(_ rows: [CalibRow]) -> String {
        var out: [String] = []
        let errs = rows.filter { $0.error != nil }
        if !errs.isEmpty { out.append("errors: \(errs.count) " + errs.map { $0.tag + "/" + $0.cls }.joined(separator: " ")) }
        out.append("tag mode".padding(toLength: 18, withPad: " ", startingAt: 0) + " " + [pad("n", 3), pad("win%", 5), pad("dn/r", 5), pad("0dn%", 5),
                   pad("1-3%", 5), pad("4+%", 4), pad("pDn", 4), pad("pMin", 5), pad("hold%", 6), pad("Qrch%", 6), pad("Qkil%", 6), pad("Qmed", 5),
                   pad("idleMd", 7), pad("idleMx", 7), pad("pDn1", 6), pad("tWin", 5), pad("tLoss", 6)].joined(separator: " ")
                   + "  perClass | downs by stage | hurt% env/run/spit/brute/boom/queen")
        for g in groups(rows) {
            let pd1 = g.firstPlayerDownMedian.isNaN ? "-" : fmt(g.firstPlayerDownMedian) + (g.noPlayerDown > 0 ? "*" : "")
            let cols = [pad("\(g.n)", 3), pad(fmt(g.winPct), 5), pad(fmt(g.downsPerRun, 1), 5), pad(fmt(g.zeroDownPct), 5), pad(fmt(g.someDownPct), 5),
                        pad(fmt(g.manyDownPct), 4), pad(fmt(g.playerDowns, 1), 4), pad(fmt(g.playerMinHp), 5), pad(fmt(g.holdPct), 6),
                        pad(fmt(g.queenReachedPct), 6), pad(fmt(g.queenKilledPct), 6), pad(fmt(g.queenKillMedian, 1), 5),
                        pad(fmt(g.idleMedian, 2), 7), pad(fmt(g.idleMax, 2), 7), pad(pd1, 6), pad(fmt(g.winTime), 5), pad(fmt(g.lossTime), 6)]
            let per = g.perClass.map { String($0.0.prefix(2)) + "\($0.1)/\($0.2)" }.joined(separator: " ")
            let ds = g.downsByStage.map { $0.0 + ":" + fmt($0.1, 1) }.joined(separator: " ")
            let hs = g.hurtShares.map { fmt($0) }.joined(separator: "/")
            out.append(g.key.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + cols.joined(separator: " ") + "  " + per + " | " + ds + " | " + hs)
        }
        out.append("(downs = squad downs per run, all four marines; pDn1: median time of the first player down, * = some runs had none; "
                   + "Qkil% is of the runs that reached her.)")
        return out.joined(separator: "\n")
    }

    /// One gate verdict.
    public struct GateLine {
        public let ok: Bool
        public let gated: Bool
        public let text: String
    }

    /// Spec §5.2 bands on rows grouped by tier + mode (any tag, station 0, no overrides). Gated lines first, then the
    /// reported ones. `passed` only when every gated band holds and every gated group exists.
    public static func gate(_ rows: [CalibRow]) -> (passed: Bool, lines: [GateLine]) {
        let base = rows.filter { $0.error == nil && $0.station == 0 && $0.th.isEmpty }
        func grp(_ tier: Int, _ mode: String) -> Group? {
            let rs = base.filter { $0.tierIx == tier && $0.mode == mode }
            return rs.isEmpty ? nil : group("\(tierTag(tier)) \(mode)", rs)
        }
        var L: [GateLine] = []
        func band(_ name: String, _ v: Float, _ lo: Float?, _ hi: Float?, gated: Bool = true, unit: String = "") {
            let ok = !v.isNaN && (lo.map { v >= $0 } ?? true) && (hi.map { v <= $0 } ?? true)
            let b = (lo.map { bnum($0) } ?? "") + "…" + (hi.map { bnum($0) } ?? "")
            L.append(GateLine(ok: ok, gated: gated, text: "\(name) \(fmt(v, 1))\(unit) band \(b)\(unit)"))
        }
        func missing(_ name: String) { L.append(GateLine(ok: false, gated: true, text: "\(name) missing (no rows)")) }
        if let g = grp(0, "auto") {
            band("rec/auto wins", g.winPct, 90, nil, unit: "%")
            band("rec/auto downs/run", g.downsPerRun, nil, 0.5)
        } else { missing("rec/auto") }
        if let g = grp(1, "auto") {
            band("vet/auto wins", g.winPct, 70, 85, unit: "%")
            band("vet/auto queen reached", g.queenReachedPct, 75, nil, unit: "%")
            band("vet/auto queen killed of reached", g.queenKilledPct, 85, nil, unit: "%")
            band("vet/auto queen kill median", g.queenKillMedian, 20, 35, gated: false, unit: " s")
            band("vet/auto runs with 1-3 downs", g.someDownPct, 55, nil, gated: false, unit: "%")
            band("vet/auto idleMax max", g.idleMax, nil, 1.3, gated: false)
        } else { missing("vet/auto") }
        if let g = grp(2, "auto") {
            band("nm/auto wins", g.winPct, nil, 30, unit: "%")
            band("nm/auto hold reached", g.holdPct, 50, nil, gated: false, unit: "%")
        } else { missing("nm/auto") }
        for (tier, lim) in [(1, Float(120)), (0, Float(270))] {
            let rs = base.filter { $0.tierIx == tier && $0.mode == "afk" }
            let name = "\(tierTag(tier))/afk first player down"
            if rs.isEmpty { missing(name); continue }
            let worst = rs.map { $0.pFirstDown < 0 ? Float.infinity : $0.pFirstDown }.max() ?? .infinity
            let best = rs.map { $0.pFirstDown < 0 ? Float.infinity : $0.pFirstDown }.min() ?? .infinity
            L.append(GateLine(ok: worst <= lim, gated: true,
                              text: "\(name) \(fmt(best))–\(worst.isFinite ? fmt(worst) : "never") s (every run) band …\(fmt(lim)) s"))
        }
        if let g = grp(1, "passive") { band("vet/passive wins", g.winPct, nil, 40, gated: false, unit: "%") }
        if let g = grp(-1, "auto") {
            band("v10/auto wins (legacy port check)", g.winPct, nil, nil, gated: false, unit: "%")
            band("v10/auto downs/run", g.downsPerRun, nil, nil, gated: false)
        }
        let gatedLines = L.filter { $0.gated }, reported = L.filter { !$0.gated }
        return (gatedLines.allSatisfy { $0.ok }, gatedLines + reported)
    }

    /// The gate as text: `CALIB: FAILED …` lines (or `CALIB: passed`) and the reported bands.
    public static func gateText(_ rows: [CalibRow]) -> (passed: Bool, text: String) {
        let (ok, lines) = gate(rows)
        var out: [String] = []
        for l in lines where l.gated && !l.ok { out.append("CALIB: FAILED " + l.text) }
        if ok { out.append("CALIB: passed") }
        for l in lines { out.append((l.gated ? "  gate " : "  info ") + (l.ok ? "ok   " : "MISS ") + l.text) }
        return (ok, out.joined(separator: "\n"))
    }

    /// `--th '{"trickle":1.3,"qHp":4200}'` → fields, or the unknown / malformed keys.
    public static func parseTh(_ json: String) -> (fields: [String: Double], errors: [String]) {
        guard !json.isEmpty else { return ([:], []) }
        guard let data = json.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let o = any as? [String: Any] else { return ([:], ["not a JSON object: " + json]) }
        var f: [String: Double] = [:], errs: [String] = []
        for (k, v) in o {
            guard Difficulty.overrideKeys.contains(k) else { errs.append("unknown tier field " + k); continue }
            if let n = v as? NSNumber, !Profile.isBool(n) { f[k] = n.doubleValue } else if let x = v as? Double { f[k] = x } else { errs.append("not a number: " + k) }
        }
        return (f, errs.sorted())
    }
}
