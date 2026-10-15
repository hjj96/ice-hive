import Foundation

/// Launch arguments, e.g. `-demo smoke -seconds 20 -debugHUD`.
/// Used by the CI simulator smoke test (`xcrun simctl launch … -demo smoke`).
struct LaunchOptions {
    /// Demo / scripted scenario name (`-demo <name>`), nil for a normal start.
    var demo: String?
    /// Optional scenario duration in seconds (`-seconds N`).
    var seconds: Double?
    /// Show SpriteKit FPS / node / draw counters (`-debugHUD`). Always on in DEBUG builds.
    var debugHUD: Bool = false
    /// Arguments that were not recognised (kept for logging).
    var unknown: [String] = []

    static let current: LaunchOptions = LaunchOptions.parse(ProcessInfo.processInfo.arguments)

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var result = LaunchOptions()
        var args = Array(arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "-demo", "--demo":
                if let value = args.first, !value.hasPrefix("-") {
                    result.demo = value
                    args.removeFirst()
                } else {
                    result.demo = "default"
                }
            case "-seconds", "--seconds":
                if let value = args.first, let number = Double(value) {
                    result.seconds = number
                    args.removeFirst()
                }
            case "-debugHUD", "--debugHUD", "-debughud":
                // Xcode may pass "-debugHUD YES"; swallow an explicit boolean value.
                if let value = args.first, ["YES", "NO", "1", "0", "true", "false"].contains(value) {
                    result.debugHUD = (value == "YES" || value == "1" || value == "true")
                    args.removeFirst()
                } else {
                    result.debugHUD = true
                }
            default:
                result.unknown.append(arg)
            }
        }
        return result
    }

    var summary: String {
        var parts: [String] = []
        parts.append("demo=\(demo ?? "-")")
        if let seconds = seconds { parts.append("seconds=\(seconds)") }
        parts.append("debugHUD=\(debugHUD)")
        return parts.joined(separator: " ")
    }
}
