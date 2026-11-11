import Foundation

// ================================================================
//  BOSS FRAMEWORK — the runtime (Stage 2 B1; data: Boss.swift). One boss at
//  a time: the current step's (a HOLD's rider, a BOSS step). `bossTick`
//  runs it once per director tick, with fixed buffers only (no allocation
//  per tick):
//    warning → spawn       the spec's ring for `warn` s, then the body
//    the body              a bug body walks with its type's AI; a chain's
//                          head is steered by the boss's own file (or a
//                          track) and its parts follow (GameBossBody.swift)
//    phases                HP thresholds: speed, cooldowns, the hive's
//                          answer, arena hazards, a stagger
//    moves                 in spec order: the instant ones on their clocks
//                          (brood, volley, a body's charge), the
//                          telegraphed ones wind-up → active → cooldown
//    damage                a chain's parts route every hit to the head's
//                          health — the boss bar — × the part's multiplier,
//                          its window, its pool, brittle, struck from behind
//    death                 the blast, the medkits, the bounty, the banner
//  The special cases v1.1 spread over six files (pulse immunity, freeze
//  checks, the bite's clock and ×1.6, the charge's source, the death) read
//  the spec here: `Swarm.boss` marks the boss's slots.
// ================================================================

/// The framework's runtime (fixed buffers allocated once per Game).
final class BossRuntime {
    // ---- warning and spawn
    /// Seconds left of the warning (-1 none), the rim edge it comes over (-1 none), a point spawn's place and heading.
    var warnT: Float = -1
    var edge = -1
    var spawnX: Float = 0, spawnZ: Float = 0, spawnY: Float = 0, spawnHd: Float = 0
    /// The body's swarm slot from the last tick (a chain: the head), -1 none.
    var slot = -1
    /// A bug body's bite clock (its own attack cooldown is the charge's gate).
    var biteCd: Float = 0
    /// A periodic rider (`BossArrival.every`): the step time of its next arrival.
    var nextAt: Float = 0
    /// A phase's `.pulseOff`: the hold's lift pulse is off while the boss lives.
    var pulseOff = false
    // ---- moves (by index into the spec's moves)
    var clock = [Float](repeating: 0, count: BOSS_MOVES)
    /// 0 idle (its clock runs), 1 wind-up, 2 active.
    var stage = [UInt8](repeating: 0, count: BOSS_MOVES)
    var timer = [Float](repeating: 0, count: BOSS_MOVES)
    /// A body charge allowed (the clock ran out and the charge's cooldown was released).
    var armed = [Bool](repeating: false, count: BOSS_MOVES)
    /// A telegraphed move's aim: the point (slam, drop) or the origin (lane, cone), its direction, its telegraph's pool
    /// slot (-1 none), the marines a sweep struck (bit k), a drop's random turn.
    var ax = [Float](repeating: 0, count: BOSS_MOVES), az = [Float](repeating: 0, count: BOSS_MOVES)
    var adx = [Float](repeating: 0, count: BOSS_MOVES), adz = [Float](repeating: 1, count: BOSS_MOVES)
    var tele = [Int](repeating: -1, count: BOSS_MOVES)
    var struck = [UInt8](repeating: 0, count: BOSS_MOVES)
    var turn = [Float](repeating: 0, count: BOSS_MOVES)
    /// The exclusive move running (-1 none).
    var busy = -1
    /// The aim the boss's own file set (`bossAimAt`) for `.set` moves.
    var setX: Float = 0, setZ: Float = 0, setDX: Float = 0, setDZ: Float = 1
    // ---- the chain body (GameBossBody.swift)
    /// Parts in use (0: a bug body or no boss).
    var parts = 0
    var role = [UInt8](repeating: 0, count: BOSS_PARTS)
    var seg = [Int](repeating: 0, count: BOSS_PARTS)
    var uid = [Int32](repeating: 0, count: BOSS_PARTS)
    var pslot = [Int](repeating: -1, count: BOSS_PARTS)
    var px = [Float](repeating: 0, count: BOSS_PARTS), py = [Float](repeating: 0, count: BOSS_PARTS)
    var pz = [Float](repeating: 0, count: BOSS_PARTS), phd = [Float](repeating: 0, count: BOSS_PARTS)
    var pool = [Float](repeating: 0, count: BOSS_PARTS), poolMax = [Float](repeating: 0, count: BOSS_PARTS)
    /// Seconds left of a weak-point window / of a part's freeze; popped; × a bonus the boss's file set (a torch-stripped
    /// node); out of the deck's reach.
    var down = [Float](repeating: 0, count: BOSS_PARTS)
    var frozen = [Float](repeating: 0, count: BOSS_PARTS)
    var popped = [Bool](repeating: false, count: BOSS_PARTS)
    var bonus = [Float](repeating: 1, count: BOSS_PARTS)
    var up = [Bool](repeating: false, count: BOSS_PARTS)
    /// The head's path history: a ring buffer of points (x, absolute y, z) and their arc length, the newest at `hHead`.
    var hx = [Float](repeating: 0, count: BOSS_PATH), hy = [Float](repeating: 0, count: BOSS_PATH)
    var hz = [Float](repeating: 0, count: BOSS_PATH), hs = [Float](repeating: 0, count: BOSS_PATH)
    var hHead = -1, hCount = 0
    /// The path's sample step (the spec's, raised so the history covers the body).
    var hStep: Float = 0.25
    /// The head now (x, absolute y, z), its heading and its arc length along the path.
    var headX: Float = 0, headY: Float = 0, headZ: Float = 0, headHd: Float = 0, headS: Float = 0
    /// The head's track (`bossSetTrack`): points it walks to in turn at the boss's speed, looping or not.
    var track = [SIMD3<Float>]()
    var trackAt = 0
    var trackLoop = false
    /// The boss's file moved the head this tick (`bossSetHead`).
    var steered = false

