import Foundation

// ================================================================
//  MARINES — movement, damage, revive, weapons, projectiles, abilities
//  (port of 06-marines.js)
// ================================================================
extension Game {

    // ---------- per-tick marine update ----------
    func tickMarines(_ dt: Float) {
        for m in marines {
            m.px = m.x; m.pz = m.z
            if m.inv > 0 { m.inv -= dt }
            if m.hurtT > 0 { m.hurtT -= dt }
            if m.dashCd > 0 { m.dashCd -= dt }
            if m.abCd > 0 { m.abCd -= dt }
            if m.muzzle > 0 { m.muzzle -= dt * 10 }
            m.bite = min(3, m.bite + dt * 5.5)
            if m.downed {
                // presses made while downed must not fire later in a random direction
                if m.isPlayer { inAbility = false; inDash = false }
                m.vx = 0; m.vz = 0; m.firing = false
                updateWeapon(m, dt, false)
                continue
            }
            var mx: Float = 0, mz: Float = 0, fire = false
            if m.isPlayer && !autopilot {
                (mx, mz, fire) = playerCommands(m)
            } else {
                (mx, mz, fire) = botThink(m, dt)
            }
            if stage == .extract && level.onLift(m.x, m.z) { mx = 0; mz = 0; m.dashT = 0 }
            let ml = hypotf2(mx, mz)
            if ml > 1 { mx /= ml; mz /= ml }
            if ml > 0.2 {
                let k = min(1, 6 * dt)
                m.faceX += (mx / ml - m.faceX) * k; m.faceZ += (mz / ml - m.faceZ) * k
                var fl = hypotf2(m.faceX, m.faceZ)
                if fl == 0 { fl = 1 }
                m.faceX /= fl; m.faceZ /= fl
            }
            moveMarine(m, dt, mx, mz)
            m.ax = sinf2(m.aim); m.az = cosf2(m.aim)
            updateWeapon(m, dt, fire)
            m.calm += dt
            let D = difficulty
            let calmRegen: Float = (m.calm > D.regenDelay && m.hp < m.maxHp * D.regenCap) ? D.regen : 0
            let regen = m.mods.regen + calmRegen
            if regen > 0 && m.hp < m.maxHp { m.hp = min(m.maxHp, m.hp + regen * dt) }
        }
        updateRevive(dt)
    }

    // ---------- collision ----------
    func moveMarine(_ m: Marine, _ dt: Float, _ wx: Float, _ wz: Float) {
        let L = level
        let crowdMul = clampf(1 - crowd[m.index] * 0.045, 0.42, 1)
        let spd = 5.3 * m.mods.speed * crowdMul
        if m.dashT > 0 { m.dashT -= dt; m.vx = m.dashX * 17; m.vz = m.dashZ * 17 }
        else { let k = min(1, 12 * dt); m.vx += (wx * spd - m.vx) * k; m.vz += (wz * spd - m.vz) * k }
        let kd = expf2(-7 * dt)
        m.kx *= kd; m.kz *= kd
        let tx = m.vx + m.kx, tz = m.vz + m.kz
        let nx = m.x + tx * dt, nz = m.z + tz * dt
        if L.canStand(nx, nz) { m.x = nx; m.z = nz }
        else if L.canStand(nx, m.z) { m.x = nx; m.vz *= 0.5 }
        else if L.canStand(m.x, nz) { m.z = nz; m.vx *= 0.5 }
        // squad members don't overlap
        for o in marines where o !== m {
            let dx = m.x - o.x, dz = m.z - o.z, d2 = dx * dx + dz * dz
            if d2 < 0.64 && d2 > 1e-6 {
                let d = d2.squareRoot(), p = (0.8 - d) * 0.5
                let qx = m.x + dx / d * p, qz = m.z + dz / d * p
                if L.canStand(qx, qz) { m.x = qx; m.z = qz }
            }
        }
    }

