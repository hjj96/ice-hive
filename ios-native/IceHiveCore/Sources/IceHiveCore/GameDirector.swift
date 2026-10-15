import Foundation

// ================================================================
//  DIRECTOR — objectives, swarm pacing, hordes, XP & upgrades
//  (port of 08-director.js)
// ================================================================
extension Game {

    func resetDirector() {
        stage = .beacons; activeBeacon = -1; beaconsDone = 0; liftT = LIFT_TIME; hordeT = attract ? 1e9 : 50; waveT = 0
        trickle = 0; hpMul = difficulty.hp; dmgMul = difficulty.dmg; queue.removeAll(); extractT = 0; hordes = 0
        beacons = level.layout.beacons.map { BeaconState(name: $0.name, x: $0.x, z: $0.z) }
    }

    /// Index of the beacon the squad should go to (the active one, else the nearest unfinished), -1 none.
    func nextBeacon() -> Int {
        if activeBeacon >= 0 { return activeBeacon }
        let P = marines[0]
        var best = -1
        var bd: Float = 1e9
        for (k, b) in beacons.enumerated() where b.state != 2 {
            let d = hypotf2(b.x - P.x, b.z - P.z)
            if d < bd { bd = d; best = k }
        }
        return best
    }

    func standingIn(_ x: Float, _ z: Float, _ r: Float) -> Int {
        var n = 0
        for m in marines where !m.downed && (m.x - x) * (m.x - x) + (m.z - z) * (m.z - z) < r * r { n += 1 }
        return n
    }

    // ---------- spawning ----------
    func pickEdge(_ cx: Float, _ cz: Float, _ dmin: Float, _ dmax: Float) -> Int {
        let L = level
        let N = L.edgeCount
        if N == 0 { return -1 }
        var fallback = -1
        for _ in 0..<40 {
            let e = rng.int(N)
            let x = L.edgeX[e], z = L.edgeZ[e]
            let d = hypotf2(x - cx, z - cz)
            if d < dmin || d > dmax { continue }
            let c = L.cellOf(x, z)
            if c < 0 || swarmFlow.d[c] == FlowField.unreachable { continue }
            if fallback < 0 { fallback = e }
            // prefer edges the camera is not looking straight at: off-screen arrivals feel like flanking
            if d > dmin + 4 || rng.next() < 0.3 { return e }
        }
        return fallback
    }

    func edgeNear(_ e0: Int, _ r: Float) -> Int {
        let L = level
        let x0 = L.edgeX[e0], z0 = L.edgeZ[e0]
        for _ in 0..<16 {
            let e = rng.int(L.edgeCount)
            if abs(L.edgeX[e] - x0) < r && abs(L.edgeZ[e] - z0) < r { return e }
        }
        return e0
    }

    func pickType(_ horde: Bool) -> UInt8 {
        let t = time, d = Float(beaconsDone), k: Float = stage == .hold ? 0.5 : 1
        let D = difficulty
        // specials follow objective progress (not wall time): the first beacon already brings spitters and boomers,
        // brutes join halfway through it, and later beacons add only a little on top
        let prog = d + (activeBeacon >= 0 ? beacons[activeBeacon].progress : 0)
        let pBrute: Float = (beaconsDone >= 1 || prog > 0.5) ? (0.012 + 0.004 * d) * k * D.specials : 0
        let pSpit: Float = t > 15 ? ((horde ? 0.05 : 0.07) + 0.008 * d) * k * D.specials : 0
        let pBoom: Float = t > 25 ? ((horde ? 0.03 : 0.045) + 0.004 * d) * k * D.specials : 0
        var r = rng.next()
        var ty = T_RUN
        if r < pBrute { ty = T_BRUTE }
        else {
            r -= pBrute
            if r < pSpit { ty = T_SPIT }
            else {
                r -= pSpit
                if r < pBoom { ty = T_BOOM }
            }
        }
        if ty != T_RUN {
            let cap = Int((Float(SPECIAL_CAP[Int(ty)]) * D.specialCap).rounded()) + (ty == T_BRUTE ? 2 * beaconsDone : 0)
            if typeAlive[Int(ty)] >= cap { ty = T_RUN } else { typeAlive[Int(ty)] += 1 }
        }
        return ty
    }

    /// The gameplay cap only changes with an explicit quality choice.
    func capLeft() -> Int { bugCap - bugs.count }

    func squadCenter() -> Vec2 {
        var x: Float = 0, z: Float = 0, n: Float = 0
        for m in marines where !m.downed { x += m.x; z += m.z; n += 1 }
        if n == 0 { return Vec2(marines[0].x, marines[0].z) }
        return Vec2(x / n, z / n)
    }

