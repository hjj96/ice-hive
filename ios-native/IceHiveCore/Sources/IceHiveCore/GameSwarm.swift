import Foundation

// ================================================================
//  SWARM LOGIC — spawning, damage, explosions, acid globs and the
//  per-tick bug update (port of 05-sim.js)
// ================================================================
// Loops over query results are `while` loops: `for … in 0..<n` is slow in unoptimised (Debug) builds.
extension Game {

    // ---------- spawning ----------
    /// mode 0: on the floor; 1: climbing up the platform side from the abyss and over the railing
    /// (nx, nz = outward normal, depth = how far below the deck it starts); 2: bursting from a vent.
    @discardableResult
    func spawnBug(_ type: UInt8, _ x: Float, _ z: Float, mode: Int = 0, nx: Float = 0, nz: Float = 0, depth: Float = 1.8) -> Int {
        let S = bugs
        if S.count >= S.capacity { return -1 }
        let i = S.count
        S.count += 1
        let T = BUG_SPECS[Int(type)]
        if type != T_RUN && !seen[Int(type)] && !attract && !simOnly {
            seen[Int(type)] = true
            toast(T.name + ": " + BUG_TIPS[Int(type)], .warn)
            emit(.bugSeen(type: BugType(rawValue: Int(type)) ?? .runner))
        }
        let k = 0.88 + rng.next() * 0.24
        S.type[i] = type; S.ms[i] = T.mass; S.dead[i] = 0; S.hit[i] = 0; S.bsrc[i] = -1; S.uid[i] = S.uidSeq; S.uidSeq &+= 1
        S.r[i] = T.radius * k; S.sc[i] = T.scale * k; S.spd[i] = T.speed * (0.85 + rng.next() * 0.3)
        // fodder is fodder: runners keep the tier's flat runner HP (13.2–16.8), so one rifle bolt always kills them; every
        // other type scales with the director's HP multiplier (the bench keeps its 1e5 multiplier on every type; the legacy
        // v1.0 row scales runners too)
        let rh = difficulty.runnerHp
        let base: Float = type == T_RUN ? (rh > 0 ? rh * (simOnly ? hpMul : 1) : 18 * hpMul) : T.hp * hpMul
        let hpv = base * (type == T_BRUTE ? 1 : k)
        S.hp[i] = hpv; S.hpMax[i] = hpv
        S.vx[i] = 0; S.vz[i] = 0; S.cd[i] = rng.next() * T.atkCd
        S.chill[i] = 0; S.frz[i] = 0; S.burn[i] = 0; S.fl[i] = 0
        S.ph[i] = rng.next() * TAU; S.vr[i] = rng.next()
        if mode == 1 {
            S.st[i] = S_CLIMB; S.t[i] = 4; S.x[i] = x + nx * 0.85; S.z[i] = z + nz * 0.85; S.y[i] = -depth
            S.ax[i] = -nx; S.az[i] = -nz; S.hd[i] = atan2f2(-nx, -nz)
        } else if mode == 2 {
            let a = rng.next() * TAU
            S.st[i] = S_CLIMB; S.t[i] = 0.45
            S.x[i] = x + (rng.next() - 0.5) * 0.8; S.z[i] = z + (rng.next() - 0.5) * 0.8; S.y[i] = -0.9
            S.ax[i] = cosf2(a); S.az[i] = sinf2(a); S.hd[i] = atan2f2(S.ax[i], S.az[i])
        } else {
            S.st[i] = S_MOVE; S.t[i] = 0; S.x[i] = x; S.z[i] = z; S.y[i] = 0; S.hd[i] = rng.next() * TAU; S.ax[i] = 0; S.az[i] = 0
        }
        S.px[i] = S.x[i]; S.pz[i] = S.z[i]
        return i
    }

