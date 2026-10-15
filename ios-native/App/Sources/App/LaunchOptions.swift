import Foundation

/// Launch arguments, e.g. `-demo combat -seconds 40 -debugHUD`.
/// Used by the CI simulator smoke test (`xcrun simctl launch … -demo combat`).
struct LaunchOptions {
    /// Demo / scripted scenario name (`-demo combat|beacon|title|smoke`), nil for a normal start.
    var demo: String?
    /// Optional scenario duration in seconds (`-seconds N`): logs "demo done" with the fps summary.
    var seconds: Double?
    /// Show the debug overlay (`-debugHUD`); SpriteKit's counters are always on in DEBUG builds.
    var debugHUD: Bool = false
    /// Player class id (`-class assault|pyro|cryo|gunner`).
    var playerClass: String?
    /// Fixed simulation seed (`-seed N`).
    var seed: UInt32?
    /// No audio (`-mute`).
    var mute: Bool = false
    /// Lock the interface orientation (`-orient portrait|landscape`).
    var orientation: String?
    /// Hide the darkness / flashlight overlay (`-nolight`), to measure its GPU cost.
    var noLighting: Bool = false
    /// Arguments that were not recognised (kept for logging).
    var unknown: [String] = []

    static let current: LaunchOptions = LaunchOptions.parse(ProcessInfo.processInfo.arguments)

    private static let truthy = ["YES", "NO", "1", "0", "true", "false"]

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var result = LaunchOptions()
        var args = Array(arguments.dropFirst())
        func value() -> String? {
            if let v = args.first, !v.hasPrefix("-") || Double(v) != nil { args.removeFirst(); return v }
            return nil
        }
        func flag() -> Bool {
            // Xcode may pass "-flag YES"; swallow an explicit boolean value.
            if let v = args.first, truthy.contains(v) { args.removeFirst(); return v == "YES" || v == "1" || v == "true" }
            return true
        }
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "-demo", "--demo": result.demo = value() ?? "default"
            case "-seconds", "--seconds": if let v = value(), let n = Double(v) { result.seconds = n }
            case "-debugHUD", "--debugHUD", "-debughud": result.debugHUD = flag()
            case "-class", "--class": result.playerClass = value()
            case "-seed", "--seed": if let v = value(), let n = UInt32(v) { result.seed = n }
            case "-mute", "--mute": result.mute = flag()
            case "-orient", "--orient": result.orientation = value()
            case "-nolight", "--nolight": result.noLighting = flag()
            default: result.unknown.append(arg)
            }
        }
        return result
    }

    var summary: String {
        var parts: [String] = []
        parts.append("demo=\(demo ?? "-")")
        if let seconds = seconds { parts.append("seconds=\(seconds)") }
        parts.append("debugHUD=\(debugHUD)")
        if let c = playerClass { parts.append("class=\(c)") }
        if let s = seed { parts.append("seed=\(s)") }
        if mute { parts.append("mute") }
        if let o = orientation { parts.append("orient=\(o)") }
        if noLighting { parts.append("nolight") }
        return parts.joined(separator: " ")
    }
}