    func queueBurst(_ e: Int, _ n: Int, _ rate: Float, _ vent: Vec2?) {
        queue.append(Burst(edge: e, n: n, rate: rate, acc: 0, vent: vent))
    }

    func startHorde(_ size0: Int, _ title: String? = nil, _ sub: String? = nil, _ rate: Float = 40) {
        var size = Float(size0)
        let c = squadCenter()
        let k = size > 300 ? 3 : 2
        if stage == .hold {
            // a few climb straight onto the lift rim; the bulk funnels up the ramp (visible pile-up, fair chokepoint)
            let L = level.lift
            let rim = pickEdge(L.x, L.z, 0, L.r + 1)
            if rim >= 0 { queueBurst(rim, Int((size * 0.12).rounded()), 14, nil) }
            size *= 0.88
        }
        for _ in 0..<k {
            let e = pickEdge(c.x, c.y, 13, 32)
            if e >= 0 { queueBurst(e, Int((size / Float(k)).rounded()), rate + rng.next() * 18, nil) }
        }
        hordes += 1
        if !simOnly && !attract {
            let t = title ?? "Орда!", s = sub ?? "Рой прорывается из бездны"
            emit(.hordeStarted(size: size0, title: t, subtitle: s))
            banner(t, s, false)
            emit(.hordeFlash)
            events.append(.sound(.siren, pos: nil, fromPlayer: false))
            events.append(.sound(.hordeRoar, pos: nil, fromPlayer: false))
            shake(0.25)
            haptic(.warning)
        }
    }

    func processQueue(_ dt: Float) {
        let L = level
        var q = 0
        while q < queue.count {
            queue[q].acc += queue[q].rate * dt
            while queue[q].acc >= 1 && queue[q].n > 0 {
                queue[q].acc -= 1; queue[q].n -= 1
                if capLeft() <= 0 { continue }
                let ty = pickType(true)
                if let v = queue[q].vent { spawnBug(ty, v.x, v.y, mode: 2) }
                else {
                    let e = edgeNear(queue[q].edge, 6)
                    spawnBug(ty, L.edgeX[e], L.edgeZ[e], mode: 1, nx: L.edgeNX[e], nz: L.edgeNZ[e], depth: 1.8 + rng.next() * 2.2)
                }
            }
            if queue[q].n <= 0 { queue.remove(at: q) } else { q += 1 }
        }
    }

    func hordeScale() -> Float { min(1, Float(bugCap) / 1400) * difficulty.horde }