    // ---------- damage ----------
    /// dot = continuous damage (burn, flame, beam): no hit flash. Returns true when the bug died.
    @discardableResult
    func hitBug(_ i: Int, _ dmg0: Float, _ src: Int, _ dot: Bool = false) -> Bool {
        let S = bugs
        if S.dead[i] != 0 { return false }
        var dmg = dmg0
        if S.frz[i] > 0 { dmg *= 2.5 }
        S.hp[i] -= dmg
        if !dot && S.fl[i] < 0.6 { S.fl[i] = 0.6 }
        if S.hp[i] <= 0 { killBug(i, src); return true }
        return false
    }

    func killBug(_ i: Int, _ src: Int) {
        let S = bugs
        S.dead[i] = 1; S.deadPending += 1
        let x = S.x[i], z = S.z[i], ty = S.type[i]
        let frozen = S.frz[i] > 0
        let isQueen = queen.alive && S.uid[i] == queen.uid
        if isQueen { xp += 60 }   // before onBugKilled, so its level-up loop counts the bounty
        onBugKilled(ty, src, x, z)
        if isQueen { queenKilled(x, z) }
        else if ty == T_BOOM { queueBoom(x, z, 3.1, 70, src, .boomer) }
        else if ty == T_BRUTE && !simOnly && src >= 0 && hypotf2(x - marines[0].x, z - marines[0].z) < 16 { hitStop(0.085, 0.12) }
        else if frozen {
            let sh: Float = (src >= 0 && src < 4) ? marines[src].mods.shatter : 1
            queueBoom(x, z, 1.7 * sh, 24 * sh, src, .frost)
        }
        if !simOnly {
            events.append(.bugKilled(type: BugType(rawValue: Int(ty)) ?? .runner, pos: Vec2(x, z), frozen: frozen, source: src,
                                     heading: S.hd[i], scale: S.sc[i], height: S.y[i]))
            if frozen { sound(.shatter, x, z) }
            else {
                if ty == T_BRUTE { sound(.thud, x, z) }
                sound(.squish, x, z)
            }
        }
        if ty == T_BRUTE && !isQueen && rng.next() < difficulty.medkitChance { dropMedkit(x, z) }
    }

    // ---------- explosions (deferred, so chain reactions ripple tick by tick) ----------
    func queueBoom(_ x: Float, _ z: Float, _ r: Float, _ dmg: Float, _ src: Int, _ kind: ExplosionKind) {
        if booms.count < 48 { booms.append(Boom(x: x, z: z, r: r, dmg: dmg, src: src, kind: kind)) }
    }

    func processBooms() {
        let n = booms.count
        if n == 0 { return }
        let S = bugs
        let qUid = queen.uid
        do {
            var k = 0
            while k < n {
                defer { k += 1 }
                let e = booms[k]
                let cnt = hash.queryCircle(S, e.x, e.z, e.r)
                let pulse = e.kind == .pulse
                let knock: Float = e.kind == .frost ? 2 : (pulse ? 5 : 11)
                let falloff = difficulty.pulseFalloff
                do {
                    var q = 0
                    while q < cnt {
                        defer { q += 1 }
                        let b = hash.qb[q]
                        // the Матка shrugs off the lift pulse, frost and knockback
                        let qb = S.uid[b] == qUid
                        if qb && pulse { continue }
                        let dx = S.x[b] - e.x, dz = S.z[b] - e.z, d = (dx * dx + dz * dz).squareRoot() + 1e-4
                        // the lift pulse fades toward the rim on the harder tiers (no binary deck wipe)
                        let f: Float = pulse ? 1 - falloff * minf(1, d / e.r) : 1 - 0.55 * minf(1, d / e.r)
                        if e.kind == .frost && !qb { S.chill[b] = minf(1, S.chill[b] + 0.45) }
                        if S.type[b] != T_BRUTE { S.vx[b] += dx / d * knock * f; S.vz[b] += dz / d * knock * f }
                        hitBug(b, e.dmg * f, e.src)
                    }
                }
                if e.kind == .boomer {
                    for m in marines {
                        let dx = m.x - e.x, dz = m.z - e.z, d = hypotf2(dx, dz)
                        if d < e.r + 0.4 {
                            hurtMarine(m, BUG_SPECS[3].dmg * dmgMul * (1 - 0.5 * d / (e.r + 0.4)), dx / (d + 0.01) * 7, dz / (d + 0.01) * 7, .boomer)
                        }
                    }
                }
                if !simOnly { explosionFx(e.x, e.z, e.r, e.kind) }
            }
        }
        booms.removeFirst(n)
    }

