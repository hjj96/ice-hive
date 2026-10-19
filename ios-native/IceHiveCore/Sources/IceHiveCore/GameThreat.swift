import Foundation

// ================================================================
//  THREAT STATE — hive pressure and the Матка as the HUD sees them
//  (v1.1, web threatState / updateThreatHUD of 08b-threat.js). The pressure
//  clock itself runs in tickDirector, the AFK clock in tickMarines.
// ================================================================

/// 0 calm · 1 the hive wakes (amber) · 2 the swarm converges (red, heartbeat, urgent marker) · 3 the Матка lives.
public enum ThreatState: Int {
    case calm, waking, converging, queen
}

/// Objective panel variant the HUD draws.
public enum ObjectiveStyle: Int {
    case normal, waking, converging, boss
}

extension Game {
    public var threatState: ThreatState {
        if attract { return .calm }
        if stage == .hold { return queen.alive ? .queen : .calm }
        if !((stage == .beacons && activeBeacon < 0) || stage == .toLift) { return .calm }
        let g = difficulty.pressureGrace
        if pressure >= g { return .converging }
        if pressure >= g - 10 { return .waking }
        return .calm
    }

    public var objectiveStyle: ObjectiveStyle {
        switch threatState {
        case .calm: return .normal
        case .waking: return .waking
        case .converging: return .converging
        case .queen: return .boss
        }
    }

    /// The objective marker pulses red (the swarm converges).
    public var markerUrgent: Bool { threatState == .converging }

    /// Station name of this mission («Кельвин-9», «Сектор Д-17»).
    public var stationName: String { level.layout.name }
}
