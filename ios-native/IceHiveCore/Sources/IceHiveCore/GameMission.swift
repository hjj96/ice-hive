import Foundation

// ================================================================
//  MISSION RUNTIME — plays the plan (Mission.swift) step by step (R1).
//  tickDirector calls `missionTick` where the hard-coded stage switch used
//  to be; the module code below is the old stage code, parameterised by the
//  step, with the same random draws in the same order, so «Operation Cold
//  Light» replays bit for bit. The director, the HUD, the threat state, the
//  bots and the calibration rows read the phase through `posture`, `stage`
//  and the queries at the end of this file instead of the old stage enum.
// ================================================================

/// How the wave director treats the current phase (the generic director, the threat state and the HUD read it).
enum DirectorPosture: Int {
    /// On the move between objectives: hive pressure, the travel beat, periodic hordes, the threat states.
    case travel
    /// A ring charging (beacon, switch): the periodic horde clock pauses, the hive answers the ring.
    case defend
    /// Holding a zone or fighting in a boss arena: hold hordes with a share over the zone's rim, fewer specials; a boss
    /// alive is the threat.
    case hold
    /// Riding out: no spawns.
    case ride
}

extension Game {

    // ---------------------------------------------------------------- the plan cursor

    /// The step the mission is on (the last one stays current after the mission is won).
    public var currentStep: MissionStep? { missionStep < mission.steps.count ? mission.steps[missionStep] : nil }

    /// The module of the current step.
    public var currentModule: MissionModule? { currentStep?.module }

    /// From resetDirector: the plan starts over at its first step.
    func resetMission() {
        missionStep = 0
        switches.removeAll(); activeSwitch = -1
        liftDur = LIFT_TIME
        // (R7: no vent shut, the full stream, no relight pending)
        switchesThrown = 0
        ventShut = [Bool](repeating: false, count: level.layout.vents.count)
        let ts = mission.tierStream, ti = difficulty.index
        streamK = ts.map { ti >= 0 && ti < $0.count ? $0[ti] : 1 } ?? 1
        pourT = 0
        relightQueue.removeAll(); relightNext = 0
        beginStep()
    }

    /// Begin step `missionStep` in its approach phase (an EXTRACT whose lift already holds the player rides at once).
    func beginStep() {
        guard let step = currentStep else { return }
        switch step {
        case .ring(let r):
            enterPhase(.approach)
            if ringProgress(r).done >= r.sites.count { completeStep() }
        case .switches(let s):
            switches = s.sites.map { SwitchState(site: $0) }
            activeSwitch = -1
            // (R7: the first pour out of an open seal's vent 4 s in)
            pourT = 4
            enterPhase(.approach)
            if !simOnly && missionStep > 0, let b = s.banner { banner(stepLine(b.title, []), stepLine(b.sub, []), true) }
            if s.needed == 0 { completeStep() }
        case .hold(let h):
            resetBossIfMet(h.boss != nil)
            liftAllowance = -1
            enterPhase(.approach)
            if !simOnly {
                if h.zone == .lift { emit(.liftCalled) }
                if let b = h.callBanner { banner(stepLine(b.title, []), stepLine(b.sub, []), true) }
            }
        case .boss:
            resetBossIfMet(true)
            liftAllowance = -1
            enterPhase(.approach)
        case .extract(let e):
            let P = marines[0]
            if level.onLift(P.x, P.z) { startRide(e) } else { liftAllowance = -1; enterPhase(.approach) }
        }
    }

    /// The current step's phase begins: the coarse stage the renderer and the report read, the director's posture.
    func enterPhase(_ p: StepPhase) {
        stepPhase = p
        stepTime = 0
        approachAllowance = false
        guard let step = currentStep else { return }
        let on = p == .active
        switch step {
        case .ring:
            stage = .beacons; posture = on ? .defend : .travel
        case .switches:
            stage = .switches; posture = on ? .defend : .travel
        case .hold(let h):
            stage = h.zone == .lift ? (on ? .hold : .toLift) : .area
            posture = on ? .hold : .travel
            approachAllowance = !on && h.travelAllowance
        case .boss(let b):
            stage = .boss; posture = on ? .hold : .travel
            approachAllowance = !on && b.travelAllowance
        case .extract(let e):
            stage = on ? .extract : .toLift
            posture = on ? .ride : .travel
            approachAllowance = !on && e.travelAllowance
        }
    }

