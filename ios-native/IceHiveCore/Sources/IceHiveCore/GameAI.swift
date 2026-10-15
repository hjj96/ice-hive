import Foundation

// ================================================================
//  PLAYER INPUT + BOT AI (playerCommands / aimAssist of 10-input.js,
//  botThink / aiPickTarget of 06-marines.js)
// ================================================================

/// Formation slots behind the player (side, back) per squad index.
let FORM: [(Float, Float)] = [(0, 0), (-2.4, -1.5), (2.4, -1.5), (0, -2.9)]

// Loops over query results are `while` loops: `for … in 0..<n` is slow in unoptimised (Debug) builds.
extension Game {

    // ---------- input API ----------
    /// Player input in WORLD space (call before each tick or once per frame; it persists).
    /// - move: desired movement, length 0...1 (longer vectors are normalised).
    /// - aim: aim angle (direction = (sin aim, cos aim)), nil = keep the current aim
    ///   (while not firing the aim then drifts toward the movement direction, as in the web game).
    /// - fire: trigger held.
    /// - ability / dash: one-shot presses, consumed by the next tick.
    /// - assist: aim-assist blend 0...1 toward the best bug in the aim direction (web: touch 0.75, gamepad 0.6, mouse 0).
    /// - abilityTarget: world point for the grenade; nil = aim-assisted target or 9 m ahead.
    public func setPlayerInput(move: Vec2, aim: Float?, fire: Bool, ability: Bool, dash: Bool,
                               assist: Float = 0, abilityTarget: Vec2? = nil) {
        inMove = move
        inAim = aim
        inFire = fire
        inAssist = clampf(assist, 0, 1)
        if ability { inAbility = true; inAbilityTarget = abilityTarget }
        if dash { inDash = true }
    }

    /// Convert a screen-space stick (x right, y down, length 0...1) to the world movement vector of the
    /// web game's fixed 45° camera.
    public static func worldFromScreen(_ sx: Float, _ sy: Float) -> Vec2 {
        Vec2(RIGHT_X * sx - FWD_X * sy, RIGHT_Z * sx - FWD_Z * sy)
    }

    /// Aim angle of a world direction.
    public static func angle(of dir: Vec2) -> Float { atan2f2(dir.x, dir.y) }

    /// Ground area visible on screen (convex polygon in world XZ, any winding). Aim assist and the
    /// grenade auto-target never pick a bug outside it. nil = no restriction.
    public func setVisibleArea(_ polygon: [Vec2]?) { viewQuad = polygon }

    func isVisible(_ x: Float, _ z: Float) -> Bool {
        guard let q = viewQuad, q.count >= 3 else { return true }
        var sign: Float = 0
        do {
            var k = 0
            while k < q.count {
                defer { k += 1 }
                let a = q[k], b = q[(k + 1) % q.count]
                let cr = (b.x - a.x) * (z - a.y) - (b.y - a.y) * (x - a.x)
                if cr == 0 { continue }
                if sign == 0 { sign = cr > 0 ? 1 : -1 } else if (cr > 0 ? 1 : -1) != sign { return false }
            }
        }
        return true
    }

    /// Soft aim assist: among bugs inside a ~23° cone around `dir` (unit, world), prefer well-aligned, close
    /// targets in dense clumps (more hits per shot), and boomers / brutes. Returns a bug slot index or -1.
    public func aimAssistTarget(from m: Marine, dir: Vec2) -> Int {
        let S = bugs
        let dx = dir.x, dz = dir.y
        let cnt = hash.queryCircle(S, m.x + dx * 8, m.z + dz * 8, 9)
        var best = -1
        var bs: Float = -1e9
        do {
            var q = 0
            while q < cnt {
                defer { q += 1 }
                let b = hash.qb[q]
                if S.st[b] == S_CLIMB && S.y[b] < -0.6 { continue }
                let vx = S.x[b] - m.x, vz = S.z[b] - m.z, d = hypotf2(vx, vz)
                if d < 0.6 || d > 17 { continue }
                let cs = (vx * dx + vz * dz) / d
                if cs < 0.92 { continue }
                // never snap to (or lob a grenade at) a bug the player cannot see
                if !isVisible(S.x[b], S.z[b]) { continue }
                let hc = b < hash.hashedCount ? hash.cell[b] : Level.cellClamp(S.x[b], S.z[b])
                let dens = Float(min(14, hash.cellDensity(hc)))
                var s = cs * 5 - d * 0.1 + dens * 0.07
                if S.type[b] == T_BOOM { s += 0.6 }
                if S.type[b] == T_BRUTE { s += 0.4 }
                if s > bs { bs = s; best = b }
            }
        }
        return best
    }

