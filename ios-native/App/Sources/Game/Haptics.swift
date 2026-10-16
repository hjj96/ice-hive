import UIKit
import IceHiveCore

/// Haptic feedback for HapticKind events, throttled like the v1 iOS bridge (native/bridge.js): a minimum gap per
/// kind, plus a short global gap between impacts / selection ticks; off when the «Вибрация» setting is off.
final class Haptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let note = UINotificationFeedbackGenerator()
    private let sel = UISelectionFeedbackGenerator()
    /// HAPTIC_GAP (s), index = HapticKind.rawValue: select, light, medium, heavy, success, warning, error.
    private static let gap: [Double] = [0.060, 0.090, 0.150, 0.250, 0.400, 0.600, 0.600]
    private static let impactGap: Double = 0.035
    private var lastAt = [Double](repeating: -1e9, count: 7)
    private var lastImpact: Double = -1e9
    var enabled = true

    func play(_ k: HapticKind) {
        guard enabled else { return }
        let i = k.rawValue
        guard i >= 0 && i < Haptics.gap.count else { return }
        let now = FrameTimer.now()
        if now - lastAt[i] < Haptics.gap[i] { return }
        let notify = k == .success || k == .warning || k == .error
        if !notify && now - lastImpact < Haptics.impactGap { return }
        lastAt[i] = now
        if !notify { lastImpact = now }
        switch k {
        case .select: sel.selectionChanged()
        case .light: light.impactOccurred()
        case .medium: medium.impactOccurred()
        case .heavy: heavy.impactOccurred()
        case .success: note.notificationOccurred(.success)
        case .warning: note.notificationOccurred(.warning)
        case .error: note.notificationOccurred(.error)
        }
    }
}