    /// The current step is done: begin the next one, or win the mission after the last. Returns false when the
    /// mission ended (the director returns at once, as the old extraction did).
    @discardableResult
    func completeStep() -> Bool {
        if missionStep + 1 >= mission.steps.count {
            endGame(true)
            return false
        }
        missionStep += 1
        emit(.missionStep(index: missionStep, module: mission.steps[missionStep].module))
        beginStep()
        return phase == .playing
    }

    /// One director tick of the current step: its stage multiplier for this tick (the phase it started the tick in),
    /// or nil when the mission just ended.
    func missionTick(_ dt: Float) -> Float? {
        guard let step = currentStep else { return 0 }
        stepTime += dt
        switch step {
        case .ring(let r): return ringTick(r, dt)
        case .switches(let s): return switchTick(s, dt)
        case .hold(let h): return holdTick(h, dt)
        case .boss(let b): return bossStepTick(b, dt)
        case .extract(let e): return extractTick(e, dt)
        }
    }

    // ---------------------------------------------------------------- zones

    func zoneCenter(_ z: MissionZone) -> Vec2 {
        switch z {
        case .lift: return Vec2(level.lift.x, level.lift.z)
        case .circle(let x, let zz, _): return Vec2(x, zz)
        }
    }

    /// The zone's radius (the lift: its whole disc; who counts as on it is `inZone`).
    func zoneRadius(_ z: MissionZone) -> Float {
        switch z {
        case .lift: return level.lift.r
        case .circle(_, _, let r): return r
        }
    }

    /// Inside the zone (the lift: its deck, `Level.onLift`).
    @inline(__always) func inZone(_ z: MissionZone, _ x: Float, _ zz: Float) -> Bool {
        switch z {
        case .lift: return level.onLift(x, zz)
        case .circle(let cx, let cz, let r): return (x - cx) * (x - cx) + (zz - cz) * (zz - cz) < r * r
        }
    }

    /// The zone of the current HOLD or BOSS step, the lift of an EXTRACT; nil on ring steps.
    public var missionZone: MissionZone? {
        switch currentStep {
        case .hold(let h)?: return h.zone
        case .boss(let b)?: return b.zone
        case .extract?: return .lift
        default: return nil
        }
    }

    /// Where hold hordes climb over the rim and the boss comes up: the current zone, else the lift (x, z, r).
    func arena() -> (x: Float, z: Float, r: Float) {
        let z = missionZone ?? .lift
        let c = zoneCenter(z)
        return (c.x, c.y, zoneRadius(z))
    }

    /// The zone the bots spread over once the player stands in it (a hold, a boss fight, the ride), and its slot radius.
    var squadZone: MissionZone? {
        if stepPhase != .active { return nil }
        switch currentStep {
        case .hold(let h)?: return h.zone
        case .boss(let b)?: return b.zone
        case .extract?: return .lift
        default: return nil
        }
    }

    func slotRadius(_ z: MissionZone) -> Float {
        switch z {
        case .lift: return 5.2
        case .circle(_, _, let r): return max(1.2, min(5.2, r * 0.55))
        }
    }

    // ---------------------------------------------------------------- RING (the classic beacons)

    /// Beacons of the current RING step done, and its beacon count.
    func ringProgress(_ r: RingStep) -> (done: Int, total: Int) {
        var d = 0
        for k in r.sites where beacons[k].state == 2 { d += 1 }
        return (d, r.sites.count)
    }