    init() { track.reserveCapacity(64) }

    /// A fresh boss (the spec and the kind stay with the Game).
    func reset() {
        warnT = -1; edge = -1; slot = -1; biteCd = 0; nextAt = 0; pulseOff = false
        for m in 0..<BOSS_MOVES { clock[m] = 0; stage[m] = 0; timer[m] = 0; armed[m] = false; tele[m] = -1; struck[m] = 0 }
        busy = -1
        parts = 0
        for q in 0..<BOSS_PARTS { pslot[q] = -1; down[q] = 0; frozen[q] = 0; popped[q] = false; bonus[q] = 1; up[q] = false }
        hHead = -1; hCount = 0; headS = 0
        track.removeAll(keepingCapacity: true); trackAt = 0; trackLoop = false; steered = false
    }
}

/// When a hold's boss rider comes (`BossRider.arrival`).
public enum BossArrival: Equatable {
    /// `at` s into the COUNTED hold (nil: the boss row's own `at` — the Queen: 35 / 35 / 30 s; ∞ never). The classic rider.
    /// A counted hold only: an endless hold (`HoldStep.time` ∞) never counts, so it never comes there.
    case holdTime(Float?)
    /// `at` s after the hold started (counted or not): a boss in an endless hold.
    case stepTime(Float)
    /// A periodic peak (R10's Dig In): first `first` s after the hold started, then `gap` s after each death — the boss
    /// state starts afresh for every arrival (`BossState.arrivals` counts them).
    case every(first: Float, gap: Float)
}

extension Game {

    // ---------------------------------------------------------------- the step's boss

    /// The current step brings a boss (a HOLD with a rider, a BOSS step).
    var stepBringsBoss: Bool {
        switch currentStep {
        case .hold(let h)?: return h.boss != nil
        case .boss?: return true
        default: return false
        }
    }

    /// A step that brings a boss begins: its kind and its spec (the step's own spec, else the tier's row). A boss met in an
    /// earlier step (or a warning still pending) is cleared first; one still alive leaves the arena (no plan does that: a
    /// rider that locks its hold and a BOSS step both end with it dead).
    func bossBegin(_ kind: BossKind, spec: BossSpec?) {
        if boss.spawned || bossRT.warnT >= 0 {
            if boss.alive { bossLeave() }
            boss = BossState()
            bossRT.reset()
        }
        boss.kind = kind
        bossSpec = spec ?? difficulty.boss(kind)
    }

    /// The boss leaves without dying (its slots go, no reward): a new step brought its own while it lived.
    func bossLeave() {
        let S = bugs
        var i = 0
        while i < S.count {
            if S.boss[i] != 0 && S.dead[i] == 0 { S.dead[i] = 1; S.deadPending += 1 }
            i += 1
        }
        boss.alive = false
        bossRT.parts = 0; bossRT.slot = -1
    }

    /// The boss's slot (a bug body; a chain: the head) now, -1 when it is not alive.
    func bossSlotNow() -> Int {
        if !boss.alive { return -1 }
        let S = bugs, s = bossRT.slot
        if s >= 0 && s < S.count && S.uid[s] == boss.uid && S.dead[s] == 0 { return s }
        var i = 0
        while i < S.count { if S.uid[i] == boss.uid && S.dead[i] == 0 { return i }; i += 1 }
        return -1
    }

    /// Its health fraction for the boss bar (0 when it is not alive).
    public var bossHpFraction: Float { boss.alive ? boss.hpFraction : 0 }

    /// The hold's periodic horde clock waits (the boss lives and its spec says so).
    var bossHoldsHordes: Bool { boss.alive && bossSpec.pausesHordes }

    // ---------------------------------------------------------------- warning and spawn

    /// A rim edge of its arena (the current HOLD / BOSS zone; classic: the lift) on its far side (z − centre.z < backZ),
    /// else any rim edge within its radius + margin, else the edge nearest to the arena.
    func bossRimEdge(margin: Float, backZ: Float) -> Int {
        let L = level, T = arena()
        let r2 = (T.r + margin) * (T.r + margin)
        var back = 0, rim = 0, near = 0
        var nd: Float = 1e9
        var e = 0
        let N = L.edgeCount
        while e < N {
            let dx = L.edgeX[e] - T.x, dz = L.edgeZ[e] - T.z, d2 = dx * dx + dz * dz
            if d2 < nd { nd = d2; near = e }
            if d2 < r2 { rim += 1; if dz < backZ { back += 1 } }
            e += 1
        }
        if rim == 0 { return near }
        var k = Int(Float(back > 0 ? back : rim) * rng.next())
        e = 0
        while e < N {
            let dx = L.edgeX[e] - T.x, dz = L.edgeZ[e] - T.z
            if dx * dx + dz * dz < r2 && (back == 0 || dz < backZ) {
                if k == 0 { return e }
                k -= 1
            }
            e += 1
        }
        return near
    }

    /// The warning: `warn` s of red ring where it comes (a rim edge picked now, or its point).
    func bossWarn() {
        let R = bossRT, B = bossSpec
        var x: Float, z: Float
        switch B.spawn {
        case .rim(_, let margin, let backZ):
            R.edge = bossRimEdge(margin: margin, backZ: backZ); R.warnT = B.warn
            if level.edgeCount == 0 { return }
            x = level.edgeX[R.edge]; z = level.edgeZ[R.edge]
        case .point(let px, let pz, let py, let hd):
            R.spawnX = px; R.spawnZ = pz; R.spawnY = py; R.spawnHd = hd; R.warnT = B.warn
            x = px; z = pz
        case .arena(let lift, let hd):
            let a = arena()
            R.spawnX = a.x; R.spawnZ = a.z; R.spawnY = level.groundY(a.x, a.z) + lift; R.spawnHd = hd; R.warnT = B.warn
            x = a.x; z = a.z
        }
        teleRing(x, z, B.warnRing, 1.0, 0.12, 0.08, B.warn, pulse: true, cause: .bossRim)
        emit(.bossWarning(kind: boss.kind, pos: Vec2(x, z)))
    }

