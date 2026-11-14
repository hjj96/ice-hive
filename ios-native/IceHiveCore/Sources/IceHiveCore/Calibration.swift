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
    /// Mission template id (`MissionTemplate.named`); nil = «Operation Cold Light».
    public var mission: String?
    /// Stage 1 R6: «Кельвин-9» with its interactives laid (`PropLayout.kelvin`; station 0 only).
    public var props: Bool
    /// Stage 1 R5: «Кельвин-9» Mk II (`KelvinStation.mk2`: the overhead routes and the interactives laid) — the classic
    /// mission's station since R5; the presets' classic rows run on it (station 0 only; the legacy v1.0 row never does).
    public var mk2: Bool
    /// Stage 2 B4: keep the boss's timeline (its phases, cues and moves, the squad's downs) in the row's `trace` — the headless
    /// log of a fight (`icehive-calib --trace`); off in every preset.
    public var trace: Bool

    public init(tag: String, cls: MarineClass, tier: Int, mode: CalibMode, maxs: Float? = nil, seed: UInt32, station: UInt32 = 0,
                th: [String: Double] = [:], quality: QualityTier = .med, mission: String? = nil, props: Bool = false, mk2: Bool = false,
                trace: Bool = false) {
        self.tag = tag; self.cls = cls; self.tier = tier; self.mode = mode
        self.maxs = maxs ?? (mode == .afk ? 420 : 600)
        self.seed = seed; self.station = station; self.th = th; self.quality = quality; self.mission = mission; self.props = props
        self.mk2 = mk2; self.trace = trace
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

/// The overhead in one run (Stage 1 R2; only in runs where it was on — the classic rows keep their bytes).
public struct CalibOverhead: Equatable {
    public var packs = 0, spawns = 0, drops = 0, landed = 0, hits = 0, downs = 0, hurt = 0
    public var kills = 0, knockdowns = 0, shattered = 0, hops = 0, maxUp = 0, maxZones = 0
    /// Stage 1 R4: Droppers sent up, pins and how they ended (dash, the squad's fire, timed out, the marine down), the pins'
    /// total hold (ms), squad HP lost to Droppers and the downs they caused; perches taken, spits from them; duct rattles,
    /// grilles shot shut, bugs lost at a shut duct.
    public var droppers = 0, pins = 0, pinDash = 0, pinFire = 0, pinTimeout = 0, pinDown = 0, pinMs = 0, dropperHurt = 0, dropperDowns = 0
    /// Droppers' drops (telegraphs) and landings, Droppers killed up there / knocked down / hopped down.
    public var dropperDrops = 0, dropperLanded = 0, dropperKills = 0, dropperKnocks = 0, dropperHops = 0
    public var perched = 0, perchSpits = 0, rattles = 0, seals = 0, ductLost = 0
    public init() {}
    init(_ s: OverheadStats) {
        packs = s.packs; spawns = s.spawns; drops = s.drops; landed = s.landed; hits = s.hits; downs = s.downs
        hurt = Int(s.hurt.rounded()); kills = s.kills; knockdowns = s.knockdowns; shattered = s.shattered; hops = s.hops
        maxUp = s.maxUp; maxZones = s.maxZones
        droppers = s.droppers; pins = s.pins; pinDash = s.pinDash; pinFire = s.pinFire; pinTimeout = s.pinTimeout; pinDown = s.pinDown
        pinMs = Int((s.pinTime * 1000).rounded()); dropperHurt = Int(s.dropperHurt.rounded()); dropperDowns = s.dropperDowns
        perched = s.perched; perchSpits = s.perchSpits; rattles = s.rattles; seals = s.seals; ductLost = s.ductLost
        dropperDrops = s.dropperDrops; dropperLanded = s.dropperLanded; dropperKills = s.dropperKills; dropperKnocks = s.dropperKnocks
        dropperHops = s.dropperHops
    }
    /// Field names and values in JSON order.
    var fields: [(String, Int)] {
        [("packs", packs), ("spawns", spawns), ("drops", drops), ("landed", landed), ("hits", hits), ("downs", downs), ("hurt", hurt),
         ("kills", kills), ("knock", knockdowns), ("shatter", shattered), ("hops", hops), ("maxUp", maxUp), ("maxZones", maxZones),
         ("droppers", droppers), ("pins", pins), ("pinDash", pinDash), ("pinFire", pinFire), ("pinTO", pinTimeout), ("pinDown", pinDown),
         ("pinMs", pinMs), ("drpHurt", dropperHurt), ("drpDowns", dropperDowns), ("perched", perched), ("perchSpits", perchSpits),
         ("rattles", rattles), ("seals", seals), ("ductLost", ductLost), ("drpDrops", dropperDrops), ("drpLanded", dropperLanded),
         ("drpKills", dropperKills), ("drpKnock", dropperKnocks), ("drpHops", dropperHops)]
    }
}

/// The interactive props in one run (Stage 1 R6; only on a station that had them — the classic rows keep their bytes).
public struct CalibProps: Equatable {
    public var bursts = 0, curtainKills = 0, upKills = 0, freezes = 0, steamHurt = 0, lampsBroken = 0, lampSpits = 0, restores = 0, lockers = 0
    /// Light circuits lit at the end, of the station's.
    public var lights = 0, circuits = 0
    public init() {}
    init(_ s: PropStats, lights: Int, circuits: Int) {
        bursts = s.bursts; curtainKills = s.curtainKills; upKills = s.upKills; freezes = s.freezes; steamHurt = Int(s.steamHurt.rounded())
        lampsBroken = s.lampsBroken; lampSpits = s.lampSpits; restores = s.restores; lockers = s.lockers
        self.lights = lights; self.circuits = circuits
    }
    /// Field names and values in JSON order.
    var fields: [(String, Int)] {
        [("bursts", bursts), ("curtainKills", curtainKills), ("upKills", upKills), ("freezes", freezes), ("steamHurt", steamHurt), ("lampsBroken", lampsBroken),
         ("lampSpits", lampSpits), ("restores", restores), ("lockers", lockers), ("lights", lights), ("circuits", circuits)]
    }
}

/// The Threader in one run (Stage 2 B4; only in runs where it came — every other row keeps its bytes): when its phases came
/// (s after its spawn, −1 not reached), its moves, the squad's answers, the boss bar's damage by part, seconds up out of
/// reach / untouchable / down.
public struct CalibThreader: Equatable {
    public var p2T: Float = -1, p3T: Float = -1
    public var locks = 0, strikes = 0, strikeHits = 0, recoils = 0, climbs = 0, coils = 0, crushed = 0, letGo = 0, gaps = 0
    public var rimes = 0, rimeHits = 0, squeezes = 0, steamHurt = 0, pulls = 0, charges = 0, chargeHits = 0
    public var sheds = 0, ticks = 0, packs = 0, popped = 0, stripped = 0, freezeLocks = 0, brittles = 0, pains = 0
    public var dmgHead = 0, dmgNode = 0, dmgBody = 0, dmgP1 = 0, dmgP2 = 0, dmgP3 = 0
    public var upT: Float = 0, untouchT: Float = 0, downT: Float = 0
    public init() {}
    init(_ s: ThreaderStats) {
        p2T = s.p2T; p3T = s.p3T; locks = s.locks; strikes = s.strikes; strikeHits = s.strikeHits; recoils = s.recoils; climbs = s.climbs
        coils = s.coils; crushed = s.crushed; letGo = s.letGo; gaps = s.gaps; rimes = s.rimes; rimeHits = s.rimeHits; squeezes = s.squeezes
        steamHurt = Int(s.steamHurt.rounded()); pulls = s.pulls; charges = s.charges; chargeHits = s.chargeHits; sheds = s.sheds
        ticks = s.ticks; packs = s.packs; popped = s.popped; stripped = s.stripped; freezeLocks = s.freezeLocks; brittles = s.brittles
        pains = s.pains
        dmgHead = Int(s.dmgHead.rounded()); dmgNode = Int(s.dmgNode.rounded()); dmgBody = Int(s.dmgBody.rounded())
        dmgP1 = Int(s.dmgP1.rounded()); dmgP2 = Int(s.dmgP2.rounded()); dmgP3 = Int(s.dmgP3.rounded())
        upT = s.upT; untouchT = s.untouchT; downT = s.downT
    }
    /// Integer fields in JSON order (the times come first, as tenths of a second).
    var fields: [(String, Int)] {
        [("locks", locks), ("strikes", strikes), ("strikeHits", strikeHits), ("recoils", recoils), ("climbs", climbs), ("coils", coils),
         ("crushed", crushed), ("letGo", letGo), ("gaps", gaps), ("rimes", rimes), ("rimeHits", rimeHits), ("squeezes", squeezes),
         ("steamHurt", steamHurt), ("pulls", pulls), ("charges", charges), ("chargeHits", chargeHits), ("sheds", sheds), ("ticks", ticks),
         ("packs", packs), ("popped", popped), ("stripped", stripped), ("freezeLocks", freezeLocks), ("brittles", brittles),
         ("pains", pains), ("dmgHead", dmgHead),
         ("dmgNode", dmgNode), ("dmgBody", dmgBody), ("dmgP1", dmgP1), ("dmgP2", dmgP2), ("dmgP3", dmgP3)]
    }
}

/// A holdout in one run (Stage 2 D1 «Dig In»; only in runs that played one — every other row keeps its bytes): the waves
/// held, the score banked and earned (raw), the last bank's wave, the Queens met and killed, the biggest wave horde met
/// (bugs) and when each wave was held (s).
public struct CalibHoldout: Equatable {
    public var held = 0, banked = 0, score = 0, bankWave = 0, queens = 0, queenKills = 0, maxHorde = 0
    public var waveAt: [Float] = []
    public init() {}
    /// Integer fields in JSON order (`waveAt` follows as a list).
    var fields: [(String, Int)] {
        [("held", held), ("banked", banked), ("score", score), ("bankWave", bankWave), ("queens", queens), ("qKills", queenKills),
         ("maxHorde", maxHorde)]
    }
}

/// One result row (web run.mjs '[R]' line).
public struct CalibRow {
    public var tag = "", cls = "assault", q = "med", mode = "auto"
    public var tierIx = 1
    public var seed: UInt32 = 0
    public var station: UInt32 = 0
    /// Mission template id; nil = «Operation Cold Light» (its rows carry no `mission` key: the classic rows stay as they were).
    public var mission: String? = nil
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
    /// The overhead's numbers (Stage 1 R2), only when it was on in the run (written as a trailing `"oh"` object).
    public var oh: CalibOverhead? = nil
    /// The props' numbers (Stage 1 R6), only on a station with props (a trailing `"props"` object).
    public var props: CalibProps? = nil
    /// Stage 2 B4: the Threader's numbers, only when it came (a trailing `"thr"` object).
    public var thr: CalibThreader? = nil
    /// Stage 2 D1: a holdout's numbers, only in runs that played one (a trailing `"dig"` object).
    public var dig: CalibHoldout? = nil
    /// Stage 2 B4: the boss's timeline when the run asked for it (`CalibRun.trace`; never in the JSON).
    public var trace: [String]? = nil
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
        if let m = mission { s += "\"mission\":\(jstr(m))," }
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
        s += "\"hurtBy\":\(jints(hurtBy)),\"downBy4\":\(jints(downBy4))"
        if let o = oh { s += ",\"oh\":{" + o.fields.map { jstr($0.0) + ":\($0.1)" }.joined(separator: ",") + "}" }
        if let p = props { s += ",\"props\":{" + p.fields.map { jstr($0.0) + ":\($0.1)" }.joined(separator: ",") + "}" }
        if let t = thr {
            s += ",\"thr\":{\"p2T\":\(jnum(t.p2T)),\"p3T\":\(jnum(t.p3T)),\"upT\":\(jnum(t.upT)),\"untouchT\":\(jnum(t.untouchT)),"
            s += "\"downT\":\(jnum(t.downT))," + t.fields.map { jstr($0.0) + ":\($0.1)" }.joined(separator: ",") + "}"
        }
        if let h = dig {
            s += ",\"dig\":{" + h.fields.map { jstr($0.0) + ":\($0.1)" }.joined(separator: ",")
            s += ",\"waveAt\":[" + h.waveAt.map { jnum($0) }.joined(separator: ",") + "]}"
        }
        return s + "}"
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
        mission = o["mission"] as? String
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
        if let oo = o["oh"] as? [String: Any] {
            func v(_ k: String) -> Int { Int(d(oo[k]) ?? 0) }
            var c = CalibOverhead()
            c.packs = v("packs"); c.spawns = v("spawns"); c.drops = v("drops"); c.landed = v("landed"); c.hits = v("hits")
            c.downs = v("downs"); c.hurt = v("hurt"); c.kills = v("kills"); c.knockdowns = v("knock"); c.shattered = v("shatter")
            c.hops = v("hops"); c.maxUp = v("maxUp"); c.maxZones = v("maxZones")
            c.droppers = v("droppers"); c.pins = v("pins"); c.pinDash = v("pinDash"); c.pinFire = v("pinFire"); c.pinTimeout = v("pinTO")
            c.pinDown = v("pinDown"); c.pinMs = v("pinMs"); c.dropperHurt = v("drpHurt"); c.dropperDowns = v("drpDowns")
            c.perched = v("perched"); c.perchSpits = v("perchSpits"); c.rattles = v("rattles"); c.seals = v("seals"); c.ductLost = v("ductLost")
            c.dropperDrops = v("drpDrops"); c.dropperLanded = v("drpLanded"); c.dropperKills = v("drpKills"); c.dropperKnocks = v("drpKnock")
            c.dropperHops = v("drpHops")
            oh = c
        }
        if let to = o["thr"] as? [String: Any] {
            func v(_ k: String) -> Int { Int(d(to[k]) ?? 0) }
            func f(_ k: String, _ dflt: Float) -> Float { Float(d(to[k]) ?? Double(dflt)) }
            var c = CalibThreader()
            c.p2T = f("p2T", -1); c.p3T = f("p3T", -1); c.upT = f("upT", 0); c.untouchT = f("untouchT", 0); c.downT = f("downT", 0)
            c.locks = v("locks"); c.strikes = v("strikes"); c.strikeHits = v("strikeHits"); c.recoils = v("recoils"); c.climbs = v("climbs")
            c.coils = v("coils"); c.crushed = v("crushed"); c.letGo = v("letGo"); c.gaps = v("gaps"); c.rimes = v("rimes")
            c.rimeHits = v("rimeHits"); c.squeezes = v("squeezes"); c.steamHurt = v("steamHurt"); c.pulls = v("pulls"); c.charges = v("charges")
            c.chargeHits = v("chargeHits"); c.sheds = v("sheds"); c.ticks = v("ticks"); c.packs = v("packs"); c.popped = v("popped")
            c.stripped = v("stripped"); c.freezeLocks = v("freezeLocks"); c.brittles = v("brittles"); c.pains = v("pains")
            c.dmgHead = v("dmgHead"); c.dmgNode = v("dmgNode")
            c.dmgBody = v("dmgBody"); c.dmgP1 = v("dmgP1"); c.dmgP2 = v("dmgP2"); c.dmgP3 = v("dmgP3")
            thr = c
        }
        if let ho = o["dig"] as? [String: Any] {
            func v(_ k: String) -> Int { Int(d(ho[k]) ?? 0) }
            var c = CalibHoldout()
            c.held = v("held"); c.banked = v("banked"); c.score = v("score"); c.bankWave = v("bankWave"); c.queens = v("queens")
            c.queenKills = v("qKills"); c.maxHorde = v("maxHorde")
            if let a = ho["waveAt"] as? [Any] { c.waveAt = a.compactMap { d($0).map { Float($0) } } }
            dig = c
        }
        if let po = o["props"] as? [String: Any] {
            func v(_ k: String) -> Int { Int(d(po[k]) ?? 0) }
            var c = CalibProps()
            c.bursts = v("bursts"); c.curtainKills = v("curtainKills"); c.upKills = v("upKills"); c.freezes = v("freezes"); c.steamHurt = v("steamHurt")
            c.lampsBroken = v("lampsBroken"); c.lampSpits = v("lampSpits"); c.restores = v("restores"); c.lockers = v("lockers")
            c.lights = v("lights"); c.circuits = v("circuits")
            props = c
        }
    }
}

