import Foundation

// ================================================================
//  THE THREADER AND THE SQUAD (Stage 2 B4; design §1.5 «Bots», «Counterplay
//  by class», «Calibration: an autopilot that avoids the lure and punishes
//  the head») — what the bots and the calibration autopilot (the player's
//  seat) do against it. GameAI / GameMarines call in here only while the
//  Threader lives (`threaderActive`): every other mission, the Queen and B1's
//  toy chain keep their numbers and random draws.
//    TARGETS   the head while it is down first (once seen: a bot's
//              reaction, the autopilot's a person's), then the exposed nodes
//              not popped (the Gunner presses them hardest), never the ×0.25
//              body nor anything behind armour up on the trunks (the
//              turret's job: it watches the nodes); the player's aim assist
//              prefers them too. Its parts count for no ability's crowd.
//    DODGES    out of the lure's light when it comes within 2 m (the
//              autopilot later: a person), out of the strike's closing
//              ring (a dash at the last moment), out of the coil with a
//              dash through a gap (or walking out through the gap two
//              frozen segments opened), out of the rime lane, the squeeze's
//              curtains, the pull-down's lane and a charge's path.
//    ABILITIES the Cryo's Ice Wave on the head down (brittle), the Assault's
//              grenade on the head down or on a node of a shrinking coil
//              (it lets go),
//              the Pyro's napalm under a strike spot (the recoil), the
//              Gunner's turret near the nodes.
//    PLACES    the autopilot fights from a corner of the pump housing (away
//              from the light) and closes in on the head while it is down;
//              the Pyro closes in on it too; the other bots keep their
//              places round the island.
// ================================================================
extension Game {

    // ---------------------------------------------------------------- targets

    /// A bot's pick among its parts (aiPickTarget's score: lower is better): the head while it is down (−14, once it has seen
    /// it land: BOT_REACT s, the autopilot a person's reaction); an exposed node
    /// not popped (−5; the Gunner −8, the Assault −6) — low (the coil, a strike's neck), stripped by the torch or in P3; never
    /// a node behind its plates up on the trunks (× 0.25 there: the turret's job). Updates `bs` and returns the slot when it
    /// beats it.
    func threaderAITarget(_ m: Marine, _ range: Float, _ bs: inout Float) -> Int {
        let R = bossRT, S = bugs
        var best = -1
        var q = 0
        while q < R.parts {
            defer { q = q == 0 ? 1 + THREADER_SEGMENTS : q + 1 }
            var bonus: Float
            if q == 0 {
                // (once it has seen the head land: a bot's reaction, the autopilot's a person's)
                let seen = thr.mode == .down && thr.t >= (m.isPlayer ? threaderReact(thr.stats.strikes * 3 + 5) : BOT_REACT)
                if R.down[0] > 0 && seen { bonus = 14 } else { continue }
            } else {
                if R.popped[q] { continue }
                // (an exposed node — low, P3 —: the Gunner's sustained fire, the Assault's pierce rounds «popping nodes at range»)
                if R.up[q] && boss.phase < 2 { continue }
                bonus = m.cls == .gunner ? 8 : (m.cls == .assault ? 6 : 5)
            }
            let b = bossPartSlot(q)
            if b < 0 || S.dead[b] != 0 { continue }
            let dx = S.x[b] - m.x, dz = S.z[b] - m.z, d = (dx * dx + dz * dz).squareRoot()
            if d > range + S.r[b] { continue }
            let s = d + absf(angDiff(m.aim, atan2f2(dx, dz))) * 2.2 - bonus
            if s < bs { bs = s; best = b }
        }
        return best
    }