    func tryDash(_ m: Marine, _ dx0: Float, _ dz0: Float) {
        if m.dashCd > 0 || m.downed { return }
        var dx = dx0, dz = dz0
        let l = hypotf2(dx, dz)
        if !(l >= 0.1) { dx = m.ax; dz = m.az } else { dx /= l; dz /= l }
        m.dashX = dx; m.dashZ = dz; m.dashT = 0.22; m.inv = max(m.inv, 0.32); m.dashCd = 3 * m.mods.dashCd
        if !simOnly {
            emit(.dash(marine: m.index, dir: Vec2(dx, dz)))
            sound(.dash, m.x, m.z)
            if m.isPlayer { haptic(.select) }
        }
    }

    // ---------- damage to marines ----------
    func hurtMarine(_ m: Marine, _ dmg: Float, _ kx: Float, _ kz: Float) {
        if m.downed { return }
        if godMode || m.inv > 0 || m.dashT > 0 { m.kx += kx * 0.3; m.kz += kz * 0.3; return }
        m.hp -= dmg; m.hurtT = 0.22; m.kx += kx; m.kz += kz; m.calm = 0
        // taking a hit breaks the combo: it rewards clean play, not just standing in a horde
        if m.isPlayer { combo = 0; comboT = 0 }
        if !simOnly {
            emit(.hurt(marine: m.index, amount: dmg))
            if m.isPlayer {
                emit(.damageFlash(amount: min(1, dmg / 28)))
                shake(0.12 + dmg * 0.012)
                events.append(.sound(.hurt, pos: nil, fromPlayer: true))
                haptic(dmg >= 12 ? .heavy : .light)
            }
        }
        if m.hp <= 0 { downMarine(m) }
    }

    func downMarine(_ m: Marine) {
        m.hp = 0; m.downed = true; m.revive = 0; m.firing = false; m.dashT = 0
        if !simOnly {
            emit(.downed(marine: m.index))
            toast(m.isPlayer ? "Вы ранены — ждите помощи" : m.name + " ранен", .warn)
            sound(.down, m.x, m.z)
            if m.isPlayer { hitStop(0.3, 0.2); shake(0.4); haptic(.error) }
        }
    }

    func updateRevive(_ dt: Float) {
        for m in marines where m.downed {
            var helped = false
            for o in marines where o !== m && !o.downed {
                if (o.x - m.x) * (o.x - m.x) + (o.z - m.z) * (o.z - m.z) < 5.3 { helped = true }
            }
            m.revive = helped ? m.revive + dt / 3 : max(0, m.revive - dt * 0.25)
            if m.revive >= 1 {
                m.downed = false; m.hp = m.maxHp * difficulty.reviveHp; m.inv = 1.6; m.revive = 0
                if !simOnly {
                    emit(.revived(marine: m.index))
                    toast(m.isPlayer ? "Вы снова в строю" : m.name + " в строю", .gold)
                    sound(.revive, m.x, m.z)
                }
            }
        }
    }

    // ---------- projectiles ----------
    func fireBolt(_ ox: Float, _ oz: Float, _ ang: Float, _ spd: Float, _ dmg: Float, _ pierce: Int, _ own: Int, _ col: UInt8, _ playerShot: Bool) {
        let P = projectiles
        if P.count >= Projectiles.capacity { return }
        let k = P.count
        P.count += 1
        P.x[k] = ox; P.z[k] = oz; P.dx[k] = sinf2(ang); P.dz[k] = cosf2(ang); P.spd[k] = spd; P.life[k] = 0.42
        P.dmg[k] = dmg; P.pierce[k] = UInt8(clamping: pierce); P.own[k] = Int8(truncatingIfNeeded: own); P.col[k] = col; P.last[k] = 0
        P.flags[k] = playerShot ? 1 : 0
        if playerShot { shots += 1 }
    }