    /// The player's aim angle pulled toward the aim-assist target (strength 0...1), as the web game does for touch.
    public func assistedAim(_ angle: Float, strength: Float) -> Float {
        let P = marines[0]
        let b = aimAssistTarget(from: P, dir: Vec2(sinf2(angle), cosf2(angle)))
        if b < 0 { return angle }
        return angle + angDiff(angle, atan2f2(bugs.x[b] - P.x, bugs.z[b] - P.z)) * clampf(strength, 0, 1)
    }

    /// Player commands from the stored input (called from the fixed-step tick).
    func playerCommands(_ m: Marine) -> (Float, Float, Bool) {
        let wx = inMove.x, wz = inMove.y
        let fire = inFire
        var aimed = false
        if let a = inAim {
            var ang = a
            if inAssist > 0 {
                let b = aimAssistTarget(from: m, dir: Vec2(sinf2(a), cosf2(a)))
                if b >= 0 { ang += angDiff(ang, atan2f2(bugs.x[b] - m.x, bugs.z[b] - m.z)) * inAssist }
            }
            m.aim = ang; aimed = true
        } else if fire {
            aimed = true   // firing without a new aim keeps the current aim (touch: aim stick held near its centre)
        }
        if !aimed && abs(wx) + abs(wz) > 0.15 { m.aim += angDiff(m.aim, atan2f2(wx, wz)) * 0.25 }
        m.ax = sinf2(m.aim); m.az = cosf2(m.aim)
        if inAbility {
            inAbility = false
            var tx = m.x + m.ax * 9, tz = m.z + m.az * 9
            if let t = inAbilityTarget { tx = t.x; tz = t.y }
            else {
                let b = aimAssistTarget(from: m, dir: Vec2(m.ax, m.az))
                if b >= 0 { tx = bugs.x[b]; tz = bugs.z[b] }
            }
            inAbilityTarget = nil
            useAbility(m, tx, tz)
        }
        if inDash { inDash = false; tryDash(m, wx, wz) }
        return (wx, wz, fire)
    }

    // ---------- AI ----------
    func aiPickTarget(_ m: Marine, _ range: Float) -> Int {
        let S = bugs
        let cnt = hash.queryCircle(S, m.x, m.z, range)
        var best = -1
        var bs: Float = 1e9
        let P = marines[0]
        do {
            var q = 0
            while q < cnt {
                defer { q += 1 }
                let b = hash.qb[q]
                if S.st[b] == S_CLIMB && S.y[b] < -0.8 { continue }
                let dx = S.x[b] - m.x, dz = S.z[b] - m.z, d = (dx * dx + dz * dz).squareRoot()
                let off = abs(angDiff(m.aim, atan2f2(dx, dz)))
                var s = d + off * 2.2
                let ty = S.type[b]
                if ty == T_BOOM && d < 8 { s -= 6 }
                if ty == T_BRUTE { s -= 2.5 }
                if S.st[b] == S_CHARGE || S.st[b] == S_WIND { s -= 3 }
                if !P.downed {
                    let px = S.x[b] - P.x, pz = S.z[b] - P.z
                    if px * px + pz * pz < 16 { s -= 3 }
                }
                if m.cls == .cryo && S.frz[b] > 0 { s += 4 }
                if s < bs { bs = s; best = b }
            }
        }
        return best
    }

