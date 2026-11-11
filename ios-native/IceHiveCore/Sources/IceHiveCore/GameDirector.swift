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
        // v1.1 (web resetDirector + queenReset): a pressure clock, a warning or a fight never carries over
        calm = false; beaconHordeMul = 1; pressure = 0; idleMul = 1; huntPressure = false; huntAfk = false; heartAt = -9
        liftAllowance = -1
        beat = 0; beatT = 10; beaconPushes = 0; lullT = 0
        queen = QueenState()
        qWarn = -1; qEdge = -1; qSlot = -1; qBrood = 0; qVolley = 0; qRam = 0; qMeleeCd = 0; qArmed = false
        // the mission plan starts over at its first step (GameMission.swift)
        resetMission()
    }

    /// Index of the beacon the squad should go to (the active one, else the nearest unfinished one of the current RING
    /// step), -1 none.
    func nextBeacon() -> Int {
        if activeBeacon >= 0 { return activeBeacon }
        guard case .ring(let r)? = currentStep else { return -1 }
        let P = marines[0]
        var best = -1
        var bd: Float = 1e9
        for k in r.sites where beacons[k].state != 2 {
            let b = beacons[k]
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
        let t = time, d = Float(beaconsDone), k: Float = posture == .hold ? 0.5 : 1
        let D = difficulty
        // specials follow objective progress (not wall time): the first beacon already brings spitters and boomers,
        // brutes join halfway through it, and later beacons add only a little on top — or the tier's stall clock:
        // a squad that never touches an objective still meets brutes
        let prog = d + (activeBeacon >= 0 ? beacons[activeBeacon].progress : 0)
        let pBrute: Float = (beaconsDone >= 1 || prog > 0.5 || (t > D.stallTime && !attract)) ? (0.012 + 0.004 * d) * k : 0
        let pSpit: Float = t > 15 ? ((horde ? 0.05 : 0.07) + 0.008 * d) * k : 0
        let pBoom: Float = t > 25 ? ((horde ? 0.03 : 0.045) + 0.004 * d) * k : 0
        // wave pacing: fewer runners, a larger share of the bugs that matter (the special caps still hold)
        let mix: Float = D.waves ? D.mix : 1
        var r = rng.next() / (D.specials * mix)
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
            if Float(typeAlive[Int(ty)]) >= specialCapFor(ty) { ty = T_RUN } else { typeAlive[Int(ty)] += 1 }
        }
        return ty
    }

    /// Live cap of a special type: (SPECIAL_CAP + 2·done for brutes) · specCap, compared as a float (web; not rounded).
    func specialCapFor(_ ty: UInt8) -> Float {
        // wave pacing: a larger share of specials, lower live caps (a heavy fight is never a wall of brutes or a carpet
        // of boomers on a 250–350 swarm): spitters 14, brutes 5 + 1 per beacon done, boomers 10
        if difficulty.waves { return Float(WAVE_SPECIAL_CAP[Int(ty)] + (ty == T_BRUTE ? beaconsDone : 0)) * difficulty.specialCap }
        return Float(SPECIAL_CAP[Int(ty)] + (ty == T_BRUTE ? 2 * beaconsDone : 0)) * difficulty.specialCap
    }

    /// The gameplay cap only changes with an explicit quality choice.
    func capLeft() -> Int { bugCap - bugs.count }

    func squadCenter() -> Vec2 {
        var x: Float = 0, z: Float = 0, n: Float = 0
        for m in marines where !m.downed { x += m.x; z += m.z; n += 1 }
        if n == 0 { return Vec2(marines[0].x, marines[0].z) }
        return Vec2(x / n, z / n)
    }

    func queueBurst(_ e: Int, _ n: Int, _ rate: Float, _ vent: Vec2?, delay: Float = 0) {
        queue.append(Burst(edge: e, n: n, rate: rate, acc: -rate * delay, vent: vent))
    }

    /// `title` / `sub` (nil = the default horde banner) are only evaluated when the game shows text (not `simOnly`).
    func startHorde(_ size000: Int, _ title: @autoclosure () -> GameText? = nil, _ sub: @autoclosure () -> GameText? = nil, _ rate: Float = 40) {
        // (R7: the hive's stream thinned by seals; 1 on every other plan — the size as given)
        let size00 = streamK != 1 ? Int((Float(size000) * streamK).rounded()) : size000
        let size0: Int
        if difficulty.waves && !attract {
            // wave pacing: packs from 2–4 sides, staggered (GameWaves)
            size0 = wavesHorde(size00, rate)
        } else {
            // every horde is scaled by the tier here (web startHorde's first line; callers already rounded once)
            size0 = attract ? size00 : Int((Float(size00) * difficulty.horde).rounded())
            var size = Float(size0)
            let c = squadCenter()
            let k = size > 300 ? 3 : 2
            if posture == .hold {
                // a few climb straight onto the lift rim; the bulk funnels up the ramp (visible pile-up, fair chokepoint)
                let L = arena()
                let rim = pickEdge(L.x, L.z, 0, L.r + 1)
                if rim >= 0 { queueBurst(rim, Int((size * 0.12).rounded()), 14, nil) }
                size *= 0.88
            }
            for _ in 0..<k {
                let e = pickEdge(c.x, c.y, 13, 32)
                if e >= 0 { queueBurst(e, Int((size / Float(k)).rounded()), rate + rng.next() * 18, nil) }
            }
        }
        hordes += 1
        if !simOnly && !attract {
            let t = title() ?? .hordeTitle, s = sub() ?? .hordeSubtitle
            emit(.hordeStarted(size: size0, title: t, subtitle: s))
            banner(t, s, false)
            emit(.hordeFlash)
            events.append(.sound(.siren, pos: nil, loud: nil))
            events.append(.sound(.hordeRoar, pos: nil, loud: nil))
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

    /// Horde sizes no longer follow the gameplay cap (the web's min(1, cap / 1400) halved every horde on «Графика:
    /// низкая» and broke the tier bands): a low cap only limits the live swarm, so a tier plays the same on every
    /// quality. The tier's horde multiplier is applied inside startHorde, as on the web.
    func hordeScale() -> Float { 1 }

    // ---------- per-tick ----------
    func tickDirector(_ dt: Float) {
        time += dt
        let minutes = time / 60
        let D = difficulty
        // flat per-beacon steps: escalation comes from the objective, not a cliff after the second beacon
        hpMul = (1 + 0.06 * Float(beaconsDone) + 0.06 * minutes) * D.hp
        dmgMul = (1 + 0.03 * Float(beaconsDone)) * D.dmg
        let L = level
        var stageMul: Float = 1
        if !attract {
            // the mission plan: the current step's module (it may finish the step and begin the next one); nil = the
            // last step is done and the mission is won
            guard let m = missionTick(dt) else { return }
            // (× the hive's stream: R7's thinning switches; 1 on every other plan)
            stageMul = m * streamK
        } else {
            // (the title's attract swarm: smaller on the wave pacing)
            stageMul = D.waves ? (bugs.count < 95 ? 0.8 : 0) : (bugs.count < 220 ? 1.5 : 0)
        }
        // hive pressure: loitering on the move between objectives (no ring running, or dawdling on the way to a zone)
        // wakes the hive — past the tier's grace the trickle and the horde clock speed up and part of the swarm starts
        // hunting the player
        if !attract {
            var loiter = posture == .travel
            if loiter && approachAllowance {
                // the walk itself is the objective: the clock starts only once the travel allowance is used up
                if liftAllowance < 0 { liftAllowance = liftTravelAllowance() ?? -1 }
                if liftAllowance != 0 {
                    loiter = false
                    if liftAllowance > 0 { liftAllowance = max(0, liftAllowance - dt) }
                }
            }
            if !calm { pressure = loiter ? pressure + dt : max(0, pressure - 3 * dt) }
            let over = max(0, pressure - D.pressureGrace)
            idleMul = 1 + min(3, 0.05 * over)
            stageMul *= idleMul
            if over > 0 { hordeT -= dt * (idleMul - 1) }
            huntPressure = idleMul >= 1.5
            // (the legacy v1.0 row has no pressure and no AFK hunt)
            huntAfk = afkTime > 12 && D.pressureGrace.isFinite
            // heartbeat while the swarm converges (game time: silent in pause and menus)
            if !simOnly && time - heartAt >= 1.2 && threatState == .converging {
                heartAt = time
                events.append(.sound(.heart, pos: nil, loud: nil))
            }
        }
        // the first-run coach holds the swarm back (no trickle, no hordes)
        if calm { stageMul = 0; hordeT = max(hordeT, 25) }
        // wave pacing: lulls and peaks, packs from several sides (GameWaves)
        if D.waves && !attract {
            if stageMul > 0 { wavesTick(dt, stageMul) }
        }
        // continuous trickle from the abyss edges
        else if stageMul > 0 {
            let rate = (1.8 + 0.5 * minutes + 0.5 * Float(beaconsDone)) * stageMul * (attract ? 3 : D.trickle)
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
            // periodic hordes (the timer pauses while a ring is defended, and while the Матка lives)
            if posture != .defend && !queen.alive { hordeT -= dt }
            if hordeT <= 0 {
                if posture == .hold {
                    hordeT = 13 + rng.next() * 4
                    startHorde(Int(((360 + rng.next() * 160) * hordeScale() * holdHordeK).rounded()), .hordeTitle, GameText(holdHordeSub), 55)
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

    /// Beacon `k` of the current RING step is lit; the step ends with its last beacon (the next step begins: classic, the
    /// walk to the lift). False = the mission ended.
    @discardableResult
    func completeBeacon(_ k: Int) -> Bool {
        beacons[k].state = 2; beacons[k].progress = 1; activeBeacon = -1; beaconsDone += 1
        enterPhase(.approach)
        // a breather for the squad: everyone standing patches up a quarter of their armour
        for m in marines where !m.downed { m.hp = min(m.maxHp, m.hp + m.maxHp * difficulty.beaconHeal) }
        hordeT = max(hordeT, 28 + rng.next() * 10)   // breather before the next push
        if difficulty.waves { beat = 0; beatT = 10 + rng.next() * 4; lullT = 0 }
        if !simOnly {
            emit(.beaconCompleted(index: k))
            events.append(.sound(.beaconDone, pos: nil, loud: nil))
            haptic(.success)
        }
        guard case .ring(let r)? = currentStep else { return true }
        let p = ringProgress(r)
        if p.done >= p.total { return completeStep() }
        if !simOnly {
            banner(GameText(.bannerBeaconOnline), GameText(.bannerBeaconOnlineSub, [.int(p.done), .int(p.total)]), true)
        }
        return true
    }

    /// Seconds the walk from the player to the current step's zone (classic: the lift) may take before it counts as
    /// dawdling: the objective-flow path at full speed (5.3 m/s) × 1.3 + 5 s. nil while the objective flow still points
    /// at the last objective.
    func liftTravelAllowance() -> Float? {
        let L = zoneCenter(missionZone ?? .lift), P = marines[0]
        guard objFlowKey == (Int(L.x.rounded()), Int(L.y.rounded())) else { return nil }
        let d = objFlow.distance(level.cellOf(P.x, P.z))
        let path = d < FlowField.unreachable ? Float(d) : hypotf2(L.x - P.x, L.y - P.z) * 1.4
        return path / 5.3 * 1.3 + 5
    }

    func endGame(_ won: Bool) {
        if phase != .playing { return }
        phase = won ? .won : .lost
        if !simOnly {
            emit(won ? .victory : .defeat)
            events.append(.sound(won ? .victory : .defeat, pos: nil, loud: nil))
            haptic(won ? .success : .error)
        }
    }

    // ---------- kills, XP, combo ----------
    func onBugKilled(_ ty: UInt8, _ src: Int, _ x: Float, _ z: Float) {
        kills += 1
        if simOnly || attract { return }
        if difficulty.waves {
            // fewer, tougher kills: × xpK keeps the rhythm of level-ups (the fraction carries over)
            xpCarry += Float(BUG_SPECS[Int(ty)].xp) * difficulty.xpK
            let w = Int(xpCarry.rounded(.down))
            xpCarry -= Float(w)
            xp += w
        } else {
            xp += BUG_SPECS[Int(ty)].xp
        }
        if src == 0 {
            playerKills += 1; combo += 1; comboT = 1.0   // a real streak: a second without a kill (or a hit taken) ends it
            if combo > bestCombo { bestCombo = combo }
            if !benchCombat {
                events.append(.sound(.kill, pos: nil, loud: nil))
                if combo % 25 == 0 { emit(.combo(count: combo)); events.append(.sound(.combo, pos: nil, loud: nil)) }
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
        toast(GameText(.toastUpgrade, [.name(u.name)]), .gold)
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