    func ringTick(_ r: RingStep, _ dt: Float) -> Float? {
        let D = difficulty
        if activeBeacon < 0 {
            for k in r.sites {
                let b = beacons[k]
                if b.state == 0 && standingIn(b.x, b.z, r.radius) > 0 {
                    beacons[k].state = 1; activeBeacon = k; waveT = D.waves ? 9 : 2; beaconPushes = 0
                    enterPhase(.active)
                    // (wave pacing: a third of the stream's opening horde, from 3–4 sides; the pushes follow the charge)
                    let open: Float = D.waves ? 70 + 0.3 * D.beaconHordeStep * Float(beaconsDone) : 270 + D.beaconHordeStep * Float(beaconsDone)
                    startHorde(Int((open * hordeScale() * beaconHordeMul).rounded()),
                               GameText(.bannerDefend), GameText(.bannerDefendSub, [.name(b.name)]))
                    beaconHordeMul = 1
                    if !simOnly { emit(.beaconStarted(index: k)); events.append(.sound(.beacon, pos: nil, loud: nil)) }
                    break
                }
            }
            return 1
        }
        let k = activeBeacon
        let b = beacons[k]
        let mul = r.stageMul.value(D)
        // the ring charges only with a marine inside; bugs crowding the ring slow it down
        let contested = hash.queryCircle(bugs, b.x, b.z, r.radius - 0.5) >= r.contestedAt
        beacons[k].contested = contested
        chargeRing(b.x, b.z, r.radius, &beacons[k].progress, dt, r.chargeTime, rate: contested ? r.contestedRate : 1)
        if D.waves { wavesBeaconTick(k, dt) } else { waveT -= dt }
        if !D.waves && waveT <= 0 {
            waveT = 6 + rng.next() * 3
            let vents = level.layout.vents.indices.filter { ventOpen($0) && hypotf2(level.layout.vents[$0].x - b.x, level.layout.vents[$0].y - b.z) < 14 }
                .map { level.layout.vents[$0] }
            if !vents.isEmpty {
                let v = vents[rng.int(vents.count)]
                queueBurst(-1, Int(((38 + 8 * Float(beaconsDone)) * hordeScale() * D.horde).rounded()), 22, v)
            } else {
                let e = pickEdge(b.x, b.z, 8, 22)
                if e >= 0 { queueBurst(e, Int((30 * hordeScale() * D.horde).rounded()), 24, nil) }
            }
        }
        if beacons[k].progress >= 1 && !completeBeacon(k) { return nil }
        return mul
    }

    /// One tick of a «stand in the ring» charge (beacons, switches; R6's props reuse it): while a standing marine is
    /// inside, `progress` grows by dt / time × rate, up to 1. Returns whether one was inside.
    @discardableResult
    func chargeRing(_ x: Float, _ z: Float, _ r: Float, _ progress: inout Float, _ dt: Float, _ time: Float, rate: Float = 1) -> Bool {
        if standingIn(x, z, r) == 0 { return false }
        progress = min(1, progress + dt / time * rate)
        return true
    }

    // ---------------------------------------------------------------- SWITCH

    /// Switches of the current SWITCH step thrown.
    public var switchesDone: Int {
        var n = 0
        for s in switches where s.state == 2 { n += 1 }
        return n
    }

    /// The switch to go to: the one being thrown, else the nearest waiting one; -1 none.
    func nextSwitch() -> Int {
        if activeSwitch >= 0 { return activeSwitch }
        let P = marines[0]
        var best = -1
        var bd: Float = 1e9
        for (k, s) in switches.enumerated() where s.state != 2 {
            let d = hypotf2(s.site.x - P.x, s.site.z - P.z)
            if d < bd { bd = d; best = k }
        }
        return best
    }