    /// It comes: its body (a bug climbing over the rim or standing at its point; a chain at its point with the body behind).
    func bossSpawn() {
        let R = bossRT, B = bossSpec, L = level
        switch B.body {
        case .bug(let type, let radius, let scale):
            var i = -1
            let ty = UInt8(type.rawValue)
            switch B.spawn {
            case .rim(let depth, let margin, let backZ):
                if L.edgeCount == 0 { R.warnT = -1; return }
                let e = R.edge >= 0 ? R.edge : bossRimEdge(margin: margin, backZ: backZ)
                i = spawnBug(ty, L.edgeX[e], L.edgeZ[e], mode: 1, nx: L.edgeNX[e], nz: L.edgeNZ[e], depth: depth)
            case .point, .arena:
                bossSpawnPlace()
                i = spawnBug(ty, R.spawnX, R.spawnZ)
            }
            if i < 0 { R.warnT = 0.5; return }   // bug arrays full (debug floods only): try again shortly
            let S = bugs
            let hp = config.bossHp ?? B.hp * hpMul
            S.hp[i] = hp; S.hpMax[i] = hp; S.r[i] = radius; S.sc[i] = scale; S.spd[i] = B.speed
            S.boss[i] = BOSS_BUG
            bossArrived(i)
        case .chain(let c):
            bossSpawnPlace()
            let i = bossSpawnChain(c)
            if i < 0 { R.warnT = 0.5; return }
            bossArrived(i)
        }
    }

    /// A point / arena spawn's place now (the rim's edge is the warning's).
    func bossSpawnPlace() {
        let R = bossRT
        switch bossSpec.spawn {
        case .rim:
            // (a chain coming over a rim: the edge, heading inward)
            if R.edge < 0 { if case .rim(_, let m, let b) = bossSpec.spawn { R.edge = bossRimEdge(margin: m, backZ: b) } }
            if R.edge >= 0 && R.edge < level.edgeCount {
                R.spawnX = level.edgeX[R.edge]; R.spawnZ = level.edgeZ[R.edge]; R.spawnY = level.groundY(R.spawnX, R.spawnZ)
                R.spawnHd = atan2f2(-level.edgeNX[R.edge], -level.edgeNZ[R.edge])
            }
        case .point(let x, let z, let y, let hd): R.spawnX = x; R.spawnZ = z; R.spawnY = y; R.spawnHd = hd
        case .arena(let lift, let hd): let a = arena(); R.spawnX = a.x; R.spawnZ = a.z; R.spawnY = level.groundY(a.x, a.z) + lift; R.spawnHd = hd
        }
    }

    /// Its body stands in slot `i` (a chain: the head): the public view, its moves' first clocks, the presentation.
    func bossArrived(_ i: Int) {
        let R = bossRT, B = bossSpec, S = bugs
        boss.uid = S.uid[i]; boss.spawned = true; boss.alive = true; boss.done = false; boss.enraged = false; boss.phase = 0
        boss.t0 = time; boss.killT = 0; boss.hpFraction = 1; boss.warning = -1; boss.position = Vec2(S.x[i], S.z[i])
        boss.untouchable = 0; boss.stagger = 0; boss.lock = 0; boss.brittle = 0; boss.arrivals += 1
        if R.parts > 0 { boss.height = R.headY; boss.heading = R.headHd } else { boss.height = 0; boss.heading = S.hd[i] }
        R.warnT = -1; R.slot = i
        var m = 0
        while m < min(B.moves.count, BOSS_MOVES) {
            R.clock[m] = B.moves[m].first; R.armed[m] = false; R.stage[m] = 0; R.tele[m] = -1
            m += 1
        }
        R.busy = -1; R.biteCd = 0; R.pulseOff = false
        if !simOnly {
            if let b = B.banner { banner(GameText(b.title), GameText(b.sub), false) }
            events.append(.sound(.siren, pos: nil, loud: nil))
            if let r = B.roar { events.append(.sound(r, pos: nil, loud: nil)) }
            shake(B.arrivalShake)
            haptic(.heavy)
            emit(.bossSpawned(kind: boss.kind, pos: boss.position))
        }
    }

    // ---------------------------------------------------------------- the tick

    /// Every tick of a step that brings the boss (a HOLD's rider, a BOSS step): `expected` — it comes on this tier; `due` —
    /// its warning may start (the classic hold: `at` s of counted hold; a BOSS step: its delay in the arena).
    func bossTick(_ dt: Float, expected: Bool, due: Bool) {
        let R = bossRT
        if !boss.spawned {
            if !expected { return }
            if R.warnT < 0 {
                if due { bossWarn() }
            } else {
                R.warnT -= dt
                if R.warnT <= 0 { bossSpawn() }
            }
            if !boss.spawned { boss.warning = R.warnT }
            return
        }
        if !boss.alive { return }
        let S = bugs
        // its slot from the last tick, unless compact() moved it (then one scan)
        var qi = R.slot
        if qi < 0 || qi >= S.count || S.uid[qi] != boss.uid {
            qi = -1
            var i = 0
            while i < S.count { if S.uid[i] == boss.uid { qi = i; break }; i += 1 }
        }
        if qi < 0 || S.dead[qi] != 0 {
            boss.alive = false; boss.done = true; boss.killT = time - boss.t0; boss.hpFraction = 0; R.slot = -1
            return
        }
        R.slot = qi
        // the boss's own file (it may steer a chain's head, open windows, aim moves), then a chain's body follows
        bossOwnTick(dt)
        if R.parts > 0 { bossBodyTick(dt) }
        let qx = S.x[qi], qz = S.z[qi]
        boss.position = Vec2(qx, qz)
        boss.hpFraction = clampf(S.hp[qi] / S.hpMax[qi], 0, 1)
        // immunities (the beam, the nova and the frost blasts skip it too)
        let B = bossSpec
        if B.immune.freeze { S.frz[qi] = 0 }
        if S.chill[qi] > B.immune.chillCap { S.chill[qi] = B.immune.chillCap }
        // phases: below each threshold once (its speed, the hive's answer, hazards, a stagger)
        while boss.phase + 1 < B.phases.count && S.hp[qi] < S.hpMax[qi] * B.phases[boss.phase + 1].below { bossEnterPhase(boss.phase + 1, qi) }
        if R.biteCd > 0 { R.biteCd -= dt }
        if boss.untouchable > 0 { boss.untouchable = maxf(0, boss.untouchable - dt) }
        if boss.stagger > 0 { boss.stagger = maxf(0, boss.stagger - dt) }
        if boss.lock > 0 { boss.lock = maxf(0, boss.lock - dt) }
        if boss.brittle > 0 { boss.brittle = maxf(0, boss.brittle - dt) }
        bossMoves(dt, qi, qx, qz)
    }

