import Foundation

/// Smoothed per-section CPU timings of a frame (ms), for the heartbeat log and the debug HUD.
final class FrameTimer {
    private(set) var ms: [Double]
    private var maxMs: [Double]
    private let names: [String]
    private var t0: Double = 0
    private var index = 0

    init(_ names: [String]) {
        self.names = names
        ms = [Double](repeating: 0, count: names.count)
        maxMs = ms
    }

    @inline(__always) static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func begin() { t0 = FrameTimer.now(); index = 0 }

    /// End of the next section (sections are marked in the order of `names`).
    func mark() {
        let t = FrameTimer.now()
        if index < ms.count {
            let v = (t - t0) * 1000
            ms[index] += (v - ms[index]) * 0.1
            if v > maxMs[index] { maxMs[index] = v }
        }
        index += 1
        t0 = t
    }

    /// Worst value per section since the last call (heartbeat), then reset.
    func takeMax() -> String {
        var parts: [String] = []
        for (k, n) in names.enumerated() where maxMs[k] >= 2 { parts.append(n + "=" + String(format: "%.0f", maxMs[k])) }
        for k in 0..<maxMs.count { maxMs[k] = 0 }
        return parts.isEmpty ? "-" : parts.joined(separator: " ")
    }

    var summary: String {
        var parts: [String] = []
        for (k, n) in names.enumerated() { parts.append(n + "=" + String(format: "%.1f", ms[k])) }
        return parts.joined(separator: " ")
    }
}