    func switchTick(_ s: SwitchStep, _ dt: Float) -> Float? {
        let D = difficulty
        // R7 (Vent Purge): the open seals' vents pour packs while the step runs
        if let p = s.pour { ventPourTick(s, p, dt) }
        if activeSwitch < 0 {
            for k in switches.indices where switches[k].state == 0 {
                let w = switches[k].site
                if standingIn(w.x, w.z, w.radius) > 0 {
                    switches[k].state = 1; activeSwitch = k
                    enterPhase(.active)
                    // the hive answers: a surge from two sides at the switch (× the stream: R7's thinning)
                    let n = Int((s.alarm.value(D) * D.horde * (D.waves ? D.popK : 1) * streamK).rounded())
                    if n > 0 { surge(n, sides: 2, near: Vec2(w.x, w.z), dmin: 10, dmax: 26, rate: 9) }
                    if !simOnly { emit(.switchStarted(index: k)); events.append(.sound(.beacon, pos: nil, loud: nil)) }
                    break
                }
            }
            return 1
        }
        let k = activeSwitch
        let w = switches[k].site
        let mul = s.stageMul.value(D)
        if !chargeRing(w.x, w.z, w.radius, &switches[k].progress, dt, w.time) && s.drains > 0 {
            switches[k].progress = maxf(0, switches[k].progress - dt / w.time * s.drains)
        }
        // R7: the hive pushes again at the step's marks of the progress (the last push from three sides)
        let p = switches[k].pushes
        if p < s.pushes.count && switches[k].progress >= s.pushes[p] {
            switches[k].pushes = p + 1
            let n = Int((s.alarm.value(D) * s.pushK * D.horde * (D.waves ? D.popK : 1) * streamK).rounded())
            if n > 0 { surge(n, sides: p == s.pushes.count - 1 ? 3 : 2, near: Vec2(w.x, w.z), dmin: 10, dmax: 26, rate: 9) }
        }
        if switches[k].progress >= 1 && !throwSwitch(k, s) { return nil }
        return mul
    }

    /// Switch `k` is thrown (an escalation step if the step says so); the step ends with the last one needed. False = the
    /// mission ended.
    @discardableResult
    func throwSwitch(_ k: Int, _ s: SwitchStep) -> Bool {
        switches[k].state = 2; switches[k].progress = 1; activeSwitch = -1
        switchesThrown += 1
        if s.escalates { beaconsDone += 1 }
        // R7: each thinning switch thins the hive's stream; a seal shuts its vent for good
        if s.thins > 0 { streamK *= 1 - s.thins }
        if switches[k].site.kind == .seal { sealVent(switches[k].site.vent) }
        // R6's seam: a breaker switch brings back the light circuit whose breaker it stands on
        if !props.circuits.isEmpty { propsSwitchThrown(switches[k].site) }
        enterPhase(.approach)
        if !simOnly {
            emit(.switchThrown(index: k))
            events.append(.sound(.beaconDone, pos: nil, loud: nil))
            haptic(.success)
            if let t = s.doneToast { toast(GameText(t), .gold) }
        }
        if switchesDone >= s.needed { return completeStep() }
        return true
    }

    // ---------------------------------------------------------------- R7: vents, pours, the stream

    /// Vent `k` of the station takes packs (not shut by a seal).
    @inline(__always) func ventOpen(_ k: Int) -> Bool { k < 0 || k >= ventShut.count || !ventShut[k] }

    /// The station's vent `k` is sealed for good (a seal switch thrown): no pack pours out of it again.
    func sealVent(_ k: Int) {
        guard k >= 0 && k < ventShut.count, !ventShut[k] else { return }
        ventShut[k] = true
        if !simOnly {
            let v = level.layout.vents[k]
            emit(.ventSealed(index: k))
            sound(.shock, v.x, v.y)
        }
    }

    /// Every `pourGap` s (± 2 s) one open seal's vent of the step (waiting: not being sealed, not shut), picked at random,
    /// pours a pack: `pour` × the tier's horde (× its population scale on the wave pacing) × the stream.
    func ventPourTick(_ s: SwitchStep, _ pour: PacingValue, _ dt: Float) {
        pourT -= dt
        if pourT > 0 { return }
        pourT = s.pourGap + (rng.next() - 0.5) * 4
        var open = 0
        for w in switches where w.state == 0 && w.site.vent >= 0 && w.site.vent < ventShut.count && !ventShut[w.site.vent] { open += 1 }
        if open == 0 { return }
        var pick = rng.int(open), k = -1
        for (j, w) in switches.enumerated() where w.state == 0 && w.site.vent >= 0 && w.site.vent < ventShut.count && !ventShut[w.site.vent] {
            if pick == 0 { k = j; break }
            pick -= 1
        }
        if k < 0 { return }
        let D = difficulty
        let n = Int((pour.value(D) * D.horde * (D.waves ? D.popK : 1) * streamK).rounded())
        if n <= 0 { return }
        let vi = switches[k].site.vent, v = level.layout.vents[vi]
        queueBurst(-1, n, 5, v)
        emit(.ventPour(index: vi, count: n))
    }

