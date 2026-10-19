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
    // v1.1
    /// Tier id (rec / vet / nm / v10), station name.
    public let tier: String
    public let station: String
    public let threat: ThreatState
    public let pressure: Float
    public let queenSpawned: Bool
    public let queenAlive: Bool
    /// Her current health (0 when not alive).
    public let queenHp: Float

    public var description: String {
        let nums = String(format: "t=%6.1f bugs=%d kills=%d beacons=%d liftT=%.1f lvl=%d hordes=%d hp=%.0f pos=(%.1f,%.1f) press=%.1f",
                          time, bugsAlive, kills, beaconsDone, liftT, level, hordes, playerHp, playerPos.x, playerPos.y, pressure)
        let q = queenSpawned ? (queenAlive ? String(format: " queen=%.0f", queenHp) : " queen=dead") : ""
        return nums + q + " \(phase) stage=\(stage) tier=\(tier) threat=\(threat.rawValue) downed=" + downed.map { $0 ? "1" : "0" }.joined() + " obj=«" + objective + "»"
    }
}

/// Everything the threat tests check (web `__dbgExt.threat()`).
public struct ThreatDebug {
    public let tier: String
    public let stage: MissionStage
    public let liftT: Float
    public let pressure: Float
    public let idleMul: Float
    public let afkTime: Float
    public let state: ThreatState
    public let downs: Int
    public let downBy: DamageSource
    public let runners: Int
    public let runnerHpMax: Float
    public let brutes: Int
    public let queen: QueenState
    /// Her slot values (0 / -1 when she is not alive).
    public let queenHp: Float, queenHpMax: Float, queenFreeze: Float, queenChill: Float
    public let queenBugState: Int
    public let queenSlot: Int
}

/// The coach as the tests see it (web `tut()`).
public struct CoachDebug {
    public let active: Bool
    public let step: Int
    public let stepTime: Float
    public let calm: Bool
    public let beaconHordeMul: Float
    public let hordes: Int
    public let time: Float
    public let activeBeacon: Int
    public let reviveTime: Float
    public let groups: Int
}

extension Game {
    /// Snapshot of the run (same as `debugState`).
    public var state: DebugState { debugState }

    public var debugState: DebugState {
        let P = marines[0]
        let qs = queenSlotNow()
        return DebugState(phase: phase, time: time, stage: stage, objective: objectiveText, bugsAlive: bugs.aliveCount, kills: kills,
                          beaconsDone: beaconsDone, liftT: liftT, level: xpLevel, hordes: hordes, playerHp: P.hp,
                          playerPos: Vec2(P.x, P.z), downed: marines.map { $0.downed },
                          tier: difficulty.id, station: stationName, threat: threatState, pressure: pressure,
                          queenSpawned: queen.spawned, queenAlive: queen.alive, queenHp: qs >= 0 ? bugs.hp[qs] : 0)
    }

    /// Her live slot, -1 when she is not alive.
    func queenSlotNow() -> Int {
        if !queen.alive { return -1 }
        let S = bugs
        if qSlot >= 0 && qSlot < S.count && S.uid[qSlot] == queen.uid && S.dead[qSlot] == 0 { return qSlot }
        var i = 0
        while i < S.count { if S.uid[i] == queen.uid && S.dead[i] == 0 { return i }; i += 1 }
        return -1
    }

    public var threatDebug: ThreatDebug {
        let S = bugs
        var runners = 0, brutes = 0
        var rmax: Float = 0
        var i = 0
        while i < S.count {
            if S.dead[i] == 0 {
                if S.type[i] == T_RUN { runners += 1; rmax = max(rmax, S.hpMax[i]) } else if S.type[i] == T_BRUTE { brutes += 1 }
            }
            i += 1
        }
        let q = queenSlotNow()
        return ThreatDebug(tier: difficulty.id, stage: stage, liftT: liftT, pressure: pressure, idleMul: idleMul, afkTime: afkTime,
                           state: threatState, downs: downs, downBy: downBy, runners: runners, runnerHpMax: rmax, brutes: brutes, queen: queen,
                           queenHp: q >= 0 ? S.hp[q] : 0, queenHpMax: q >= 0 ? S.hpMax[q] : 0, queenFreeze: q >= 0 ? S.frz[q] : 0,
                           queenChill: q >= 0 ? S.chill[q] : 0, queenBugState: q >= 0 ? Int(S.st[q]) : -1, queenSlot: q)
    }