    func updateProjectiles(_ dt: Float) {
        let P = projectiles, S = bugs
        var k = 0
        while k < P.count {
            var sx = P.x[k], sz = P.z[k]
            let dx = P.dx[k], dz = P.dz[k]
            var len = P.spd[k] * dt
            var alive = true
            var guardN = 4
            while alive && guardN > 0 {
                guardN -= 1
                let (b, segT) = hash.segmentHit(S, sx, sz, dx, dz, len, P.last[k])
                if b < 0 { break }
                let own = Int(P.own[k])
                let hx = sx + dx * segT, hz = sz + dz * segT
                if (P.flags[k] & 1) != 0 && (P.flags[k] & 2) == 0 { hits += 1; P.flags[k] |= 2 }
                S.vx[b] += dx * 1.2; S.vz[b] += dz * 1.2
                let killed = hitBug(b, P.dmg[k], own)
                emit(.bulletHit(pos: Vec2(hx, hz), dir: Vec2(dx, dz), killed: killed))
                if own >= 0 && own < 4 && marines[own].mods.explosive > 0 && rng.next() < 0.12 * Float(marines[own].mods.explosive) {
                    queueBoom(hx, hz, 1.7, 22 * marines[own].mods.dmg, own, .mini)
                }
                if P.pierce[k] > 0 { P.pierce[k] -= 1; P.last[k] = S.uid[b]; len -= segT; sx = hx; sz = hz }
                else { alive = false }
            }
            P.x[k] += dx * P.spd[k] * dt; P.z[k] += dz * P.spd[k] * dt
            P.life[k] -= dt
            if !alive || P.life[k] <= 0 { P.remove(k) } else { k += 1 }
        }
    }

    // ---------- weapons ----------
    /// Muzzle point of a marine's weapon.
    public func muzzlePosition(_ m: Marine) -> Vec2 {
        Vec2(m.x + m.ax * 0.95 + m.az * 0.22, m.z + m.az * 0.95 - m.ax * 0.22)
    }

    func updateWeapon(_ m: Marine, _ dt: Float, _ want: Bool) {
        let C = m.spec, md = m.mods
        m.firing = false
        switch m.cls {
        case .assault:
            if m.reload > 0 { m.reload -= dt; if m.reload <= 0 { m.ammo = C.mag } }
            m.fireCd -= dt
            if want && m.reload <= 0 {
                m.firing = true
                var shotsN = 0
                while m.fireCd <= 0 && m.ammo > 0 && shotsN < 3 {
                    let mp = muzzlePosition(m)
                    fireBolt(mp.x, mp.y, m.aim + (rng.next() - 0.5) * C.spread * 2, C.pspeed, C.dmg * md.dmg, C.pierce + md.pierce, m.index, 0, m.isPlayer)
                    m.ammo -= 1; m.fireCd += 1 / (C.rof * md.rof); m.muzzle = 1; shotsN += 1
                    if !simOnly { emit(.muzzle(marine: m.index)); sound(.pulse, m.x, m.z, m.isPlayer) }
                }
                if m.ammo <= 0 {
                    m.reload = C.reload
                    if !simOnly { emit(.reload(marine: m.index)); sound(.reload, m.x, m.z, m.isPlayer) }
                }
            }
            if !want && m.fireCd < 0 { m.fireCd = 0 }
            m.bar = m.reload > 0 ? 1 - m.reload / C.reload : Float(m.ammo) / Float(C.mag)
        case .gunner:
            let spinning = want && m.over <= 0
            m.spin = spinning ? min(1, m.spin + dt / C.spinTime) : max(0, m.spin - dt / 0.9)
            if m.over > 0 { m.over -= dt; m.heat = max(0, m.heat - dt * 0.45) }
            else if spinning && m.spin > 0.35 {
                m.firing = true; m.fireCd -= dt
                let rate = C.rof * md.rof * (0.3 + 0.7 * m.spin)
                var shotsN = 0
                while m.fireCd <= 0 && shotsN < 4 {
                    let mp = muzzlePosition(m)
                    fireBolt(mp.x, mp.y, m.aim + (rng.next() - 0.5) * C.spread * 2, C.pspeed, C.dmg * md.dmg, C.pierce + md.pierce, m.index, 1, m.isPlayer)
                    m.fireCd += 1 / rate; m.muzzle = 1; shotsN += 1
                    if !simOnly { emit(.muzzle(marine: m.index)); sound(.mg, m.x, m.z, m.isPlayer) }
                }
                m.heat += dt / (C.heatTime * md.heat)
                if m.heat >= 1 {
                    m.heat = 1; m.over = 2.4
                    if !simOnly { emit(.overheat(marine: m.index)); sound(.overheat, m.x, m.z, m.isPlayer) }
                }
            } else { m.heat = max(0, m.heat - dt * 0.35); if m.fireCd < 0 { m.fireCd = 0 } }
            m.bar = 1 - m.heat
        case .pyro:
            if m.over > 0 { m.over -= dt; m.heat = max(0, m.heat - dt * 0.5) }
            else if want {
                m.firing = true; flameTick(m, dt)
                m.heat += dt / (C.heatTime * md.heat)
                if m.heat >= 1 {
                    m.heat = 1; m.over = 2.0
                    if !simOnly { emit(.overheat(marine: m.index)); sound(.overheat, m.x, m.z, m.isPlayer) }
                }
            } else { m.heat = max(0, m.heat - dt * 0.42) }
            m.bar = 1 - m.heat
        case .cryo:
            if m.over > 0 { m.over -= dt; m.energy = min(1, m.energy + dt * 0.5) }
            else if want && m.energy > 0 {
                m.firing = true; beamTick(m, dt)
                m.energy -= dt / (C.energyTime * md.heat)
                if m.energy <= 0 {
                    m.energy = 0; m.over = 1.6
                    if !simOnly { emit(.overheat(marine: m.index)); sound(.overheat, m.x, m.z, m.isPlayer) }
                }
            } else { m.energy = min(1, m.energy + dt * 0.3) }
            m.bar = m.energy
        }
        if m.isPlayer && (m.cls == .pyro || m.cls == .cryo) && m.firing { shots += 1.0 / 6.0 }
    }