    /// The turret (its think's score: squared distance, lower is better): the head down (−500), a node not popped (−300) in
    /// its reach — a pinning Dropper still comes first. Updates `bd`, returns the slot when it beats it, else -1.
    func threaderTurretTarget(_ bd: inout Float) -> Int {
        let R = bossRT, S = bugs
        let r = turretRange()
        var best = -1
        var q = 0
        while q < R.parts {
            defer { q = q == 0 ? 1 + THREADER_SEGMENTS : q + 1 }
            var bonus: Float
            if q == 0 { if R.down[0] > 0 { bonus = 500 } else { continue } } else { if R.popped[q] { continue }; bonus = 300 }
            let b = bossPartSlot(q)
            if b < 0 || S.dead[b] != 0 { continue }
            let dx = S.x[b] - turret.x, dz = S.z[b] - turret.z, d2 = dx * dx + dz * dz
            if d2 > r * r { continue }
            let s = d2 - bonus
            if s < bd { bd = s; best = b }
        }
        return best
    }

    /// The player's aim assist (aimAssistTarget's score: higher is better): the head down or a node not popped in the cone
    /// round where it is drawn (up there: ≈ 0.75 h up-screen of its footprint). Updates `bs`, returns the slot or -1.
    func threaderAssist(_ m: Marine, _ dx: Float, _ dz: Float, _ bs: inout Float) -> Int {
        let R = bossRT, S = bugs
        var best = -1
        var q = 0
        while q < R.parts {
            defer { q = q == 0 ? 1 + THREADER_SEGMENTS : q + 1 }
            var bonus: Float
            if q == 0 { if R.down[0] > 0 { bonus = 2 } else { continue } } else { if R.popped[q] { continue }; bonus = 1 }
            let b = bossPartSlot(q)
            if b < 0 || S.dead[b] != 0 { continue }
            let lift = 0.75 * maxf(0, R.py[q] - level.groundY(R.px[q], R.pz[q]))
            let vx = S.x[b] + FWD_X * lift - m.x, vz = S.z[b] + FWD_Z * lift - m.z, d = hypotf2(vx, vz)
            if d < 0.6 || d > 17 { continue }
            let cs = (vx * dx + vz * dz) / d
            if cs < 0.92 || !isVisible(S.x[b], S.z[b]) { continue }
            let s = cs * 5 - d * 0.1 + bonus
            if s > bs { bs = s; best = b }
        }
        return best
    }

    /// Bugs in the circle for an ability's crowd (hash.queryCircle): the Threader's parts are no crowd. Without a Threader
    /// alive it is the query's own count.
    func deckCrowd(_ x: Float, _ z: Float, _ r: Float) -> Int {
        let n = hash.queryCircle(bugs, x, z, r)
        if !threaderActive { return n }
        let S = bugs
        var c = 0, q = 0
        while q < n {
            let b = hash.qb[q]
            if S.boss[b] == 0 || S.boss[b] == BOSS_BUG { c += 1 }
            q += 1
        }
        return c
    }

    // ---------------------------------------------------------------- abilities

    /// A bot's ability against it (botThink, ability ready): the Cryo's Ice Wave on the head down within 6.5 m (brittle), the
    /// Assault's grenade on a node of a coil once its ring shrinks (it lets go) or on the head down, the Pyro's napalm under a
    /// strike spot within 5 m (the head recoils), the Gunner's turret with a node within 14 m. True when it used it.
    func threaderAbility(_ m: Marine) -> Bool {
        let T = thr, R = bossRT, S = bugs
        let head = bossPartSlot(0)
        let headD: Float = head >= 0 && R.down[0] > 0 ? hypotf2(S.x[head] - m.x, S.z[head] - m.z) : .infinity
        switch m.cls {
        case .cryo:
            if headD < 6.5 * m.mods.arad { return useAbility(m, 0, 0) }
        case .assault:
            // (the coil: once its ring has closed and starts to shrink — the squad's way out, not its opening move)
            if T.mode == .coil && !T.letGo && !T.crushed && T.t >= 1.5 + BOT_REACT {
                var q = 1 + THREADER_SEGMENTS
                while q < R.parts {
                    let b = bossPartSlot(q)
                    if b >= 0 && !R.popped[q] {
                        let d = hypotf2(S.x[b] - m.x, S.z[b] - m.z)
                        if d > 3 && d < 13 { return useAbility(m, S.x[b], S.z[b]) }
                    }
                    q += 1
                }
            }
            if headD < 13 && headD > 4 { return useAbility(m, S.x[head], S.z[head]) }
        case .pyro:
            if T.mode == .strike && hypotf2(T.px - m.x, T.pz - m.z) < 5 { return useAbility(m, 0, 0) }
        case .gunner:
            var q = 1 + THREADER_SEGMENTS
            while q < R.parts {
                if !R.popped[q] && hypotf2(R.px[q] - m.x, R.pz[q] - m.z) < 14 { return useAbility(m, 0, 0) }
                q += 1
            }
        }
        return false
    }

