import Foundation

// ================================================================
//  DEBUG HOOKS — equivalents of window.__dbg (12-main.js)
// ================================================================

public struct BenchResult: CustomStringConvertible {
    public let count: Int
    public let spawned: Int
    public let alive: Int
    /// Sparse ring 4–34 m around the squad, bugs immortal.
    public let msPerTick: Double
    /// Dense pile 2–12 m around the squad, bugs immortal.
    public let denseMsPerTick: Double
    /// Real combat: normal HP, autopilot shooting, kills and events on, director off.
    public let combatMsPerTick: Double

    public var description: String {
        String(format: "bench %4d bugs (spawned %4d, alive %4d): sparse %.3f ms/tick, dense %.3f ms/tick, combat %.3f ms/tick",
               count, spawned, alive, msPerTick, denseMsPerTick, combatMsPerTick)
    }
}

/// Compact snapshot for logs and tests (`__dbg.state()`).
public struct DebugState: CustomStringConvertible {
    public let phase: GamePhase
    public let time: Float
    public let stage: MissionStage
    public let objective: String
    public let bugsAlive: Int
    public let kills: Int
    public let beaconsDone: Int
    public let liftT: Float
    public let level: Int
    public let hordes: Int
    public let playerHp: Float
    public let playerPos: Vec2
    public let downed: [Bool]

    public var description: String {
        let nums = String(format: "t=%6.1f bugs=%d kills=%d beacons=%d liftT=%.1f lvl=%d hordes=%d hp=%.0f pos=(%.1f,%.1f)",
                          time, bugsAlive, kills, beaconsDone, liftT, level, hordes, playerHp, playerPos.x, playerPos.y)
        return nums + " \(phase) stage=\(stage) downed=" + downed.map { $0 ? "1" : "0" }.joined() + " obj=«" + objective + "»"
    }
}

extension Game {
    /// Snapshot of the run (same as `debugState`).
    public var state: DebugState { debugState }

    public var debugState: DebugState {
        let P = marines[0]
        return DebugState(phase: phase, time: time, stage: stage, objective: objectiveText, bugsAlive: bugs.aliveCount, kills: kills,
                          beaconsDone: beaconsDone, liftT: liftT, level: xpLevel, hordes: hordes, playerHp: P.hp,
                          playerPos: Vec2(P.x, P.z), downed: marines.map { $0.downed })
    }

    /// Spawn `n` bugs (type nil = director mix) on walkable floor in a ring around the player. Returns how many were made.
    @discardableResult
    public func debugSpawn(_ n: Int, type: BugType? = nil, minRadius: Float = 6, maxRadius: Float = 26) -> Int {
        let P = marines[0]
        var made = 0
        var k = 0
        while k < n * 6 && made < n {
            k += 1
            let a = rng.next() * TAU, r = rng.range(minRadius, maxRadius)
            let x = P.x + cosf2(a) * r, z = P.z + sinf2(a) * r
            if !level.walkable(x, z) { continue }
            let ty: UInt8 = type.map { UInt8($0.rawValue) } ?? pickType(true)
            if spawnBug(ty, x, z) >= 0 { made += 1 }
        }
        return made
    }

    /// Complete the current objective stage.
    @discardableResult
    public func debugSkip() -> MissionStage {
        switch stage {
        case .beacons:
            let b = nextBeacon()
            if b >= 0 {
                if beacons[b].state == 0 { activeBeacon = b }
                completeBeacon(b)
            }
        case .toLift:
            let L = level.lift
            for (k, m) in marines.enumerated() {
                let a = Float.pi / 4 + Float(k) * Float.pi / 2
                m.x = L.x + cosf2(a) * 2; m.px = m.x
                m.z = L.z + sinf2(a) * 2; m.pz = m.z
            }
            startHold()
        case .hold:
            liftT = 0.01
        case .extract:
            extractT = 4.5
        }
        return stage
    }

    /// Force a level-up (the UI / autoPick handles the cards).
    @discardableResult
    public func debugLevelUp() -> Int {
        xpLevel += 1; xpNext = xpFor(xpLevel); pendingLevels += 1
        emit(.levelUp(level: xpLevel))
        return xpLevel
    }

    /// Explicit quality choice: changes the gameplay bug cap (adaptive render steps must not call this).
    public func setQuality(_ q: QualityTier) { bugCap = q.bugCap }

    /// Trigger a horde of n bugs now.
    public func debugHorde(_ n: Int = 300) { startHorde(n) }

    /// Teleport the squad around (x, z).
    public func debugTeleport(_ x: Float, _ z: Float) {
        for (k, m) in marines.enumerated() {
            let a = Float(k) * TAU / 4
            m.x = x + (k > 0 ? cosf2(a) * 1.6 : 0); m.z = z + (k > 0 ? sinf2(a) * 1.6 : 0)
            if !level.canStand(m.x, m.z) { m.x = x; m.z = z }
            m.px = m.x; m.pz = m.z
        }
        updateFlows()
    }

