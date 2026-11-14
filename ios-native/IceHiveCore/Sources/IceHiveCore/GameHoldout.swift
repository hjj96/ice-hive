import Foundation

// ================================================================
//  HOLDOUT RUNTIME (Stage 2 D1 «Dig In»; data: DigIn.swift) — an endless
//  HOLD fought in waves. GameMission's HOLD hands its active phase over
//  to `holdoutTick` when the step carries `HoldStep.waves`; every other
//  hold runs exactly as before. Per tick, with plain scalars only (no
//  allocation, like the rest of the director):
//    the Queen   her arrival rule `BossArrival.waves` (GameBoss.swift):
//                the peak of every wave she leads; her death counts once,
//                the rider is re-armed at the next wave she leads
//    the pulse   the lift's shock pulse while a marine stands on its deck
//    the wave    lull → build-up → peak (its horde through startHorde:
//                over the lift's rim, the decks around it, down the
//                overhead's routes) → held (the swarm cleared, the peak's
//                time out, or the Queen dead) → the next wave's lull
//    the score   kills + waves held + Queens killed; banked on every
//                `bankEvery`-th wave held — a banked score survives the
//                fall (the report: Profile.swift)
//  The generic hold's horde clock stays off (the waves are its hordes),
//  the trickle follows the wave's phase (the stage multiplier returned).
// ================================================================
extension Game {

    // ---------------------------------------------------------------- the plan's holdout

    /// The plan's waves (its holdout HOLD's), nil on every other plan.
    public var holdoutSpec: HoldoutWaves? {
        for s in mission.steps { if case .hold(let h) = s, let w = h.waves { return w } }
        return nil
    }

    /// The plan holds out (Stage 2 D1: a HOLD fought in waves).
    public var holdoutOn: Bool { holdoutSpec != nil }

    /// The current step's waves (a holdout's HOLD), nil on every other step.
    public var holdoutWaves: HoldoutWaves? {
        if case .hold(let h)? = currentStep { return h.waves }
        return nil
    }

    /// A holdout's live score: the player's kills, the waves held and the Queens killed (0 before its hold started and on
    /// every other plan). `holdout.banked` is the part that survives the fall.
    public var holdoutScore: Int { holdout.wave > 0 ? playerKills + holdout.points : 0 }

    /// The rider of the current holdout leads wave `n` (`BossArrival.waves`, on a tier that has it).
    public func holdoutQueenLeads(_ n: Int) -> Bool {
        guard case .hold(let h)? = currentStep, let q = h.boss, case .waves(let first, let every) = q.arrival, riderExpected(q) else { return false }
        return Game.queenLeads(n, first: first, every: every)
    }

    /// Wave `n` is one of `first`, `first + every`, `first + 2 every` …
    static func queenLeads(_ n: Int, first: Int, every: Int) -> Bool {
        n >= first && (n - first) % max(1, every) == 0
    }

    /// `BossArrival.waves`: her warning may start — the peak of a wave she leads, where she has not come yet.
    func holdoutQueenDue(first: Int, every: Int) -> Bool {
        holdout.phase == .peak && holdout.queenWave != holdout.wave && Game.queenLeads(holdout.wave, first: first, every: every)
    }

    // ---------------------------------------------------------------- the hold

    /// The hold started (the player on the lift's deck): wave 1 builds at once. The generic hold's horde clock and its
    /// forced lull stay off — the waves are the hold's hordes.
    func holdoutBegin(_ w: HoldoutWaves) {
        holdout = HoldoutState()
        holdout.wave = 1
        holdout.phase = .build
        hordeT = 1e9
        lullT = 0
    }