    func flameTick(_ m: Marine, _ dt: Float) {
        let C = m.spec, md = m.mods, range = C.range * md.range, cosC = cosf2(C.cone * md.cone)
        let ox = m.x + m.ax * 0.7, oz = m.z + m.az * 0.7
        let S = bugs
        let cnt = hash.queryCircle(S, ox + m.ax * range * 0.5, oz + m.az * range * 0.5, range * 0.58)
        var hitAny = false
        for q in 0..<cnt {
            let b = Int(hash.qb[q])
            let dx = S.x[b] - ox, dz = S.z[b] - oz, d = (dx * dx + dz * dz).squareRoot() + 1e-4
            if d > range + S.r[b] { continue }
            if d > 0.9 && (dx * m.ax + dz * m.az) / d < cosC { continue }
            hitAny = true
            S.burn[b] = C.burn; S.bsrc[b] = Int8(truncatingIfNeeded: m.index)
            S.vx[b] += m.ax * 3 * dt; S.vz[b] += m.az * 3 * dt
            hitBug(b, C.dps * md.dmg * md.rof * dt * (1 - 0.35 * d / range), m.index, true)
        }
        if m.isPlayer && hitAny { hits += 1.0 / 6.0 }
    }

    func beamTick(_ m: Marine, _ dt: Float) {
        let C = m.spec, md = m.mods, len = C.range * md.range
        let ox = m.x + m.ax * 0.8, oz = m.z + m.az * 0.8
        let S = bugs
        let cnt = hash.queryCircle(S, ox + m.ax * len * 0.5, oz + m.az * len * 0.5, len * 0.56)
        var hitAny = false
        for q in 0..<cnt {
            let b = Int(hash.qb[q])
            let dx = S.x[b] - ox, dz = S.z[b] - oz, t = dx * m.ax + dz * m.az
            if t < -0.3 || t > len { continue }
            let perp = abs(dx * m.az - dz * m.ax), w = 0.42 + t / len * 0.75
            if perp > w + S.r[b] { continue }
            hitAny = true
            if S.frz[b] <= 0 {
                S.chill[b] += C.chill * md.chill * dt
                if S.chill[b] >= 1 {
                    S.chill[b] = 1; S.frz[b] = S.type[b] == T_BRUTE ? 1.3 : 2.6
                    if !simOnly { emit(.bugFrozen(pos: Vec2(S.x[b], S.z[b]))); sound(.freeze, S.x[b], S.z[b]) }
                }
            }
            hitBug(b, C.dps * md.dmg * md.rof * dt, m.index, true)
        }
        m.beamLen = len
        if m.isPlayer && hitAny { hits += 1.0 / 6.0 }
    }