    /// Phase `p` begins: its speed, the hive's answer (a horde), its arena hazards, a stagger.
    func bossEnterPhase(_ p: Int, _ qi: Int) {
        let B = bossSpec, ph = B.phases[p]
        boss.phase = p
        boss.enraged = ph.enraged
        bugs.spd[qi] = B.speed * ph.speedK
        if ph.horde > 0 || ph.hordeTitle != nil {
            startHorde(Int((ph.horde * (difficulty.waves ? ph.hordeWavesK : 1) * hordeScale()).rounded()), ph.hordeTitle.map { GameText($0) }, nil,
                       ph.hordeRate)
        }
        for h in ph.hazards { bossHazard(h) }
        if ph.stagger > 0 { boss.stagger = maxf(boss.stagger, ph.stagger) }
        emit(.bossPhase(kind: boss.kind, phase: p, enraged: ph.enraged, pos: boss.position))
    }

    /// An arena hazard of a phase (design / tech §5.2 «arena hooks»).
    func bossHazard(_ h: BossHazard) {
        switch h {
        case .pulseOff:
            bossRT.pulseOff = true
        case .lightsOut(let n):
            // the powered circuits nearest to the arena, one by one (no sort: a few circuits)
            let a = arena()
            var k = 0
            while k < n {
                var best = -1
                var bd: Float = .infinity
                for (c, cs) in props.circuits.enumerated() where cs.powered {
                    let d = hypotf2(cs.site.x - a.x, cs.site.z - a.z)
                    if d < bd { bd = d; best = c }
                }
                if best < 0 { break }
                cutCircuit(best)
                k += 1
            }
        case .overheadBrood(let n):
            if level.overhead == nil || n <= 0 { return }
            let a = arena()
            let e = routeEntry(near: Vec2(a.x, a.z))
            if e >= 0 { queueRoutePack(n, entry: e, rate: 4) }
        }
    }

    // ---------------------------------------------------------------- moves