    // ---------- per-tick ----------
    func tickDirector(_ dt: Float) {
        time += dt
        let minutes = time / 60
        let D = difficulty
        // flat per-beacon steps: escalation comes from the objective, not a cliff after the second beacon
        hpMul = (1 + 0.06 * Float(beaconsDone) + 0.06 * minutes) * D.hp
        dmgMul = (1 + 0.03 * Float(beaconsDone)) * D.dmg
        let P = marines[0], L = level
        var stageMul: Float = 1
        if !attract {
            switch stage {
            case .beacons:
                if activeBeacon < 0 {
                    for k in 0..<beacons.count {
                        let b = beacons[k]
                        if b.state == 0 && standingIn(b.x, b.z, BEACON_R) > 0 {
                            beacons[k].state = 1; activeBeacon = k; waveT = 2
                            startHorde(Int(((270 + D.beaconHordeStep * Float(beaconsDone)) * hordeScale()).rounded()), "Защищайте маяк",
                                       "Маяк «" + b.name + "» запускается — держите кольцо")
                            if !simOnly { emit(.beaconStarted(index: k)); events.append(.sound(.beacon, pos: nil, fromPlayer: false)) }
                            break
                        }
                    }
                } else {
                    let k = activeBeacon
                    let b = beacons[k]
                    stageMul = 2.0
                    // the ring charges only with a marine inside; bugs crowding the ring slow it down
                    beacons[k].contested = hash.queryCircle(bugs, b.x, b.z, BEACON_R - 0.5) >= 6
                    if standingIn(b.x, b.z, BEACON_R) > 0 {
                        beacons[k].progress = min(1, b.progress + dt / BEACON_TIME * (beacons[k].contested ? 0.3 : 1))
                    }
                    waveT -= dt
                    if waveT <= 0 {
                        waveT = 6 + rng.next() * 3
                        let vents = L.layout.vents.filter { hypotf2($0.x - b.x, $0.y - b.z) < 14 }
                        if !vents.isEmpty {
                            let v = vents[rng.int(vents.count)]
                            queueBurst(-1, Int(((38 + 8 * Float(beaconsDone)) * hordeScale()).rounded()), 22, v)
                        } else {
                            let e = pickEdge(b.x, b.z, 8, 22)
                            if e >= 0 { queueBurst(e, Int((30 * hordeScale()).rounded()), 24, nil) }
                        }
                    }
                    if beacons[k].progress >= 1 { completeBeacon(k) }
                }
            case .toLift:
                stageMul = 1.6
                if !P.downed && L.onLift(P.x, P.z) { startHold() }
            case .hold:
                stageMul = 3.2
                var on = false
                for m in marines where !m.downed && L.onLift(m.x, m.z) { on = true }
                if on {
                    liftT -= dt
                    // lift defence circuit: periodic shock pulse across the deck
                    pulseT -= dt
                    if pulseT <= 0 {
                        pulseT = D.pulseInterval
                        queueBoom(L.lift.x, L.lift.z, L.lift.r + 0.6, 48 * hpMul * D.pulseDamage, -1, .pulse)
                    }
                }
                if liftT <= 0 {
                    liftT = 0
                    // the lift only leaves with the player on it (a downed player is carried back by the squad first)
                    if L.onLift(P.x, P.z) {
                        stage = .extract; extractT = 0; queue.removeAll()
                        if !simOnly {
                            emit(.extractStarted)
                            banner("Эвакуация", "Лифт поднимается", true)
                            events.append(.sound(.lift, pos: nil, fromPlayer: false))
                        }
                    }
                }
            case .extract:
                stageMul = 0
                extractT += dt
                if extractT >= 4.6 { endGame(true); return }
            }
        } else {
            stageMul = bugs.count < 220 ? 1.5 : 0
        }
        // continuous trickle from the abyss edges
        if stageMul > 0 {
            let rate = (1.8 + 0.5 * minutes + 0.5 * Float(beaconsDone)) * stageMul * (attract ? 3 : 1) * D.trickle
            trickle += rate * dt
            if trickle >= 1 {
                let c = squadCenter()
                while trickle >= 1 {
                    trickle -= 1
                    if capLeft() <= 0 { trickle = 0; break }
                    let e = pickEdge(c.x, c.y, D.trickleMinDist, 32)
                    if e >= 0 { spawnBug(pickType(false), L.edgeX[e], L.edgeZ[e], mode: 1, nx: L.edgeNX[e], nz: L.edgeNZ[e]) }
                }
            }
            // periodic hordes (the timer pauses while a beacon defence is running)
            if activeBeacon < 0 { hordeT -= dt }
            if hordeT <= 0 {
                if stage == .hold {
                    hordeT = 13 + rng.next() * 4
                    startHorde(Int(((360 + rng.next() * 160) * hordeScale()).rounded()), "Орда!", "Они лезут на платформу", 55)
                } else {
                    hordeT = 45 + rng.next() * 15
                    startHorde(Int((min(520, 120 + 55 * Float(beaconsDone) + 25 * minutes) * hordeScale()).rounded()))
                }
            }
        }
        processQueue(dt)
        if comboT > 0 { comboT -= dt; if comboT <= 0 { combo = 0 } }
        if !attract && !godMode && marines.allSatisfy({ $0.downed }) { endGame(false) }
    }

    func completeBeacon(_ k: Int) {
        beacons[k].state = 2; beacons[k].progress = 1; activeBeacon = -1; beaconsDone += 1
        // a breather for the squad: everyone standing patches up a quarter of their armour
        for m in marines where !m.downed { m.hp = min(m.maxHp, m.hp + m.maxHp * difficulty.beaconHeal) }
        hordeT = max(hordeT, 28 + rng.next() * 10)   // breather before the next push
        if !simOnly {
            emit(.beaconCompleted(index: k))
            events.append(.sound(.beaconDone, pos: nil, fromPlayer: false))
            haptic(.success)
        }
        if beaconsDone >= beacons.count {
            stage = .toLift
            if !simOnly { emit(.liftCalled); banner("Лифт вызван", "Все к грузовой платформе", true) }
        } else if !simOnly {
            banner("Маяк запущен", "\(beaconsDone) из \(beacons.count) · ищите следующий", true)
        }
    }

    func startHold() {
        stage = .hold; liftT = LIFT_TIME; hordeT = 3; pulseT = 4
        let sub = "Лифт прибудет через \(Int(LIFT_TIME)) секунд"
        if !simOnly {
            emit(.holdStarted)
            banner("Держитесь", sub, false)
            events.append(.sound(.beacon, pos: nil, fromPlayer: false))
        }
        startHorde(Int((480 * hordeScale()).rounded()), "Держитесь", sub, 70)
    }

