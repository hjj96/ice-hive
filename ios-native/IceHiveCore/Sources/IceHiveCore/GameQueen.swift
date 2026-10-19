import Foundation

// ================================================================
//  THE МАТКА — the boss of the lift hold (v1.1 «Ставки», web 08b-threat.js
//  queenEdge / queenWarn / queenSpawn / queenTick / queenKilled / queenSkip).
//  She is a brute instance scaled up (radius 1.5, scale 4.2): the renderer
//  draws her with the brute mesh, the brute AI does her ram. Fixed fields
//  only, no allocations per tick. While she lives the hold hordes pause, the
//  trickle thins out and the lift cannot leave.
// ================================================================
extension Game {

    /// The tier (or the debug override) sends a Матка into this hold.
    var queenExpected: Bool { (config.queenAt ?? difficulty.queen.at).isFinite }

    /// A rim edge of the lift on its far side (z − lift.z < −4), else any rim edge, else the edge nearest to the lift.
    func queenEdge() -> Int {
        let L = level, T = level.lift
        let r2 = (T.r + 1.5) * (T.r + 1.5)
        var back = 0, rim = 0, near = 0
        var nd: Float = 1e9
        var e = 0
        let N = L.edgeCount
        while e < N {
            let dx = L.edgeX[e] - T.x, dz = L.edgeZ[e] - T.z, d2 = dx * dx + dz * dz
            if d2 < nd { nd = d2; near = e }
            if d2 < r2 { rim += 1; if dz < -4 { back += 1 } }
            e += 1
        }
        if rim == 0 { return near }
        var k = Int(Float(back > 0 ? back : rim) * rng.next())
        e = 0
        while e < N {
            let dx = L.edgeX[e] - T.x, dz = L.edgeZ[e] - T.z
            if dx * dx + dz * dz < r2 && (back == 0 || dz < -4) {
                if k == 0 { return e }
                k -= 1
            }
            e += 1
        }
        return near
    }

    /// 2 s of red warning ring where she will climb over the rim.
    func queenWarn() {
        qEdge = queenEdge(); qWarn = 2
        if level.edgeCount == 0 { return }
        let x = level.edgeX[qEdge], z = level.edgeZ[qEdge]
        teleRing(x, z, 3, 1.0, 0.12, 0.08, 2.0, pulse: true, cause: .queenRim)
        emit(.queenWarning(pos: Vec2(x, z)))
    }

    func queenSpawn() {
        let L = level
        if L.edgeCount == 0 { qWarn = -1; return }
        let e = qEdge >= 0 ? qEdge : queenEdge()
        let i = spawnBug(T_BRUTE, L.edgeX[e], L.edgeZ[e], mode: 1, nx: L.edgeNX[e], nz: L.edgeNZ[e], depth: 3)
        if i < 0 { qWarn = 0.5; return }   // bug arrays full (debug floods only): try again shortly
        let S = bugs, D = difficulty
        let hp = config.queenHp ?? D.queen.hp * hpMul
        S.hp[i] = hp; S.hpMax[i] = hp; S.r[i] = 1.5; S.sc[i] = 4.2; S.spd[i] = D.queen.speed
        queen.uid = S.uid[i]; queen.spawned = true; queen.alive = true; queen.done = false; queen.enraged = false
        queen.t0 = time; queen.killT = 0; queen.hpFraction = 1; queen.warning = -1; queen.position = Vec2(S.x[i], S.z[i])
        qWarn = -1; qSlot = i
        qBrood = 4; qVolley = 3; qRam = 6; qMeleeCd = 0; qArmed = false
        if !simOnly {
            banner("Матка", "Поднимается из бездны — лифт не уйдёт, пока она жива", false)
            events.append(.sound(.siren, pos: nil, loud: nil))
            events.append(.sound(.queen, pos: nil, loud: nil))
            shake(0.4)
            haptic(.heavy)
            emit(.queenSpawned(pos: queen.position))
        }
    }