    // ---------------------------------------------------------------- dodges

    /// A person's reaction for the autopilot in the player's seat: 0.3–0.65 s, spread by `key` (deterministic, no draw).
    @inline(__always) func threaderReact(_ key: Int) -> Float {
        let h = Float((UInt32(truncatingIfNeeded: key) &* 2_654_435_761) >> 8) / Float(1 << 24)
        return 0.3 + 0.35 * h
    }

    /// A sidestep (botThink applies it for `t` s over its own steering).
    @inline(__always) func threaderStep(_ m: Marine, _ x: Float, _ z: Float, _ t: Float = 0.35) {
        let l = hypotf2(x, z)
        if l < 1e-4 { return }
        m.ai.sideX = x / l; m.ai.sideZ = z / l; m.ai.sideT = max(m.ai.sideT, t)
    }

    /// Out of a lane from (ox, oz) along (dx, dz) `len` long and `half` wide (each side), with `pad` to spare: the step
    /// sideways (nil: not in it).
    func threaderLaneStep(_ m: Marine, _ ox: Float, _ oz: Float, _ dx: Float, _ dz: Float, _ len: Float, _ half: Float, pad: Float) -> Vec2? {
        let ex = m.x - ox, ez = m.z - oz, t = ex * dx + ez * dz
        if t < -pad || t > len + pad { return nil }
        let side = ex * dz - ez * dx
        if absf(side) > half + pad { return nil }
        let s: Float = side >= 0 ? 1 : -1
        return Vec2(dz * s, -dx * s)
    }