    func endGame(_ won: Bool) {
        if phase != .playing { return }
        phase = won ? .won : .lost
        if !simOnly {
            emit(won ? .victory : .defeat)
            events.append(.sound(won ? .victory : .defeat, pos: nil, fromPlayer: false))
            haptic(won ? .success : .error)
        }
    }

    // ---------- kills, XP, combo ----------
    func onBugKilled(_ ty: UInt8, _ src: Int, _ x: Float, _ z: Float) {
        kills += 1
        if simOnly || attract { return }
        xp += BUG_SPECS[Int(ty)].xp
        if src == 0 {
            playerKills += 1; combo += 1; comboT = 1.0   // a real streak: a second without a kill (or a hit taken) ends it
            if combo > bestCombo { bestCombo = combo }
            if !benchCombat {
                events.append(.sound(.kill, pos: nil, fromPlayer: true))
                if combo % 25 == 0 { emit(.combo(count: combo)); events.append(.sound(.combo, pos: nil, fromPlayer: true)) }
            }
        }
        while xp >= xpNext {
            xp -= xpNext; xpLevel += 1; xpNext = xpFor(xpLevel); pendingLevels += 1
            emit(.levelUp(level: xpLevel))
        }
    }

    // ---------- upgrades ----------
    /// Draw 3 level-up cards for the player's class (class cards weigh 1.5). Stored as `offer`.
    @discardableResult
    public func rollUpgrades() -> [Upgrade] {
        let cls = marines[0].cls
        var pool = UPGRADES.filter { $0.classes == nil || $0.classes!.contains(cls) }
        var pick: [Upgrade] = []
        while pick.count < 3 && !pool.isEmpty {
            var tot: Float = 0
            for u in pool { tot += u.classes != nil ? 1.5 : 1 }
            var r = rng.next() * tot
            var k = 0
            while k < pool.count {
                r -= pool[k].classes != nil ? 1.5 : 1
                if r <= 0 { break }
                k += 1
            }
            pick.append(pool.remove(at: min(k, pool.count - 1)))
        }
        offer = pick
        return pick
    }

    /// The UI should show the level-up cards now (the web game pauses the simulation meanwhile).
    public var wantsLevelUp: Bool { pendingLevels > 0 && stage != .extract && phase == .playing }

    /// Apply card `index` of the current offer; rolls a new offer if more levels are pending.
    @discardableResult
    public func chooseUpgrade(_ index: Int) -> Upgrade? {
        guard pendingLevels > 0, index >= 0, index < offer.count else { return nil }
        let u = offer[index]
        applyUpgrade(u.id)
        pendingLevels -= 1
        toast(u.name, .gold)
        offer = []
        if pendingLevels > 0 && !autoPickUpgrades { rollUpgrades() }
        return u
    }

    func applyUpgrade(_ id: UpgradeID) {
        let m = marines[0]
        switch id {
        case .dmg: m.mods.dmg *= 1.15
        case .rof: m.mods.rof *= 1.12
        case .pierce: m.mods.pierce += 1
        case .range: m.mods.range *= 1.18
        case .arad: m.mods.arad *= 1.2
        case .acd: m.mods.acd *= 0.85; m.abCd *= 0.85
        case .spd: m.mods.speed *= 1.08
        case .hp: m.maxHp += 20; if !m.downed { m.hp = m.maxHp }
        case .regen: m.mods.regen += 1.5
        case .dash: m.mods.dashCd *= 0.75
        case .squad: for o in marines where !o.isPlayer { o.mods.dmg *= 1.15 }
        case .cluster: m.mods.cluster += 3
        case .explosive: m.mods.explosive += 1
        case .burn: m.mods.burn *= 1.5
        case .cone: m.mods.cone *= 1.25
        case .shatter: m.mods.shatter *= 1.6
        case .chill: m.mods.chill *= 1.35
        case .turret: m.mods.turretDur += 5; m.mods.turretRof *= 1.3
        case .cool: m.mods.heat *= 1.35
        }
        upgradeCounts[id, default: 0] += 1
        // bots grow a little with the player so the squad keeps up with the escalation
        for o in marines where !o.isPlayer {
            o.mods.dmg *= difficulty.botGrow; o.maxHp += 3
            if !o.downed { o.hp = min(o.maxHp, o.hp + 10) }
        }
    }
}