    // ---------- abilities ----------
    /// «Расширенный заряд» widens the turret's reach for the gunner.
    func turretRange() -> Float {
        let o = turret.owner
        return 15 * ((o >= 0 && o < marines.count) ? marines[o].mods.arad : 1)
    }

    @discardableResult
    func useAbility(_ m: Marine, _ tx0: Float, _ tz0: Float) -> Bool {
        if m.abCd > 0 || m.downed { return false }
        let md = m.mods
        m.abCd = m.spec.abCd * md.acd
        let S = bugs
        switch m.cls {
        case .assault:
            var tx = tx0, tz = tz0
            let dx = tx - m.x, dz = tz - m.z, d = hypotf2(dx, dz)
            if d > 13 { tx = m.x + dx / d * 13; tz = m.z + dz / d * 13 }
            throwGrenade(m.x + m.ax * 0.6, m.z + m.az * 0.6, tx, tz, m.index, 5 * md.arad, 150 * md.dmg, md.cluster, true)
            if !simOnly {
                emit(.ability(marine: m.index, kind: .grenade, pos: Vec2(tx, tz), radius: 5 * md.arad))
                sound(.throwGrenade, m.x, m.z, m.isPlayer)
            }
        case .pyro:
            let k = napalms.firstIndex(where: { !$0.active }) ?? 0
            let r = 5 * md.arad
            napalms[k].active = true; napalms[k].x = m.x; napalms[k].z = m.z; napalms[k].r = r; napalms[k].t = 5; napalms[k].own = m.index
            let cnt = hash.queryCircle(S, m.x, m.z, r)
            for q in 0..<cnt {
                let b = Int(hash.qb[q])
                S.burn[b] = 5; S.bsrc[b] = Int8(truncatingIfNeeded: m.index)
                hitBug(b, 30 * md.dmg, m.index)
            }
            if !simOnly {
                emit(.ability(marine: m.index, kind: .napalm, pos: Vec2(m.x, m.z), radius: r))
                teleRing(m.x, m.z, r, 1.0, 0.32, 0.06, 5, r1: r, pulse: false, cause: .napalm)
                shake(0.3)
                sound(.napalm, m.x, m.z, m.isPlayer)
            }
        case .cryo:
            let r = 7 * md.arad
            let cnt = hash.queryCircle(S, m.x, m.z, r)
            for q in 0..<cnt {
                let b = Int(hash.qb[q])
                S.frz[b] = S.type[b] == T_BRUTE ? 1.6 : 3.2; S.chill[b] = 1; S.vx[b] = 0; S.vz[b] = 0
                hitBug(b, 30 * md.dmg, m.index)
            }
            if !simOnly {
                emit(.ability(marine: m.index, kind: .nova, pos: Vec2(m.x, m.z), radius: r))
                teleRing(m.x, m.z, 0.5, 0.3, 0.6, 0.8, 0.55, r1: r, pulse: false, cause: .nova)
                teleRing(m.x, m.z, 0.5, 0.15, 0.35, 0.6, 0.8, r1: r * 0.9, pulse: false, cause: .nova)
                shake(0.35)
                sound(.nova, m.x, m.z, m.isPlayer)
            }
        case .gunner:
            var x = m.x + m.ax * 1.3, z = m.z + m.az * 1.3
            if !level.canStand(x, z) { x = m.x; z = m.z }
            turret = Turret(active: true, x: x, z: z, t: 15 + md.turretDur, angle: m.aim, cd: 0, owner: m.index, think: 0, target: -1, tuid: 0, laser: 0)
            if !simOnly {
                emit(.ability(marine: m.index, kind: .turret, pos: Vec2(x, z), radius: turretRange()))
                sound(.turret, x, z, m.isPlayer)
            }
        }
        if m.isPlayer { haptic(.light) }
        return true
    }