    // ---------------------------------------------------------------- HOLD (the classic walk to the lift and its hold)

    func holdTick(_ h: HoldStep, _ dt: Float) -> Float? {
        let D = difficulty, P = marines[0]
        if stepPhase == .approach {
            let mul = h.approachMul.value(D)
            if !P.downed && inZone(h.zone, P.x, P.z) { startHold(h) }
            return mul
        }
        var mul = h.stageMul.value(D)
        // a boss comes into the hold `at` s into the counted hold; while she lives the trickle thins out (she is the horde)
        if let q = h.boss {
            queenTick(dt, expected: riderExpected(q), due: liftDur - liftT >= riderAt(q))
            if queen.alive { mul *= D.queen.trickle }
        }
        var on = false
        for m in marines where !m.downed && inZone(h.zone, m.x, m.z) { on = true }
        if on {
            liftT -= dt
            // lift defence circuit: periodic shock pulse across the deck (weaker toward the rim on the harder tiers)
            if h.pulse {
                pulseT -= dt
                if pulseT <= 0 {
                    if D.pulseDamage > 0 {
                        pulseT = D.pulseInterval
                        let a = arena()
                        queueBoom(a.x, a.z, a.r + 0.6, 48 * hpMul * D.pulseDamage, -1, .pulse)
                    } else { pulseT = 0.5 }
                }
            }
        }
        // R7 (Breaker Run): the station's dark circuits come back one by one over the hold
        if h.relights && relightNext < relightQueue.count { relightTick() }
        // the hold waits for its boss: it cannot end before she has come and died
        if let q = h.boss, q.locks, liftT <= 0 && (queen.alive || (!queen.spawned && riderExpected(q))) { liftT = 0.01 }
        if liftT <= 0 {
            liftT = 0
            // (the lift only leaves with the player on it: a downed player is carried back by the squad first)
            if !h.releaseWithPlayer || inZone(h.zone, P.x, P.z) {
                if !completeStep() { return nil }
            }
        }
        return mul
    }

    /// R7: the next dark circuit of the queue comes back each time the countdown passes another even share of the hold
    /// (n circuits: at 1/(n+1), 2/(n+1), …, n/(n+1)); one fixed already (a bot, the hive left it whole) is skipped.
    func relightTick() {
        guard liftDur.isFinite && liftDur > 0 else { return }
        let f = 1 - max(0, liftT) / liftDur, n = relightQueue.count
        while relightNext < n && f >= Float(relightNext + 1) / Float(n + 1) {
            let c = relightQueue[relightNext]
            relightNext += 1
            if c >= 0 && c < props.circuits.count && props.circuits[c].needsRestore { restoreCircuit(c) }
        }
    }

    /// The player stepped into the zone: the countdown, the opening horde (a share over the zone's rim).
    func startHold(_ h: HoldStep) {
        enterPhase(.active)
        liftT = h.time; liftDur = h.time; hordeT = h.firstHorde.value(difficulty); pulseT = 4
        // R7 (Breaker Run): the circuits still dark (or with lamps out) when the hold starts, nearest to the zone first
        relightQueue.removeAll(); relightNext = 0
        if h.relights && !props.circuits.isEmpty {
            let c = zoneCenter(h.zone)
            relightQueue = props.circuits.indices.filter { props.circuits[$0].needsRestore }.sorted {
                let a = props.circuits[$0].site, b = props.circuits[$1].site
                return hypotf2(a.x - c.x, a.z - c.y) < hypotf2(b.x - c.x, b.z - c.y)
            }
        }
        // (an endless hold — a holdout — has no countdown to name)
        let n = h.time.isFinite ? Int(h.time) : 0
        if !simOnly {
            emit(.holdStarted)
            if let b = h.holdBanner { banner(stepLine(b.title, [.int(n)]), stepLine(b.sub, [.int(n)]), false) }
            events.append(.sound(.beacon, pos: nil, loud: nil))
        }
        let hb = h.holdBanner, open = h.openHorde.value(difficulty)
        if open > 0 {
            startHorde(Int((open * hordeScale()).rounded()), hb.map { stepLine($0.title, [.int(n)]) }, hb.map { stepLine($0.sub, [.int(n)]) }, 70)
        }
        if difficulty.waves { lullT = 10 }
    }