    func botThink(_ m: Marine, _ dt: Float) -> (Float, Float, Bool) {
        let P = marines[0], C = m.spec, md = m.mods, S = bugs, L = level
        let range: Float = m.cls == .pyro ? C.range * md.range + 1.2 : (m.cls == .cryo ? C.range * md.range : 17)
        m.ai.think -= dt
        if m.ai.think <= 0 {
            m.ai.think = 0.12 + rng.next() * 0.08
            m.ai.target = aiPickTarget(m, range)
            m.ai.tuid = m.ai.target >= 0 ? S.uid[m.ai.target] : 0
            // abilities
            if m.abCd <= 0 {
                if m.cls == .assault && m.ai.target >= 0 {
                    let t = m.ai.target
                    let tx = S.x[t], tz = S.z[t]
                    if hypotf2(tx - m.x, tz - m.z) > 4 && (hash.queryCircle(S, tx, tz, 3.5) >= 7 || S.type[t] == T_BRUTE) { useAbility(m, tx, tz) }
                } else if m.cls == .pyro && hash.queryCircle(S, m.x, m.z, 4.5) >= 9 { useAbility(m, 0, 0) }
                else if m.cls == .cryo && hash.queryCircle(S, m.x, m.z, 6.5) >= 13 { useAbility(m, 0, 0) }
                else if m.cls == .gunner && hash.queryCircle(S, m.x, m.z, 12) >= 18 { useAbility(m, 0, 0) }
            }
        }
        // --- where to stand ---
        var gx = m.x, gz = m.z, urgent = false
        var reviveT: Marine? = nil
        var rd: Float = 1e9
        for o in marines {
            if !o.downed || o === m { continue }
            // nearest standing bot takes the job
            var mine = true
            let myD = hypotf2(m.x - o.x, m.z - o.z)
            for h in marines where h !== m && !h.downed && !h.isPlayer {
                if hypotf2(h.x - o.x, h.z - o.z) < myD - 0.5 { mine = false }
            }
            if o.isPlayer { mine = true }
            let d = hypotf2(o.x - m.x, o.z - m.z)
            if mine && d < rd && d < 40 { rd = d; reviveT = o }
        }
        if m.isPlayer {
            let o = objectivePoint(); gx = o.x; gz = o.y
            let bi = stage == .beacons ? nextBeacon() : -1
            // orbit outside the 2x2 blocked base (its corners need ~1.9 m clearance)
            if bi >= 0 && beacons[bi].state == 1 {
                gx = beacons[bi].x + cosf2(simTime * 0.3) * 2.6; gz = beacons[bi].z + sinf2(simTime * 0.3) * 2.6
            }
            if let r = reviveT { gx = r.x; gz = r.z; urgent = true }
        } else if let r = reviveT { gx = r.x; gz = r.z; urgent = true }
        else if (stage == .hold || stage == .extract) && L.onLift(P.x, P.z) {
            let a = Float.pi / 4 + Float(m.index) * Float.pi / 2
            gx = L.lift.x + cosf2(a) * 5.2; gz = L.lift.z + sinf2(a) * 5.2
        } else if activeBeacon >= 0 && hypotf2(P.x - beacons[activeBeacon].x, P.z - beacons[activeBeacon].z) < 7 {
            let b = beacons[activeBeacon], a = Float(m.index) * TAU / 3 + 0.5
            gx = b.x + cosf2(a) * 2.6; gz = b.z + sinf2(a) * 2.6
        } else {
            let fx = P.faceX, fz = P.faceZ, sx = -fz, sz = fx
            let (s, bk) = FORM[m.index]
            gx = P.x + sx * s + fx * bk; gz = P.z + sz * s + fz * bk
            if !L.canStand(gx, gz) { gx = P.x - fx * 1.5; gz = P.z - fz * 1.5 }
        }
        let wx = gx - m.x, wz = gz - m.z
        let dist = hypotf2(wx, wz)
        var mx: Float = 0, mz: Float = 0
        let arrive: Float = urgent ? 0.6 : 1.1
        if dist > arrive { let sp = clampf((dist - arrive) / 2.5, 0.25, 1); mx = wx / dist * sp; mz = wz / dist * sp }
        // path along catwalks with a flow field when the straight line is blocked or the goal is far
        if dist > 2 {
            let c = L.cellOf(m.x, m.z)
            let F = reviveT != nil ? reviveFlow : (m.isPlayer ? objFlow : squadFlow)
            let blocked = !L.canStand(m.x + wx / dist * 1.3, m.z + wz / dist * 1.3) || m.ai.stuck > 0.3
            let farFromLeader = !m.isPlayer && hypotf2(P.x - m.x, P.z - m.z) > 9
            if c >= 0 && (F.x[c] != 0 || F.z[c] != 0) && (blocked || farFromLeader || m.isPlayer) {
                // aim a little ahead of the current cell centre: follows the field and keeps off the railings
                let tx = Level.cellX(c) + F.x[c] * 1.3 - m.x, tz = Level.cellZ(c) + F.z[c] * 1.3 - m.z
                var l = hypotf2(tx, tz)
                if l == 0 { l = 1 }
                mx = tx / l; mz = tz / l
            }
        }
        // safety net: wedged for a while -> step back to the centre of the current cell (always a valid standing spot)
        if m.ai.stuck > 1.5 {
            let c = L.cellOf(m.x, m.z)
            if c >= 0 { mx = Level.cellX(c) - m.x; mz = Level.cellZ(c) - m.z }
        }
        // keep some distance from the swarm (pyro likes it closer)
        let t = m.ai.target
        let valid = t >= 0 && t < S.count && S.dead[t] == 0 && S.uid[t] == m.ai.tuid
        if valid && !urgent {
            let dx = S.x[t] - m.x, dz = S.z[t] - m.z, d = hypotf2(dx, dz)
            let keep: Float = m.cls == .pyro ? 2.2 : 3.6
            if d < keep && d > 1e-6 { mx -= dx / d * 0.7; mz -= dz / d * 0.7 }
        }
        // dodge brute charges
        m.ai.dodge -= dt
        if m.ai.dodge <= 0 {
            m.ai.dodge = 0.1
            let cnt = hash.queryCircle(S, m.x, m.z, 13)
            do {
                var q = 0
                while q < cnt {
                    defer { q += 1 }
                    let b = hash.qb[q]
                    if S.type[b] != T_BRUTE || (S.st[b] != S_WIND && S.st[b] != S_CHARGE) { continue }
                    let rx = m.x - S.x[b], rz = m.z - S.z[b], along = rx * S.ax[b] + rz * S.az[b]
                    let perp = rx * S.az[b] - rz * S.ax[b]
                    if along > 0 && along < 13 && abs(perp) < 2.0 {
                        let s: Float = perp >= 0 ? 1 : -1
                        m.ai.sideX = S.az[b] * s; m.ai.sideZ = -S.ax[b] * s; m.ai.sideT = 0.5
                        if S.st[b] == S_CHARGE && along < 6 { tryDash(m, m.ai.sideX, m.ai.sideZ) }
                    }
                }
            }
        }
        // sidestep acid globs that are about to land on us
        let GL = globs
        do {
            var k = 0
            while k < GL.count {
                defer { k += 1 }
                let left = GL.dur[k] - GL.t[k]
                if left > 0.75 { continue }
                let dx = m.x - GL.x1[k], dz = m.z - GL.z1[k], d = hypotf2(dx, dz)
                if d < 1.9 { m.ai.sideX = d > 0.05 ? dx / d : 1; m.ai.sideZ = d > 0.05 ? dz / d : 0; m.ai.sideT = 0.35 }
            }
        }
        if m.ai.sideT > 0 { m.ai.sideT -= dt; mx = m.ai.sideX; mz = m.ai.sideZ }
        // stuck detection: wants to move but barely moves -> rely on the flow field for a while
        if abs(mx) + abs(mz) > 0.5 && hypotf2(m.x - m.ai.lx, m.z - m.ai.lz) < 1.2 * dt { m.ai.stuck = min(2, m.ai.stuck + dt * 2) }
        else { m.ai.stuck = max(0, m.ai.stuck - dt) }
        m.ai.lx = m.x; m.ai.lz = m.z
        if m.hp < m.maxHp * 0.3 && crowd[m.index] > 4 && m.dashCd <= 0 {
            tryDash(m, -m.vx != 0 ? -m.vx : m.ax, -m.vz != 0 ? -m.vz : m.az)
        }
        // aim + fire
        var fire = false
        if valid {
            let d = hypotf2(S.x[t] - m.x, S.z[t] - m.z)
            let lead: Float = (m.cls == .pyro || m.cls == .cryo) ? 0 : d / 80
            let want = atan2f2(S.x[t] + S.vx[t] * lead - m.x, S.z[t] + S.vz[t] * lead - m.z)
            let diff = angDiff(m.aim, want)
            m.aim += clampf(diff, -10 * dt, 10 * dt)
            let tol: Float = (m.cls == .pyro || m.cls == .cryo) ? 0.3 : 0.14
            fire = abs(diff) < tol && d < range + 0.5
            if m.cls == .pyro && d > C.range * md.range + 0.4 { fire = false }
        } else if abs(mx) + abs(mz) > 0.2 {
            m.aim += clampf(angDiff(m.aim, atan2f2(mx, mz)), -6 * dt, 6 * dt)
        }
        return (mx, mz, fire)
    }
}