    /// One director tick of a holdout's active hold: the Queen by her arrival rule, the lift's pulse, the wave's phase. Returns
    /// the trickle's stage multiplier; it never ends the mission (only the squad's fall does).
    func holdoutTick(_ h: HoldStep, _ w: HoldoutWaves, _ dt: Float) -> Float {
        let D = difficulty
        // (the waves are the hordes: the generic hold's clock stays off)
        hordeT = 1e9
        holdout.t += dt
        // the Queen leads her waves (`BossArrival.waves`): her death counts once; the rider is re-armed when the next wave she
        // leads reaches its peak (until then the report, the HUD and calibration see her dead)
        if let q = h.boss {
            if boss.done && holdout.queenDeadT < 0 {
                holdout.queenDeadT = 0
                holdout.queensKilled += 1
                holdout.points += w.queenScore
            }
            bossTick(dt, expected: riderExpected(q), due: riderDue(q))
            if boss.alive || bossRT.warnT >= 0 { holdout.queenWave = holdout.wave }
            if holdout.queenDeadT >= 0 { holdout.queenDeadT += dt }
        }
        // the lift's shock pulse while a marine stands on its deck (weaker toward the rim on the harder tiers; a boss's phase
        // may cut it while the boss lives)
        var on = false
        for m in marines where !m.downed && inZone(h.zone, m.x, m.z) { on = true }
        if on && h.pulse && !(boss.alive && bossRT.pulseOff) {
            pulseT -= dt
            if pulseT <= 0 {
                if D.pulseDamage > 0 {
                    pulseT = D.pulseInterval
                    let a = arena()
                    queueBoom(a.x, a.z, a.r + 0.6, 48 * hpMul * D.pulseDamage, -1, .pulse)
                } else { pulseT = 0.5 }
            }
        }
        // the wave: lull → build-up → peak → held
        var mul: Float
        switch holdout.phase {
        case .lull:
            mul = w.lullMul
            if holdout.t >= w.lull { holdout.phase = .build; holdout.t = 0 }
        case .build:
            mul = w.lullMul + (w.peakMul - w.lullMul) * clampf(holdout.t / maxf(0.1, w.build), 0, 1)
            if holdout.t >= w.build { holdoutPeak(h, w) }
        case .peak:
            mul = w.peakMul
            if holdoutWaveHeld(w) { holdoutHold(w) }
        }
        // (the Queen: «she is the horde» — the trickle thins while she lives, her row's × 0.4 / 0.4 / 0.6)
        if boss.alive { mul *= bossSpec.trickle }
        return h.stageMul.value(D) * mul
    }

    /// The wave's peak: its horde (startHorde on the hold's posture — a share over the lift's rim, a share down the overhead's
    /// routes over the zone, the rest from the decks around it) and its banner; a wave the Queen leads re-arms her (a fresh
    /// boss: her warning comes on the next tick, her horde is smaller).
    func holdoutPeak(_ h: HoldStep, _ w: HoldoutWaves) {
        let n = holdout.wave, D = difficulty
        holdout.phase = .peak
        holdout.t = 0
        let queen = holdoutQueenLeads(n)
        if queen, let q = h.boss {
            if boss.done { riderRearm(q) }
            holdout.queenDeadT = -1
        }
        let s000 = Int((w.horde(n, queen: queen) * hordeScale()).rounded())
        // (its size as startHorde counts it — the stream, then the tier — and the live swarm the wave is held at)
        let s00 = streamK != 1 ? Int((Float(s000) * streamK).rounded()) : s000
        holdout.horde = Int((Float(s00) * D.horde * (D.waves ? D.popK : 1)).rounded())
        holdout.clearAt = max(w.clearMin, Int((Float(holdout.horde) * w.clearK).rounded()))
        startHorde(s000, GameText(.bannerWave, [.int(n)]), GameText(queen ? TextID.bannerWaveQueenSub : h.hordeSub), w.hordeRate)
        emit(.holdoutWave(wave: n, queen: queen))
        // (first sighting: the first wave the Queen leads — her death banks the score)
        if queen && !holdout.tipShown {
            holdout.tipShown = true
            toast(GameText(.toastTipBank), .info)
        }
    }

    /// The current wave is held: its peak ran `peakMin` s and the swarm is down to `clearAt` (or `peakMax` s passed); a wave
    /// the Queen leads once she came and died (then when the swarm is down, or `peakMin` s after her death). If she has not
    /// come within `peakMax` s (no rim edge to climb — never on Kelvin-9) it is held like any other: the hold never stalls.
    func holdoutWaveHeld(_ w: HoldoutWaves) -> Bool {
        let alive = bugs.aliveCount
        if holdoutQueenLeads(holdout.wave) && (holdout.queenWave == holdout.wave || holdout.t < w.peakMax) {
            if holdout.queenWave != holdout.wave || boss.alive || bossRT.warnT >= 0 || holdout.queenDeadT < 0 { return false }
            return alive <= holdout.clearAt || holdout.queenDeadT >= w.peakMin
        }
        if holdout.t < w.peakMin { return false }
        return alive <= holdout.clearAt || holdout.t >= w.peakMax
    }

    /// Wave `held + 1` is held: its score, an escalation step of the director, the bank on every `bankEvery`-th wave, then
    /// the next wave's lull.
    func holdoutHold(_ w: HoldoutWaves) {
        holdout.held += 1
        holdout.points += w.waveScore
        let n = holdout.held
        if w.escalateEvery > 0 && n % w.escalateEvery == 0 { beaconsDone += 1 }
        emit(.holdoutHeld(wave: n))
        if w.banks(n) { holdoutBank(w) }
        holdout.wave = n + 1
        holdout.phase = .lull
        holdout.t = 0
    }