    /// The moves in spec order: the instant ones on their clocks (× the phase's cooldowns), the telegraphed ones through
    /// wind-up, landing and their active time. A stagger pauses every clock and cancels a wind-up.
    func bossMoves(_ dt: Float, _ qi: Int, _ qx: Float, _ qz: Float) {
        let R = bossRT, B = bossSpec
        let ph = B.phases[boss.phase]
        let stalled = boss.stagger > 0
        let n = min(B.moves.count, BOSS_MOVES)
        var m = 0
        while m < n {
            defer { m += 1 }
            let mv = B.moves[m]
            if !mv.runs(in: boss.phase) { continue }
            switch mv.kind {
            case .brood:
                // adds burst from its body (only while the swarm cap has room)
                if stalled { continue }
                R.clock[m] -= dt
                if R.clock[m] <= 0 {
                    R.clock[m] = mv.cooldown * ph.cooldownK(m)
                    let ty = UInt8(mv.addType.rawValue)
                    var k = 0
                    while k < mv.count && capLeft() > 0 { spawnBug(ty, qx, qz, mode: 2); k += 1 }
                }
            case .volley:
                // one glob per standing marine within range, aimed `lead` s ahead with ± spread
                if stalled { continue }
                R.clock[m] -= dt
                if R.clock[m] <= 0 {
                    R.clock[m] = mv.cooldown * ph.cooldownK(m)
                    let r2: Float = mv.range > 0 ? mv.range * mv.range : .infinity, w = mv.spread * 2
                    for mm in marines {
                        if mm.downed || (mm.x - qx) * (mm.x - qx) + (mm.z - qz) * (mm.z - qz) > r2 { continue }
                        let ax = mm.x + mm.vx * mv.lead + (rng.next() * w - mv.spread)
                        let az = mm.z + mm.vz * mv.lead + (rng.next() * w - mv.spread)
                        launchGlob(qx, qz, ax, az)
                        if !simOnly {
                            teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, 0.95, cause: .bossVolley)
                            teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, 0.95, cause: .bossVolley)
                        }
                    }
                }
            case .bodyCharge:
                // the body's AI does the wind-up (red lane) and the charge; the boss's clock decides when it may start
                let S = bugs
                if stalled { if S.cd[qi] < BOSS_CHARGE_HOLD { S.cd[qi] = BOSS_CHARGE_HOLD }; continue }
                R.clock[m] -= dt
                let st = S.st[qi]
                if st == S_WIND { R.clock[m] = mv.cooldown * ph.cooldownK(m); R.armed[m] = false }
                else if st == S_MOVE {
                    if R.clock[m] > 0 { if S.cd[qi] < BOSS_CHARGE_HOLD { S.cd[qi] = BOSS_CHARGE_HOLD } }
                    else if !R.armed[m] { R.armed[m] = true; S.cd[qi] = 0 }
                }
            default:
                bossTelegraphed(m, mv, ph, dt, stalled, qx, qz)
            }
        }
    }

    /// One tick of a telegraphed move (slam, lane, cone, drop, pack, custom): idle → wind-up → active → idle.
    func bossTelegraphed(_ m: Int, _ mv: BossMove, _ ph: BossPhase, _ dt: Float, _ stalled: Bool, _ qx: Float, _ qz: Float) {
        let R = bossRT
        switch R.stage[m] {
        case 0:
            if stalled { return }
            if R.clock[m] > 0 { R.clock[m] -= dt }
            if R.clock[m] > 0 { return }
            if mv.exclusive && R.busy >= 0 && R.busy != m { return }   // it waits until the boss is free
            if !bossAim(m, mv, qx, qz) { R.clock[m] = 0.5; return }      // nobody to aim at: again shortly
            if mv.kind == .custom && !bossOwnMove(m, 0) { R.clock[m] = mv.cooldown * ph.cooldownK(m); return }
            R.stage[m] = 1; R.timer[m] = mv.windUp; R.struck[m] = 0
            if mv.exclusive { R.busy = m }
            R.tele[m] = bossTelegraph(m, mv)
            emit(.bossMove(kind: boss.kind, move: m, pos: Vec2(R.ax[m], R.az[m])))
            if mv.windUp > 0 { return }
            fallthrough
        case 1:
            // (straight from its start when it has no wind-up: never stalled there)
            if stalled {
                // a stagger interrupts a wind-up: the move is lost, its telegraph goes out
                bossTeleOut(m)
                bossMoveEnds(m, mv, ph, landed: false)
                return
            }
            R.timer[m] -= dt
            if R.timer[m] > 0 { return }
            bossLand(m, mv)
            R.stage[m] = 2; R.timer[m] = mv.active
            if mv.active > 0 { return }
            bossMoveEnds(m, mv, ph, landed: true)
        default:
            // active: a sweeping cone turns and strikes whoever it crosses (once); a lane stays lit
            if mv.kind == .cone && mv.sweep != 0 {
                let a = mv.sweep * dt, c = cosf2(a), s = sinf2(a)
                let dx = R.adx[m], dz = R.adz[m]
                R.adx[m] = dx * c + dz * s; R.adz[m] = -dx * s + dz * c
                let k = R.tele[m]
                if k >= 0 && k < telegraphs.count && telegraphs[k].active && telegraphs[k].cause == .bossMove {
                    telegraphs[k].dx = R.adx[m]; telegraphs[k].dz = R.adz[m]
                }
                bossStrike(m, mv)
            }
            R.timer[m] -= dt
            if R.timer[m] > 0 { return }
            bossMoveEnds(m, mv, ph, landed: true)
        }
    }

    /// The move is over: its cooldown (× the phase's), the boss free again; a custom move's end.
    func bossMoveEnds(_ m: Int, _ mv: BossMove, _ ph: BossPhase, landed: Bool) {
        let R = bossRT
        R.stage[m] = 0; R.timer[m] = 0
        R.clock[m] = mv.cooldown * ph.cooldownK(m)
        if R.busy == m { R.busy = -1 }
        if mv.kind == .custom && landed { _ = bossOwnMove(m, 2) }
    }

    /// Where a telegraphed move aims (false: nobody to aim at). Slam / drop: the point; lane / cone: from the body toward it.
    func bossAim(_ m: Int, _ mv: BossMove, _ qx: Float, _ qz: Float) -> Bool {
        let R = bossRT
        var tx = qx, tz = qz
        switch mv.aim {
        case .body:
            tx = qx; tz = qz
        case .set:
            tx = R.setX; tz = R.setZ
        case .nearest, .random:
            let r2: Float = mv.range > 0 ? mv.range * mv.range : .infinity
            var pick = -1
            if mv.aim == .nearest {
                var bd = r2
                for (k, mm) in marines.enumerated() where !mm.downed {
                    let d = (mm.x - qx) * (mm.x - qx) + (mm.z - qz) * (mm.z - qz)
                    if d <= bd { bd = d; pick = k }
                }
            } else {
                var n = 0
                for mm in marines where !mm.downed && (mm.x - qx) * (mm.x - qx) + (mm.z - qz) * (mm.z - qz) <= r2 { n += 1 }
                if n > 0 {
                    var j = rng.int(n)
                    for (k, mm) in marines.enumerated() where !mm.downed && (mm.x - qx) * (mm.x - qx) + (mm.z - qz) * (mm.z - qz) <= r2 {
                        if j == 0 { pick = k; break }
                        j -= 1
                    }
                }
            }
            if pick < 0 { return false }
            let mm = marines[pick]
            tx = mm.x + mm.vx * mv.lead; tz = mm.z + mm.vz * mv.lead
            if mv.spread > 0 { tx += (rng.next() * 2 - 1) * mv.spread; tz += (rng.next() * 2 - 1) * mv.spread }
        }
        var dx = tx - qx, dz = tz - qz
        let d = hypotf2(dx, dz)
        if mv.aim == .set { dx = R.setDX; dz = R.setDZ }
        else if d > 1e-3 { dx /= d; dz /= d }
        else { dx = sinf2(boss.heading); dz = cosf2(boss.heading) }
        let l = hypotf2(dx, dz)
        R.adx[m] = l > 1e-6 ? dx / l : 0; R.adz[m] = l > 1e-6 ? dz / l : 1
        switch mv.kind {
        case .lane, .cone: R.ax[m] = qx; R.az[m] = qz
        default: R.ax[m] = tx; R.az[m] = tz
        }
        R.turn[m] = mv.kind == .drop ? rng.next() * TAU : 0
        return true
    }

    /// The move's telegraph by its shape (its pool slot, -1 none). A drop's targets each get one (the first slot returned).
    @discardableResult
    func bossTelegraph(_ m: Int, _ mv: BossMove) -> Int {
        let R = bossRT, c = mv.color
        let x = R.ax[m], z = R.az[m], dx = R.adx[m], dz = R.adz[m]
        switch mv.kind {
        case .drop:
            var first = -1
            for k in 0..<max(1, mv.count) {
                let p = bossDropPoint(m, mv, k)
                let s = teleShape(.drop, p.x, p.y, r0: mv.radius * 1.45, r1: mv.radius, color: c, life: max(0.05, mv.windUp))
                if first < 0 { first = s }
            }
            return first
        case .lane:
            return teleShape(mv.shape == .beam ? .beam : .lane, x, z, dx: dx, dz: dz, len: mv.length, w: mv.radius, color: c,
                             life: mv.windUp + mv.active, wind: mv.windUp)
        case .cone:
            return teleShape(.cone, x, z, dx: dx, dz: dz, len: mv.length, w: mv.angle, color: c, life: mv.windUp + mv.active, wind: mv.windUp)
        case .slam, .pack, .custom:
            if mv.kind != .slam && mv.windUp <= 0 { return -1 }
            switch mv.shape {
            case .fill: return teleShape(.fill, x, z, r0: mv.radius, color: c, life: max(0.05, mv.windUp), pulse: false)
            case .drop: return teleShape(.drop, x, z, r0: mv.radius * 1.45, r1: mv.radius, color: c, life: max(0.05, mv.windUp))
            case .lane, .beam:
                return teleShape(mv.shape, x, z, dx: dx, dz: dz, len: mv.length, w: mv.radius, color: c, life: mv.windUp + mv.active, wind: mv.windUp)
            case .cone:
                return teleShape(.cone, x, z, dx: dx, dz: dz, len: mv.length, w: mv.angle, color: c, life: mv.windUp + mv.active, wind: mv.windUp)
            case .ring: return teleShape(.ring, x, z, r0: mv.radius, color: c, life: max(0.05, mv.windUp))
            }
        default:
            return -1
        }
    }

    /// The `k`-th drop target of a drop move: the aim, then a ring round it (`spread` m out, turned by the move's random turn).
    func bossDropPoint(_ m: Int, _ mv: BossMove, _ k: Int) -> Vec2 {
        let R = bossRT
        if k == 0 || mv.count <= 1 { return Vec2(R.ax[m], R.az[m]) }
        let a = R.turn[m] + Float(k - 1) * TAU / Float(mv.count - 1)
        let r = maxf(mv.spread, mv.radius * 2)
        return Vec2(R.ax[m] + sinf2(a) * r, R.az[m] + cosf2(a) * r)
    }

    /// Its telegraph goes out (a wind-up cancelled).
    func bossTeleOut(_ m: Int) {
        let k = bossRT.tele[m]
        if k >= 0 && k < telegraphs.count && telegraphs[k].cause == .bossMove { telegraphs[k].active = false }
        bossRT.tele[m] = -1
    }

    /// The move lands: its hit in its shape (marines, and the bugs when it kills them), a pack's adds, a window on the head.
    func bossLand(_ m: Int, _ mv: BossMove) {
        let R = bossRT
        switch mv.kind {
        case .pack:
            let n = mv.count
            if n > 0 {
                let e = pickEdge(R.ax[m], R.az[m], 0, 14)
                if e >= 0 { queueBurst(e, n, 10, nil) }
            }
        case .custom:
            _ = bossOwnMove(m, 1)
        default:
            if !(mv.kind == .cone && mv.sweep != 0) { bossStrike(m, mv) }
        }
        if mv.opensDown > 0 { bossOpenWindow(0, mv.opensDown) }
    }

    /// The hit of a move on everything in its shape now (a sweep: each marine once).
    func bossStrike(_ m: Int, _ mv: BossMove) {
        let R = bossRT
        let dmg = mv.damage * dmgMul, src = bossSpec.source
        for mm in marines {
            if mm.downed || (R.struck[m] & UInt8(1 << mm.index)) != 0 { continue }
            guard let push = bossShapeHit(m, mv, mm.x, mm.z, 0.42) else { continue }
            R.struck[m] |= UInt8(1 << mm.index)
            if dmg > 0 { hurtMarine(mm, dmg, push.x * mv.knockback, push.y * mv.knockback, src) }
        }
        if mv.hitsBugs {
            let S = bugs
            var i = 0
            while i < S.count {
                defer { i += 1 }
                if S.dead[i] != 0 || S.boss[i] != 0 || S.up[i] != 0 { continue }
                if bossShapeHit(m, mv, S.x[i], S.z[i], S.r[i]) != nil { hitBug(i, 1e6, -1) }
            }
        }
    }

    /// Whether (x, z) with radius `r` is inside the move's shape, and the unit push out of it (nil: outside).
    func bossShapeHit(_ m: Int, _ mv: BossMove, _ x: Float, _ z: Float, _ r: Float) -> Vec2? {
        let R = bossRT
        let ox = R.ax[m], oz = R.az[m], dx = R.adx[m], dz = R.adz[m]
        func radial(_ cx: Float, _ cz: Float, _ rad: Float) -> Vec2? {
            let ex = x - cx, ez = z - cz, d = hypotf2(ex, ez)
            if d > rad + r { return nil }
            return d > 1e-3 ? Vec2(ex / d, ez / d) : Vec2(dx, dz)
        }
        switch mv.kind {
        case .drop:
            for k in 0..<max(1, mv.count) {
                let p = bossDropPoint(m, mv, k)
                if let v = radial(p.x, p.y, mv.radius) { return v }
            }
            return nil
        case .lane:
            let ex = x - ox, ez = z - oz, t = ex * dx + ez * dz
            if t < -r || t > mv.length + r { return nil }
            let side = ex * dz - ez * dx
            if absf(side) > mv.radius * 0.5 + r { return nil }
            let s: Float = side >= 0 ? 1 : -1
            return Vec2(dz * s, -dx * s)
        case .cone:
            // (the half-angle widened by the body's own angular size)
            let ex = x - ox, ez = z - oz, d = hypotf2(ex, ez)
            if d > mv.length + r { return nil }
            if d > r {
                let half = minf(Float.pi, mv.angle + Float(asin(Double(minf(1, r / d)))))
                if (ex * dx + ez * dz) / d < cosf2(half) { return nil }
            }
            return d > 1e-3 ? Vec2(ex / d, ez / d) : Vec2(dx, dz)
        default:
            switch mv.shape {
            case .lane, .beam:
                let ex = x - ox, ez = z - oz, t = ex * dx + ez * dz
                if t < -r || t > mv.length + r { return nil }
                let side = ex * dz - ez * dx
                if absf(side) > mv.radius * 0.5 + r { return nil }
                let s: Float = side >= 0 ? 1 : -1
                return Vec2(dz * s, -dx * s)
            default:
                return radial(ox, oz, mv.radius)
            }
        }
    }

    // ---------------------------------------------------------------- weak points, windows, the boss's file's API

    /// A weak-point window on part `p` (a chain; a bug body only shows it) for `t` s: its `downK` applies (the head down).
    public func bossOpenWindow(_ p: Int, _ t: Float) {
        guard boss.alive, t > 0 else { return }
        let R = bossRT
        let q = R.parts > 0 ? min(max(0, p), R.parts - 1) : 0
        if R.parts > 0 { R.down[q] = maxf(R.down[q], t) }
        emit(.bossWindow(kind: boss.kind, part: q, pos: R.parts > 0 ? Vec2(R.px[q], R.pz[q]) : boss.position, time: t))
    }

    /// The boss's file: the aim of its `.set` moves (a point, and the direction lanes / cones take).
    public func bossAimAt(_ x: Float, _ z: Float, dir: Vec2? = nil) {
        let R = bossRT
        R.setX = x; R.setZ = z
        if let d = dir { let l = hypotf2(d.x, d.y); if l > 1e-6 { R.setDX = d.x / l; R.setDZ = d.y / l } }
    }

    /// The boss's file: untouchable for `t` s (design §1.5: the Threader up in its ring duct), staggered, brittle.
    public func bossUntouchable(_ t: Float) { if boss.alive { boss.untouchable = maxf(boss.untouchable, t) } }
    public func bossStagger(_ t: Float) { if boss.alive { boss.stagger = maxf(boss.stagger, t) } }
    public func bossBrittle(_ t: Float) { if boss.alive { boss.brittle = maxf(boss.brittle, t) } }

    /// The boss's file: × part `p`'s damage from now on (a torch-stripped node: 1.25).
    public func bossPartBonus(_ p: Int, _ k: Float) { if p >= 0 && p < bossRT.parts { bossRT.bonus[p] = maxf(0, k) } }

    // ---------------------------------------------------------------- damage

    /// hitBug on a chain's part (`Swarm.boss` = p + 1): × the part's multiplier (popped, its window, brittle, a bonus, from
    /// behind), into its pool, and onto the head's health — the boss bar. Returns true when the boss died of it.
    func bossPartHit(_ i: Int, _ p: Int, _ dmg: Float, _ src: Int, _ dot: Bool, _ dir: Vec2?) -> Bool {
        let S = bugs, R = bossRT
        if !dot && S.fl[i] < 0.6 { S.fl[i] = 0.6 }
        if !boss.alive || p < 0 || p >= R.parts || boss.untouchable > 0 { return false }
        guard let c = bossSpec.chain else { return false }
        let ps = p == 0 ? c.head : (p <= c.segments ? c.segment : c.nodes[min(c.nodes.count - 1, p - 1 - c.segments)])
        var k = R.popped[p] ? ps.poppedK : ps.damageK
        if R.down[p] > 0 { k *= ps.downK }
        if boss.brittle > 0 { k *= BOSS_BRITTLE_K }
        k *= R.bonus[p]
        if ps.rearK != 1, let d = dir {
            let h = R.phd[p]
            if d.x * sinf2(h) + d.y * cosf2(h) >= 0.5 { k *= ps.rearK }
        }
        let d = dmg * k
        if !(d > 0) { return false }
        if R.poolMax[p] > 0 && !R.popped[p] {
            R.pool[p] -= d
            if R.pool[p] <= 0 { R.pool[p] = 0; bossPartPopped(p, ps) }
        }
        let h = bossPartSlot(0)
        if h < 0 || S.dead[h] != 0 { return false }
        S.hp[h] -= d
        if S.hp[h] <= 0 { killBug(h, src); return true }
        return false
    }

    /// Part `p`'s pool is spent: popped (dark; `poppedK` from now on), the boss staggers, its own file reacts.
    func bossPartPopped(_ p: Int, _ ps: BossPartSpec) {
        let R = bossRT
        R.popped[p] = true
        if ps.popStagger > 0 { boss.stagger = maxf(boss.stagger, ps.popStagger) }
        emit(.bossPartPopped(kind: boss.kind, part: p, pos: Vec2(R.px[p], R.pz[p])))
        bossOwnPart(p, popped: true)
    }

    /// A chain part that would freeze (the beam's chill full, an Ice Wave, a coolant mist) when the boss is not immune: it
    /// never freezes solid — the body locks (`freezeLock`), an open window makes it brittle (`brittle`, an Ice Wave).
    func bossPartFreeze(_ i: Int, nova: Bool) {
        let S = bugs, R = bossRT, I = bossSpec.immune
        let b = S.boss[i]
        if I.freeze || b == 0 || b == BOSS_BUG { return }
        let p = Int(b) - 1
        if p >= R.parts { return }
        S.chill[i] = minf(S.chill[i], I.chillCap)
        if I.freezeLock > 0 && R.frozen[p] <= 0 {
            R.frozen[p] = I.freezeLock
            boss.lock = maxf(boss.lock, I.freezeLock)
            emit(.bossPartFrozen(kind: boss.kind, part: p, pos: Vec2(R.px[p], R.pz[p])))
            bossOwnPart(p, popped: false)
        }
        if nova && I.brittle > 0 && R.down[p] > 0 { boss.brittle = maxf(boss.brittle, I.brittle) }
    }

    /// The cryo beam's chill on a boss slot (beamTick, overheadBeam): a freeze-immune boss ignores it; else the chill
    /// builds to its cap and a full one is the freeze reaction.
    func bossBeamChill(_ i: Int, _ amount: Float) {
        let S = bugs, I = bossSpec.immune
        if I.freeze { return }
        S.chill[i] += amount
        if S.chill[i] >= 1 { bossPartFreeze(i, nova: false) }
        if S.chill[i] > I.chillCap { S.chill[i] = I.chillCap }
    }

    // ---------------------------------------------------------------- death and the debug skip

    /// killBug on its slot (after onBugKilled): the blast, the medkits, the presentation; a chain's other parts go with it.
    func bossKilled(_ x: Float, _ z: Float) {
        let R = bossRT, B = bossSpec
        boss.alive = false; boss.done = true; boss.killT = time - boss.t0; boss.hpFraction = 0; R.slot = -1
        boss.position = Vec2(x, z)
        if R.parts > 0 { bossDropParts() }
        if let b = B.deathBlast { queueBoom(x, z, b.r, b.dmg, b.src, b.kind) }   // (src 0: the player gets the blast's kills)
        for o in B.reward.medkits { dropMedkit(x + o.x, o.y == 0 ? z : z + o.y) }
        R.busy = -1
        if !simOnly {
            emit(.bossKilled(kind: boss.kind, pos: Vec2(x, z)))
            hitStop(0.2, 0.15)
            if let b = B.deathBanner { banner(GameText(b.title), GameText(b.sub), true) }
            haptic(.success)
        }
    }

    /// debugSkip() in its step: it dies (or never comes).
    func bossSkip() {
        if boss.alive {
            let S = bugs
            var i = 0
            while i < S.count {
                if S.uid[i] == boss.uid && S.dead[i] == 0 { killBug(i, -1); break }
                i += 1
            }
        }
        boss.alive = false; boss.spawned = true; boss.done = true; bossRT.warnT = -1; boss.warning = -1
    }

    // ---------------------------------------------------------------- arrivals (GameMission's HOLD rider)

    /// The rider comes on this tier (the classic: the tier has a Queen; the debug `bossAt` sends it anyway).
    func riderExpected(_ q: BossRider) -> Bool {
        switch q.arrival {
        case .holdTime(let at): return (config.bossAt ?? at ?? bossSpec.at).isFinite
        case .stepTime(let at): return bossAvailable && (config.bossAt ?? at).isFinite
        case .every(let first, _): return bossAvailable && (config.bossAt ?? first).isFinite
        }
    }

    /// Its warning may start now: `at` s of counted hold (the classic), `at` s into the hold, or the periodic clock.
    func riderDue(_ q: BossRider) -> Bool {
        switch q.arrival {
        case .holdTime(let at): return liftDur - liftT >= (config.bossAt ?? at ?? bossSpec.at)
        case .stepTime(let at): return stepTime >= (config.bossAt ?? at)
        case .every(let first, _): return stepTime >= (boss.arrivals == 0 ? (config.bossAt ?? first) : bossRT.nextAt)
        }
    }

    /// A periodic rider died: it comes again `gap` s later, a fresh boss (its arrivals counted on).
    func riderRearm(_ q: BossRider) {
        guard case .every(_, let gap) = q.arrival, boss.done else { return }
        let n = boss.arrivals, kind = boss.kind
        boss = BossState()
        boss.kind = kind; boss.arrivals = n
        bossRT.reset()
        bossRT.nextAt = stepTime + gap
    }

    /// The step's boss is there on this tier (the legacy row has none; a debug health brings it anyway).
    var bossAvailable: Bool { config.bossHp != nil || bossSpec.hp > 0 }

    // ---------------------------------------------------------------- the boss's own file

    /// Every tick before its body follows and its moves run: the boss's own behaviour (steer a chain's head —
    /// `bossSetHead` / `bossSetTrack` —, open windows, aim `.set` moves). A new boss adds its case.
    func bossOwnTick(_ dt: Float) {
        switch boss.kind {
        case .queen: queenOwnTick(dt)
        }
    }

    /// A `.custom` move of the boss's own file: `stage` 0 its wind-up starts (false: skip it this time), 1 it lands, 2 it
    /// ends.
    func bossOwnMove(_ m: Int, _ stage: Int) -> Bool {
        switch boss.kind {
        case .queen: return false
        }
    }

    /// A part's pool was spent (`popped`) or the part froze: the boss's own reaction on top of the spec's.
    func bossOwnPart(_ p: Int, popped: Bool) {
        switch boss.kind {
        case .queen: break
        }
    }

    // ---------------------------------------------------------------- debug

    /// The boss of the current step comes right now (a hold or a boss arena only, before it came; a hold without a rider:
    /// the tier's Queen). `hp` overrides its health. Returns its uid or 0.
    @discardableResult
    public func debugBoss(hp: Float? = nil) -> Int32 {
        if posture != .hold || boss.spawned { return 0 }
        if !stepBringsBoss { boss.kind = .queen; bossSpec = difficulty.queen }
        bossRT.edge = -1
        bossSpawn()
        if let h = hp, h > 0, bossRT.slot >= 0 { bugs.hp[bossRT.slot] = h; bugs.hpMax[bossRT.slot] = h }
        return boss.spawned ? boss.uid : 0
    }
}
