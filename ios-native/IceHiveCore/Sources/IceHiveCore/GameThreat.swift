import Foundation

// ================================================================
//  THREAT STATE — hive pressure and the Матка as the HUD sees them
//  (v1.1, web threatState / updateThreatHUD of 08b-threat.js). The pressure
//  clock itself runs in tickDirector, the AFK clock in tickMarines.
// ================================================================

/// 0 calm · 1 the hive wakes (amber) · 2 the swarm converges (red, heartbeat, urgent marker) · 3 the boss lives (the Матка).
public enum ThreatState: Int {
    case calm, waking, converging, boss
}

/// Objective panel variant the HUD draws.
public enum ObjectiveStyle: Int {
    case normal, waking, converging, boss
}

extension Game {
    /// By the plan's phase: a hold or a boss arena — the boss while she lives; on the move between objectives — the hive
    /// pressure; a ring charging or the ride — calm.
    public var threatState: ThreatState {
        if attract { return .calm }
        switch posture {
        case .hold: return boss.alive ? .boss : .calm
        case .defend, .ride: return .calm
        case .travel: break
        }
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
        case .boss: return .boss
        }
    }

    /// The objective marker pulses red (the swarm converges).
    public var markerUrgent: Bool { threatState == .converging }

    /// Station of this mission (KELVIN-9, or SECTOR D-17 for a generated one).
    public var stationName: NameRef { level.layout.name }
}