    /// × the current HOLD step's periodic hordes (1 outside a hold: the classic numbers).
    var holdHordeK: Float {
        if case .hold(let h)? = currentStep { return h.hordeK }
        return 1
    }

    /// The subtitle of the current hold's periodic hordes (the lift's outside a hold).
    var holdHordeSub: TextID {
        if case .hold(let h)? = currentStep { return h.hordeSub }
        return .bannerHordeLiftSub
    }

    /// The rider comes on this tier (or the debug `queenAt` sends her).
    func riderExpected(_ q: BossRider) -> Bool { (config.queenAt ?? q.at ?? difficulty.queen.at).isFinite }

    /// Seconds of counted hold before her warning.
    func riderAt(_ q: BossRider) -> Float { config.queenAt ?? q.at ?? difficulty.queen.at }

    /// A step that brings a boss starts from a fresh boss state when an earlier step already met her.
    func resetBossIfMet(_ brings: Bool) {
        if !brings || !queen.spawned { return }
        queen = QueenState()
        qWarn = -1; qEdge = -1; qSlot = -1; qBrood = 0; qVolley = 0; qRam = 0; qMeleeCd = 0; qArmed = false
    }

    // ---------------------------------------------------------------- BOSS

    /// The tier has the boss (the legacy row has none; a debug health brings her anyway).
    var bossAvailable: Bool { config.queenHp != nil || difficulty.queen.hp > 0 }

    func bossStepTick(_ b: BossStep, _ dt: Float) -> Float? {
        let D = difficulty, P = marines[0]
        if stepPhase == .approach {
            let mul = b.approachMul.value(D)
            if !P.downed && inZone(b.zone, P.x, P.z) { enterPhase(.active) }
            return mul
        }
        var mul = b.stageMul.value(D)
        if !bossAvailable {
            return completeStep() ? mul : nil
        }
        queenTick(dt, expected: true, due: stepTime >= (config.queenAt ?? b.delay))
        if queen.alive { mul *= D.queen.trickle }
        if queen.done && !completeStep() { return nil }
        return mul
    }

    // ---------------------------------------------------------------- EXTRACT

    func extractTick(_ e: ExtractStep, _ dt: Float) -> Float? {
        if stepPhase == .approach {
            let mul = e.approachMul.value(difficulty), P = marines[0]
            if level.onLift(P.x, P.z) { startRide(e) }
            return mul
        }
        extractT += dt
        if extractT >= e.duration && !completeStep() { return nil }
        return 0
    }

    /// The lift leaves (the spawn queue is dropped).
    func startRide(_ e: ExtractStep) {
        enterPhase(.active)
        extractT = 0; queue.removeAll()
        if !simOnly {
            emit(.extractStarted)
            banner(GameText(.bannerExtract), GameText(.bannerExtractSub), true)
            events.append(.sound(.lift, pos: nil, loud: nil))
        }
    }

    // ---------------------------------------------------------------- debug / demo staging (R7)

    /// The switch being thrown jumps to `p` of its ring (demo staging: the CI shot of a ring nearly full); none: no-op.
    public func debugSwitchProgress(_ p: Float) {
        guard activeSwitch >= 0 && activeSwitch < switches.count else { return }
        switches[activeSwitch].progress = clampf(p, 0, 0.999)
    }

    /// A pack of `count` pours out of the station's vent `k` now (demo staging), unless a seal shut it.
    public func debugVentPour(_ k: Int, count: Int) {
        guard k >= 0 && k < level.layout.vents.count && ventOpen(k) && count > 0 else { return }
        queueBurst(-1, count, 6, level.layout.vents[k])
        emit(.ventPour(index: k, count: count))
    }

    // ---------------------------------------------------------------- queries (HUD, bots, coach, calibration)

    /// `id` with as many of `args` as its signature takes, in order: a step can swap in a line that names fewer things
    /// (the Queen's hold line has no name, the generic boss line names her).
    func stepLine(_ id: TextID, _ args: [TextArg]) -> GameText {
        let n = id.signature.count
        return GameText(id, n >= args.count ? args : Array(args.prefix(n)))
    }

