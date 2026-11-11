import Foundation

// ================================================================
//  HUD / RENDER STATE — read-only views for the app (objectiveText,
//  objectiveProgress, contextual hints of 11-ui.js, lasers, stats)
// ================================================================

/// Contextual hint line under the objective.
public struct HintLine: Equatable {
    public let text: GameText
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
    // v1.1
    /// Player downs, and what downed the player last.
    public let downs: Int
    public let downBy: DamageSource
    /// Tier index (0…2, -1 legacy).
    public let tierIndex: Int
    public let beaconsDone: Int
    public let queenSpawned: Bool
    public let queenDone: Bool
    /// Stage reached.
    public let stage: MissionStage
}

extension Game {
    public var player: Marine { marines[0] }

    /// Objective line (top centre), nil in attract mode (the app uppercases it). The current plan step's lines
    /// (Mission.swift): on the way, the hive waking / converging, the step's work, a boss in it.
    public var objective: GameText? {
        if attract { return nil }
        guard let step = currentStep else { return nil }
        let ts = threatState
        /// On the way: the hive's state wins over the step's own line.
        func onTheWay(_ line: TextID, _ waking: TextID, _ converge: TextID) -> GameText {
            GameText(ts == .converging ? converge : (ts == .waking ? waking : line))
        }
        switch step {
        case .ring(let r):
            if activeBeacon >= 0 { return stepLine(r.chargeText, [.name(beacons[activeBeacon].name)]) }
            if ts == .converging { return GameText(r.convergeText) }
            if ts == .waking { return GameText(r.wakingText) }
            let p = ringProgress(r)
            return stepLine(r.lineText, [.int(p.done), .int(p.total)])
        case .switches(let s):
            if activeSwitch >= 0 { return GameText(s.throwText) }
            if ts == .converging { return GameText(s.convergeText) }
            if ts == .waking { return GameText(s.wakingText) }
            return stepLine(s.lineText, [.int(switchesDone), .int(s.needed)])
        case .hold(let h):
            if stepPhase == .approach { return onTheWay(h.approachText, h.wakingText, h.convergeText) }
            if ts == .queen { return stepLine(liftT <= 0.011 ? h.lockedText : h.bossText, [.name((h.boss?.kind ?? .queen).name)]) }
            return stepLine(h.holdText, [.time(liftT.rounded(.up))])
        case .boss(let b):
            if stepPhase == .approach { return onTheWay(b.approachText, b.wakingText, b.convergeText) }
            return stepLine(b.fightText, [.name(b.boss.name)])
        case .extract(let e):
            if stepPhase == .approach { return onTheWay(e.approachText, e.wakingText, e.convergeText) }
            return GameText(e.rideText)
        }
    }

    /// Changes whenever `objective` / `objectiveStyle` would (the HUD rebuilds its line only then): the plan step and its
    /// phase, the active beacon / switch, the beacons and switches done, the threat state, the lift lock, the hold's
    /// countdown second.
    public var objectiveKey: Int {
        if attract { return -1 }
        let hold = holdActive && liftT.isFinite ? Int(liftT.rounded(.up)) : 0
        var k = missionStep * 2 + stepPhase.rawValue
        k = k * 16 + (activeBeacon + 1)
        k = k * 32 + min(31, beaconsDone)
        k = k * 16 + min(15, activeSwitch + 1)
        k = k * 16 + min(15, switches.isEmpty ? 0 : switchesDone)
        k = k * 4 + threatState.rawValue
        k = k * 2 + (liftLocked ? 1 : 0)
        return k * 100_000 + hold
    }

    /// Objective progress bar 0...1, or -1 = hidden (the Матка: her lost health; pressure: press / grace).
    public var objectiveProgress: Float {
        let ts = threatState
        if ts == .queen { return 1 - queenHpFraction }
        if ts != .calm { return min(1, pressure / difficulty.pressureGrace) }
        switch currentStep {
        case .ring?: if activeBeacon >= 0 { return beacons[activeBeacon].progress }
        case .switches?: if activeSwitch >= 0 { return switches[activeSwitch].progress }
        case .hold?: if stepPhase == .active && liftDur.isFinite { return 1 - liftT / liftDur }
        default: break
        }
        return -1
    }

    /// Where the objective marker points (the next beacon or switch, the step's zone), nil = hidden.
    public var objectiveMarker: Vec2? {
        let P = marines[0]
        var t: Vec2? = nil
        switch currentStep {
        case .ring(let r)?:
            let b = nextBeacon()
            if b >= 0 && (beacons[b].state == 0 || hypotf2(beacons[b].x - P.x, beacons[b].z - P.z) > r.radius) { t = beacons[b].position }
        case .switches?:
            let s = nextSwitch()
            if s >= 0 && (switches[s].state == 0 || hypotf2(switches[s].site.x - P.x, switches[s].site.z - P.z) > switches[s].site.radius) {
                t = switches[s].position
            }
        case .hold(let h)?:
            if stepPhase == .approach || !inZone(h.zone, P.x, P.z) { t = zoneCenter(h.zone) }
        case .boss(let b)?:
            if stepPhase == .approach || !inZone(b.zone, P.x, P.z) { t = zoneCenter(b.zone) }
        case .extract?:
            if stepPhase == .approach { t = Vec2(level.lift.x, level.lift.z) }
        case nil: break
        }
        if let p = t, hypotf2(p.x - P.x, p.y - P.z) < 4 { return nil }
        return t
    }