    /// The bots' and the autopilot's dodges (botThink, after the overhead's): the lure's light, the strike's ring, the coil,
    /// the rime lane, the squeeze's curtains, the pull-down's lane, a charge.
    func threaderDodge(_ m: Marine) {
        let T = thr, R = bossRT
        let auto = m.isPlayer
        // the lure: out of the light when its edge comes within 2 m (the autopilot: once it feels it — a person)
        if T.lureOn && T.locked < 0 && T.mode != .strike {
            let dx = m.x - T.lx, dz = m.z - T.lz, d = hypotf2(dx, dz)
            let near = auto ? (T.exposure[m.index] > threaderReact(T.stats.locks * 7 + m.index) * 0.6 || d < T.lr - 0.4)
                            : d < T.lr + THREADER_LURE_DODGE
            if near {
                if d > 0.05 { threaderStep(m, dx, dz, 0.3) } else { threaderStep(m, -sinf2(T.ang), -cosf2(T.ang), 0.3) }
            }
        }
        // the strike's closing ring: out of it (a dash in its last moment)
        for j in 0..<2 {
            let mv = j == 0 ? T.iStrike : T.iStrikeLow
            if mv < 0 || R.stage[mv] != 1 { continue }
            let wind = bossSpec.moves[mv].windUp
            let seen = wind - R.timer[mv]
            if seen < (auto ? threaderReact(T.stats.locks * 13 + 1) : BOT_REACT) { continue }
            let dx = m.x - T.px, dz = m.z - T.pz, d = hypotf2(dx, dz)
            if d >= THREADER_STRIKE_R + 0.7 { continue }
            let ux = d > 0.05 ? dx / d : sinf2(m.aim + 1.57), uz = d > 0.05 ? dz / d : cosf2(m.aim + 1.57)
            threaderStep(m, ux, uz, 0.4)
            if R.timer[mv] < 0.4 && d < THREADER_STRIKE_R + 0.3 { tryDash(m, ux, uz) }
        }
        // the coil: a dash out through a gap (the open gap if two segments froze; walking out through it otherwise)
        if T.mode == .coil && !T.letGo && !T.crushed && T.t >= (auto ? 0.5 : 0.25) {
            let dx = m.x - T.cx, dz = m.z - T.cz, d = hypotf2(dx, dz)
            if d < T.cr + 0.5 {
                var ux = d > 0.05 ? dx / d : 1, uz = d > 0.05 ? dz / d : 0
                if T.coilGap >= 0 && T.coilGap < R.parts {
                    let gx = R.px[T.coilGap] - T.cx, gz = R.pz[T.coilGap] - T.cz, gl = hypotf2(gx, gz)
                    if gl > 0.05 { ux = gx / gl; uz = gz / gl }
                } else {
                    // (through the middle of the nearest gap between two ring segments)
                    let a = atan2f2(ux, uz)
                    var best = a
                    var bd: Float = .infinity
                    var q = 1
                    while q <= THREADER_SEGMENTS && q < R.parts {
                        let ax = atan2f2(R.px[q] - T.cx, R.pz[q] - T.cz)
                        let mid = ax + 0.5 * (1.6 / maxf(0.5, T.cr))
                        let dd = absf(angDiff(a, mid))
                        if dd < bd { bd = dd; best = mid }
                        q += 1
                    }
                    ux = sinf2(best); uz = cosf2(best)
                }
                if m.dashCd <= 0 && (T.coilGap < 0 || d < 1) { tryDash(m, ux, uz) } else { threaderStep(m, ux, uz, 0.3) }
            }
        }
        // the rime lane
        if T.mode == .rime && T.iRime >= 0 && R.stage[T.iRime] == 1 {
            let mv = bossSpec.moves[T.iRime]
            if mv.windUp - R.timer[T.iRime] >= (auto ? threaderReact(T.stats.rimes * 5 + 2) : BOT_REACT),
               let s = threaderLaneStep(m, R.ax[T.iRime], R.az[T.iRime], R.adx[T.iRime], R.adz[T.iRime], mv.length, mv.radius * 0.5, pad: 0.6) {
                threaderStep(m, s.x, s.y, 0.35)
            }
        }
        // the squeeze's curtains (warning or venting)
        if T.mode == .squeeze, let A = level.layout.manifold, T.sqTrunk >= 0 {
            let tr = A.trunks[T.sqTrunk]
            for k in 0..<tr.bursts.count {
                let ts = threaderBurstStart(k, tr.bursts.count)
                let tt = T.sqT - ts
                if tt < (auto ? 0.4 : 0.2) || tt > THREADER_SQUEEZE_WARN + THREADER_SQUEEZE_VENT { continue }
                let (a, b) = threaderBurstSpan(tr, k, A)
                let dx = b.x - a.x, dz = b.y - a.y, l = maxf(0.1, hypotf2(dx, dz))
                if let s = threaderLaneStep(m, a.x, a.y, dx / l, dz / l, l, A.burstWidth, pad: 0.6) { threaderStep(m, s.x, s.y, 0.35) }
            }
        }
        // the pull-down's lane
        if T.mode == .pull, let A = level.layout.manifold, T.pullTrunk >= 0, T.t >= (auto ? 0.5 : 0.3) {
            let tr = A.trunks[T.pullTrunk], d = tr.dir
            let half = T.iPull >= 0 ? bossSpec.moves[T.iPull].radius * 0.5 : 1.6
            if let s = threaderLaneStep(m, tr.a.x, tr.a.y, d.x, d.y, tr.length, half, pad: 0.7) { threaderStep(m, s.x, s.y, 0.4) }
        }
        // a charge: out of its way
        if T.mode == .charge {
            let fx = sinf2(T.hd), fz = cosf2(T.hd)
            if let s = threaderLaneStep(m, R.headX, R.headZ, fx, fz, 9, 1.4, pad: 0.4) {
                threaderStep(m, s.x, s.y, 0.35)
                if T.iCharge >= 0 && R.stage[T.iCharge] == 2 && hypotf2(m.x - R.headX, m.z - R.headZ) < 4.5 { tryDash(m, s.x, s.y) }
            }
        }
    }