    /// The objective's ring is being worked: a beacon charging or a switch being thrown (the coach's last step).
    var objectiveEngaged: Bool { activeBeacon >= 0 || activeSwitch >= 0 }

    /// A HOLD step's countdown is running (calibration: downs and swarm sizes «in the hold»).
    public var holdActive: Bool { stepPhase == .active && currentModule == .hold }

    /// Calibration: the stage name of the current phase (rows' `stage` and `stageAt`; the classic beacons · toLift ·
    /// hold · extract).
    public var calibStage: String {
        guard let step = currentStep else { return "" }
        let on = stepPhase == .active
        switch step {
        case .ring(let r): return on ? r.names.active : r.names.approach
        case .switches(let s): return on ? s.names.active : s.names.approach
        case .hold(let h): return on ? h.names.active : h.names.approach
        case .boss(let b): return on ? b.names.active : b.names.approach
        case .extract(let e): return on ? e.names.active : e.names.approach
        }
    }

    /// Calibration: the `downSt` key of a down now (RING: b1…b3 while a beacon charges, «trav» between them; else the
    /// stage name).
    public var calibDownKey: String {
        if currentModule == .ring { return activeBeacon >= 0 ? "b\(beaconsDone + 1)" : "trav" }
        return calibStage
    }

    /// Calibration: the `idleSt` key (RING: b1…b3 / trav0…trav2; else the stage name).
    public var calibIdleKey: String {
        if currentModule == .ring { return activeBeacon >= 0 ? "b\(beaconsDone + 1)" : "trav\(beaconsDone)" }
        return calibStage
    }

    /// Objective lines of the modules beyond the classic ones, at their widest arguments (the HUD's layout check; R7's
    /// missions' lines too).
    public static var moduleObjectiveSamples: [GameText] {
        [GameText(.objSwitches, [.int(6), .int(6)]), GameText(.objHoldRing), GameText(.objReach), GameText(.objHoldArea, [.clock(599)]),
         GameText(.objKillBoss, [.name(.queen)]), GameText(.objWakingMove), GameText(.objConvergeMove),
         GameText(.objRestorePower, [.int(6), .int(6)]), GameText(.objHoldBreaker), GameText(.objToGenerator),
         GameText(.objHoldGenerator, [.clock(599)]), GameText(.objSealVents, [.int(6), .int(6)]), GameText(.objHoldSeal)]
    }

    /// R7: the report strip of a plan that draws its own (`MissionPlan.ownStrip`; nil: the classic strip): one item per
    /// beacon of a RING step, per switch a SWITCH step needs, per HOLD (+ its boss rider), BOSS and EXTRACT — at most six
    /// (the report's strip). On: a beacon lit, a switch thrown, a hold or boss fight reached, the boss killed, the ride.
    func planStrip(won: Bool) -> [ReportStripItem]? {
        guard mission.ownStrip else { return nil }
        var out: [ReportStripItem] = []
        var lit = 0
        for b in beacons where b.state == 2 { lit += 1 }
        var rings = 0, thrown = 0
        for (k, step) in mission.steps.enumerated() {
            let reached = won || missionStep > k || (missionStep == k && stepPhase == .active)
            switch step {
            case .ring(let r):
                for _ in r.sites { out.append(ReportStripItem(label: GameText(r.stripText ?? .reportStripBeacon), on: lit > rings)); rings += 1 }
            case .switches(let s):
                for _ in 0..<s.needed { out.append(ReportStripItem(label: GameText(s.stripText ?? .reportStripBeacon), on: switchesThrown > thrown)); thrown += 1 }
            case .hold(let h):
                out.append(ReportStripItem(label: GameText(h.stripText ?? .reportStripLift), on: reached))
                if h.boss != nil { out.append(ReportStripItem(label: GameText(.reportStripQueen), on: won || (queen.spawned && queen.done))) }
            case .boss(let b):
                out.append(ReportStripItem(label: GameText(b.stripText ?? .reportStripQueen), on: won || (queen.spawned && queen.done)))
            case .extract(let e):
                out.append(ReportStripItem(label: GameText(e.stripText ?? .reportStripExtract), on: won))
            }
        }
        return Array(out.prefix(6))
    }
}