    public var coachDebug: CoachDebug {
        CoachDebug(active: coach.active, step: coach.step, stepTime: coach.stepTime, calm: calm, beaconHordeMul: beaconHordeMul, hordes: hordes,
                   time: time, activeBeacon: activeBeacon, reviveTime: coach.reviveTime, groups: coachGroupCount)
    }

    /// The Матка climbs up right now (lift hold only, before she came). `hp` overrides her health. Returns her uid or 0.
    @discardableResult
    public func debugQueen(hp: Float? = nil) -> Int32 {
        if stage != .hold || queen.spawned { return 0 }
        qEdge = -1
        queenSpawn()
        if let h = hp, h > 0, qSlot >= 0 { bugs.hp[qSlot] = h; bugs.hpMax[qSlot] = h }
        return queen.spawned ? queen.uid : 0
    }

    /// Set the hive pressure clock (s).
    public func debugSetPressure(_ s: Float) { pressure = max(0, s) }

    /// Set the lift countdown (hold only).
    public func debugSetLiftTime(_ t: Float) { if stage == .hold { liftT = max(0, min(liftDur, t)) } }

    /// Set a squad member's armour; ≤ 0 downs it (web `__dbgExt.hurt`).
    public func debugHurt(marine k: Int, hp: Float) {
        guard k >= 0 && k < marines.count else { return }
        let m = marines[k]
        if hp <= 0 { if !m.downed { downMarine(m) } } else { m.hp = min(m.maxHp, hp); m.downed = false }
    }

    /// Jump the coach to step k (demo `-coachStep`); starts it if it was off.
    public func debugCoachStep(_ k: Int) {
        if attract { return }
        let s = max(0, min(4, k))
        if !coach.active { coach.active = true; beaconHordeMul = 0.65 }
        coachStep(s)
    }

    /// Force report inputs (web `__dbgExt.meta`): player downs, what downed the player, the pressure clock.
    public func debugSetOutcome(downs d: Int? = nil, downBy b: DamageSource? = nil, pressure p: Float? = nil, idleMul im: Float? = nil) {
        if let d = d { downs = max(0, d) }
        if let b = b { downBy = b; lastHit = b }
        if let p = p { pressure = max(0, p) }
        if let im = im { idleMul = max(1, im) }
    }

    /// Force report fixture fields (mission time, own kills, beacons done, the Матка's fate).
    public func debugSetRun(time t: Float? = nil, playerKills pk: Int? = nil, beaconsDone bd: Int? = nil, queenKilled qk: Bool? = nil, stage st: MissionStage? = nil) {
        if let t = t { time = max(0, t) }
        if let pk = pk { playerKills = max(0, pk) }
        if let bd = bd {
            beaconsDone = max(0, min(beacons.count, bd))
            for k in beacons.indices { beacons[k].state = k < beaconsDone ? 2 : 0; beacons[k].progress = k < beaconsDone ? 1 : 0 }
            activeBeacon = -1
        }
        if let qk = qk { queen.spawned = true; queen.alive = false; queen.done = qk }
        if let st = st { stage = st }
    }

    /// End the mission now (report fixtures; `won` = evacuation).
    public func debugEnd(won: Bool) { endGame(won) }

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
            queenSkip()   // the Матка dies (or never comes) first
            liftT = 0.01
        case .extract:
            extractT = 4.5
        }
        return stage
    }

    /// Hold the extraction at `t` seconds (CI screenshots of the rising lift); no-op outside the extract stage.
    public func debugPinExtract(_ t: Float) {
        if stage == .extract { extractT = max(0, min(4.4, t)) }
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