    func throwGrenade(_ sx: Float, _ sz: Float, _ tx: Float, _ tz: Float, _ own: Int, _ r: Float, _ dmg: Float, _ cluster: Int, _ big: Bool) {
        guard let k = grenades.firstIndex(where: { !$0.active }) else { return }
        grenades[k] = Grenade(active: true, sx: sx, sz: sz, tx: tx, tz: tz, t: 0, dur: big ? 0.7 : 0.38, own: own, r: r, dmg: dmg, cluster: cluster, big: big)
        if !simOnly { emit(.grenadeThrown(from: Vec2(sx, sz), to: Vec2(tx, tz), big: big)) }
    }

    func updateAbilities(_ dt: Float) {
        let S = bugs
        for k in 0..<grenades.count where grenades[k].active {
            grenades[k].t += dt
            if grenades[k].t < grenades[k].dur { continue }
            grenades[k].active = false
            let g = grenades[k]
            queueBoom(g.tx, g.tz, g.r, g.dmg, g.own, g.big ? .frag : .mini)
            if g.cluster > 0 {
                for _ in 0..<g.cluster {
                    let a = rng.next() * TAU, d = 2 + rng.next() * 2.5
                    throwGrenade(g.tx, g.tz, g.tx + cosf2(a) * d, g.tz + sinf2(a) * d, g.own, 2.6, g.dmg * 0.4, 0, false)
                }
            }
        }
        for k in 0..<napalms.count where napalms[k].active {
            napalms[k].t -= dt
            if napalms[k].t <= 0 { napalms[k].active = false; continue }
            let n = napalms[k]
            let cnt = hash.queryCircle(S, n.x, n.z, n.r + 1.4)
            let dmg = 28 * marines[n.own].mods.dmg * dt
            for q in 0..<cnt {
                let b = Int(hash.qb[q])
                let d = hypotf2(S.x[b] - n.x, S.z[b] - n.z)
                if abs(d - n.r) > 1.3 { continue }
                S.burn[b] = 3.5; S.bsrc[b] = Int8(truncatingIfNeeded: n.own)
                hitBug(b, dmg, n.own, true)
            }
        }
        if turret.active {
            turret.t -= dt
            if turret.t <= 0 {
                turret.active = false
                if !simOnly { emit(.turretExpired(pos: Vec2(turret.x, turret.z))) }
            } else {
                turret.think -= dt
                if turret.think <= 0 {
                    turret.think = 0.12; turret.target = -1
                    let cnt = hash.queryCircle(S, turret.x, turret.z, turretRange())
                    var bd: Float = 1e9
                    for q in 0..<cnt {
                        let b = Int(hash.qb[q])
                        let ddx = S.x[b] - turret.x, ddz = S.z[b] - turret.z
                        let d = ddx * ddx + ddz * ddz - (S.type[b] == T_BOOM ? 30 : 0)
                        if d < bd { bd = d; turret.target = b }
                    }
                    if turret.target >= 0 { turret.tuid = S.uid[turret.target] }
                }
                let b = turret.target
                if b >= 0 && b < S.count && S.dead[b] == 0 && S.uid[b] == turret.tuid {
                    let want = atan2f2(S.x[b] - turret.x, S.z[b] - turret.z)
                    let d = angDiff(turret.angle, want)
                    turret.angle += clampf(d, -9 * dt, 9 * dt)
                    turret.cd -= dt
                    if abs(d) < 0.2 && turret.cd <= 0 {
                        let md = marines[turret.owner].mods
                        turret.cd = 1 / (10 * md.turretRof)
                        fireBolt(turret.x + sinf2(turret.angle) * 0.7, turret.z + cosf2(turret.angle) * 0.7, turret.angle + (rng.next() - 0.5) * 0.05,
                                 90, 11 * md.dmg, 0, turret.owner, 2, false)
                        turret.laser = 1
                        if !simOnly { emit(.turretShot(pos: Vec2(turret.x, turret.z), angle: turret.angle)); sound(.tur, turret.x, turret.z) }
                    }
                }
            }
        }
    }
}
