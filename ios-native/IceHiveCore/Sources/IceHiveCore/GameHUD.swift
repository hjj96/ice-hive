import Foundation

// ================================================================
//  HUD / RENDER STATE — read-only views for the app (objectiveText,
//  objectiveProgress, contextual hints of 11-ui.js, lasers, stats)
// ================================================================

/// Contextual hint line under the objective.
public struct HintLine: Equatable {
    public let text: String
    /// Red (urgent) styling.
    public let urgent: Bool
}

/// End-of-mission numbers (end screen rows).
public struct MissionStats {
    public let time: Float
    public let kills: Int
    public let playerKills: Int
    /// 0...100.
    public let accuracy: Int
    public let bestCombo: Int
    public let level: Int
    public let won: Bool
}

extension Game {
    public var player: Marine { marines[0] }

    /// Objective line (top centre), empty in attract mode.
    public var objectiveText: String {
        if attract { return "" }
        switch stage {
        case .beacons:
            if activeBeacon >= 0 { return "Удерживайте маяк «" + beacons[activeBeacon].name + "»" }
            return "Запустите маяки \(beaconsDone)/\(beacons.count)"
        case .toLift: return "Лифт вызван — к платформе"
        case .hold: return "Держитесь на лифте · " + formatTime(liftT.rounded(.up))
        case .extract: return "Эвакуация!"
        }
    }

    /// Objective progress bar 0...1, or -1 = hidden.
    public var objectiveProgress: Float {
        if stage == .beacons && activeBeacon >= 0 { return beacons[activeBeacon].progress }
        if stage == .hold { return 1 - liftT / liftDur }
        return -1
    }

    /// Where the objective marker points (next beacon / lift), nil = hidden.
    public var objectiveMarker: Vec2? {
        let P = marines[0]
        var t: Vec2? = nil
        if stage == .beacons {
            let b = nextBeacon()
            if b >= 0 && (beacons[b].state == 0 || hypotf2(beacons[b].x - P.x, beacons[b].z - P.z) > BEACON_R) { t = beacons[b].position }
        } else if stage == .toLift || (stage == .hold && !level.onLift(P.x, P.z)) {
            t = Vec2(level.lift.x, level.lift.z)
        }
        if let p = t, hypotf2(p.x - P.x, p.y - P.z) < 4 { return nil }
        return t
    }

    /// The game's own contextual hint (the app shows its control hint during the first 7 s itself).
    public var contextHint: HintLine? {
        let P = marines[0]
        if attract { return nil }
        if P.downed { return HintLine(text: "Вы ранены — союзники идут на помощь", urgent: true) }
        if time < 7 { return nil }
        for k in 1..<marines.count where marines[k].downed && hypotf2(marines[k].x - P.x, marines[k].z - P.z) < 6 {
            return HintLine(text: "Встаньте рядом с раненым, чтобы поднять его", urgent: false)
        }
        if stage == .beacons && activeBeacon >= 0 {
            let b = beacons[activeBeacon]
            if standingIn(b.x, b.z, BEACON_R) == 0 { return HintLine(text: "Вернитесь в кольцо маяка!", urgent: true) }
            if b.contested { return HintLine(text: "Рой в кольце — зарядка замедлена", urgent: true) }
            return nil
        }
        if stage == .beacons && activeBeacon < 0 {
            let b = nextBeacon()
            if b >= 0 && hypotf2(beacons[b].x - P.x, beacons[b].z - P.z) < 9 { return HintLine(text: "Встаньте в кольцо маяка", urgent: false) }
            return nil
        }
        if stage == .hold && !level.onLift(P.x, P.z) { return HintLine(text: "На платформу! Отсчёт стоит", urgent: true) }
        if stage == .hold && liftT > LIFT_TIME - 8 { return HintLine(text: "Защитный контур лифта бьёт током каждые 5 секунд", urgent: false) }
        return nil
    }

    /// Combo counter shown from ×5.
    public var comboShown: Int { combo >= 5 ? combo : 0 }

    /// Live bugs (not dead).
    public var bugsAlive: Int { bugs.aliveCount }

    /// Lift platform rise during extraction (web liftGroup.position.y).
    public var liftRise: Float {
        if stage != .extract { return 0 }
        let u = extractT / 4.5
        return u * u * 22
    }

    public var accuracy: Int { shots > 0 ? Int((100 * min(1, hits / shots)).rounded()) : 0 }

    public var stats: MissionStats {
        MissionStats(time: time, kills: kills, playerKills: playerKills, accuracy: accuracy, bestCombo: bestCombo, level: xpLevel, won: phase == .won)
    }

    /// Visual laser length of a marine (first bug along the aim, max 24 m), measured on the current hash.
    public func laserLength(_ m: Marine, maxDistance: Float = 24) -> Float {
        let mp = muzzlePosition(m)
        return hash.raycast(bugs, mp.x, mp.y, m.ax, m.az, maxDistance).0
    }

    /// First bug along a ray: (distance or maxDistance, bug slot or -1).
    public func raycastBugs(origin: Vec2, dir: Vec2, maxDistance: Float) -> (distance: Float, bug: Int) {
        let r = hash.raycast(bugs, origin.x, origin.y, dir.x, dir.y, maxDistance)
        return (r.0, r.1)
    }

    /// Live bugs whose body overlaps the circle (slot indices).
    public func bugsInCircle(_ center: Vec2, radius: Float) -> [Int] {
        let n = hash.queryCircle(bugs, center.x, center.y, radius)
        var out: [Int] = []
        out.reserveCapacity(n)
        for q in 0..<n { out.append(Int(hash.qb[q])) }
        return out
    }

    /// Turret laser length toward its current aim.
    public var turretLaserLength: Float {
        if !turret.active { return 0 }
        return hash.raycast(bugs, turret.x + sinf2(turret.angle) * 0.7, turret.z + cosf2(turret.angle) * 0.7,
                            sinf2(turret.angle), cosf2(turret.angle), turretRange() + 1).0
    }

    /// Flow field toward the nearest standing marine (debug overlays).
    public var swarmFlowField: FlowField { swarmFlow }
}