    // ---------------------------------------------------------------- places

    /// The autopilot's place in the fight (the BOSS step's objective point while the Threader is its boss): a corner of the
    /// pump housing away from the lure's light, or 5 m from the head while it is down (in reach). nil: the zone's centre.
    func threaderObjective(_ b: BossStep) -> Vec2? {
        guard b.boss == .threader, stepPhase == .active, case .circle(let cx, let cz, let r) = b.zone else { return nil }
        let T = thr, P = marines[0]
        if boss.alive && T.mode == .down {
            var dx = P.x - T.px, dz = P.z - T.pz
            let d = hypotf2(dx, dz)
            if d > 0.05 { dx /= d; dz /= d } else { dx = 1; dz = 0 }
            let gx = T.px + dx * 5, gz = T.pz + dz * 5
            if level.canStand(gx, gz) { return Vec2(gx, gz) }
        }
        let sr = max(1.2, min(5.2, r * 0.55))
        var best = Vec2(cx + sr * 0.7071, cz + sr * 0.7071)
        var bd: Float = -1
        for k in 0..<4 {
            let a = Float.pi / 4 + Float(k) * Float.pi / 2
            let p = Vec2(cx + cosf2(a) * sr, cz + sinf2(a) * sr)
            if !level.canStand(p.x, p.y) { continue }
            // (away from the light; a little toward where the player already is)
            let away = T.lureOn ? hypotf2(p.x - T.lx, p.y - T.lz) : 6
            let s = minf(away, 6) * 2 - hypotf2(p.x - P.x, p.y - P.z) * 0.3
            if s > bd { bd = s; best = p }
        }
        return best
    }

    /// A bot's own place while the Threader lives (nil: its place round the island): the Pyro closes in on the head while it is
    /// down (4.5 m: the torch's reach).
    func threaderBotGoal(_ m: Marine) -> Vec2? {
        let T = thr
        guard m.cls == .pyro, T.mode == .down else { return nil }
        var dx = m.x - T.px, dz = m.z - T.pz
        let d = hypotf2(dx, dz)
        if d < 6 { return nil }
        dx /= d; dz /= d
        let gx = T.px + dx * 4.5, gz = T.pz + dz * 4.5
        return level.canStand(gx, gz) ? Vec2(gx, gz) : nil
    }
}

extension Game {
    /// One line of the boss's state for a trace (calibration `--trace`, tests): its health, place, mode and the squad's.
    public var bossTraceState: String {
        let R = bossRT
        var s = String(format: "%@ hp=%.0f%% head=(%.1f, %.1f, %.1f)", boss.kind.rawValue, bossHpFraction * 100, R.headX, R.headY, R.headZ)
        if boss.kind == .threader {
            let T = thr
            s += " mode=\(T.mode) e=\(T.e)" + String(format: " s=%.1f lure=(%.1f, %.1f)", T.s, T.lx, T.lz)
            s += " light=" + T.exposure.map { String(format: "%.1f", $0) }.joined(separator: "/")
            let st = T.stats
            s += String(format: " dmg h/n/b=%.0f/%.0f/%.0f p=%.0f/%.0f/%.0f", st.dmgHead, st.dmgNode, st.dmgBody, st.dmgP1, st.dmgP2, st.dmgP3)
        }
        s += " squad=" + marines.map { $0.downed ? "D" : String(format: "(%.0f,%.0f)", $0.x, $0.z) }.joined(separator: " ")
        return s
    }
}