    /// Presentation side of fxExplosion: event, sound, telegraph rings, shake / flash / hit-stop by distance to the player.
    func explosionFx(_ x: Float, _ z: Float, _ r: Float, _ kind: ExplosionKind) {
        events.append(.explosion(kind: kind, pos: Vec2(x, z), radius: r))
        switch kind {
        case .pulse:
            teleRing(x, z, 1, 0.2, 1.0, 0.85, 0.45, r1: r, pulse: false, cause: .pulse)
            teleRing(x, z, 1, 0.1, 0.5, 0.45, 0.7, r1: r * 0.95, pulse: false, cause: .pulse)
            sound(.shock, x, z)
        case .frost:
            break
        case .frag, .boomer, .mini:
            let big = kind.isBig
            let P = marines[0]
            let d = hypotf2(P.x - x, P.z - z)
            shake((big ? 0.11 : 0.06) * r * clampf(1 - d / 26, 0, 1))
            if big && d < 9 {
                emit(.screenFlash(amount: 0.25 * (1 - d / 9)))
                if kind == .frag ? d < 8 : d < 3.5 { hitStop(0.05, 0.3) }
                haptic(.medium)
            }
            sound(big ? .explode : .pop, x, z)
        }
    }

    // ---------- acid globs (spitters) ----------
    func launchGlob(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float) {
        let G = globs
        if G.count >= AcidGlobs.capacity { return }
        let k = G.count
        G.count += 1
        G.x0[k] = x0; G.z0[k] = z0; G.x1[k] = x1; G.z1[k] = z1; G.t[k] = 0; G.dur[k] = 0.95
        if !simOnly { emit(.acidLaunched(from: Vec2(x0, z0), to: Vec2(x1, z1))); sound(.spit, x0, z0) }
    }

    func updateGlobs(_ dt: Float) {
        let G = globs
        var k = 0
        while k < G.count {
            G.t[k] += dt
            if G.t[k] < G.dur[k] { k += 1; continue }
            let x = G.x1[k], z = G.z1[k]
            for m in marines {
                let d = hypotf2(m.x - x, m.z - z)
                // (the Матка's volley globs count as spitter acid, like the web)
                if d < 1.5 { hurtMarine(m, BUG_SPECS[1].dmg * dmgMul, 0, 0, .spitter) }
            }
            if !simOnly { emit(.acidSplash(pos: Vec2(x, z))); sound(.acid, x, z) }
            G.count -= 1
            let l = G.count
            G.x0[k] = G.x0[l]; G.z0[k] = G.z0[l]; G.x1[k] = G.x1[l]; G.z1[k] = G.z1[l]; G.t[k] = G.t[l]; G.dur[k] = G.dur[l]
        }
    }

