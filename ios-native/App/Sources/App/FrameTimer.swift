import Foundation

/// Smoothed per-section CPU timings of a frame (ms), for the heartbeat log and the debug HUD.
final class FrameTimer {
    private(set) var ms: [Double]
    private let names: [String]
    private var t0: Double = 0
    private var index = 0

    init(_ names: [String]) {
        self.names = names
        ms = [Double](repeating: 0, count: names.count)
    }

    @inline(__always) static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func begin() { t0 = FrameTimer.now(); index = 0 }

    /// End of the next section (sections are marked in the order of `names`).
    func mark() {
        let t = FrameTimer.now()
        if index < ms.count { ms[index] += ((t - t0) * 1000 - ms[index]) * 0.1 }
        index += 1
        t0 = t
    }

    var summary: String {
        var parts: [String] = []
        for (k, n) in names.enumerated() { parts.append(n + "=" + String(format: "%.1f", ms[k])) }
        return parts.joined(separator: " ")
    }
}
