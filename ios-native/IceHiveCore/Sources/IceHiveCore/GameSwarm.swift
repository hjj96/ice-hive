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
            let bt = BugType(rawValue: Int(type)) ?? .runner
            if let tip = GameText.bugTip(bt) { toast(tip, .warn) }
            emit(.bugSeen(type: bt))
        }
        let k = 0.88 + rng.next() * 0.24
        S.type[i] = type; S.ms[i] = T.mass; S.dead[i] = 0; S.hit[i] = 0; S.bsrc[i] = -1; S.uid[i] = S.uidSeq; S.uidSeq &+= 1
        S.up[i] = 0; S.re[i] = 0   // (not on the overhead: GameOverhead.spawnRouteBug sets these after)
        S.boss[i] = 0   // (not a boss's: GameBoss.bossSpawn marks its body after)
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
        S.mood[i] = M_CALM; S.mdx[i] = 0; S.mdz[i] = 0
        // (the wave arrays only draw from the RNG on the wave pacing: the legacy stream replays v1.0 bit for bit)
        if difficulty.waves { S.mt[i] = rng.next() * 2; S.lt[i] = 0.5 + rng.next() } else { S.mt[i] = 0; S.lt[i] = 0 }
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

    /// Stage 2 B1: a slot for part `part` of a boss's chain body at (x, absolute height y, z) — no random draw, no
    /// first-sighting tip (every Swarm array set, as spawnBug does): state `.boss` (the swarm's AI never moves it; the boss
    /// places it every tick), heavy (the swarm flows round it), its own health `hp`.
    func spawnBossPart(_ type: UInt8, _ x: Float, _ z: Float, _ y: Float, _ r: Float, _ sc: Float, hp: Float, part: Int) -> Int {
        let S = bugs
        if S.count >= S.capacity { return -1 }
        let i = S.count
        S.count += 1
        S.type[i] = type; S.ms[i] = 40; S.dead[i] = 0; S.hit[i] = 0; S.bsrc[i] = -1; S.uid[i] = S.uidSeq; S.uidSeq &+= 1
        S.up[i] = 0; S.re[i] = 0; S.rs[i] = 0; S.rx[i] = x; S.ry[i] = y; S.rz[i] = z
        S.boss[i] = UInt8(clamping: part + 1)
        S.r[i] = r; S.sc[i] = sc; S.spd[i] = 0
        S.hp[i] = hp; S.hpMax[i] = hp
        S.vx[i] = 0; S.vz[i] = 0; S.cd[i] = 0
        S.chill[i] = 0; S.frz[i] = 0; S.burn[i] = 0; S.fl[i] = 0
        S.ph[i] = 0; S.vr[i] = 0.5
        S.mood[i] = M_CALM; S.mdx[i] = 0; S.mdz[i] = 0; S.mt[i] = 0; S.lt[i] = 0
        S.st[i] = S_BOSS; S.t[i] = 0; S.x[i] = x; S.z[i] = z; S.y[i] = y; S.hd[i] = 0; S.ax[i] = 0; S.az[i] = 0
        S.px[i] = x; S.pz[i] = z
        return i
    }

    // ---------- damage ----------
    /// dot = continuous damage (burn, flame, beam): no hit flash. `dir`: the hit's direction (a round's flight, a blast's
    /// push) — a boss part struck from behind takes its `rearK`. Returns true when the bug died (a boss part: the boss).
    @discardableResult
    func hitBug(_ i: Int, _ dmg0: Float, _ src: Int, _ dot: Bool = false, dir: Vec2? = nil) -> Bool {
        let S = bugs
        if S.dead[i] != 0 { return false }
        var dmg = dmg0
        if S.frz[i] > 0 { dmg *= 2.5 }
        // Stage 2 B1: a part of a boss's chain body routes the hit to the boss bar (its multipliers, its pool)
        let bb = S.boss[i]
        if bb != 0 && bb != BOSS_BUG { return bossPartHit(i, Int(bb) - 1, dmg, src, dot, dir) }
        S.hp[i] -= dmg
        if !dot && S.fl[i] < 0.6 { S.fl[i] = 0.6 }
        if S.hp[i] <= 0 { killBug(i, src); return true }
        // Stage 1 R4: a Dropper pinning a marine lets go once it has taken PIN_BREAK damage (the squad got it off)
        if S.st[i] == S_PIN { pinDamage(i, dmg, src) }
        return false
    }

    func killBug(_ i: Int, _ src: Int) {
        let S = bugs
        // the overhead (Stage 1 R2): its drop telegraph goes with it; its height is absolute up there (R4: a pinning Dropper
        // lets its marine go, a perched spitter frees its perch)
        // (Stage 2 B1: a boss's chain part keeps an absolute height too, but it is no route bug)
        let routeSt = S.st[i] >= S_HIGH
        let hKill: Float = routeSt ? S.y[i] - level.groundY(S.x[i], S.z[i]) : S.y[i]
        if routeSt && S.st[i] != S_BOSS { overheadBugDied(i, src) }
        S.dead[i] = 1; S.deadPending += 1
        let x = S.x[i], z = S.z[i], ty = S.type[i]
        let frozen = S.frz[i] > 0
        // the boss's body (the Queen; a chain's head): its bounty, its death (GameBoss.bossKilled)
        let isBoss = boss.alive && S.uid[i] == boss.uid
        if isBoss { xp += bossSpec.reward.xp }   // before onBugKilled, so its level-up loop counts the bounty
        onBugKilled(ty, src, x, z)
        if isBoss { bossKilled(x, z) }
        else if ty == T_BOOM { queueBoom(x, z, 3.1, 70, src, .boomer) }
        else if ty == T_BRUTE && !simOnly && src >= 0 && hypotf2(x - marines[0].x, z - marines[0].z) < 16 { hitStop(0.085, 0.12) }
        else if frozen {
            let sh: Float = (src >= 0 && src < 4) ? marines[src].mods.shatter : 1
            queueBoom(x, z, 1.7 * sh, 24 * sh, src, .frost)
        }
        if !simOnly {
            events.append(.bugKilled(type: BugType(rawValue: Int(ty)) ?? .runner, pos: Vec2(x, z), frozen: frozen, source: src,
                                     heading: S.hd[i], scale: S.sc[i], height: hKill))
            if frozen { sound(.shatter, x, z) }
            else {
                if ty == T_BRUTE { sound(.thud, x, z) }
                sound(.squish, x, z)
            }
        }
        if ty == T_BRUTE && !isBoss && rng.next() < difficulty.medkitChance { dropMedkit(x, z) }
    }

    // ---------- explosions (deferred, so chain reactions ripple tick by tick) ----------
    func queueBoom(_ x: Float, _ z: Float, _ r: Float, _ dmg: Float, _ src: Int, _ kind: ExplosionKind) {
        if booms.count < 48 { booms.append(Boom(x: x, z: z, r: r, dmg: dmg, src: src, kind: kind)) }
    }

    func processBooms() {
        let n = booms.count
        if n == 0 { return }
        let S = bugs
        let pulseImmune = bossSpec.immune.pulse
        do {
            var k = 0
            while k < n {
                defer { k += 1 }
                let e = booms[k]
                let cnt = hash.queryCircle(S, e.x, e.z, e.r)
                // (Stage 2 B4: a chain boss takes the blast as one creature — BossSpec.areaOnce)
                bossRT.areaHit = true
                defer { bossRT.areaHit = false }
                let pulse = e.kind == .pulse
                let knock: Float = e.kind == .frost ? 2 : (pulse ? 5 : 11)
                let falloff = difficulty.pulseFalloff
                do {
                    var q = 0
                    while q < cnt {
                        defer { q += 1 }
                        let b = hash.qb[q]
                        // a boss (the Матка) shrugs off frost and knockback, and the lift pulse when its spec says so
                        let qb = S.boss[b] != 0
                        if qb && pulse && pulseImmune { continue }
                        let dx = S.x[b] - e.x, dz = S.z[b] - e.z, d = (dx * dx + dz * dz).squareRoot() + 1e-4
                        // the lift pulse fades toward the rim on the harder tiers (no binary deck wipe)
                        let f: Float = pulse ? 1 - falloff * minf(1, d / e.r) : 1 - 0.55 * minf(1, d / e.r)
                        if e.kind == .frost && !qb { S.chill[b] = minf(1, S.chill[b] + 0.45) }
                        if S.type[b] != T_BRUTE && !qb { S.vx[b] += dx / d * knock * f; S.vz[b] += dz / d * knock * f }
                        // (Stage 2 B4: a chain boss's part hears the blast — the Threader's coil lets go of a grenade on a node)
                        if qb && S.boss[b] != BOSS_BUG { bossOwnBlast(Int(S.boss[b]) - 1, e.kind, e.src) }
                        hitBug(b, e.dmg * f, e.src, dir: Vec2(dx / d, dz / d))
                    }
                }
                // the overhead (Stage 1 R2): blasts reach up at BLAST_UP × their radius and knock the bugs up there down
                if H_overheadReach(e.kind) && hash.overheadCount > 0 { overheadBlast(e) }
                // Stage 1 R4: and strike the duct mouths' grilles
                if H_overheadReach(e.kind) && !oh.ducts.isEmpty { ductBlast(e) }
                // Stage 1 R6: the squad's blasts reach the steam valves up on their pipes too
                if H_overheadReach(e.kind) && !props.valves.isEmpty { valveBlast(e) }
                // wave pacing: the survivors around a blast scatter — a short flight away from it, then back in
                if difficulty.waves && (e.kind == .frag || e.kind == .boomer || e.kind == .mini) {
                    let fr = e.r * 1.9
                    let cnt2 = hash.queryCircle(S, e.x, e.z, fr)
                    var q = 0
                    while q < cnt2 {
                        let b = hash.qb[q]
                        q += 1
                        if S.dead[b] != 0 || S.type[b] == T_BRUTE || S.boss[b] != 0 || S.st[b] != S_MOVE { continue }
                        let dx = S.x[b] - e.x, dz = S.z[b] - e.z, d = (dx * dx + dz * dz).squareRoot()
                        if d < 0.05 { continue }
                        S.mood[b] = M_FLEE; S.mt[b] = (0.45 + 0.5 * rng.next()) * (1.2 - 0.5 * d / fr)
                        S.mdx[b] = dx / d; S.mdz[b] = dz / d
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
    /// `lamp`: the station lamp the glob was spat at (Stage 1 R6: it breaks on landing), −1 a marine.
    func launchGlob(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float, lamp: Int = -1) {
        let G = globs
        if G.count >= AcidGlobs.capacity { return }
        let k = G.count
        G.count += 1
        G.x0[k] = x0; G.z0[k] = z0; G.x1[k] = x1; G.z1[k] = z1; G.t[k] = 0; G.dur[k] = 0.95; G.lamp[k] = lamp
        G.h0[k] = 0
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
            // Stage 1 R6: a glob spat at a lamp breaks it
            if G.lamp[k] >= 0 { hurtLamp(G.lamp[k], LAMP_SPIT_DMG) }
            G.count -= 1
            let l = G.count
            G.x0[k] = G.x0[l]; G.z0[k] = G.z0[l]; G.x1[k] = G.x1[l]; G.z1[k] = G.z1[l]; G.t[k] = G.t[l]; G.dur[k] = G.dur[l]
            G.lamp[k] = G.lamp[l]
            G.h0[k] = G.h0[l]
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
        var ta0 = 0, ta1 = 0, ta2 = 0, ta3 = 0, ta4 = 0
        var ci = 0
        while ci < n {
            let i = ci
            ci += 1
            // (Stage 2 B1: a boss's chain parts are no swarm bugs; its bug body — the Queen — counts as its type)
            if DEAD[i] != 0 || ST[i] == S_BOSS { continue }
            switch TY[i] { case 0: ta0 += 1; case 1: ta1 += 1; case 2: ta2 += 1; case 3: ta3 += 1; default: ta4 += 1 }
        }
        typeAlive[0] = ta0; typeAlive[1] = ta1; typeAlive[2] = ta2; typeAlive[3] = ta3
        if typeAlive.count > 4 { typeAlive[4] = ta4 }
        let spreadRate = 1.4 * pyroSpread()
        // burn damage multiplier of each possible igniter (index src + 1, 0 = no marine)
        let BURNMUL = burnMulScratch
        BURNMUL[0] = 1
        do { var k = 0; while k < 4 { BURNMUL[k + 1] = marines[k].mods.burn; k += 1 } }
        let quiet = simOnly
        let liftFall = stage == .extract && extractT > 0.4
        let dmgMulL = dmgMul
        let UID = S.uid
        // a boss's bug body (the Матка): no moods, no favourite marine; its bite × its spec's on its own clock
        // (BossRuntime.biteCd), its bite and charge hits count as its source
        let qUid = boss.uid
        let qBite = bossSpec.bite, qSrc = bossSpec.source
        // hive pressure / AFK: part of the swarm hunts the player (even uids at idleMul ≥ 1.5, uid % 3 ≠ 0 after 12 s AFK)
        let huntP = huntPressure, huntA = huntAfk
        let anyHunt = MUP[0] != 0 && (huntP || huntA)

        let burnDps = CLASS_SPECS[1].burnDps
        // wave pacing (native-vx-feel): individual steering — a favourite marine, flanking arcs, wander, moods (hesitate,
        // feint, surge, flight from blasts, panic on fire), runner leaps, spitters strafing between spits
        let waves = difficulty.waves
        let MOOD = S.mood, MT = S.mt, MDX = S.mdx, MDZ = S.mdz, LT = S.lt
        let simT = simTime
        let biteK = difficulty.bite
        // Stage 1 R6: the hive spits on the station's lamps (only on a station with light circuits)
        let lampsLive = !props.lamps.isEmpty
        var iNext = 0
        while iNext < n {
            let i = iNext
            iNext += 1
            if DEAD[i] != 0 { continue }
            let ty = TY[i]
            if FL[i] > 0 { FL[i] -= dt * 4 }
            // --- up on the overhead (Stage 1 R2): its own update (GameOverhead); never true on a station without routes. A
            // boss's chain part (Stage 2 B1): the boss places it ---
            if ST[i] >= S_HIGH { if ST[i] != S_BOSS { routeTick(i, dt) }; continue }
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
                if ST[i] == S_LEAP { ST[i] = S_MOVE; Y[i] = 0 }   // ice drops a leaping runner onto the deck
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
                if y >= 0 || T[i] <= 0 {
                    y = 0; ST[i] = S_MOVE; VX[i] = AX[i] * 2; VZ[i] = AZ[i] * 2
                    // wave pacing: some runners vault the railing — a short hop inward instead of a crawl over it
                    if waves && ty == T_RUN && VR[i] > 0.55 {
                        ST[i] = S_LEAP; T[i] = LEAP_T * 0.85; VX[i] = AX[i] * 5.5; VZ[i] = AZ[i] * 5.5
                    }
                }
                Y[i] = y
                continue
            }
            // --- a runner's leap (wave pacing): airborne along its launch vector, height arcing over the deck ---
            if st == S_LEAP {
                T[i] -= dt
                let p = clampf(1 - T[i] / LEAP_T, 0, 1)
                Y[i] = 1.7 * p * (1 - p)   // ≈ 0.42 m at the top
                var nx = x + VX[i] * dt, nz = z + VZ[i] * dt
                if !walkAt(walk, nx, nz) { nx = x; nz = z; VX[i] *= 0.2; VZ[i] *= 0.2 }
                X[i] = nx; Z[i] = nz
                PH[i] += dt * 20
                if T[i] <= 0 {
                    Y[i] = 0; ST[i] = S_MOVE; VX[i] *= 0.4; VZ[i] *= 0.4
                    if CD[i] > 0.1 { CD[i] = 0.1 }   // it lands biting
                }
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
            // wave pacing: every bug has a favourite marine (uid % 4) and goes for that one unless another is much
            // closer — the swarm splits over the squad instead of funnelling into the nearest marine
            if waves && !hunt && u != qUid && bd > 6.25 {
                let pk = Int(u & 3)
                if !(anyUp && MUP[pk] == 0) {
                    let dx = MX[pk] - x, dz = MZ[pk] - z, d2 = dx * dx + dz * dz
                    let lim = bd.squareRoot() + 7
                    if d2 < lim * lim { bd = d2; best = pk }
                }
            }
            let dist = bd.squareRoot() + 1e-4
            let tx = (MX[best] - x) / dist, tz = (MZ[best] - z) / dist
            var ddx: Float, ddz: Float
            if dist < 5.5 || c0 < 0 || (flowX[c0] == 0 && flowZ[c0] == 0) { ddx = tx; ddz = tz }
            else { ddx = flowX[c0]; ddz = flowZ[c0] }
            var speed = SPD[i] * (1 - 0.6 * CHILL[i]) * (BURN[i] > 0 ? 1.15 : 1)
            if CD[i] > 0 { CD[i] -= dt }
            var acc: Float = 9
            var md = M_CALM
            if waves && u != qUid && st == S_MOVE {
                if MT[i] > 0 { MT[i] -= dt }
                if LT[i] > 0 { LT[i] -= dt }
                md = MOOD[i]
                if BURN[i] > 0 && ty != T_BRUTE {
                    // a burning bug panics: it darts about at random, now and then forgetting the squad
                    if md != M_PANIC || MT[i] <= 0 {
                        var rx = rng.next() - 0.5, rz = rng.next() - 0.5
                        // half the darts still lean toward the target: panic, not a retreat
                        if rng.next() < 0.5 { rx += tx * 0.6; rz += tz * 0.6 }
                        let rl = hypotf2(rx, rz) + 1e-4
                        md = M_PANIC; MT[i] = 0.22 + rng.next() * 0.3; MDX[i] = rx / rl; MDZ[i] = rz / rl
                    }
                } else if md == M_PANIC {
                    md = M_CALM; MT[i] = 0.4
                } else if md == M_CALM && MT[i] <= 0 {
                    if dist > 3.5 && dist < 15 && ty != T_BRUTE {
                        let r = rng.next()
                        if r < 0.17 { md = M_HESITATE; MT[i] = 0.3 + rng.next() * 0.5 }
                        else if r < 0.27 && ty == T_RUN && dist < 10 {
                            // a feint: it backs off at a slant, then comes in hard
                            let sd: Float = rng.next() < 0.5 ? 1 : -1
                            md = M_FEINT; MT[i] = 0.25 + rng.next() * 0.25; MDX[i] = -tx * 0.6 - tz * 0.8 * sd; MDZ[i] = -tz * 0.6 + tx * 0.8 * sd
                        } else if r < 0.4 { md = M_SURGE; MT[i] = 0.4 + rng.next() * 0.4 }
                        else { MT[i] = 1.0 + rng.next() * 2.4 }
                    } else { MT[i] = 0.5 + rng.next() * 1.0 }
                } else if md != M_CALM && MT[i] <= 0 {
                    // a hesitation or a feint ends in a surge; a surge or a flight in calm
                    if md == M_HESITATE || md == M_FEINT { md = M_SURGE; MT[i] = 0.45 + rng.next() * 0.45 }
                    else { md = M_CALM; MT[i] = 1.0 + rng.next() * 2.4 }
                }
                MOOD[i] = md
                switch md {
                case M_HESITATE: speed *= 0.1
                case M_FEINT: ddx = MDX[i]; ddz = MDZ[i]; speed *= 0.8
                case M_SURGE: speed *= 1.5; acc = 14
                case M_FLEE: ddx = MDX[i]; ddz = MDZ[i]; speed *= 1.35; acc = 16
                case M_PANIC: ddx = MDX[i]; ddz = MDZ[i]; speed *= 1.3; acc = 14
                default: break
                }
                if md == M_CALM || md == M_SURGE {
                    // flanking arcs and wander: the approach bends to one side (by uid) far out and straightens near
                    // the target; a slow per-bug weave on top. Only where the bent step stays on the deck.
                    var ang: Float = 0
                    if dist > 4 {
                        let sd: Float = (u & 4) != 0 ? 1 : -1
                        ang = sd * (0.22 + 0.5 * VR[i]) * minf(1, (dist - 4) * 0.1)
                    }
                    ang += 0.3 * waveOsc(simT * (0.35 + 0.4 * VR[i]) + Float(u & 63) * 0.137)
                    let a2 = ang * ang
                    let sn = ang * (1 - a2 / 6 * (1 - a2 / 20)), cs = 1 - a2 / 2 * (1 - a2 / 12)
                    let rx = ddx * cs + ddz * sn, rz = -ddx * sn + ddz * cs
                    if walkAt(walk, x + rx * 1.4, z + rz * 1.4) { ddx = rx; ddz = rz }
                }
            }
            // --- type behaviours ---
            if ty == T_SPIT {
                if st == S_MOVE {
                    // (R6: now and then a ready spit goes at a lamp instead — at most once in LAMP_SPIT_GAP s for the hive)
                    if lampsLive && CD[i] <= 0 && anyUp && simT >= props.lampSpitAt, case let lk = lampSpitTarget(x, z), lk >= 0 {
                        spitAtLamp(i, lk)
                    } else if dist < 11 && dist > 3.2 && CD[i] <= 0 && anyUp {
                        let m = marines[best]
                        let ax = MX[best] + m.vx * 0.8 + (rng.next() - 0.5) * 1.2
                        let az = MZ[best] + m.vz * 0.8 + (rng.next() - 0.5) * 1.2
                        ST[i] = S_WIND; T[i] = 0.5; AX[i] = ax; AZ[i] = az
                        if !quiet {
                            teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, 1.45, cause: .acidTarget)
                            teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, 1.45, cause: .acidTarget)
                        }
                    } else if dist < 4 { ddx = -tx; ddz = -tz; speed *= 0.8 }
                    else if dist < 10 && CD[i] > 0.4 {
                        if waves && md == M_CALM {
                            // wave pacing: between spits it strafes across the squad's front instead of standing in line
                            let sd: Float = (u & 8) != 0 ? 1 : -1
                            ddx = -tz * sd * 0.95 + tx * 0.1; ddz = tx * sd * 0.95 + tz * 0.1; speed *= 0.5
                        } else { speed *= 0.25 }
                    }
                } else {
                    speed = 0
                    T[i] -= dt
                    if T[i] <= 0 {
                        launchGlob(x, z, AX[i], AZ[i], lamp: lampsLive ? lampOfSpitter(UID[i]) : -1)
                        ST[i] = S_MOVE; CD[i] = 2.8 + rng.next() * 1.6
                    }
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
                                hurtMarine(marines[k], 16 * dmgMulL, AX[i] * 13, AZ[i] * 13, u == qUid ? qSrc : .brute)
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
            // --- a runner leaps at its marine from 1.6–4 m (wave pacing): fast, low, landing in a bite ---
            if waves && ty == T_RUN && ST[i] == S_MOVE && md != M_FLEE && md != M_PANIC && LT[i] <= 0 && dist > 1.6 && dist < 4.0
                && MUP[best] != 0 {
                if rng.next() < 0.55 {
                    let m = marines[best]
                    let lx = MX[best] + m.vx * 0.25 - x, lz = MZ[best] + m.vz * 0.25 - z
                    let ll = hypotf2(lx, lz) + 1e-4
                    let v = clampf(ll / LEAP_T, 6.5, 11.5)
                    ST[i] = S_LEAP; T[i] = LEAP_T; AX[i] = lx / ll; AZ[i] = lz / ll; VX[i] = AX[i] * v; VZ[i] = AZ[i] * v
                    HD[i] = atan2f2(lx, lz)
                    LT[i] = 2.2 + rng.next() * 2.0
                    continue
                }
                LT[i] = 0.5 + rng.next() * 0.6
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
            // (a boss's bug body bites × its spec's on its own clock: its cd only gates its charge, see bossMoves)
            let qm = u == qUid
            if dist < ri + 0.62 && (qm ? bossRT.biteCd <= 0 : CD[i] <= 0) && ST[i] == S_MOVE && ty != T_BOOM && MUP[best] != 0 {
                // attack slots: only a few small bugs can land a bite per second on one marine
                let mm = marines[best]
                if ty == T_BRUTE || mm.bite >= 1 {
                    if ty != T_BRUTE { mm.bite -= 1 }
                    let kb: Float = ty == T_BRUTE ? 6 : 0.6
                    let bk: Float = waves && (ty == T_RUN || ty == T_SPIT) ? biteK : 1
                    hurtMarine(mm, BUG_SPECS[Int(ty)].dmg * dmgMulL * (qm ? qBite : 1) * bk, tx * kb, tz * kb, qm ? qSrc : DamageSource(bugType: ty))
                    let cd = BUG_SPECS[Int(ty)].atkCd * (0.8 + rng.next() * 0.4)
                    if qm { bossRT.biteCd = cd } else { CD[i] = cd }
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

    /// The explosions that reach the overhead: the squad's frag and its bomblets (not a boomer's, not the frost shatter, not
    /// the lift's deck circuit).
    @inline(__always) func H_overheadReach(_ k: ExplosionKind) -> Bool { k == .frag || k == .mini }

    /// A smooth periodic wave in [-1, 1] of phase `p` (one period per unit) from basic arithmetic only (a shaped triangle:
    /// no libm, so a mission plays bit-identically on every platform).
    @inline(__always) func waveOsc(_ p: Float) -> Float {
        let f = p - p.rounded(.down)
        let t = 4 * absf(f - 0.5) - 1
        return t * (1.5 - 0.5 * t * t)
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
                    if b.isPlayer { toast(.medkitToast(40), .gold) }
                }
            }
        }
    }
}