    // ---------- per-tick swarm update ----------
    func simBugs(_ dt: Float) {
        let S = bugs, H = hash, L = level
        var anyUp = false
        do {
            var k = 0
            while k < 4 {
                defer { k += 1 }
                let m = marines[k]
                mX[k] = m.x; mZ[k] = m.z; mUp[k] = m.downed ? 0 : 1
                if !m.downed { anyUp = true }
                crowd[k] = 0
            }
        }
        let n = S.count
        let X = S.x, Z = S.z, VX = S.vx, VZ = S.vz, Y = S.y, R = S.r, SPD = S.spd, SC = S.sc
        let T = S.t, CD = S.cd, CHILL = S.chill, FRZ = S.frz, BURN = S.burn, PH = S.ph, HD = S.hd, FL = S.fl
        let AX = S.ax, AZ = S.az, VR = S.vr, MS = S.ms, TY = S.type, ST = S.st, DEAD = S.dead, HIT = S.hit, BSRC = S.bsrc
        let hStart = H.start, hItems = H.items, hCell = H.cell
        let hashN = H.hashedCount
        let walk = L.walk, liftCell = L.liftCell
        let flowX = swarmFlow.x, flowZ = swarmFlow.z
        let MX = mX, MZ = mZ, MUP = mUp, CROWD = crowd
        let G = GRID
        let GH = GRID_HALF
        let GF = Float(GRID)
        var ta0 = 0, ta1 = 0, ta2 = 0, ta3 = 0
        var ci = 0
        while ci < n {
            let i = ci
            ci += 1
            if DEAD[i] != 0 { continue }
            switch TY[i] { case 0: ta0 += 1; case 1: ta1 += 1; case 2: ta2 += 1; default: ta3 += 1 }
        }
        typeAlive[0] = ta0; typeAlive[1] = ta1; typeAlive[2] = ta2; typeAlive[3] = ta3
        let spreadRate = 1.4 * pyroSpread()
        // burn damage multiplier of each possible igniter (index src + 1, 0 = no marine)
        let BURNMUL = burnMulScratch
        BURNMUL[0] = 1
        do { var k = 0; while k < 4 { BURNMUL[k + 1] = marines[k].mods.burn; k += 1 } }
        let quiet = simOnly
        let liftFall = stage == .extract && extractT > 0.4
        let dmgMulL = dmgMul
        let UID = S.uid
        // the Матка: her melee runs on its own clock (qMeleeCd), her charge hits count as hers
        let qUid = queen.uid
        // hive pressure / AFK: part of the swarm hunts the player (even uids at idleMul ≥ 1.5, uid % 3 ≠ 0 after 12 s AFK)
        let huntP = huntPressure, huntA = huntAfk
        let anyHunt = MUP[0] != 0 && (huntP || huntA)

        let burnDps = CLASS_SPECS[1].burnDps
        var iNext = 0
        while iNext < n {
            let i = iNext
            iNext += 1
            if DEAD[i] != 0 { continue }
            let ty = TY[i]
            if FL[i] > 0 { FL[i] -= dt * 4 }
            // --- status effects ---
            if BURN[i] > 0 {
                BURN[i] -= dt
                let src = Int(BSRC[i])
                if hitBug(i, burnDps * BURNMUL[(src >= 0 && src < 4) ? src + 1 : 0] * dt, src, true) { continue }
                if rng.next() < spreadRate * dt {
                    let c = i < hashN ? hCell[i] : Level.cellClamp(X[i], Z[i])
                    let e = hStart[c + 1]
                    var kk = hStart[c]
                    while kk < e {
                        let o = hItems[kk]; kk += 1
                        if o != i && DEAD[o] == 0 && BURN[o] <= 0 { BURN[o] = 2.5; BSRC[o] = Int8(truncatingIfNeeded: src); break }
                    }
                }
            }
            if FRZ[i] > 0 {
                FRZ[i] -= dt; VX[i] = 0; VZ[i] = 0
                if FRZ[i] <= 0 { CHILL[i] = 0.5 }
                continue
            }
            if CHILL[i] > 0 { CHILL[i] = maxf(0, CHILL[i] - dt * 0.4) }
            let x = X[i], z = Z[i]
            let st = ST[i]
            let fx0 = x + GH, fz0 = z + GH
            // cell of the bug (-1 outside the grid), inlined: this loop runs for every bug every tick
            let c0 = (fx0 >= 0 && fx0 < GF && fz0 >= 0 && fz0 < GF) ? Int(fz0) &* G &+ Int(fx0) : -1
            if liftFall && liftCell[Level.cellClamp(x, z)] != 0 {
                Y[i] -= dt * (4 + (-Y[i]) * 3); PH[i] += dt * 20
                if Y[i] < -12 { DEAD[i] = 1; S.deadPending += 1 }
                continue
            }
            // --- climbing up the side of the platform, cresting over the railing / bursting from a vent ---
            if st == S_CLIMB {
                T[i] -= dt; PH[i] += dt * 14
                var y = Y[i]
                if y < -0.85 { y += dt * (2.8 + VR[i]) }
                else { y += dt * 2.4; X[i] = x + AX[i] * 2.6 * dt; Z[i] = z + AZ[i] * 2.6 * dt }
                if y >= 0 || T[i] <= 0 { y = 0; ST[i] = S_MOVE; VX[i] = AX[i] * 2; VZ[i] = AZ[i] * 2 }
                Y[i] = y
                continue
            }
            // --- pick target marine ---
            var best = 0
            var bd: Float = 1e9
            var k = 0
            let u = UID[i]
            let hunt = anyHunt && ((huntP && (u & 1) == 0) || (huntA && u % 3 != 0))
            while k < 4 {
                if !(anyUp && MUP[k] == 0) && !(hunt && k != 0) {
                    let dx = MX[k] - x, dz = MZ[k] - z, d2 = dx * dx + dz * dz
                    if d2 < bd { bd = d2; best = k }
                }
                k += 1
            }
            let dist = bd.squareRoot() + 1e-4
            let tx = (MX[best] - x) / dist, tz = (MZ[best] - z) / dist
            var ddx: Float, ddz: Float
            if dist < 5.5 || c0 < 0 || (flowX[c0] == 0 && flowZ[c0] == 0) { ddx = tx; ddz = tz }
            else { ddx = flowX[c0]; ddz = flowZ[c0] }
            var speed = SPD[i] * (1 - 0.6 * CHILL[i]) * (BURN[i] > 0 ? 1.15 : 1)
            if CD[i] > 0 { CD[i] -= dt }
            var acc: Float = 9
            // --- type behaviours ---
            if ty == T_SPIT {
                if st == S_MOVE {
                    if dist < 11 && dist > 3.2 && CD[i] <= 0 && anyUp {
                        let m = marines[best]
                        let ax = MX[best] + m.vx * 0.8 + (rng.next() - 0.5) * 1.2
                        let az = MZ[best] + m.vz * 0.8 + (rng.next() - 0.5) * 1.2
                        ST[i] = S_WIND; T[i] = 0.5; AX[i] = ax; AZ[i] = az
                        if !quiet {
                            teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, 1.45, cause: .acidTarget)
                            teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, 1.45, cause: .acidTarget)
                        }
                    } else if dist < 4 { ddx = -tx; ddz = -tz; speed *= 0.8 }
                    else if dist < 10 && CD[i] > 0.4 { speed *= 0.25 }
                } else {
                    speed = 0
                    T[i] -= dt
                    if T[i] <= 0 { launchGlob(x, z, AX[i], AZ[i]); ST[i] = S_MOVE; CD[i] = 2.8 + rng.next() * 1.6 }
                }
            } else if ty == T_BRUTE {
                if st == S_MOVE {
                    if dist < 9.5 && dist > 2.4 && CD[i] <= 0 && anyUp {
                        ST[i] = S_WIND; T[i] = 0.8; AX[i] = tx; AZ[i] = tz; HIT[i] = 0
                        if !quiet { teleLane(x, z, tx, tz, 12, 2.3, 0.8, 0.9); sound(.roar, x, z) }
                    }
                } else if st == S_WIND {
                    speed = 0; ddx = AX[i]; ddz = AZ[i]
                    T[i] -= dt
                    if T[i] <= 0 { ST[i] = S_CHARGE; T[i] = 0.9 }
                } else if st == S_CHARGE {
                    ddx = AX[i]; ddz = AZ[i]; speed = 12.5; acc = 30
                    T[i] -= dt
                    do {
                        var k = 0
                        while k < 4 {
                            defer { k += 1 }
                            if MUP[k] == 0 || (HIT[i] & UInt8(1 << k)) != 0 { continue }
                            let dx = MX[k] - x, dz = MZ[k] - z
                            let rr = R[i] + 0.6
                            if dx * dx + dz * dz < rr * rr {
                                HIT[i] |= UInt8(1 << k)
                                hurtMarine(marines[k], 16 * dmgMulL, AX[i] * 13, AZ[i] * 13, u == qUid ? .queen : .brute)
                            }
                        }
                    }
                    if T[i] <= 0 { ST[i] = S_MOVE; CD[i] = 5 + rng.next() * 3 }
                }
            } else if ty == T_BOOM {
                if st == S_MOVE && dist < 2.4 && anyUp {
                    ST[i] = S_SWELL; T[i] = 0.8
                    if !quiet { teleRing(x, z, 3.1, 1.0, 0.45, 0.1, 0.8, cause: .boomerSwell); sound(.swell, x, z) }
                } else if st == S_SWELL {
                    speed *= 0.35; T[i] -= dt
                    if T[i] <= 0 { killBug(i, -1); continue }
                }
            }
            // --- steering ---
            let k1 = minf(1, acc * dt)
            var vx = VX[i] + (ddx * speed - VX[i]) * k1
            var vz = VZ[i] + (ddz * speed - VZ[i]) * k1
            // --- separation (the 2x2 cells nearest the bug's sub-cell position, at most 16 live neighbours) ---
            let ri = R[i], mi = MS[i]
            var px: Float = 0, pz: Float = 0
            var checks = 0
            let hc = i < hashN ? hCell[i] : Level.cellClamp(x, z)
            let hi = hc % G, hj = hc / G
            let di0 = (x + GH - Float(hi)) < 0.5 ? -1 : 0
            let dj0 = (z + GH - Float(hj)) < 0.5 ? -1 : 0
            var dj = dj0
            sep: while dj <= dj0 + 1 {
                let j = hj + dj
                dj += 1
                if j < 0 || j >= G { continue }
                var di = di0
                while di <= di0 + 1 {
                    let ii = hi + di
                    di += 1
                    if ii < 0 || ii >= G { continue }
                    let c = j * G + ii
                    let e = hStart[c + 1]
                    var kk = hStart[c]
                    while kk < e {
                        let o = hItems[kk]; kk += 1
                        if o == i || DEAD[o] != 0 { continue }
                        let dx = x - X[o], dz = z - Z[o], rr = ri + R[o], d2 = dx * dx + dz * dz
                        if d2 < rr * rr && d2 > 1e-8 {
                            let d = d2.squareRoot(), mo = MS[o]
                            let w = (rr - d) / d * (mo / (mi + mo))
                            px += dx * w; pz += dz * w
                        }
                        checks += 1
                        if checks >= 16 { break sep }
                    }
                }
            }
            // --- marines are solid; bugs pressing on them slow them down ---
            k = 0
            while k < 4 {
                let dx = x - MX[k], dz = z - MZ[k], rr = ri + 0.42, d2 = dx * dx + dz * dz
                if d2 < (rr + 0.5) * (rr + 0.5) {
                    if MUP[k] != 0 { CROWD[k] += mi }
                    if d2 < rr * rr && d2 > 1e-8 { let d = d2.squareRoot(), w = (rr - d) / d; px += dx * w; pz += dz * w }
                }
                k += 1
            }
            let pl = hypotf2(px, pz)
            if pl > 0.14 { px *= 0.14 / pl; pz *= 0.14 / pl }
            var nx = x + vx * dt + px * 0.65, nz = z + vz * dt + pz * 0.65
            if c0 >= 0 && walk[c0] == 1 && !walkAt(walk, nx, nz) {
                if walkAt(walk, nx, z) { nz = z; vz *= 0.3 }
                else if walkAt(walk, x, nz) { nx = x; vx *= 0.3 }
                else {
                    nx = x; nz = z; vx *= -0.2; vz *= -0.2
                    if st == S_CHARGE { ST[i] = S_MOVE; CD[i] = 4 }
                }
            }
            X[i] = nx; Z[i] = nz; VX[i] = vx; VZ[i] = vz
            // --- melee ---
            // (the Матка bites ×1.6 on her own clock: her cd only gates the ram, see queenTick)
            let qm = u == qUid
            if dist < ri + 0.62 && (qm ? qMeleeCd <= 0 : CD[i] <= 0) && ST[i] == S_MOVE && ty != T_BOOM && MUP[best] != 0 {
                // attack slots: only a few small bugs can land a bite per second on one marine
                let mm = marines[best]
                if ty == T_BRUTE || mm.bite >= 1 {
                    if ty != T_BRUTE { mm.bite -= 1 }
                    let kb: Float = ty == T_BRUTE ? 6 : 0.6
                    hurtMarine(mm, BUG_SPECS[Int(ty)].dmg * dmgMulL * (qm ? 1.6 : 1), tx * kb, tz * kb, qm ? .queen : DamageSource(bugType: ty))
                    let cd = BUG_SPECS[Int(ty)].atkCd * (0.8 + rng.next() * 0.4)
                    if qm { qMeleeCd = cd } else { CD[i] = cd }
                    PH[i] += 1.5
                } else { CD[i] = 0.15 + rng.next() * 0.2 }
            }
            // --- heading + gait phase ---
            let sp2 = vx * vx + vz * vz, stN = ST[i]
            var want: Float = 0
            var hasWant = false
            if stN == S_WIND {
                want = ty == T_SPIT ? atan2f2(AX[i] - x, AZ[i] - z) : atan2f2(AX[i], AZ[i]); hasWant = true
            } else if sp2 > 0.09 { want = atan2f2(vx, vz); hasWant = true }
            if hasWant { HD[i] += angDiff(HD[i], want) * minf(1, 10 * dt) }
            PH[i] += sp2.squareRoot() * dt * 8 / SC[i]
        }
    }

    /// Floor cell at (x, z) is walkable (inline helper of the swarm loop).
    @inline(__always) func walkAt(_ walk: UnsafeMutablePointer<UInt8>, _ x: Float, _ z: Float) -> Bool {
        let fx = x + GRID_HALF, fz = z + GRID_HALF
        if !(fx >= 0 && fx < Float(GRID) && fz >= 0 && fz < Float(GRID)) { return false }
        return walk[Int(fz) &* GRID &+ Int(fx)] == 1
    }

    func pyroSpread() -> Float { pyroIdx >= 0 ? marines[pyroIdx].mods.burn : 1 }
    func pyroBurnMul(_ src: Int) -> Float { (src >= 0 && src < 4) ? marines[src].mods.burn : 1 }

    // ---------- medkits ----------
    func dropMedkit(_ x: Float, _ z: Float) {
        guard let k = medkits.firstIndex(where: { !$0.active }) else { return }
        if !level.walkable(x, z) { return }
        medkits[k].active = true; medkits[k].x = x; medkits[k].z = z; medkits[k].t = 30
        emit(.medkitDropped(pos: Vec2(x, z)))
    }

    func updateMedkits(_ dt: Float) {
        for k in 0..<medkits.count where medkits[k].active {
            medkits[k].t -= dt
            if medkits[k].t <= 0 { medkits[k].active = false; continue }
            let kx = medkits[k].x, kz = medkits[k].z
            var best: Marine? = nil
            var bd: Float = 1.7
            for m in marines {
                if m.downed || m.hp >= m.maxHp { continue }
                let d = hypotf2(m.x - kx, m.z - kz)
                if d < bd { bd = d; best = m }
            }
            if let b = best {
                b.hp = min(b.maxHp, b.hp + 40); medkits[k].active = false
                if !simOnly {
                    emit(.healed(marine: b.index, amount: 40, pos: Vec2(kx, kz)))
                    sound(.heal, kx, kz, b.isPlayer)
                    if b.isPlayer { toast("Аптечка +40", .gold) }
                }
            }
        }
    }
}
