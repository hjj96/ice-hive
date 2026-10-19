import Foundation

/// Launch arguments, e.g. `-demo combat -seconds 40 -debugHUD`.
/// Used by the CI simulator smoke test (`xcrun simctl launch … -demo combat`).
struct LaunchOptions {
    /// Demo / scripted scenario name (`-demo combat|beacon|title|calm|probe|hold|extract|queen|queenlock|coach|pressure|report|levelup|pause|end`),
    /// nil for a normal start.
    var demo: String?
    /// Optional scenario duration in seconds (`-seconds N`): logs "demo done" with the fps summary.
    var seconds: Double?
    /// Show the debug overlay (`-debugHUD`: fps, timings, swarm, draw calls in the bottom-left corner).
    var debugHUD: Bool = false
    /// Player class id (`-class assault|pyro|cryo|gunner`).
    var playerClass: String?
    /// Fixed simulation seed (`-seed N`).
    var seed: UInt32?
    /// No audio (`-mute`).
    var mute: Bool = false
    /// Lock the interface orientation (`-orient portrait|landscape`).
    var orientation: String?
    /// Demo swarm size override (`-bugs N`, combat / beacon demos; capped by the quality tier's bug cap).
    var bugs: Int?
    /// World target scale (`-mscale N`, pixels per point; default 2 like the web build's pixel ratio on «высокая»; the
    /// drawable, and the HUD in it, always use the screen's native scale).
    var metalScale: Double?
    /// Draw every swarm speckle again as an anti-aliased dot (`-glintDots`; off = the web's plain speckles).
    var glintDots: Bool = false
    /// CI: behave as if Metal could not start (`-failMetal`), to check the failure message.
    var failMetal: Bool = false
    /// Store screenshots (`-storeShot`): no debug overlay even in a DEBUG build.
    var storeShot: Bool = false
    // v1.1 «Ставки»
    /// Mission tier 0 Новобранец / 1 Ветеран / 2 Кошмар (`-tier N`; demos default to Ветеран; on the title it acts as the
    /// player's pick).
    var tier: Int?
    /// Run the first-run coach or not (`-coach 0|1`; default: the first-mission rule).
    var coach: Bool?
    /// `-demo coach`: jump to coach step N (0…4) at the start.
    var coachStep: Int?
    /// The Матка climbs up at the start of the hold (`-queen`).
    var queen: Bool = false
    /// Her absolute health (`-queenHp N`).
    var queenHp: Float?
    /// Demo meta fixture (`-profile fresh|returning|veteran`): profile, tier pick and coach flag in memory only.
    var profile: String?
    /// `-demo report`: the report fixture (`-report win|loss|first|chip`).
    var report: String?
    /// `-demo pressure`: the threat state shown (`-pressure amber|red`).
    var pressure: String?
    /// Station seed (`-station N`): only with the generated-stations flag (logged and ignored otherwise).
    var station: UInt32?
    /// Log the rects of every title / report / pause element and any overlap or off-screen element (`-layoutCheck`).
    var layoutCheck: Bool = false
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
            case "-bugs", "--bugs": if let v = value(), let n = Int(v), n >= 0 { result.bugs = n }
            case "-mscale", "--mscale": if let v = value(), let n = Double(v), n > 0.4, n <= 4 { result.metalScale = n }
            case "-glintDots", "--glintDots": result.glintDots = flag()
            case "-failMetal", "--failMetal": result.failMetal = flag()
            case "-storeShot", "--storeShot": result.storeShot = flag()
            case "-tier", "--tier": if let v = value(), let n = Int(v), (0...2).contains(n) { result.tier = n }
            case "-coach", "--coach": result.coach = flag()
            case "-coachStep", "--coachStep": if let v = value(), let n = Int(v), (0...4).contains(n) { result.coachStep = n }
            case "-queen", "--queen": result.queen = flag()
            case "-queenHp", "--queenHp": if let v = value(), let n = Float(v), n > 0 { result.queenHp = n }
            case "-profile", "--profile": result.profile = value()
            case "-report", "--report": result.report = value()
            case "-pressure", "--pressure": result.pressure = value()
            case "-station", "--station": if let v = value(), let n = UInt32(v) { result.station = n }
            case "-layoutCheck", "--layoutCheck": result.layoutCheck = flag()
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
        if let b = bugs { parts.append("bugs=\(b)") }
        if let m = metalScale { parts.append("mscale=\(m)") }
        if glintDots { parts.append("glintDots") }
        if failMetal { parts.append("failMetal") }
        if storeShot { parts.append("storeShot") }
        if let t = tier { parts.append("tier=\(t)") }
        if let c = coach { parts.append("coach=\(c)") }
        if let c = coachStep { parts.append("coachStep=\(c)") }
        if queen { parts.append("queen") }
        if let q = queenHp { parts.append("queenHp=\(q)") }
        if let p = profile { parts.append("profile=\(p)") }
        if let r = report { parts.append("report=\(r)") }
        if let p = pressure { parts.append("pressure=\(p)") }
        if let s = station { parts.append("station=\(s)") }
        if layoutCheck { parts.append("layoutCheck") }
        return parts.joined(separator: " ")
    }
}
