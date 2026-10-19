import Foundation

// ================================================================
//  COACH «Учебная высадка» — the five-step first-run tutorial (v1.1, web
//  11b-coach.js). tickCoach(dt) runs every tick right before tickDirector.
//  Each step completes on its action OR its timeout, never a fail state.
//  While steps 1–4 run, `calm` asks the director for no trickle, no hordes and
//  a frozen pressure clock; the first beacon of a coached run starts a smaller
//  horde (`beaconHordeMul`). The card and the ghost thumb are the app's
//  (`CoachText` gives the strings, `coach.target` the control to point at).
// ================================================================

/// Step timeouts (s); the beacon step has none.
let COACH_MAX: [Float] = [7, 12, 9, 8, .infinity]

/// Card texts of the coach (the app picks the variant by its input mode; the core pins the strings).
public enum CoachText {
    public static let steps = 5
    /// Touch: «Левый палец — бег» …; keyboard (WASD / IJKL / Q / пробел): «WASD — бег» ….
    public static func text(step: Int, abilityShort: String, keyboard: Bool) -> String {
        switch step {
        case 0: return keyboard ? "WASD — бег" : "Левый палец — бег"
        case 1: return keyboard ? "IJKL — прицел и огонь" : "Правый палец — прицел, огонь сам"
        case 2: return abilityShort + " — по толпе" + (keyboard ? " (Q)" : "")
        case 3: return "Рывок — из окружения" + (keyboard ? " (пробел)" : "")
        default: return "Маяк — встаньте в кольцо"
        }
    }
    /// «N/5».
    public static func counter(step: Int) -> String { "\(step + 1)/\(steps)" }
    public static let skip = "Пропустить"
    /// Every revive line the coach can show (warm-up).
    public static let reviveLines: [String] = BOT_NAMES.map { reviveLine($0) }
    static func reviveLine(_ name: String) -> String { name + " ранен — встаньте рядом, чтобы поднять" }
}

extension Game {

    /// Game init, after resetWorld (web coachBegin).
    func coachBegin() {
        coach = CoachState()
        coachGroupCount = 0
        coachSeenSent = false
        coachReviveArmed = config.reviveLineArmed && !attract
        if attract || !config.coach { return }
        coach.active = true
        beaconHordeMul = 0.65
        coachStep(0)
    }

    func coachStep(_ k: Int) {
        let P = marines[0]
        coach.step = k; coach.stepTime = 0
        coachStartX = P.x; coachStartZ = P.z; coachFire = 0
        calm = k <= 3
        if k == 1 { coachGroup(9, 16, 10, 5) }
        else if k == 2 { coachGroup(8, 13, 18, 30); P.abCd = 0 }
        else if k == 3 {
            var a = 0
            while a < 8 {
                let ang = Float(a) * TAU / 8
                let x = P.x + cosf2(ang) * 4.2, z = P.z + sinf2(ang) * 4.2
                if level.walkable(x, z) && capLeft() > 0 { coachSpawned(spawnBug(T_RUN, x, z, mode: 2)) }
                a += 1
            }
            P.dashCd = 0
        }
        emit(.coachStep(index: k))
    }

    /// Practice group: n runners from one stretch of railing dmin…dmax away (skipped when no edge qualifies).
    func coachGroup(_ dmin: Float, _ dmax: Float, _ n: Int, _ rate: Float) {
        let P = marines[0]
        var e = pickEdge(P.x, P.z, dmin, dmax)
        if e < 0 { e = pickEdge(P.x, P.z, dmin * 0.6, dmax + 8) }
        if e < 0 || coachGroupCount >= 2 { return }
        coachGroups[coachGroupCount] = CoachGroup(edge: e, n: n, rate: rate, acc: 0)
        coachGroupCount += 1
    }

    /// Practice runners come at half health.
    func coachSpawned(_ i: Int) {
        if i >= 0 { bugs.hp[i] *= 0.5; bugs.hpMax[i] *= 0.5 }
    }

    func coachQueue(_ dt: Float) {
        let L = level
        var q = 0
        while q < coachGroupCount {
            coachGroups[q].acc += coachGroups[q].rate * dt
            while coachGroups[q].acc >= 1 && coachGroups[q].n > 0 {
                coachGroups[q].acc -= 1; coachGroups[q].n -= 1
                if capLeft() <= 0 { continue }
                let e = edgeNear(coachGroups[q].edge, 6)
                coachSpawned(spawnBug(T_RUN, L.edgeX[e], L.edgeZ[e], mode: 1, nx: L.edgeNX[e], nz: L.edgeNZ[e], depth: 1.8 + rng.next() * 2.2))
            }
            if coachGroups[q].n <= 0 {   // drop the finished slot (swap the last one in)
                coachGroupCount -= 1
                coachGroups[q] = coachGroups[coachGroupCount]
            } else { q += 1 }
        }
    }

    /// Every tick before tickDirector (never in attract mode).
    func tickCoach(_ dt: Float) {
        if attract { return }
        // revive line: the first time a squadmate goes down in this run
        if coach.reviveTime > 0 {
            coach.reviveTime -= dt
            if coach.reviveTime <= 0 { coach.reviveTime = 0; coach.reviveLine = nil }
        }
        if coachReviveArmed {
            var k = 1
            while k < marines.count {
                if marines[k].downed {
                    coachReviveArmed = false
                    coach.reviveTime = 6
                    coach.reviveLine = CoachText.reviveLine(marines[k].name)
                    break
                }
                k += 1
            }
        }
        if !coach.active { return }
        coachQueue(dt)
        let P = marines[0], s = coach.step
        coach.stepTime += dt
        if P.firing { coachFire += dt }
        // walking onto a beacon ends the coach early: the player found the objective on their own
        if s <= 3 && activeBeacon >= 0 { coachEnd(seen: true); return }
        var ok = false
        switch s {
        case 0: ok = hypotf2(P.x - coachStartX, P.z - coachStartZ) >= 3
        case 1: ok = coachFire >= 1.2 && coach.stepTime > 2.5
        case 2: ok = P.abCd > 0.5
        case 3: ok = P.dashT > 0
        default: ok = activeBeacon >= 0
        }
        if !ok && coach.stepTime <= COACH_MAX[min(s, 4)] { return }
        haptic(.select)
        if ok { events.append(.sound(.click, pos: nil, loud: nil)) }
        if s >= 3 { coachMarkSeen() }   // seen enough: never forced again
        if s >= 4 { coachEnd(seen: true) } else { coachStep(s + 1) }
    }

    func coachEnd(seen: Bool) {
        coach.active = false; coach.step = -1; coach.stepTime = 0
        coachGroupCount = 0
        calm = false
        if seen { coachMarkSeen() }
        emit(.coachEnded)
    }

    /// Once per Game: the app stores `tut = 1`.
    func coachMarkSeen() {
        if coachSeenSent { return }
        coachSeenSent = true
        emit(.coachSeen)
    }

    /// The card's «Пропустить».
    public func coachSkip() {
        if !coach.active { return }
        events.append(.sound(.click, pos: nil, loud: nil))
        haptic(.select)
        coachEnd(seen: true)
    }

    /// Bots leave the practice groups to the player while fewer than two bugs press on them.
    @inline(__always) func coachHoldFire(_ m: Marine) -> Bool {
        coach.active && coach.step <= 3 && !m.isPlayer && crowd[m.index] < 2
    }
}
