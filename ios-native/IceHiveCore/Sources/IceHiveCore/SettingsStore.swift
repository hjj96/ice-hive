import Foundation

// ================================================================
//  SETTINGS / RECORDS — UserDefaults under the web game's keys
//  ("ledulei.<k>", values as JSON text like the web localStorage):
//    cls      "\"pyro\""                     last class
//    best     {"kills":N,"win":S}            record kills, best evacuation time (s, 0 = none)
//    muted    true / false
//    vol      0.2 … 1 (default 0.8)
//    haptics  true / false (iOS app only, default on)
//    quality  "\"auto\"" | "\"low\"" | "\"med\"" | "\"high\""
//  v1.1 «Ставки» meta keys (web 11c-meta.js / 11b-coach.js / 04b-stations.js):
//    profile  {"v":1,"runs":…,"wins":…,"earned":…,"recTip":…,"cls":{…}}   fighter profile (absent → built from `best`)
//    diff     0 / 1 / 2                         the player's tier pick (absent = no pick)
//    tut      1                                 the first-run coach was seen
//    sticks   0…6                               whole seconds of thumb-stick use (ghost sticks fade at 6)
//    seed     1…0x3fffffff                      station for the next mission (only with the stations flag)
//  v1.x (the Capacitor app, same bundle id) kept them in Capacitor
//  Preferences = UserDefaults.standard "CapacitorStorage.ledulei.<k>":
//  on the first launch of 2.0 every such key is copied over (also keys
//  this version does not read yet, e.g. a later 1.x profile), so an
//  update keeps the player's record and settings.
// ================================================================
public final class SettingsStore {

    private let d: UserDefaults
    private static let prefix = "ledulei."
    private static let legacyPrefix = "CapacitorStorage.ledulei."

    public private(set) var cls: String = "assault"
    public private(set) var bestKills: Int = 0
    /// Best evacuation time in whole seconds, 0 = never evacuated.
    public private(set) var bestWin: Int = 0
    public private(set) var muted: Bool = false
    public private(set) var vol: Float = 0.8
    public private(set) var haptics: Bool = true
    /// "auto" | "low" | "med" | "high".
    public private(set) var quality: String = "auto"

    /// Keys copied from the v1 (Capacitor) store at init.
    public private(set) var migrated: [String] = []

    // ---------- v1.1 meta ----------
    /// The `best` key is present and an object (a v1.0 player).
    public private(set) var hasBest: Bool = false
    public private(set) var profile: Profile = Profile()
    /// The player's tier pick on the title (nil until the first tap).
    public private(set) var diffPick: Int? = nil
    public private(set) var tutSeen: Bool = false
    public private(set) var stickSeconds: Int = 0
    /// Station for the next mission (read, but unused while the stations flag is off).
    public private(set) var stationSeed: UInt32 = 0
    /// Demo runs: the meta keys live in memory only and are never written.
    public let volatileMeta: Bool

    /// Tier of the next mission (web effectiveTier).
    public var effectiveTier: Int { IceHiveCore.effectiveTier(diffPick: diffPick, profile: profile) }
    /// The first mission ever: the coach runs, Новобранец, station seed 0.
    public var isFirstMission: Bool { !tutSeen && !hasBest && profile.runs == 0 }

    /// `volatileMeta`: demo fixture — the meta keys (profile, diff, tut, sticks, seed) come from it and stay in memory.
    public init(defaults: UserDefaults = .standard, volatileMeta: MetaFixture? = nil) {
        d = defaults
        self.volatileMeta = volatileMeta != nil
        migrate()
        load()
        if let f = volatileMeta {
            hasBest = f.hasBest; profile = f.profile; diffPick = f.diffPick; tutSeen = f.tutSeen
            stickSeconds = f.stickSeconds; stationSeed = f.stationSeed
        } else {
            loadMeta()
        }
    }

    private func raw(_ k: String) -> String? { d.string(forKey: SettingsStore.prefix + k) }