    /// The app's own control hint (hud.hint.controls) shows during the first 7 s unless the coach runs.
    public var showControlHint: Bool { !attract && !coach.active && time < 7 }

    /// The game's own contextual hint (web updateHUD order; the control hint of the first 7 s is the app's).
    public var contextHint: HintLine? {
        let P = marines[0]
        if attract { return nil }
        if P.downed { return HintLine(text: GameText(.hintPlayerDown), urgent: true) }
        if let r = coach.reviveLine, coach.reviveTime > 0 { return HintLine(text: r, urgent: false) }
        if coach.active { return nil }
        if time < 7 { return nil }
        for k in 1..<marines.count where marines[k].downed && hypotf2(marines[k].x - P.x, marines[k].z - P.z) < 6 {
            return HintLine(text: GameText(.hintReviveNear), urgent: false)
        }
        switch currentStep {
        case .ring(let r)?:
            if activeBeacon >= 0 {
                let b = beacons[activeBeacon]
                if standingIn(b.x, b.z, r.radius) == 0 { return HintLine(text: GameText(.hintBackToRing), urgent: true) }
                if b.contested { return HintLine(text: GameText(.hintRingContested), urgent: true) }
                return nil
            }
            let b = nextBeacon()
            if b >= 0 && hypotf2(beacons[b].x - P.x, beacons[b].z - P.z) < 9 { return HintLine(text: GameText(.hintStepInRing), urgent: false) }
            return nil
        case .hold(let h)? where stepPhase == .active && h.zone == .lift:
            // (the lift's hints)
            if !level.onLift(P.x, P.z) { return HintLine(text: GameText(.hintToPlatform), urgent: true) }
            if h.pulse && liftT > liftDur - 8 { return HintLine(text: holdHint, urgent: false) }
            return nil
        case .hold(let h)? where stepPhase == .active && h.outHint != nil:
            // R7: a hold on a deck with its own hint (Breaker Run's generator) — the player out of its zone
            if !inZone(h.zone, P.x, P.z), let t = h.outHint { return HintLine(text: GameText(t), urgent: true) }
            return nil
        case .switches(let s)? where activeSwitch >= 0 && s.drains > 0:
            // R7: a switch being thrown drains while nobody stands in its ring (Breaker Run's breakers, Vent Purge's seals)
            let w = switches[activeSwitch].site
            if standingIn(w.x, w.z, w.radius) == 0 { return HintLine(text: GameText(.hintBackToSwitch), urgent: true) }
            return nil
        default:
            return nil
        }
    }

    /// The lift-pulse hint of this tier (hint.pulse: every N s; hint.pulse_falloff: every N s, weaker at the rim).
    public var holdHint: GameText { Game.holdHintText(difficulty) }

    /// The hold hint of a tier (public: the HUD warms all three).
    public static func holdHintText(_ d: Difficulty) -> GameText {
        GameText(d.pulseFalloff > 0 ? .hintPulseFalloff : .hintPulse, [.int(Int(d.pulseInterval))])
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
        MissionStats(time: time, kills: kills, playerKills: playerKills, accuracy: accuracy, bestCombo: bestCombo, level: xpLevel, won: phase == .won,
                     downs: downs, downBy: downBy, tierIndex: difficulty.index, beaconsDone: beaconsDone, queenSpawned: queen.spawned,
                     queenDone: queen.done, stage: stage)
    }

    /// What the profile and the mission report need from this run (call at mission end; surrender counts as a loss).
    public func runSummary(won: Bool, surrendered: Bool) -> RunSummary {
        // (R7: escalating switches count as escalation steps too — the beacons line counts the beacons lit)
        var lit = 0
        for b in beacons where b.state == 2 { lit += 1 }
        var r = RunSummary(cls: playerClass, won: won, surrendered: surrendered && !won, time: time, playerKills: playerKills,
                           beaconsDone: lit, queenSpawned: queen.spawned, queenDone: queen.done, downs: downs, downBy: downBy,
                           tierIndex: difficulty.index, tierMul: difficulty.scoreMul, stage: stage,
                           pressureLoss: pressure >= difficulty.pressureGrace && idleMul > 1,
                           shots: Int(shots.rounded()), hits: Int(hits.rounded()), accuracy: accuracy, bestCombo: bestCombo, level: xpLevel,
                           station: stationName, beaconsTotal: mission.ringSiteCount, lightsOn: lightsLit, lightsTotal: props.circuits.count)
        // R7: the plan's switch line (its first SWITCH step that scores) and its own report strip
        for s in mission.steps {
            guard case .switches(let w) = s, let t = w.scoreText else { continue }
            r.switchLine = t; r.switchesDone = min(switchesThrown, mission.switchCount); r.switchesTotal = mission.switchCount; r.switchScore = w.score
            break
        }
        r.strip = planStrip(won: won)
        return r
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
        for q in 0..<n { out.append(hash.qb[q]) }
        return out
    }

    /// Live bugs inside the square |dx|, |dz| < halfExtent around `center` (web `nearCam`: 22 m around the
    /// camera target drives the swarm chitter / rumble loops, full at 500).
    public func bugCountNear(_ center: Vec2, halfExtent: Float = 22) -> Int {
        let S = bugs, X = S.x, Z = S.z, D = S.dead
        var n = 0, i = 0
        let cnt = S.count
        while i < cnt {
            if D[i] == 0 && absf(X[i] - center.x) < halfExtent && absf(Z[i] - center.y) < halfExtent { n += 1 }
            i += 1
        }
        return n
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