    /// Run the simulation for `seconds` of game time as fast as possible (level-ups auto-picked),
    /// stopping early when the mission ends.
    @discardableResult
    public func fastForward(seconds: Float) -> DebugState {
        let n = Int((seconds * 60).rounded())
        var k = 0
        while k < n && phase == .playing {
            tick()
            while pendingLevels > 0 && phase == .playing {
                if offer.isEmpty { rollUpgrades() }
                if chooseUpgrade(0) == nil { pendingLevels = 0 }
            }
            k += 1
        }
        return debugState
    }

    /// True if any simulation number went non-finite (tests).
    public func hasNonFinite() -> Bool {
        let S = bugs
        for i in 0..<S.count {
            if !S.x[i].isFinite || !S.z[i].isFinite || !S.vx[i].isFinite || !S.vz[i].isFinite || !S.hp[i].isFinite || !S.y[i].isFinite || !S.hd[i].isFinite {
                return true
            }
        }
        for m in marines {
            if !m.x.isFinite || !m.z.isFinite || !m.vx.isFinite || !m.vz.isFinite || !m.hp.isFinite || !m.aim.isFinite || !m.kx.isFinite { return true }
        }
        let P = projectiles
        for k in 0..<P.count where !P.x[k].isFinite || !P.z[k].isFinite { return true }
        return false
    }

    /// Simulation benchmark (__dbg.bench): for each count, spawn that many bugs and time the fixed step only.
    /// Restores the world afterwards.
    public func benchmark(counts: [Int] = [500, 1500, 3000], warmupTicks: Int = 10, measureTicks: Int = 60) -> [BenchResult] {
        let saved = bugs.snapshot()
        let savedMarines = marines.map { ($0.x, $0.z, $0.px, $0.pz, $0.vx, $0.vz, $0.hp, $0.downed, $0.aim, $0.abCd, $0.dashCd, $0.heat, $0.energy, $0.ammo) }
        let savedSim = simOnly, savedGod = godMode, savedTime = simTime, savedHp = hpMul, savedAuto = autopilot
        let savedKills = kills, savedPK = playerKills, savedShots = shots, savedHits = hits, savedCombo = combo, savedBest = bestCombo
        let savedXp = xp, savedLvl = xpLevel, savedNext = xpNext, savedPending = pendingLevels, savedTick = tickCount
        let savedEvents = events.count
        simOnly = true; godMode = true
        hpMul = 1e5   // bugs survive the volley so every tick processes the full count
        var out: [BenchResult] = []
        func run(_ n: Int, _ r0: Float, _ r1: Float) -> (Int, Double) {
            clearWorldForBench()
            let made = debugSpawn(n, type: nil, minRadius: r0, maxRadius: r1)
            for _ in 0..<warmupTicks { tick() }
            let t0 = ProcessInfo.processInfo.systemUptime
            for _ in 0..<measureTicks { tick() }
            let t1 = ProcessInfo.processInfo.systemUptime
            return (made, (t1 - t0) * 1000 / Double(measureTicks))
        }
        for c in counts {
            let n = min(c, MAX_BUGS)
            let (made, ms) = run(n, 4, 34)
            let alive = bugs.aliveCount
            let (_, dense) = run(n, 2, 12)
            // real combat: normal bug HP, the autopilot shooting, kills and events on
            hpMul = 1; simOnly = false; benchCombat = true; autopilot = true
            let (_, kill) = run(n, 2, 12)
            autopilot = savedAuto; simOnly = true; benchCombat = false; hpMul = 1e5
            out.append(BenchResult(count: c, spawned: made, alive: alive, msPerTick: ms, denseMsPerTick: dense, combatMsPerTick: kill))
        }
        clearWorldForBench()
        bugs.restore(saved)
        for (k, s) in savedMarines.enumerated() {
            let m = marines[k]
            (m.x, m.z, m.px, m.pz, m.vx, m.vz, m.hp, m.downed, m.aim, m.abCd, m.dashCd, m.heat, m.energy, m.ammo) = s
        }
        simOnly = savedSim; godMode = savedGod; simTime = savedTime; hpMul = savedHp
        kills = savedKills; playerKills = savedPK; shots = savedShots; hits = savedHits; combo = savedCombo; bestCombo = savedBest
        xp = savedXp; xpLevel = savedLvl; xpNext = savedNext; pendingLevels = savedPending; tickCount = savedTick
        if events.count > savedEvents { events.removeSubrange(savedEvents..<events.count) }
        hash.rebuild(bugs); updateFlows()
        return out
    }

    private func clearWorldForBench() {
        bugs.clear(); hash.clear(); globs.count = 0; booms.removeAll(keepingCapacity: true); queue.removeAll()
        projectiles.count = 0
        for k in grenades.indices { grenades[k].active = false }
        for k in napalms.indices { napalms[k].active = false }
        for k in medkits.indices { medkits[k].active = false }
        turret.active = false
    }
}