    private static func parse(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    /// v1 → v2: copy every Capacitor Preferences value under "CapacitorStorage.ledulei." that has no 2.0 key yet
    /// (keys never written by 2.0) and holds valid JSON text — whatever the key, so values a 1.x release added later
    /// (a profile, tier records, …) survive the update too.
    private func migrate() {
        let pre = SettingsStore.legacyPrefix
        let legacy = d.dictionaryRepresentation().keys.filter { $0.hasPrefix(pre) && $0.count > pre.count }.sorted()
        for lk in legacy {
            let k = String(lk.dropFirst(pre.count))
            guard d.object(forKey: SettingsStore.prefix + k) == nil,
                  let v = d.string(forKey: lk), SettingsStore.parse(v) != nil else { continue }
            d.set(v, forKey: SettingsStore.prefix + k)
            migrated.append(k)
        }
    }

    private func load() {
        if let s = raw("cls"), let v = SettingsStore.parse(s) as? String { cls = v }
        if let s = raw("best"), let v = SettingsStore.parse(s) as? [String: Any] {
            bestKills = max(0, (v["kills"] as? NSNumber)?.intValue ?? 0)
            bestWin = max(0, (v["win"] as? NSNumber)?.intValue ?? 0)
        }
        if let s = raw("muted"), let v = SettingsStore.bool(SettingsStore.parse(s)) { muted = v }
        if let s = raw("vol"), let v = SettingsStore.parse(s) as? NSNumber {
            let f = v.floatValue
            vol = f.isFinite && f > 0 ? max(0.1, min(1, f)) : 0.8
        }
        if let s = raw("haptics"), let v = SettingsStore.bool(SettingsStore.parse(s)) { haptics = v }
        if let s = raw("quality"), let v = SettingsStore.parse(s) as? String, ["auto", "low", "med", "high"].contains(v) { quality = v }
    }

    private func put(_ k: String, _ json: String) { d.set(json, forKey: SettingsStore.prefix + k) }

    /// Load order of the spec (§3): `hasBest`, the profile (or its migration from `best`), the tier pick, the coach flag,
    /// the stick seconds, the station seed. Corrupt values fall back to their defaults and stay on disk until rewritten.
    private func loadMeta() {
        hasBest = raw("best").flatMap { SettingsStore.parse($0) } is [String: Any]
        profile = Profile.load(raw: raw("profile"), legacyBest: hasBest ? (bestKills, bestWin) : nil)
        diffPick = nil
        if let s = raw("diff"), let n = SettingsStore.parse(s) as? NSNumber, !Profile.isBool(n) {
            let v = n.doubleValue
            if v == 0 || v == 1 || v == 2 { diffPick = Int(v) }
        }
        tutSeen = SettingsStore.truthy(raw("tut").flatMap { SettingsStore.parse($0) })
        stickSeconds = 0
        if let s = raw("sticks"), let n = SettingsStore.parse(s) as? NSNumber, !Profile.isBool(n), n.doubleValue.isFinite {
            stickSeconds = max(0, min(1_000_000, Int(n.doubleValue.rounded(.towardZero))))
        }
        stationSeed = 0
        if let s = raw("seed"), let n = SettingsStore.parse(s) as? NSNumber, !Profile.isBool(n) { stationSeed = Stations.sanitize(n.doubleValue) }
    }

    /// JS truthiness of a parsed JSON value (absent / unparsable → false).
    static func truthy(_ v: Any?) -> Bool {
        guard let v = v else { return false }
        if v is NSNull { return false }
        if let n = v as? NSNumber { return Profile.isBool(n) ? n.boolValue : (n.doubleValue != 0 && !n.doubleValue.isNaN) }
        if let s = v as? String { return !s.isEmpty }
        return true   // objects and arrays
    }

    /// Write the profile (once per mission end).
    public func saveProfile(_ p: Profile) {
        profile = p
        if !volatileMeta { put("profile", p.encoded()) }
    }
    /// The title tier selector / the report chip (0).
    public func setDiff(_ i: Int) {
        let v = max(0, min(2, i))
        diffPick = v
        if !volatileMeta { put("diff", "\(v)") }
    }
    /// `.coachSeen`.
    public func setTutSeen() {
        if tutSeen { return }
        tutSeen = true
        if !volatileMeta { put("tut", "1") }
    }
    /// Whole seconds of stick use (the HUD calls this ≤ 6 times ever).
    public func setStickSeconds(_ s: Int) {
        let v = max(0, min(6, s))
        if v == stickSeconds { return }
        stickSeconds = v
        if !volatileMeta { put("sticks", "\(v)") }
    }
    /// Station of the next mission (only with the stations flag).
    public func setStationSeed(_ s: UInt32) {
        let v = Stations.sanitize(Double(s))
        stationSeed = v
        if !volatileMeta { put("seed", "\(v)") }
    }

    public func setClass(_ id: String) { cls = id; put("cls", "\"" + id + "\"") }
    public func setMuted(_ m: Bool) { muted = m; put("muted", m ? "true" : "false") }
    public func setHaptics(_ on: Bool) { haptics = on; put("haptics", on ? "true" : "false") }
    public func setQuality(_ q: String) { quality = q; put("quality", "\"" + q + "\"") }

    /// Web cycleVolume(): 100 → 80 → 60 → 40 → 20 %, remembered.
    @discardableResult
    public func cycleVolume() -> Float {
        let steps: [Float] = [1, 0.8, 0.6, 0.4, 0.2]
        let k = steps.firstIndex { abs($0 - vol) < 0.05 } ?? -1
        vol = steps[(k + 1) % steps.count]
        put("vol", String(format: "%.1f", vol))
        return vol
    }

    /// Web endGame(): kills record, fastest evacuation. Returns true when the kill count is a new record.
    @discardableResult
    public func recordMission(kills: Int, won: Bool, time: Float) -> Bool {
        var newRecord = false
        if kills > bestKills { bestKills = kills; newRecord = true }
        let t = Int(time.rounded())
        if won && t > 0 && (bestWin == 0 || t < bestWin) { bestWin = t }
        put("best", "{\"kills\":\(bestKills),\"win\":\(bestWin)}")
        return newRecord
    }

    /// Effective master volume (0 when muted).
    public var masterVolume: Float { muted ? 0 : vol }
}

/// Demo meta store (`SettingsStore(volatileMeta:)`): what the fixture profile looks like; nothing is written.
public struct MetaFixture {
    public var profile: Profile
    public var diffPick: Int?
    public var tutSeen: Bool
    public var hasBest: Bool
    public var stickSeconds: Int
    public var stationSeed: UInt32

    public init(profile: Profile = Profile(), diffPick: Int? = nil, tutSeen: Bool = false, hasBest: Bool = false, stickSeconds: Int = 0, stationSeed: UInt32 = 0) {
        self.profile = profile; self.diffPick = diffPick; self.tutSeen = tutSeen; self.hasBest = hasBest
        self.stickSeconds = stickSeconds; self.stationSeed = stationSeed
    }

    /// A first launch: nothing stored.
    public static let fresh = MetaFixture()
    /// A returning player (spec §3): 6 runs, 3 evacuations, assault Сержант with Н·В medals, pyro Ефрейтор.
    public static let returning: MetaFixture = {
        var p = Profile()
        p.runs = 6; p.wins = 3; p.earned = 23_000
        var a = ClassRecord(); a.xp = 2300; a.runs = 4; a.wins = 2; a.best = 9120; a.bestWin = 402; a.ev = [1, 1, 0]
        var y = ClassRecord(); y.xp = 400; y.runs = 2; y.wins = 1; y.best = 3300; y.ev = [1, 0, 0]
        p.cls[.assault] = a; p.cls[.pyro] = y
        return MetaFixture(profile: p, tutSeen: true, hasBest: true, stickSeconds: 6)
    }()
}