// ================================================================
//  RUNNER
// ================================================================
public enum Calibration {

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
        var own: LevelSource? = nil
        if let id = c.mission {
            guard let t = MissionTemplate.named(id) else {
                var bad = CalibRow()
                bad.tag = c.tag; bad.cls = c.cls.id; bad.mode = c.mode.rawValue; bad.tierIx = c.tier; bad.error = "unknown mission " + id
                return bad
            }
            cfg.mission = t
            // (R7: a mission with its own station — Kelvin-9 with its props laid — plays it on station 0)
            own = t.station
        }
        // (station 0: a mission's own station (R7); «Кельвин-9» Mk II for the classic rows of the presets (R5); with R6's props
        // only; or bare)
        let lv = level ?? (c.station == 0 ? (own.map { Level(source: $0, seed: c.seed) }
                                              ?? (c.mk2 ? Level(source: KelvinStation.mk2, seed: c.seed)
                                                  : c.props ? Level(source: KelvinStation(props: .kelvin), seed: c.seed) : nil))
                                          : Level(source: StationGenerator(), seed: c.station))
        let g = Game(seed: c.seed, playerClass: c.cls, config: cfg, level: lv)
        var row = CalibRow()
        row.tag = c.tag; row.cls = c.cls.id; row.q = c.quality.rawValue; row.mode = c.mode.rawValue
        row.tierIx = c.tier; row.seed = c.seed; row.station = c.station; row.mission = c.mission; row.th = c.th; row.tier = g.difficulty.id

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
        var tick = 0
        var trace: [String] = []
        // (Stage 2 D1: a holdout's waves — when each was held — and its biggest horde)
        var waveAt: [Float] = []
        var maxHorde = 0
        while g.phase == .playing && g.time < c.maxs {
            if c.mode == .passive { P.mods.dmg = 0; P.abCd = 99; P.mods.explosive = 0 }
            if c.mode == .afkbeacon && !afkStop && g.objectiveEngaged { afkStop = true; g.autopilot = false }
            let hp0 = P.hp
            g.tick()
            if c.trace {
                g.drainEvents { e in if let l = traceLine(e, g) { trace.append(l) } }
                // (the boss's place and mode every 2 s while it lives)
                if g.boss.alive && tick % 120 == 0 { trace.append(String(format: "t=%6.1f ", g.time) + g.bossTraceState) }
            } else { g.clearEvents() }
            if !P.downed && P.hp < hp0 { pTaken += hp0 - P.hp } else if P.downed && hp0 > 0 { pTaken += hp0 }
            // (stage names come from the plan's step: the classic beacons · toLift · hold · extract)
            let st = g.calibStage, t = r1(g.time)
            mark(st, t)
            if g.activeBeacon >= 0 { mark("b\(g.beaconsDone + 1)", t) }
            if g.beaconsDone > 0 { mark("c\(g.beaconsDone)", t) }
            for k in 0..<4 {
                let m = g.marines[k]
                if m.downed && !wasDown[k] {
                    row.downs[k] += 1
                    if row.firstDown < 0 { row.firstDown = t }
                    if k == 0 && row.pFirstDown < 0 { row.pFirstDown = t }
                    if g.holdActive { row.holdDowns += 1 }
                    addDown(g.calibDownKey)
                }
                wasDown[k] = m.downed
                if !m.downed && m.hp < minHp[k] { minHp[k] = m.hp }
            }
            if !P.downed && P.hp < P.maxHp * 0.3 { lowT += SIM_DT }
            if !P.downed && P.hp < P.maxHp * 0.5 { halfT += SIM_DT }
            if g.idleMul > row.idleMax {
                row.idleMax = g.idleMul
                row.idleSt = g.calibIdleKey
            }
            if g.holdActive && row.pressAtHold == nil { row.pressAtHold = r1(g.pressure) }
            if g.pressure > row.pressMax { row.pressMax = g.pressure }
            if row.firstBrute < 0 && g.typeAlive[2] > 0 { row.firstBrute = t }
            // the step's boss (the Матка in the classic; the rows' key stays «queen»)
            let Q = g.boss
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
            while g.holdout.held > waveAt.count { waveAt.append(t) }
            if g.holdout.horde > maxHorde { maxHorde = g.holdout.horde }
            if tick % 30 == 0 {
                let S = g.bugs
                var alive = 0, near = 0, deck = 0
                var i = 0
                let hold = g.holdActive
                // (the deck of the hold: the lift's disc on the classic plan)
                let L = g.arena()
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
        row.stage = g.calibStage; row.beacons = g.beaconsDone; row.kills = g.kills; row.level = g.xpLevel
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
        // the overhead (Stage 1 R2): its numbers only when its channel was open (the classic rows are unchanged)
        if g.overheadOn || g.overheadStats.spawns > 0 { row.oh = CalibOverhead(g.overheadStats) }
        // the props (Stage 1 R6): only on a station that had them
        if g.hasProps { row.props = CalibProps(g.propStats, lights: g.lightsLit, circuits: g.circuits.count) }
        // Stage 2 B4: the Threader, only when it came
        if g.boss.kind == .threader && g.boss.spawned { row.thr = CalibThreader(g.threaderStats) }
        // Stage 2 D1: a holdout, only when the plan has one
        if g.holdoutOn {
            var h = CalibHoldout()
            h.held = g.holdout.held; h.banked = g.holdout.banked; h.score = g.holdoutScore; h.bankWave = g.holdout.bankWave
            h.queens = g.boss.arrivals; h.queenKills = g.holdout.queensKilled; h.maxHorde = maxHorde; h.waveAt = waveAt
            row.dig = h
        }
        if c.trace { row.trace = trace }
        return row
    }

    /// One line of a fight's timeline (`CalibRun.trace`): the steps, the boss's warning / arrival / phases / moves / windows /
    /// pops / freezes / cues / death, the squad's downs and revives; nil for every other event.
    static func traceLine(_ e: GameEvent, _ g: Game) -> String? {
        let t = String(format: "t=%6.1f ", g.time)
        func p(_ v: Vec2) -> String { String(format: "(%.1f, %.1f)", v.x, v.y) }
        let hp = String(format: " hp=%.0f%%", g.bossHpFraction * 100)
        switch e {
        case .missionStep(let k, let m): return t + "step \(k) \(m.rawValue)"
        case .bossWarning(let k, let pos): return t + "\(k.rawValue) warning at " + p(pos)
        case .bossSpawned(let k, let pos): return t + "\(k.rawValue) spawned at " + p(pos) + String(format: " hpMax=%.0f", g.threatDebug.bossHpMax)
        case .bossPhase(let k, let ph, let en, _): return t + "\(k.rawValue) phase \(ph + 1)" + (en ? " enraged" : "") + hp
        case .bossMove(let k, let m, let pos):
            let id = m < g.bossSpec.moves.count ? g.bossSpec.moves[m].id : "\(m)"
            return t + "\(k.rawValue) move \(id) at " + p(pos) + hp
        case .bossWindow(let k, let part, _, let time): return t + "\(k.rawValue) window part \(part) " + String(format: "%.1f s", time)
        case .bossPartPopped(let k, let part, _): return t + "\(k.rawValue) popped part \(part)" + hp
        case .bossPartFrozen(let k, let part, _): return t + "\(k.rawValue) frozen part \(part)"
        case .bossCue(let k, let cue, let pos, let v): return t + "\(k.rawValue) \(cue) at " + p(pos) + " v=\(v)"
        case .bossKilled(let k, let pos): return t + "\(k.rawValue) killed at " + p(pos) + String(format: " after %.1f s", g.boss.killT)
        case .downed(let m): return t + "down marine \(m)"
        case .revived(let m): return t + "revived marine \(m)"
        default: return nil
        }
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

    /// `n` runs per class of one tier + mode (`mission`: a template id, which also prefixes the tag when none is given; `mk2`:
    /// on «Кельвин-9» Mk II — station 0, a tier ≥ 0).
    public static func batch(tier: Int, mode: CalibMode, n: Int, classes: [MarineClass] = MarineClass.allCases, seed0: UInt32 = 1000,
                             tag: String? = nil, th: [String: Double] = [:], maxs: Float? = nil, station: UInt32 = 0,
                             quality: QualityTier = .med, mission: String? = nil, props: Bool = false, mk2: Bool = false) -> [CalibRun] {
        var out: [CalibRun] = []
        let prefix = tag ?? mission
        let onMk2 = mk2 && station == 0 && tier >= 0
        for k in 0..<n {
            for c in classes {
                let tg = (prefix.map { $0 + "-" } ?? "") + tierTag(tier) + (quality == .med ? "" : "-q" + quality.rawValue)
                out.append(CalibRun(tag: tg, cls: c, tier: tier, mode: mode, maxs: maxs, seed: seed(seed0, mode: mode, tier: tier, cls: c, k: k),
                                    station: station, th: th, quality: quality, mission: mission, props: props, mk2: onMk2))
            }
        }
        return out
    }

    /// A mission template's own preset (its tiers × runs per class, autopilot, then one AFK run per class on each tier of its
    /// AFK bands; seeds from its base; nil = the template has none — the classic's is `gate`).
    public static func templateRuns(_ t: MissionTemplate, th: [String: Double] = [:], tag: String? = nil) -> [CalibRun]? {
        guard let c = t.calib else { return nil }
        var out: [CalibRun] = []
        // (`tag`: a tuning batch's rows carry `<tag>-<id>-<tier>`; Stage 2 D1: an endless mission's autopilot runs last up to `maxs`)
        let tg = tag.map { $0 + "-" + t.id }
        for tier in c.tiers {
            out += batch(tier: tier, mode: .auto, n: c.runs(tier), seed0: c.seedBase, tag: tg, th: tier >= 0 ? th : [:], maxs: c.maxs, mission: t.id)
        }
        for a in c.afk { out += batch(tier: a.tier, mode: .afk, n: 1, seed0: c.seedBase, tag: tg, th: th, mission: t.id) }
        return out
    }

    /// The fixed presets; a template id is a preset too (`icehive-calib --preset drill-switch`). `missions`: every gated
    /// template (R7: Breaker Run, Vent Purge) — the CI's mission gate, its own step and rows (calib-missions.jsonl), so the
    /// classic `gate` rows and calib.jsonl stay byte-identical.
    public static let presetNames = ["gate", "full", "stations", "legacy", "drills", "missions", "bosses", "holdout", "overhead", "props"]

    /// The overhead preset's share of packs sent up (Stage 1 R2; since R5 the tiers carry their own, 0.15 / 0.2 / 0.2).
    public static let overheadRoutes: Double = 0.2
    /// Stage 1 R4: the overhead preset's second half sets the Dropper and perch channels (s between sends) — since R5 the
    /// tiers' own values on Veteran.
    public static let overheadDropperGap: Double = 22, overheadPerchGap: Double = 28

    /// gate: CI (≈ 212 runs, 64 of them the informational low-quality rows); full: tuning; stations: generated seeds 0–4; legacy:
    /// the v1.0 port check; overhead: generated stations 1–4 with their routes and the overhead channel on (informational).
    public static func preset(_ name: String, seed0: UInt32 = 1000, th: [String: Double] = [:], tag: String? = nil) -> [CalibRun]? {
        switch name {
        case "gate":
            // (Stage 1 R5: the classic rows on «Кельвин-9» Mk II — the overhead and the props on; the legacy v1.0 row keeps the
            // bare v1.0 station)
            var out: [CalibRun] = batch(tier: 0, mode: .auto, n: 8, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 1, mode: .auto, n: 16, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 2, mode: .auto, n: 8, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 1, mode: .afk, n: 1, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 0, mode: .afk, n: 1, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 1, mode: .passive, n: 1, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: -1, mode: .auto, n: 2, seed0: seed0, tag: tag)
            // informational: Low graphics (cap 220 on the wave pacing, 700 on the legacy stream) must keep the tier bands (hordes no
            // longer shrink with the cap)
            out += batch(tier: 1, mode: .auto, n: 8, seed0: seed0, tag: tag, th: th, quality: .low, mk2: true)
            out += batch(tier: 2, mode: .auto, n: 8, seed0: seed0, tag: tag, th: th, quality: .low, mk2: true)
            return out
        case "missions", "bosses", "holdout":
            // R7: the gated mission templates (their own bands; the CI step «Calibration gate: missions»); Stage 2 B4: the boss
            // missions' (the Manifold: «Calibration gate: bosses»); Stage 2 D1: the endless missions' (Dig In: «Calibration gate:
            // holdout») — each template in its own preset
            var out: [CalibRun] = []
            for t in MissionTemplate.all where t.calib?.gated == true && t.calib?.preset == name { out += templateRuns(t, th: th, tag: tag) ?? [] }
            return out
        case "drills":
            var out: [CalibRun] = []
            for t in MissionTemplate.drills { out += templateRuns(t, th: th) ?? [] }
            return out
        case "full":
            var out: [CalibRun] = batch(tier: 0, mode: .auto, n: 40, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 1, mode: .auto, n: 40, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 2, mode: .auto, n: 40, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 1, mode: .afk, n: 2, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 0, mode: .afk, n: 2, seed0: seed0, tag: tag, th: th, mk2: true)
            out += batch(tier: 1, mode: .passive, n: 2, seed0: seed0, tag: tag, th: th, mk2: true)
            return out
        case "stations":
            var out: [CalibRun] = []
            for s in 0..<5 {
                out += batch(tier: 1, mode: .auto, n: 4, seed0: seed0, tag: (tag.map { $0 + "-" } ?? "") + "st\(s)", th: th, station: UInt32(s))
            }
            return out
        case "legacy":
            return batch(tier: -1, mode: .auto, n: 8, seed0: seed0, tag: tag)
        case "overhead":
            // Stage 1 R2 (informational): the routes the post-pass gives generated stations 1–4, Ветеран, the director sending
            // `routes` of its packs up (--th can change it, or the caps); since R5 the tiers carry the overhead and its bugs, so
            // this first half turns the Dropper and perch channels off (R2's runners alone; compare with the second half)
            var t = th
            if t["routes"] == nil { t["routes"] = overheadRoutes }
            if t["dropperGap"] == nil { t["dropperGap"] = 0 }
            if t["perchGap"] == nil { t["perchGap"] = 0 }
            var out: [CalibRun] = []
            for s in 1...4 {
                out += batch(tier: 1, mode: .auto, n: 2, seed0: seed0, tag: (tag.map { $0 + "-" } ?? "") + "oh-st\(s)", th: t, station: UInt32(s))
            }
            // Stage 1 R4: the same stations with the overhead's bugs — the Dropper channel (its pins), perched spitters, the
            // duct mouths' rattles and seals (Veteran's own channels since R5)
            var tb = th
            if tb["routes"] == nil { tb["routes"] = overheadRoutes }
            if tb["dropperGap"] == nil { tb["dropperGap"] = overheadDropperGap }
            if tb["perchGap"] == nil { tb["perchGap"] = overheadPerchGap }
            for s in 1...4 {
                out += batch(tier: 1, mode: .auto, n: 2, seed0: seed0, tag: (tag.map { $0 + "-" } ?? "") + "ohb-st\(s)", th: tb, station: UInt32(s))
            }
            return out
        case "props":
            // Stage 1 R6 (informational): «Operation Cold Light» on «Кельвин-9» with its interactives laid (valves, seven light
            // circuits, a supply locker): the bots pop valves and re-light, the hive breaks lamps. Since R5 the gate's classic
            // rows run on Mk II (these props and the overhead): the same seeds here are the classic mission without the overhead
            var out: [CalibRun] = batch(tier: 0, mode: .auto, n: 4, seed0: seed0, tag: (tag.map { $0 + "-" } ?? "") + "props", th: th, props: true)
            out += batch(tier: 1, mode: .auto, n: 8, seed0: seed0, tag: (tag.map { $0 + "-" } ?? "") + "props", th: th, props: true)
            return out
        default:
            return MissionTemplate.named(name).flatMap { templateRuns($0, th: th, tag: tag) }
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
        let ohRows = rows.filter { $0.error == nil && $0.oh != nil }
        if !ohRows.isEmpty { out.append(""); out.append(overheadTable(ohRows)) }
        let prRows = rows.filter { $0.error == nil && $0.props != nil }
        if !prRows.isEmpty { out.append(""); out.append(propsTable(prRows)) }
        let thRows = rows.filter { $0.error == nil && $0.thr != nil }
        if !thRows.isEmpty { out.append(""); out.append(threaderTable(thRows)) }
        let hoRows = rows.filter { $0.error == nil && $0.dig != nil }
        if !hoRows.isEmpty { out.append(""); out.append(holdoutTable(hoRows)) }
        return out.joined(separator: "\n")
    }

    /// A holdout per group (Stage 2 D1 «Dig In»): the waves held — median, quartiles, min–max —, the runs that banked at waves 5
    /// / 10 / 15 / 20, the medians of the score banked, earned and taken by the fall (raw), the Queens met and killed per run,
    /// the medians of when waves 1 / 5 / 10 were held and of the run's length (s), the runs still standing at the time cap, the
    /// biggest wave horde met; then, per group, the waves the runs fell in.
    static func holdoutTable(_ rows: [CalibRow]) -> String {
        var g: [String: [CalibRow]] = [:]
        for r in rows { g[r.tag + " " + r.mode, default: []].append(r) }
        var out = ["holdout".padding(toLength: 18, withPad: " ", startingAt: 0) + " "
                   + ["n", "held", "p25", "p75", "min", "max", "b5%", "b10%", "b15%", "b20%", "bank", "score", "lost", "qMet", "qKill",
                      "t1", "t5", "t10", "tEnd", "stand", "horde"].map { pad($0, 5) }.joined(separator: " ")]
        for k in g.keys.sorted() {
            let rs = g[k]!
            let n = rs.count
            let held = rs.map { Float($0.dig!.held) }.sorted()
            func q(_ p: Float) -> Float { held.isEmpty ? .nan : held[min(held.count - 1, Int((Float(held.count - 1) * p).rounded()))] }
            func share(_ w: Int) -> String { fmt(pct(rs.filter { $0.dig!.held >= w }.count, n)) }
            func med(_ f: (CalibHoldout) -> Int) -> String { fmt(median(rs.map { Float(f($0.dig!)) })) }
            func per(_ f: (CalibHoldout) -> Int) -> String { fmt(Float(rs.reduce(0) { $0 + f($1.dig!) }) / Float(max(1, n)), 1) }
            func at(_ w: Int) -> String { fmt(median(rs.compactMap { r -> Float? in r.dig!.waveAt.count >= w ? r.dig!.waveAt[w - 1] : nil })) }
            let cols = [pad("\(n)", 5), pad(fmt(median(held), 1), 5), pad(fmt(q(0.25)), 5), pad(fmt(q(0.75)), 5), pad(fmt(held.first ?? .nan), 5),
                        pad(fmt(held.last ?? .nan), 5), pad(share(5), 5), pad(share(10), 5), pad(share(15), 5), pad(share(20), 5),
                        pad(med { $0.banked }, 5), pad(med { $0.score }, 5), pad(med { max(0, $0.score - $0.banked) }, 5),
                        pad(per { $0.queens }, 5), pad(per { $0.queenKills }, 5), pad(at(1), 5), pad(at(5), 5), pad(at(10), 5),
                        pad(fmt(median(rs.map { $0.t })), 5), pad("\(rs.filter { $0.result == "playing" }.count)", 5),
                        pad("\(rs.map { $0.dig!.maxHorde }.max() ?? 0)", 5)]
            out.append(k.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + cols.joined(separator: " "))
        }
        out.append("(held: median waves held, p25 / p75 / min / max of the runs; b5% …: runs that banked at wave 5, 10, 15, 20; bank / score / "
                   + "lost: medians of the raw score banked, earned, and taken by the fall; qMet / qKill: Queens met / killed per run; t1 / t5 / "
                   + "t10: median s when wave 1 / 5 / 10 was held; tEnd: median run length; stand: runs still standing at the time cap; horde: "
                   + "the biggest wave horde met, bugs)")
        out.append("")
        out.append("holdout falls".padding(toLength: 18, withPad: " ", startingAt: 0) + " runs by the wave they fell in (wave:runs; a run standing at the cap counts its next wave)")
        for k in g.keys.sorted() {
            var hist: [Int: Int] = [:]
            for r in g[k]! { hist[r.dig!.held + 1, default: 0] += 1 }
            out.append(k.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + hist.keys.sorted().map { "\($0):\(hist[$0]!)" }.joined(separator: " "))
        }
        return out.joined(separator: "\n")
    }

    /// The Threader per group (Stage 2 B4): the medians of when its phases came and its kill (s after its spawn: P1 = up to
    /// P2), the median win time; per fight: locks, strikes (and hits), coils (marines crushed, let go early), rime spits,
    /// squeezes, pulls, charges, ticks shed, duct packs, nodes popped / stripped, frozen locks; the boss bar's damage by part
    /// (%); seconds up out of reach, untouchable, the head down.
    static func threaderTable(_ rows: [CalibRow]) -> String {
        var g: [String: [CalibRow]] = [:]
        for r in rows { g[r.tag + " " + r.mode, default: []].append(r) }
        var out = ["threader".padding(toLength: 18, withPad: " ", startingAt: 0) + " "
                   + ["n", "P1", "P2", "P3", "kill", "win", "locks", "strk", "hit", "coil", "crush", "letGo", "rime", "squez", "pull", "chrg",
                      "ticks", "packs", "pop", "strip", "frzL", "brtl", "pain", "head%", "node%", "body%", "upS", "untS", "downS"]
                   .map { pad($0, 5) }.joined(separator: " ")]
        for k in g.keys.sorted() {
            let rs = g[k]!
            let n = Float(rs.count)
            func m(_ f: (CalibThreader) -> Int) -> String { fmt(Float(rs.reduce(0) { $0 + f($1.thr!) }) / n, 1) }
            func mf(_ f: (CalibThreader) -> Float) -> String { fmt(rs.reduce(Float(0)) { $0 + f($1.thr!) } / n, 0) }
            let p2 = rs.compactMap { $0.thr!.p2T >= 0 ? $0.thr!.p2T : nil }
            let p3 = rs.compactMap { r -> Float? in let t = r.thr!; return t.p3T >= 0 && t.p2T >= 0 ? t.p3T - t.p2T : nil }
            let kills = rs.compactMap { r -> Float? in guard let q = r.queen, let kt = q.killT, r.thr!.p3T >= 0 else { return nil }; return kt - r.thr!.p3T }
            let killT = rs.compactMap { $0.queen?.killT }
            let wins = rs.filter { $0.won }.map { $0.t }
            let dmg = rs.reduce(Float(0)) { $0 + Float($1.thr!.dmgHead + $1.thr!.dmgNode + $1.thr!.dmgBody) }
            func share(_ f: (CalibThreader) -> Int) -> String { fmt(dmg > 0 ? 100 * Float(rs.reduce(0) { $0 + f($1.thr!) }) / dmg : 0) }
            let cols = [pad("\(rs.count)", 5), pad(fmt(median(p2)), 5), pad(fmt(median(p3)), 5), pad(fmt(median(kills)), 5), pad(fmt(median(killT)), 5),
                        pad(fmt(median(wins)), 5), pad(m { $0.locks }, 5), pad(m { $0.strikes }, 5), pad(m { $0.strikeHits }, 5), pad(m { $0.coils }, 5),
                        pad(m { $0.crushed }, 5), pad(m { $0.letGo }, 5), pad(m { $0.rimes }, 5), pad(m { $0.squeezes }, 5), pad(m { $0.pulls }, 5),
                        pad(m { $0.charges }, 5), pad(m { $0.ticks }, 5), pad(m { $0.packs }, 5), pad(m { $0.popped }, 5), pad(m { $0.stripped }, 5),
                        pad(m { $0.freezeLocks }, 5), pad(m { $0.brittles }, 5), pad(m { $0.pains }, 5), pad(share { $0.dmgHead }, 5),
                        pad(share { $0.dmgNode }, 5), pad(share { $0.dmgBody }, 5),
                        pad(mf { $0.upT }, 5), pad(mf { $0.untouchT }, 5), pad(mf { $0.downT }, 5)]
            out.append(k.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + cols.joined(separator: " "))
        }
        out.append("(P1 / P2 / P3: median seconds in each phase of the fights that got there — P1 from the spawn, P3 to the kill; kill: the "
                   + "median kill time from the spawn; win: the median mission time of the wins)")
        return out.joined(separator: "\n")
    }

    /// The interactive props per group (Stage 1 R6): per run — valves burst, bugs the curtains killed on the deck and up on
    /// the spans, squad HP lost to the steam, lamps the hive broke, its spits at lamps, circuits brought back, lockers
    /// opened; the light circuits lit at the end (mean, of the station's).
    static func propsTable(_ rows: [CalibRow]) -> String {
        var g: [String: [CalibRow]] = [:]
        for r in rows { g[r.tag + " " + r.mode, default: []].append(r) }
        var out = ["props per run".padding(toLength: 18, withPad: " ", startingAt: 0) + " "
                   + ["n", "bursts", "kills", "upKill", "freeze", "steam", "broken", "spits", "restor", "locker", "lights"].map { pad($0, 6) }.joined(separator: " ")]
        for k in g.keys.sorted() {
            let rs = g[k]!
            let n = Float(rs.count)
            func m(_ f: (CalibProps) -> Int) -> String { fmt(Float(rs.reduce(0) { $0 + f($1.props!) }) / n, 1) }
            let lights = m { $0.lights } + "/\(rs.first?.props?.circuits ?? 0)"
            let cols = [pad("\(rs.count)", 6), pad(m { $0.bursts }, 6), pad(m { $0.curtainKills }, 6), pad(m { $0.upKills }, 6),
                        pad(m { $0.freezes }, 6), pad(m { $0.steamHurt }, 6), pad(m { $0.lampsBroken }, 6), pad(m { $0.lampSpits }, 6), pad(m { $0.restores }, 6),
                        pad(m { $0.lockers }, 6), pad(lights, 6)]
            out.append(k.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + cols.joined(separator: " "))
        }
        out.append("(kills: deck bugs the scald curtains killed; freeze: bugs a coolant mist froze; steam: squad HP lost in the curtains; "
                   + "lights: circuits lit at the end)")
        return out.joined(separator: "\n")
    }

    /// The overhead's numbers per group (Stage 1 R2): per run — packs up, bugs spawned up there, drops, landings, hits on a
    /// marine, marine downs by a drop, HP lost to drops, kills up there, knock-downs, shattered falls, hops down; the most up
    /// at once and drop telegraphs at once (max over the runs); the share of the squad's downs a drop caused (informational
    /// band on Ветеран: ≤ 20 %, tech.md §2.3).
    static func overheadTable(_ rows: [CalibRow]) -> String {
        var g: [String: [CalibRow]] = [:]
        for r in rows { g[r.tag + " " + r.mode, default: []].append(r) }
        var out = ["overhead per run".padding(toLength: 18, withPad: " ", startingAt: 0) + " "
                   + ["n", "packs", "up", "drops", "land", "hits", "dnDrop", "hurt", "kills", "knock", "shat", "hops", "maxUp", "maxZn", "drop%dn"]
                   .map { pad($0, 6) }.joined(separator: " ")]
        for k in g.keys.sorted() {
            let rs = g[k]!
            let n = Float(rs.count)
            func m(_ f: (CalibOverhead) -> Int) -> String { fmt(Float(rs.reduce(0) { $0 + f($1.oh!) }) / n, 1) }
            let downs = rs.reduce(0) { $0 + $1.squadDowns }, dd = rs.reduce(0) { $0 + $1.oh!.downs }
            let cols = [pad("\(rs.count)", 6), pad(m { $0.packs }, 6), pad(m { $0.spawns }, 6), pad(m { $0.drops }, 6), pad(m { $0.landed }, 6),
                        pad(m { $0.hits }, 6), pad(m { $0.downs }, 6), pad(m { $0.hurt }, 6), pad(m { $0.kills }, 6), pad(m { $0.knockdowns }, 6),
                        pad(m { $0.shattered }, 6), pad(m { $0.hops }, 6), pad("\(rs.map { $0.oh!.maxUp }.max() ?? 0)", 6),
                        pad("\(rs.map { $0.oh!.maxZones }.max() ?? 0)", 6), pad(fmt(pct(dd, downs)), 6)]
            out.append(k.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + cols.joined(separator: " "))
        }
        out.append("(drop%dn: squad downs a drop's bite caused, of all squad downs — informational band on Veteran ≤ 20 %)")
        // Stage 1 R4: the overhead's bugs, per run (only groups that met any)
        let bugRows = g.keys.sorted().filter { k in g[k]!.contains { r in r.oh!.droppers + r.oh!.perched + r.oh!.rattles > 0 } }
        if !bugRows.isEmpty {
            out.append("")
            out.append("overhead bugs/run".padding(toLength: 18, withPad: " ", startingAt: 0) + " "
                       + ["n", "drpUp", "drDrop", "drLand", "drKill", "drKnck", "drHop", "pins", "dash", "fire", "tmout", "pinDn", "pinS", "drHurt",
                          "drDn", "perch", "spits", "rattle", "seal", "lost", "drp%dn"]
                       .map { pad($0, 6) }.joined(separator: " "))
            for k in bugRows {
                let rs = g[k]!
                let n = Float(rs.count)
                func m(_ f: (CalibOverhead) -> Int) -> String { fmt(Float(rs.reduce(0) { $0 + f($1.oh!) }) / n, 1) }
                let downs = rs.reduce(0) { $0 + $1.squadDowns }, dd = rs.reduce(0) { $0 + $1.oh!.dropperDowns }
                let pinS = Float(rs.reduce(0) { $0 + $1.oh!.pinMs }) / 1000 / max(1, Float(rs.reduce(0) { $0 + $1.oh!.pins }))
                let cols = [pad("\(rs.count)", 6), pad(m { $0.droppers }, 6), pad(m { $0.dropperDrops }, 6), pad(m { $0.dropperLanded }, 6),
                            pad(m { $0.dropperKills }, 6), pad(m { $0.dropperKnocks }, 6), pad(m { $0.dropperHops }, 6),
                            pad(m { $0.pins }, 6), pad(m { $0.pinDash }, 6), pad(m { $0.pinFire }, 6),
                            pad(m { $0.pinTimeout }, 6), pad(m { $0.pinDown }, 6), pad(fmt(pinS, 2), 6), pad(m { $0.dropperHurt }, 6),
                            pad(m { $0.dropperDowns }, 6), pad(m { $0.perched }, 6), pad(m { $0.perchSpits }, 6), pad(m { $0.rattles }, 6),
                            pad(m { $0.seals }, 6), pad(m { $0.ductLost }, 6), pad(fmt(pct(dd, downs)), 6)]
                out.append(k.padding(toLength: 18, withPad: " ", startingAt: 0) + " " + cols.joined(separator: " "))
            }
            out.append("(pinS: mean seconds a pin held; drp%dn: squad downs a Dropper caused, of all squad downs; lost: bugs bound for a "
                       + "duct mouth shot shut)")
        }
        return out.joined(separator: "\n")
    }

    /// One gate verdict.
    public struct GateLine {
        public let ok: Bool
        public let gated: Bool
        public let text: String
    }

    /// Spec §5.2 bands on rows grouped by tier + mode (any tag, station 0, no overrides, med quality, the classic
    /// mission), then each mission template's own bands on its rows (when the rows have any). Gated lines first, then the
    /// reported ones. `passed` only when every gated band holds and every gated classic group exists (a run of templates
    /// only skips the classic bands).
    public static func gate(_ rows: [CalibRow], templates: [MissionTemplate] = MissionTemplate.all) -> (passed: Bool, lines: [GateLine]) {
        let all = rows.filter { $0.error == nil && $0.station == 0 && $0.th.isEmpty && $0.mission == nil }
        let base = all.filter { $0.q == "med" }
        func grp(_ tier: Int, _ mode: String, q: String = "med") -> Group? {
            let rs = all.filter { $0.tierIx == tier && $0.mode == mode && $0.q == q }
            return rs.isEmpty ? nil : group("\(tierTag(tier)) \(mode)", rs)
        }
        var L: [GateLine] = []
        func band(_ name: String, _ v: Float, _ lo: Float?, _ hi: Float?, gated: Bool = true, unit: String = "") {
            let ok = !v.isNaN && (lo.map { v >= $0 } ?? true) && (hi.map { v <= $0 } ?? true)
            let b = (lo.map { bnum($0) } ?? "") + "…" + (hi.map { bnum($0) } ?? "")
            L.append(GateLine(ok: ok, gated: gated, text: "\(name) \(fmt(v, 1))\(unit) band \(b)\(unit)"))
        }
        func missing(_ name: String) { L.append(GateLine(ok: false, gated: true, text: "\(name) missing (no rows)")) }
        // (a run of mission templates only — `--preset drills` — has no classic rows to gate; no rows at all still fail)
        let onlyTemplates = !rows.isEmpty && rows.allSatisfy { $0.mission != nil }
        if !onlyTemplates {
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
            if let g = grp(1, "auto", q: "low") { band("vet/auto wins on low graphics", g.winPct, 70, 85, gated: false, unit: "%") }
            if let g = grp(2, "auto", q: "low") { band("nm/auto wins on low graphics", g.winPct, nil, 30, gated: false, unit: "%") }
            if let g = grp(-1, "auto") {
                band("v10/auto wins (legacy port check)", g.winPct, nil, nil, gated: false, unit: "%")
                band("v10/auto downs/run", g.downsPerRun, nil, nil, gated: false)
            }
        }
        // mission templates: their own rows and bands (autopilot, med quality, station 0, no overrides), and their AFK bands
        for t in templates {
            guard let c = t.calib else { continue }
            let mine = rows.filter { $0.error == nil && $0.mission == t.id && $0.station == 0 && $0.th.isEmpty && $0.q == "med" }
            if mine.isEmpty { continue }
            let trs = mine.filter { $0.mode == "auto" }
            for b in c.bands {
                let rs = trs.filter { $0.tierIx == b.tier }
                if rs.isEmpty { continue }
                let g = group(t.id, rs)
                // (a boss band — Stage 2 D1: a waves band — without a win band reports no wins line: its own lines below are its gate)
                if b.winLo != nil || b.winHi != nil || !b.ownBands {
                    band("\(t.id) \(tierTag(b.tier))/auto wins", g.winPct, b.winLo, b.winHi, gated: c.gated, unit: "%")
                }
                if let d = b.downsHi { band("\(t.id) \(tierTag(b.tier))/auto downs/run", g.downsPerRun, nil, d, gated: c.gated) }
                // (Stage 2 B1: a boss mission's boss bands — reached, killed of those reached, the kill median)
                if let r = b.bossReachedLo { band("\(t.id) \(tierTag(b.tier))/auto boss reached", g.queenReachedPct, r, nil, gated: c.gated, unit: "%") }
                if let k = b.bossKilledLo { band("\(t.id) \(tierTag(b.tier))/auto boss killed of reached", g.queenKilledPct, k, nil, gated: c.gated, unit: "%") }
                if b.bossMedianLo != nil || b.bossMedianHi != nil {
                    band("\(t.id) \(tierTag(b.tier))/auto boss kill median", g.queenKillMedian, b.bossMedianLo, b.bossMedianHi, gated: c.gated, unit: " s")
                }
                // (Stage 2 D1: an endless mission's band — the median waves held)
                if b.wavesLo != nil || b.wavesHi != nil {
                    band("\(t.id) \(tierTag(b.tier))/auto waves held median", median(rs.map { Float($0.dig?.held ?? 0) }), b.wavesLo, b.wavesHi, gated: c.gated)
                }
            }
            // (Stage 2 B4: bands reported beside the gate)
            for b in c.info {
                let rs = trs.filter { $0.tierIx == b.tier }
                if rs.isEmpty { continue }
                let g = group(t.id, rs)
                if b.winLo != nil || b.winHi != nil { band("\(t.id) \(tierTag(b.tier))/auto wins", g.winPct, b.winLo, b.winHi, gated: false, unit: "%") }
                if let d = b.downsHi { band("\(t.id) \(tierTag(b.tier))/auto downs/run", g.downsPerRun, nil, d, gated: false) }
            }
            for a in c.afk {
                let rs = mine.filter { $0.tierIx == a.tier && $0.mode == "afk" }
                if rs.isEmpty { continue }
                let firsts = rs.map { $0.pFirstDown < 0 ? Float.infinity : $0.pFirstDown }
                let worst = firsts.max() ?? .infinity, best = firsts.min() ?? .infinity
                L.append(GateLine(ok: worst <= a.firstDownMax, gated: c.gated && c.afkGated,
                                  text: "\(t.id) \(tierTag(a.tier))/afk first player down \(fmt(best))–\(worst.isFinite ? fmt(worst) : "never") s (every run) band …\(fmt(a.firstDownMax)) s"))
                // (Stage 2 D1: an endless mission's AFK squad — the waves it held, reported)
                if rs.contains(where: { $0.dig != nil }) {
                    band("\(t.id) \(tierTag(a.tier))/afk waves held median", median(rs.map { Float($0.dig?.held ?? 0) }), nil, nil, gated: false)
                }
            }
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