    /// Called from the hold branch of tickDirector every tick.
    func queenTick(_ dt: Float) {
        if !queen.spawned {
            if !queenExpected { return }
            if qWarn < 0 {
                if liftDur - liftT >= (config.queenAt ?? difficulty.queen.at) { queenWarn() }
            } else {
                qWarn -= dt
                if qWarn <= 0 { queenSpawn() }
            }
            if !queen.spawned { queen.warning = qWarn }
            return
        }
        if !queen.alive { return }
        let S = bugs, D = difficulty
        // her slot from the last tick, unless compact() moved her (then one scan)
        var qi = qSlot
        if qi < 0 || qi >= S.count || S.uid[qi] != queen.uid {
            qi = -1
            var i = 0
            while i < S.count { if S.uid[i] == queen.uid { qi = i; break }; i += 1 }
        }
        if qi < 0 || S.dead[qi] != 0 {
            queen.alive = false; queen.done = true; queen.killT = time - queen.t0; queen.hpFraction = 0; qSlot = -1
            return
        }
        qSlot = qi
        let qx = S.x[qi], qz = S.z[qi]
        queen.position = Vec2(qx, qz)
        queen.hpFraction = clampf(S.hp[qi] / S.hpMax[qi], 0, 1)
        // immune to freeze and deep chill (beamTick / the nova / frost blasts skip her too)
        S.frz[qi] = 0
        if S.chill[qi] > 0.5 { S.chill[qi] = 0.5 }
        // enrage once below half health: faster, angrier, and the hive answers her call
        if !queen.enraged && S.hp[qi] < S.hpMax[qi] * 0.5 {
            queen.enraged = true
            S.spd[qi] = D.queen.speed * 1.35
            // (the web passes '' as the subtitle, which falls back to the horde line: nil here)
            startHorde(Int((D.queen.horde * hordeScale()).rounded()), "Матка в ярости", nil, 50)
            emit(.queenEnraged(pos: queen.position))
        }
        let en = queen.enraged
        if qMeleeCd > 0 { qMeleeCd -= dt }
        // brood: runners burst from her body (only while the swarm cap has room)
        qBrood -= dt
        if qBrood <= 0 {
            qBrood = D.queen.broodT * (en ? 0.7 : 1)
            var k = 0
            while k < D.queen.broodN && capLeft() > 0 { spawnBug(T_RUN, qx, qz, mode: 2); k += 1 }
        }
        // acid volley: one glob per standing marine within 18 m, aimed 0.8 s ahead with ±1.2 m spread
        qVolley -= dt
        if qVolley <= 0 {
            qVolley = D.queen.volleyT * (en ? 0.75 : 1)
            for m in marines {
                if m.downed || (m.x - qx) * (m.x - qx) + (m.z - qz) * (m.z - qz) > 324 { continue }
                let ax = m.x + m.vx * 0.8 + (rng.next() * 2.4 - 1.2)
                let az = m.z + m.vz * 0.8 + (rng.next() * 2.4 - 1.2)
                launchGlob(qx, qz, ax, az)
                if !simOnly {
                    teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, 0.95, cause: .queenVolley)
                    teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, 0.95, cause: .queenVolley)
                }
            }
        }
        // ram: the brute AI does the wind-up (red lane) and the charge; her own clock decides when it may start
        qRam -= dt
        let st = S.st[qi]
        if st == S_WIND { qRam = D.queen.ramT * (en ? 0.75 : 1); qArmed = false }
        else if st == S_MOVE {
            if qRam > 0 { if S.cd[qi] < 0.5 { S.cd[qi] = 0.5 } }
            else if !qArmed { qArmed = true; S.cd[qi] = 0 }
        }
    }

    /// killBug on her uid (after onBugKilled): the blast, two medkits and the presentation.
    func queenKilled(_ x: Float, _ z: Float) {
        queen.alive = false; queen.done = true; queen.killT = time - queen.t0; queen.hpFraction = 0; qSlot = -1
        queen.position = Vec2(x, z)
        queueBoom(x, z, 8, 300, 0, .frag)   // src 0: the player gets the blast's kills
        dropMedkit(x + 1, z); dropMedkit(x - 1, z)
        if !simOnly {
            emit(.queenKilled(pos: Vec2(x, z)))
            hitStop(0.2, 0.15)
            banner("Матка убита", "Лифт свободен", true)
            haptic(.success)
        }
    }

    /// debugSkip() in the hold: she dies (or never comes) before the lift is released.
    func queenSkip() {
        if queen.alive {
            let S = bugs
            var i = 0
            while i < S.count {
                if S.uid[i] == queen.uid && S.dead[i] == 0 { killBug(i, -1); break }
                i += 1
            }
        }
        queen.alive = false; queen.spawned = true; queen.done = true; qWarn = -1; queen.warning = -1
    }

    /// The lift timer is out and the Матка still lives: the lift waits (HUD «Лифт заблокирован — Матка жива»).
    public var liftLocked: Bool { stage == .hold && queen.alive && liftT <= 0.011 }

    /// Her health fraction for the boss bar (0 when she is not alive).
    public var queenHpFraction: Float { queen.alive ? queen.hpFraction : 0 }
}
