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
//  v1.x (the Capacitor app, same bundle id) kept them in Capacitor
//  Preferences = UserDefaults.standard "CapacitorStorage.ledulei.<k>":
//  on the first launch of 2.0 they are copied over, so an update keeps
//  the player's record and settings.
// ================================================================
public final class SettingsStore {

    private let d: UserDefaults
    private static let prefix = "ledulei."
    private static let legacyPrefix = "CapacitorStorage.ledulei."
    private static let keys = ["cls", "best", "muted", "vol", "haptics", "quality"]

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

    public init(defaults: UserDefaults = .standard) {
        d = defaults
        migrate()
        load()
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

    /// v1 → v2: copy every Capacitor Preferences value we do not have yet (keys never written by 2.0).
    private func migrate() {
        for k in SettingsStore.keys where d.object(forKey: SettingsStore.prefix + k) == nil {
            if let v = d.string(forKey: SettingsStore.legacyPrefix + k), SettingsStore.parse(v) != nil {
                d.set(v, forKey: SettingsStore.prefix + k)
                migrated.append(k)
            }
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