    /// The score banks: it survives the fall. The squad patches up (the tier's breather, as at a beacon lit); the banner
    /// shows the banked score as the report will (× the tier's multiplier).
    func holdoutBank(_ w: HoldoutWaves) {
        holdout.banked = holdoutScore
        holdout.bankWave = holdout.held
        holdout.banks += 1
        if w.bankHeal { for m in marines where !m.downed { m.hp = minf(m.maxHp, m.hp + m.maxHp * difficulty.beaconHeal) } }
        emit(.holdoutBanked(wave: holdout.held, score: holdout.banked))
        if !simOnly {
            let shown = RunScore.scaled(holdout.banked, tierMul: difficulty.scoreMul)
            banner(GameText(.bannerBanked), GameText(.bannerBankedSub, [.num(shown), .int(holdout.held + max(1, w.bankEvery))]), true)
            events.append(.sound(.beaconDone, pos: nil, loud: nil))
            haptic(.success)
        }
    }

    // ---------------------------------------------------------------- queries (HUD, report, demos)

    /// The objective line of a holdout: the Queen while she lives, the wave held in a lull, else the wave (and the bank it
    /// brings).
    func holdoutObjective(_ w: HoldoutWaves, _ ts: ThreatState) -> GameText {
        if ts == .boss { return GameText(.objDigInQueen) }
        if holdout.phase == .lull && holdout.held > 0 { return GameText(.objDigInHeld, [.int(holdout.held)]) }
        if w.banks(holdout.wave) { return GameText(.objDigInBank, [.int(holdout.wave)]) }
        return GameText(.objDigIn, [.int(max(1, holdout.wave))])
    }

    /// A holdout's objective bar: the way to the next bank (waves held since the last one, of `bankEvery`); −1 elsewhere.
    public var holdoutProgress: Float {
        guard let w = holdoutWaves, w.bankEvery > 0 else { return -1 }
        return Float(holdout.held % w.bankEvery) / Float(w.bankEvery)
    }

    /// Changes whenever a holdout's objective line would (the HUD's `objectiveKey`).
    var holdoutKey: Int { holdout.wave * 4 + holdout.phase.rawValue + 1 }

    /// The lift ring's fill in a hold (the renderer): the countdown's share; a hold without one — a holdout — the way to its
    /// next bank.
    public var holdProgress: Float {
        if liftDur.isFinite && liftDur > 0 { return 1 - liftT / liftDur }
        return max(0, holdoutProgress)
    }

    /// The report's numbers of a holdout (nil on every other plan).
    func holdoutSummary() -> HoldoutSummary? {
        guard let w = holdoutSpec else { return nil }
        let waves = holdout.held * w.waveScore
        return HoldoutSummary(held: holdout.held, kills: playerKills, waveScore: waves, queens: holdout.queensKilled,
                              queenScore: holdout.points - waves, banked: holdout.banked, bankWave: holdout.bankWave, bankEvery: w.bankEvery)
    }

    /// Objective lines of a holdout at their widest arguments (the HUD's layout check).
    static var holdoutObjectiveSamples: [GameText] {
        [GameText(.objDigIn, [.int(99)]), GameText(.objDigInBank, [.int(95)]), GameText(.objDigInHeld, [.int(99)]), GameText(.objDigInQueen)]
    }

    // ---------------------------------------------------------------- debug / demo staging

    /// Demo / tests: the holdout jumps to wave `n` — its build-up ends on the next tick (the peak) — as if the waves before it
    /// were held (their score, escalation steps and banks counted; a wave the Queen leads is held only once she died: her kill
    /// counted too); no-op outside a running holdout.
    public func debugHoldoutWave(_ n: Int) {
        guard let w = holdoutWaves, stepPhase == .active, n >= 1 else { return }
        while holdout.held + 1 < n {
            holdout.held += 1
            holdout.points += w.waveScore
            if holdoutQueenLeads(holdout.held) { holdout.queensKilled += 1; holdout.points += w.queenScore }
            if w.escalateEvery > 0 && holdout.held % w.escalateEvery == 0 { beaconsDone += 1 }
            if w.banks(holdout.held) { holdout.banked = holdoutScore; holdout.bankWave = holdout.held; holdout.banks += 1 }
        }
        holdout.wave = holdout.held + 1
        holdout.phase = .build
        holdout.t = w.build
    }

    /// Demo / tests: the current wave is held now (a Queen leading it dies first — her death counts); no-op outside a running
    /// holdout.
    public func debugHoldoutHold() {
        guard let w = holdoutWaves, stepPhase == .active else { return }
        if boss.alive || bossRT.warnT >= 0 { bossSkip() }
        if boss.done && holdout.queenDeadT < 0 {
            holdout.queenDeadT = 0
            holdout.queensKilled += 1
            holdout.points += w.queenScore
        }
        holdoutHold(w)
    }
}
