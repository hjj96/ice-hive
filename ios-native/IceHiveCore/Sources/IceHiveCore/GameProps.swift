import Foundation

// ================================================================
//  INTERACTIVE PROPS AT RUN TIME (Stage 1 R6 «Valves, light, lockers»;
//  design.md §1.4, §1.1.5; the data: Props.swift).
//   · STEAM VALVES: rounds aimed up strike a ready valve at its footprint
//     (updateProjectiles), the squad's blasts reach it at BLAST_UP × their
//     radius (processBooms); at VALVE_HP it bursts — VALVE_WARN s of warning
//     (an amber ring, the lane under its span), then the scald curtain for
//     VALVE_VENT s: deck bugs under the span take CURTAIN_BUG_DPS, marines in
//     it CURTAIN_MARINE_DPS, the bugs up on the span die, no drop lands in it;
//     ready again 25 s after the burst. A coolant line (the cold variant)
//     bursts into COOLANT_MIST s of freezing mist instead: the bugs in it
//     freeze (COOLANT_CHILL a second), those up on the span fall and shatter,
//     marines are not hurt. The bots (and the autopilot) pop one
//     when VALVE_BOT_CROWD deck bugs stand under it and no marine does; the
//     player's aim assist finds it where it is drawn; the bots step out of it.
//   · LIGHT CIRCUITS: the station's lamps (Level.lamps) on their circuits. A
//     lamp burns while its circuit has power and it is whole; lit deck — a
//     burning lamp's pool within LAMP_LIT_R, a lit beacon within BEACON_LIT_R
//     — is the overhead's no-drop circles (R2's seam: drops never land there).
//     The hive breaks lamps: a spitter now and then spits on one (at most
//     once in LAMP_SPIT_GAP s, the lime ring on the lamp), a charging
//     brute breaks the posts it rams. A marine
//     standing BREAKER_TIME s in a breaker's ring brings the whole circuit
//     back (a SWITCH step's breaker switch does the same when thrown: R1's
//     seam); DARK missions start with every circuit off. Idle bots re-light.
//     The report counts the circuits lit at extraction.
//   · SUPPLY LOCKERS: LOCKER_TIME s in the ring — a medkit and the opener's
//     ability ready, once per mission; hurt bots (and a hurt autopilot) use it.
//  Nothing here runs, or draws a random number, on a station without props:
//  the classic mission replays byte for byte. Text only when not simOnly.
// ================================================================

/// What a steam valve is doing.
public enum ValvePhase: Int {
    /// Its gauge amber: shoot it.
    case ready
    /// Hit to VALVE_HP: the warning before the curtain (VALVE_WARN s).
    case burst
    /// The scald curtain stands under its span (VALVE_VENT s).
    case venting
    /// Building pressure again (VALVE_COOL s; the gauge fills).
    case recharge
}

/// A steam valve of the station now (public view for the renderer, the bots and the tests).
public struct ValveState: Equatable {
    public let site: ValveSite
    public internal(set) var phase: ValvePhase = .ready
    /// Seconds left of the warning, the curtain or the recharge.
    public internal(set) var t: Float = 0
    public internal(set) var hp: Float = VALVE_HP
    /// Deck bugs under its span (counted four times a second while it is ready; the bots pop it at VALVE_BOT_CROWD).
    public internal(set) var crowd = 0
    /// Who burst it (a marine index, −1 nobody): the curtain's kills are theirs.
    public internal(set) var src = -1
    public init(site: ValveSite) { self.site = site }
    /// The amber gauge 0…1: full while ready, empty through the burst and the curtain, filling during the recharge.
    public var gauge: Float { phase == .ready ? 1 : (phase == .recharge ? 1 - max(0, t) / site.coolTime : 0) }
    /// A steam curtain is up (the burst's warning included: nothing drops into it, the bots keep out; a coolant mist hurts
    /// no marine and blocks no drop).
    public var hot: Bool { site.kind == .steam && (phase == .burst || phase == .venting) }
}

/// A light circuit now.
public struct CircuitState: Equatable {
    public let site: CircuitSite
    /// The breaker is on (a DARK mission starts with it off).
    public internal(set) var powered = true
    /// Its lamps (indices into `Game.lamps`).
    public internal(set) var lamps: [Int] = []
    /// Lamps burning now.
    public internal(set) var burning = 0
    /// The breaker ring's charge 0…1 (it drains while nobody stands in it).
    public internal(set) var progress: Float = 0
    /// Sim time of its last restore (the renderer brings its lamps on one by one from the breaker).
    public internal(set) var restoredAt: Float = -99
    public init(site: CircuitSite) { self.site = site }
    /// Lit: powered with at least half its lamps burning (the report counts these).
    public var lit: Bool { powered && !lamps.isEmpty && burning * 2 >= lamps.count }
    /// The breaker ring does something: the circuit is off or a lamp of it is out.
    public var needsRestore: Bool { !powered || burning < lamps.count }
}

/// A deck lamp now.
public struct LampState: Equatable {
    public let site: LampSite
    public internal(set) var hp: Float = LAMP_HP
    /// Burning: whole, on a powered circuit (a lamp on no circuit always burns).
    public internal(set) var on = true
    /// Sim time it last went on or off (the renderer's flicker).
    public internal(set) var changedAt: Float = -99
    public init(site: LampSite) { self.site = site }
}

/// A supply locker now.
public struct LockerState: Equatable {
    public let site: LockerSite
    public internal(set) var used = false
    /// The ring's charge 0…1 (it drains while nobody stands in it).
    public internal(set) var progress: Float = 0
    /// The marine who opened it (−1 not yet).
    public internal(set) var openedBy = -1
    public init(site: LockerSite) { self.site = site }
}

/// What the props did in a mission (debug logs, tests, calibration rows).
public struct PropStats: Equatable {
    /// Valves burst, bugs the curtains killed on the deck and up on the spans, bugs a coolant mist froze, squad HP lost to
    /// the steam.
    public internal(set) var bursts = 0, curtainKills = 0, upKills = 0, freezes = 0
    public internal(set) var steamHurt: Float = 0
    /// Lamps the hive broke, spits it aimed at lamps, circuits brought back (rings and switches), lockers opened.
    public internal(set) var lampsBroken = 0, lampSpits = 0, restores = 0, lockers = 0
    public init() {}
}

/// The props' runtime state (reset with the world).
struct PropsState {
    var valves: [ValveState] = []
    var circuits: [CircuitState] = []
    var lamps: [LampState] = []
    var lockers: [LockerState] = []
    /// The lit mask or a curtain changed: the overhead's no-drop circles are rebuilt at the end of the tick.
    var dirty = false
    /// Beacons lit when the no-drop circles were last built (a lit beacon lights its deck for good).
    var beaconsSeen = 0
    /// Sim time from which the hive may spit on a lamp again; the spitters winding up at a lamp (uid, lamp).
    var lampSpitAt: Float = 0
    var lampSpitters: [(Int32, Int)] = []
    /// Last «They're cutting the lights» toast (sim time).
    var cutToastAt: Float = -99
    /// First-sighting tips shown: valve, breaker, locker; their clock.
    var tips = [false, false, false]
    var tipT: Float = 0
    /// Valve crowd counting clock; steam damage on each marine not yet dealt (applied in 2.5 HP steps).
    var crowdT: Float = 0
    var steamAcc: [Float] = [0, 0, 0, 0]
    var stats = PropStats()
    var isEmpty: Bool { valves.isEmpty && circuits.isEmpty && lockers.isEmpty }
}

extension Game {

    // ---------------------------------------------------------------- public views
    /// The station's steam valves, light circuits, deck lamps (only on a station with circuits) and supply lockers.
    public var valves: [ValveState] { props.valves }
    public var circuits: [CircuitState] { props.circuits }
    public var lamps: [LampState] { props.lamps }
    public var lockers: [LockerState] { props.lockers }
    public var propStats: PropStats { props.stats }
    /// The station has interactive props (empty on the classic mission).
    public var hasProps: Bool { !props.isEmpty }
    /// Light circuits lit now (the report's «Lights on at extraction N/M»).
    public var lightsLit: Int {
        var n = 0
        for c in props.circuits where c.lit { n += 1 }
        return n
    }

    /// Lit deck at (x, z): a burning lamp's pool within LAMP_LIT_R or a lit beacon within BEACON_LIT_R (only on a station
    /// with light circuits; drops never land there).
    public func lit(_ x: Float, _ z: Float) -> Bool {
        if props.circuits.isEmpty { return false }
        for l in props.lamps where l.on && l.site.circuit >= 0 {
            let p = l.site.pool
            if (x - p.x) * (x - p.x) + (z - p.y) * (z - p.y) < LAMP_LIT_R * LAMP_LIT_R { return true }
        }
        for b in beacons where b.state == 2 && (x - b.x) * (x - b.x) + (z - b.z) * (z - b.z) < BEACON_LIT_R * BEACON_LIT_R { return true }
        return false
    }

    // ---------------------------------------------------------------- reset
    /// From resetWorld (after the director): the props of the station as laid; a DARK mission starts with every circuit off.
    /// The title's attract swarm leaves them alone (empty state: the renderer draws every lamp burning).
    func resetProps() {
        props = PropsState()
        let P = level.layout.props
        if P.isEmpty || attract { return }
        props.valves = P.valves.map { ValveState(site: $0) }
        props.lockers = P.lockers.map { LockerState(site: $0) }
        if !P.circuits.isEmpty {
            let dark = mission.modifiers.contains(.dark)
            props.circuits = P.circuits.map { var c = CircuitState(site: $0); c.powered = !dark; return c }
            props.lamps = level.lamps.map { LampState(site: $0) }
            for k in props.lamps.indices {
                let c = props.lamps[k].site.circuit
                if c >= 0 { props.circuits[c].lamps.append(k); props.lamps[k].on = !dark }
            }
            for c in props.circuits.indices { recount(c) }
        }
        rebuildNoDrop()
    }

    // ---------------------------------------------------------------- the tick
    /// Once per tick after the abilities and medkits (Game.tick, stations with props).
    func propsTick(_ dt: Float) {
        if !props.valves.isEmpty { valvesTick(dt) }
        if !props.circuits.isEmpty {
            circuitsTick(dt)
            bruteLamps()
            if beaconsDone != props.beaconsSeen { props.dirty = true }
        }
        if !props.lockers.isEmpty { lockersTick(dt) }
        if !simOnly && !attract { propTips(dt) }
        if props.dirty { rebuildNoDrop() }
    }

    /// The overhead's no-drop circles (R2's seam, `OverheadState.noDrop`): the lit deck — burning lamps' pools, lit beacons
    /// — and every hot curtain (circles every 1.5 m along its span).
    func rebuildNoDrop() {
        var c: [SIMD3<Float>] = []
        if !props.circuits.isEmpty {
            for l in props.lamps where l.on && l.site.circuit >= 0 { let p = l.site.pool; c.append(SIMD3(p.x, p.y, LAMP_LIT_R)) }
            for b in beacons where b.state == 2 { c.append(SIMD3(b.x, b.z, BEACON_LIT_R)) }
        }
        for v in props.valves where v.hot {
            let s = v.site, len = hypotf2(s.bx - s.ax, s.bz - s.az)
            let n = max(1, Int((len / 1.5).rounded(.up)))
            for k in 0...n {
                let u = Float(k) / Float(n)
                c.append(SIMD3(s.ax + (s.bx - s.ax) * u, s.az + (s.bz - s.az) * u, s.width + 0.3))
            }
        }
        oh.noDrop = c
        props.beaconsSeen = beaconsDone
        props.dirty = false
    }

    // ---------------------------------------------------------------- steam valves
    func valvesTick(_ dt: Float) {
        props.crowdT -= dt
        let count = props.crowdT <= 0
        if count { props.crowdT = 0.25 }
        for k in props.valves.indices {
            switch props.valves[k].phase {
            case .ready:
                if count { props.valves[k].crowd = curtainCrowd(k) }
            case .burst:
                props.valves[k].t -= dt
                if props.valves[k].t <= 0 { startCurtain(k) }
            case .venting:
                props.valves[k].t -= dt
                curtainTick(k, dt)
                if props.valves[k].t <= 0 {
                    props.valves[k].phase = .recharge; props.valves[k].t = props.valves[k].site.coolTime; props.dirty = true
                    for j in 0..<4 { props.steamAcc[j] = 0 }
                }
            case .recharge:
                props.valves[k].t -= dt
                if props.valves[k].t <= 0 {
                    props.valves[k].phase = .ready; props.valves[k].t = 0; props.valves[k].hp = VALVE_HP; props.valves[k].src = -1
                    emit(.valveReady(index: k))
                }
            }
        }
    }

    /// Damage to valve `k` (a round aimed up, a blast reaching up): at VALVE_HP it bursts. Only a ready valve takes it.
    func hitValve(_ k: Int, _ dmg: Float, _ src: Int) {
        guard k >= 0 && k < props.valves.count, props.valves[k].phase == .ready else { return }
        props.valves[k].hp -= dmg
        if props.valves[k].hp <= 0 { burstValve(k, src) }
    }

    /// Valve `k` bursts: the warning (the amber ring of «it explodes» at the curtain's centre, the lane under the span),
    /// then the curtain.
    func burstValve(_ k: Int, _ src: Int) {
        props.valves[k].phase = .burst; props.valves[k].t = VALVE_WARN; props.valves[k].hp = 0; props.valves[k].src = src
        props.stats.bursts += 1
        props.dirty = true
        let s = props.valves[k].site, c = s.mid
        if !simOnly {
            let dx = s.bx - s.ax, dz = s.bz - s.az, len = max(0.1, hypotf2(dx, dz))
            let cold = s.kind == .coolant
            // (steam: the amber ring of «it explodes»; a coolant line's in frost blue)
            teleRing(c.x, c.y, 0.6, cold ? 0.35 : 1.0, cold ? 0.75 : 0.45, cold ? 1.0 : 0.1, VALVE_WARN + 0.15, r1: s.width + len * 0.5,
                     pulse: false, cause: .steam)
            teleSteam(s.ax, s.az, dx / len, dz / len, len, s.width * 2, VALVE_WARN, s.ventTime, cold: cold)
            emit(.valveBurst(index: k))
            sound(cold ? .freeze : .overheat, c.x, c.y)
        }
    }

    func startCurtain(_ k: Int) {
        props.valves[k].phase = .venting; props.valves[k].t = props.valves[k].site.ventTime
        if !simOnly {
            let c = props.valves[k].site.mid
            emit(.valveVented(index: k))
            sound(.nova, c.x, c.y)
        }
    }

    /// One tick of a curtain: the deck bugs under the span scald (CURTAIN_BUG_DPS, a damage over time), the bugs up on the
    /// span die (they are all light bugs up there), the marines in it take CURTAIN_MARINE_DPS in 2.5 HP steps.
    func curtainTick(_ k: Int, _ dt: Float) {
        if props.valves[k].site.kind == .coolant { mistTick(k, dt); return }
        let v = props.valves[k], s = v.site, S = bugs
        var i = 0
        let n = S.count
        while i < n {
            defer { i += 1 }
            if S.dead[i] != 0 { continue }
            let st = S.st[i]
            if st == S_FALL { continue }
            // (Stage 2 B1: a boss's chain part scalds like a deck bug — its hit routed to the boss bar — never dies of it)
            if st == S_BOSS {
                if s.covers(S.x[i], S.z[i], pad: S.r[i] * 0.5) || s.spanCovers(S.x[i], S.z[i]) { hitBug(i, CURTAIN_BUG_DPS * dt, v.src, true) }
                continue
            }
            // (Stage 1 R4: a Dropper pinning a marine, S_PIN, is on the deck)
            if (st >= S_HIGH && st != S_PIN) || S.up[i] != 0 {
                // up on the span (or over the curtain): scalded off the pipe — dead
                if !s.spanCovers(S.x[i], S.z[i]) && !s.covers(S.x[i], S.z[i]) { continue }
                if hitBug(i, 1e6, v.src) { props.stats.upKills += 1 }
            } else {
                if !s.covers(S.x[i], S.z[i], pad: S.r[i] * 0.5) { continue }
                if st == S_CLIMB && S.y[i] < -0.6 { continue }   // still below the deck edge
                if hitBug(i, CURTAIN_BUG_DPS * dt, v.src, true) { props.stats.curtainKills += 1 }
            }
        }
        for m in marines {
            let j = m.index
            if m.downed || !s.covers(m.x, m.z) { props.steamAcc[j] = 0; continue }
            props.steamAcc[j] += CURTAIN_MARINE_DPS * dt
            if props.steamAcc[j] >= 2.5 {
                let hp0 = m.hp
                hurtMarine(m, props.steamAcc[j], 0, 0, .environment)
                props.stats.steamHurt += max(0, hp0 - max(0, m.hp))
                props.steamAcc[j] = 0
            }
        }
    }

    /// One tick of a coolant line's freezing mist: the deck bugs under the span chill (COOLANT_CHILL a second) and freeze,
    /// the bugs up on the span freeze and fall (they shatter on the deck); the Queen never freezes; no marine is hurt.
    func mistTick(_ k: Int, _ dt: Float) {
        let v = props.valves[k], s = v.site, S = bugs
        var i = 0
        let n = S.count
        while i < n {
            defer { i += 1 }
            // (a boss never freezes: the Матка is immune, a chain part locks its body instead)
            if S.dead[i] != 0 { continue }
            if S.boss[i] != 0 {
                if S.boss[i] != BOSS_BUG && (s.covers(S.x[i], S.z[i]) || s.spanCovers(S.x[i], S.z[i])) { bossPartFreeze(i, nova: false) }
                continue
            }
            let st = S.st[i]
            if st == S_FALL { continue }
            if (st >= S_HIGH && st != S_PIN) || S.up[i] != 0 {
                if !s.spanCovers(S.x[i], S.z[i]) && !s.covers(S.x[i], S.z[i]) { continue }
                S.frz[i] = 3.2; S.chill[i] = 1
                knockDown(i, src: v.src)
                props.stats.freezes += 1
                continue
            }
            if S.frz[i] > 0 || !s.covers(S.x[i], S.z[i], pad: S.r[i] * 0.5) { continue }
            if st == S_CLIMB && S.y[i] < -0.6 { continue }
            S.chill[i] = minf(1, S.chill[i] + COOLANT_CHILL * dt)
            if S.chill[i] >= 1 {
                S.frz[i] = S.type[i] == T_BRUTE ? 1.3 : 2.6; S.vx[i] = 0; S.vz[i] = 0
                props.stats.freezes += 1
                if !simOnly { emit(.bugFrozen(pos: Vec2(S.x[i], S.z[i]))); sound(.freeze, S.x[i], S.z[i]) }
            }
        }
    }

    /// Deck bugs under valve `k`'s span (not those still climbing below the edge).
    func curtainCrowd(_ k: Int) -> Int {
        let s = props.valves[k].site, S = bugs
        var c = 0, i = 0
        let n = S.count
        while i < n {
            defer { i += 1 }
            if S.dead[i] != 0 || (S.st[i] >= S_HIGH && S.st[i] != S_PIN) || S.up[i] != 0 { continue }
            if S.st[i] == S_CLIMB && S.y[i] < -0.6 { continue }
            if s.covers(S.x[i], S.z[i]) { c += 1 }
        }
        return c
    }

    /// A round aimed up: the ready valve whose footprint (VALVE_HIT_R) the segment touches first, nearer than `maxT`.
    /// (-1, maxT) when none.
    func valveSegmentHit(_ sx: Float, _ sz: Float, _ dx: Float, _ dz: Float, _ maxT: Float) -> (Int, Float) {
        var best = -1
        var segT = maxT
        for k in props.valves.indices where props.valves[k].phase == .ready {
            let s = props.valves[k].site
            let bx = s.x - sx, bz = s.z - sz, t = bx * dx + bz * dz
            if t < -0.3 || t > segT { continue }
            let px = bx - dx * t, pz = bz - dz * t
            if px * px + pz * pz < VALVE_HIT_R * VALVE_HIT_R { segT = maxf(0, t); best = k }
        }
        return (best, segT)
    }

    /// Projectile `k` struck valve `v` at (hx, hz): the round stops there.
    func shotValve(_ k: Int, _ v: Int, _ hx: Float, _ hz: Float) {
        let P = projectiles
        if (P.flags[k] & 1) != 0 && (P.flags[k] & 2) == 0 { hits += 1; P.flags[k] |= 2 }
        hitValve(v, P.dmg[k], Int(P.own[k]))
        emit(.valveHit(index: v))
    }

    /// The squad's blasts reach a valve at BLAST_UP × their radius (like the bugs up there).
    func valveBlast(_ e: Boom) {
        let R = e.r * BLAST_UP
        for k in props.valves.indices where props.valves[k].phase == .ready {
            let s = props.valves[k].site, d = hypotf2(s.x - e.x, s.z - e.z)
            if d < R + VALVE_HIT_R { hitValve(k, e.dmg * (1 - 0.55 * minf(1, d / R)), e.src) }
        }
    }

    /// A lane telegraph in steam white (frost blue: a coolant mist) — the curtain's strip on the deck, pulsing through the
    /// warning, fading over the curtain.
    func teleSteam(_ x: Float, _ z: Float, _ dx: Float, _ dz: Float, _ len: Float, _ w: Float, _ wind: Float, _ charge: Float,
                   cold: Bool = false) {
        if simOnly { return }
        let k = teleAlloc(); if k < 0 { return }
        var e = Telegraph()
        e.active = true; e.shape = .lane; e.cause = .steam; e.x = x; e.z = z; e.dx = dx; e.dz = dz; e.len = len; e.w = w
        e.r = cold ? 0.3 : 0.62; e.g = cold ? 0.7 : 0.86; e.b = 1.0; e.t = 0; e.life = wind + charge; e.wind = wind; e.pulse = true
        telegraphs[k] = e
        events.append(.telegraph(index: k, shape: .lane, cause: .steam, pos: Vec2(x, z)))
    }

    // ---------------------------------------------------------------- lamps and circuits
    /// Burning lamps of circuit `c`.
    func recount(_ c: Int) {
        var n = 0
        for k in props.circuits[c].lamps where props.lamps[k].on { n += 1 }
        props.circuits[c].burning = n
    }

    func circuitsTick(_ dt: Float) {
        for c in props.circuits.indices {
            if !props.circuits[c].needsRestore || stepOwnsBreaker(c) { props.circuits[c].progress = 0; continue }
            let s = props.circuits[c].site
            if standingIn(s.x, s.z, s.radius) > 0 {
                props.circuits[c].progress = minf(1, props.circuits[c].progress + dt / s.time)
                if props.circuits[c].progress >= 1 { restoreCircuit(c) }
            } else {
                props.circuits[c].progress = maxf(0, props.circuits[c].progress - dt * 0.5)
            }
        }
    }

    /// Circuit `c` back on: power, every lamp of it whole and burning (the renderer staggers them from the breaker).
    func restoreCircuit(_ c: Int) {
        guard c >= 0 && c < props.circuits.count else { return }
        props.circuits[c].powered = true
        props.circuits[c].progress = 0
        props.circuits[c].restoredAt = simTime
        for k in props.circuits[c].lamps {
            props.lamps[k].hp = LAMP_HP
            if !props.lamps[k].on { props.lamps[k].on = true; props.lamps[k].changedAt = simTime }
        }
        recount(c)
        props.stats.restores += 1
        props.dirty = true
        if !simOnly {
            let s = props.circuits[c].site
            emit(.circuitRestored(index: c))
            sound(.shock, s.x, s.z)
            let P = marines[0]
            if hypotf2(s.x - P.x, s.z - P.z) < 30 { toast(GameText(.toastLightsUp), .gold) }
        }
    }

    /// Circuit `c` loses its power (a darkness event; debug): its lamps go out, whole.
    func cutCircuit(_ c: Int) {
        guard c >= 0 && c < props.circuits.count, props.circuits[c].powered else { return }
        props.circuits[c].powered = false
        props.circuits[c].progress = 0
        for k in props.circuits[c].lamps where props.lamps[k].on { props.lamps[k].on = false; props.lamps[k].changedAt = simTime }
        recount(c)
        props.dirty = true
        emit(.circuitCut(index: c))
    }

    /// Lamp `k` breaks (the hive): it goes out until its circuit's breaker brings it back.
    func breakLamp(_ k: Int) {
        guard k >= 0 && k < props.lamps.count, props.lamps[k].site.circuit >= 0, props.lamps[k].hp > 0 else { return }
        props.lamps[k].hp = 0
        if props.lamps[k].on { props.lamps[k].on = false; props.lamps[k].changedAt = simTime }
        recount(props.lamps[k].site.circuit)
        props.stats.lampsBroken += 1
        props.dirty = true
        if !simOnly {
            let f = props.lamps[k].site.foot
            emit(.lampBroken(index: k))
            sound(.shatter, f.x, f.y)
            let P = marines[0]
            if simTime - props.cutToastAt >= 25 && hypotf2(f.x - P.x, f.y - P.z) < 26 {
                props.cutToastAt = simTime
                toast(GameText(.toastLightsCut), .warn)
            }
        }
    }

    /// A lamp takes `dmg` (the hive's acid): at 0 it breaks.
    func hurtLamp(_ k: Int, _ dmg: Float) {
        guard k >= 0 && k < props.lamps.count, props.lamps[k].hp > 0 else { return }
        if props.lamps[k].hp - dmg <= 0 { breakLamp(k) } else { props.lamps[k].hp -= dmg }
    }

    /// A charging brute breaks the lamp posts it rams on its way (design: «brutes ram lamps as they pass»; a brute walking
    /// or cresting the railing beside a post leaves it).
    func bruteLamps() {
        if typeAlive[Int(T_BRUTE)] == 0 { return }
        let S = bugs
        var i = 0
        let n = S.count
        while i < n {
            defer { i += 1 }
            if S.dead[i] != 0 || S.type[i] != T_BRUTE || S.st[i] != S_CHARGE { continue }
            let x = S.x[i], z = S.z[i], rr = S.r[i] + 0.3
            for k in props.lamps.indices where props.lamps[k].hp > 0 && props.lamps[k].site.circuit >= 0 {
                let l = props.lamps[k].site
                if absf(l.x - x) < rr && absf(l.z - z) < rr && (l.x - x) * (l.x - x) + (l.z - z) * (l.z - z) < rr * rr { breakLamp(k) }
            }
        }
    }

    /// A spitter at (x, z) whose spit is ready may aim at a lamp instead (at most once in LAMP_SPIT_GAP s for the whole hive):
    /// the nearest whole lamp whose foot is 3.2–11 m away and in the squad's sight (≤ 24 m from it). -1 none.
    func lampSpitTarget(_ x: Float, _ z: Float) -> Int {
        if simTime < props.lampSpitAt { return -1 }
        let c = squadCenter()
        var best = -1
        var bd: Float = 121
        for k in props.lamps.indices where props.lamps[k].on && props.lamps[k].site.circuit >= 0 {
            let f = props.lamps[k].site.foot
            let d2 = (f.x - x) * (f.x - x) + (f.y - z) * (f.y - z)
            if d2 < 10.24 || d2 >= bd { continue }
            if (f.x - c.x) * (f.x - c.x) + (f.y - c.y) * (f.y - c.y) > 576 { continue }
            bd = d2; best = k
        }
        return best
    }

    /// Spitter `i` winds up at lamp `k` (the lime ring and fill on the lamp's foot, like an aimed spit; the glob breaks it).
    func spitAtLamp(_ i: Int, _ k: Int) {
        let S = bugs, f = props.lamps[k].site.foot
        S.st[i] = S_WIND; S.t[i] = 0.5; S.ax[i] = f.x; S.az[i] = f.y
        props.lampSpitAt = simTime + LAMP_SPIT_GAP
        props.lampSpitters.removeAll { $0.0 == S.uid[i] }
        if props.lampSpitters.count >= 4 { props.lampSpitters.removeFirst() }
        props.lampSpitters.append((S.uid[i], k))
        props.stats.lampSpits += 1
        if !simOnly {
            teleRing(f.x, f.y, 1.5, 0.75, 1.0, 0.15, 1.45, cause: .acidTarget)
            teleFill(f.x, f.y, 1.5, 0.5, 0.85, 0.08, 1.45, cause: .acidTarget)
        }
    }

    /// The lamp a spitter launching now was winding up at (-1: it aimed at a marine).
    func lampOfSpitter(_ uid: Int32) -> Int {
        guard let j = props.lampSpitters.firstIndex(where: { $0.0 == uid }) else { return -1 }
        let k = props.lampSpitters[j].1
        props.lampSpitters.remove(at: j)
        return k
    }

    /// While a SWITCH step's breaker switch stands on circuit `c`'s breaker, the step's ring is the one (it restores the
    /// circuit when thrown — `propsSwitchThrown`).
    func stepOwnsBreaker(_ c: Int) -> Bool {
        guard case .switches? = currentStep else { return false }
        let b = props.circuits[c].site
        for s in switches where s.state != 2 && s.site.kind == .breaker && hypotf2(s.site.x - b.x, s.site.z - b.z) < 1.5 { return true }
        return false
    }

    /// R1's seam: a SWITCH step's switch of kind `.breaker` was thrown — the circuit whose breaker it stands on comes back.
    func propsSwitchThrown(_ site: SwitchSite) {
        guard site.kind == .breaker else { return }
        for c in props.circuits.indices where hypotf2(props.circuits[c].site.x - site.x, props.circuits[c].site.z - site.z) < 1.5 {
            restoreCircuit(c)
            return
        }
    }

    // ---------------------------------------------------------------- supply lockers
    func lockersTick(_ dt: Float) {
        for k in props.lockers.indices where !props.lockers[k].used {
            let s = props.lockers[k].site
            if standingIn(s.x, s.z, s.radius) > 0 {
                props.lockers[k].progress = minf(1, props.lockers[k].progress + dt / s.time)
                if props.lockers[k].progress >= 1 { openLocker(k) }
            } else {
                props.lockers[k].progress = maxf(0, props.lockers[k].progress - dt * 0.5)
            }
        }
    }

    /// Locker `k` opens: a medkit at the ring, every standing marine in the ring gets its ability back.
    func openLocker(_ k: Int) {
        let s = props.lockers[k].site
        var who = -1
        var bd: Float = .infinity
        for m in marines where !m.downed {
            let d = hypotf2(m.x - s.x, m.z - s.z)
            if d >= s.radius { continue }
            m.abCd = 0
            if d < bd { bd = d; who = m.index }
        }
        props.lockers[k].used = true; props.lockers[k].progress = 1; props.lockers[k].openedBy = who
        props.stats.lockers += 1
        dropMedkit(s.x, s.z)
        if !simOnly {
            emit(.lockerOpened(index: k, marine: who))
            sound(.reload, s.x, s.z)
            if who == 0 { toast(GameText(.toastLocker), .gold) }
        }
    }

    // ---------------------------------------------------------------- first-sighting tips
    /// Twice a second: the first time a valve, a breaker that needs its ring, or an unused locker is near the player and in
    /// sight, its tip (once per mission each).
    func propTips(_ dt: Float) {
        props.tipT -= dt
        if props.tipT > 0 || props.tips.allSatisfy({ $0 }) { return }
        props.tipT = 0.5
        let P = marines[0]
        if P.downed || coach.active { return }
        func near(_ x: Float, _ z: Float, _ r: Float) -> Bool { hypotf2(x - P.x, z - P.z) < r && isVisible(x, z) }
        if !props.tips[0], props.valves.contains(where: { $0.phase == .ready && near($0.site.x, $0.site.z, 12) }) {
            props.tips[0] = true
            toast(GameText(.toastTipValve), .warn)
        } else if !props.tips[1], props.circuits.contains(where: { $0.needsRestore && near($0.site.x, $0.site.z, 9) }) {
            props.tips[1] = true
            toast(GameText(.toastTipBreaker), .warn)
        } else if !props.tips[2], props.lockers.contains(where: { !$0.used && near($0.site.x, $0.site.z, 9) }) {
            props.tips[2] = true
            toast(GameText(.toastTipLocker), .warn)
        }
    }

    // ---------------------------------------------------------------- the bots and the autopilot
    /// The think of a bot (or the autopilot) on a station with props (botThink, every 0.12–0.2 s): a valve worth popping,
    /// a locker when hurt, a dark breaker when the squad is idle (bots only).
    func propThink(_ m: Marine) {
        m.ai.valve = props.valves.isEmpty ? -1 : botValvePick(m)
        m.ai.locker = props.lockers.isEmpty ? -1 : lockerDuty(m)
        m.ai.breaker = props.circuits.isEmpty || m.isPlayer ? -1 : breakerDuty(m)
    }

    /// The ready valve a rifle or rotary cannon should pop: VALVE_BOT_CROWD deck bugs under its span, no marine in it, its
    /// footprint ≤ 17 m away (the nearest such). -1 none.
    func botValvePick(_ m: Marine) -> Int {
        guard m.cls == .assault || m.cls == .gunner else { return -1 }
        var best = -1
        var bd: Float = 17 * 17
        for (k, v) in props.valves.enumerated() where v.phase == .ready && v.crowd >= VALVE_BOT_CROWD {
            let dx = v.site.x - m.x, dz = v.site.z - m.z, d2 = dx * dx + dz * dz
            if d2 >= bd || d2 < 1 { continue }
            var clear = true
            for o in marines where !o.downed && v.site.covers(o.x, o.z, pad: 0.4) { clear = false }
            if !clear { continue }
            bd = d2; best = k
        }
        return best
    }

    /// Aim at valve `m.ai.valve` and say whether to fire (nil: it is no longer ready — back to the bugs).
    func valveFire(_ m: Marine, _ dt: Float) -> Bool? {
        let k = m.ai.valve
        guard k >= 0 && k < props.valves.count, props.valves[k].phase == .ready else { m.ai.valve = -1; return nil }
        let s = props.valves[k].site
        let want = atan2f2(s.x - m.x, s.z - m.z)
        let diff = angDiff(m.aim, want)
        m.aim += clampf(diff, -10 * dt, 10 * dt)
        m.aimUp = true
        return abs(diff) < 0.14 && hypotf2(s.x - m.x, s.z - m.z) < 17.5
    }

    /// The locker a hurt marine should go to: unused, ≤ 18 m (the autopilot: 14 m, between objectives only), the marine
    /// below 45 % armour (kept until the locker opens or the swarm closes in), nobody else on it. -1 none.
    func lockerDuty(_ m: Marine) -> Int {
        let S = bugs
        let keep = m.ai.locker
        if keep >= 0 && keep < props.lockers.count && !props.lockers[keep].used {
            let s = props.lockers[keep].site
            if hypotf2(s.x - m.x, s.z - m.z) < 24 && hash.queryCircle(S, m.x, m.z, 5) < 4 && (!m.isPlayer || posture == .travel) { return keep }
        }
        if m.hp >= m.maxHp * 0.45 || (m.isPlayer && posture != .travel) { return -1 }
        if hash.queryCircle(S, m.x, m.z, 6) >= 2 { return -1 }
        let reach: Float = m.isPlayer ? 14 : 18
        var best = -1
        var bd = reach
        for (k, l) in props.lockers.enumerated() where !l.used {
            if marines.contains(where: { $0 !== m && !$0.downed && $0.ai.locker == k }) { continue }
            let d = hypotf2(l.site.x - m.x, l.site.z - m.z)
            if d < bd { bd = d; best = k }
        }
        return best
    }

    /// The dark breaker an idle bot should bring back: the squad between objectives, no bugs within 10 m of the bot, the
    /// breaker ≤ 22 m from the player and ≤ 25 m from the bot, no other bot nearer to it or on it (kept until it is lit or
    /// the swarm closes in). -1 none.
    func breakerDuty(_ m: Marine) -> Int {
        let S = bugs, P = marines[0]
        let keep = m.ai.breaker
        if keep >= 0 && keep < props.circuits.count && props.circuits[keep].needsRestore && !stepOwnsBreaker(keep) && posture == .travel {
            let s = props.circuits[keep].site
            if hypotf2(s.x - P.x, s.z - P.z) < 28 && hash.queryCircle(S, m.x, m.z, 7) < 3 { return keep }
        }
        if posture != .travel || P.downed { return -1 }
        if hash.queryCircle(S, m.x, m.z, 10) > 0 { return -1 }
        var best = -1
        var bd: Float = 25
        for (c, ci) in props.circuits.enumerated() where ci.needsRestore && (!ci.powered || ci.burning * 2 < ci.lamps.count) {
            if stepOwnsBreaker(c) { continue }
            let s = ci.site
            if hypotf2(s.x - P.x, s.z - P.z) > 22 { continue }
            let d = hypotf2(s.x - m.x, s.z - m.z)
            if d >= bd { continue }
            var taken = false
            for o in marines where o !== m && !o.isPlayer && !o.downed {
                if o.ai.breaker == c || hypotf2(s.x - o.x, s.z - o.z) < d - 0.5 { taken = true }
            }
            if taken { continue }
            bd = d; best = c
        }
        return best
    }

    /// Where a bot on a prop duty stands (a locker: its ring's centre; a breaker: 1.1 m from the pedestal on its side — it
    /// arrives within 0.6 m, inside the ring), nil without a duty.
    func propDutyGoal(_ m: Marine) -> Vec2? {
        if m.ai.locker >= 0 && m.ai.locker < props.lockers.count {
            let s = props.lockers[m.ai.locker].site
            return Vec2(s.x, s.z)
        }
        if m.ai.breaker >= 0 && m.ai.breaker < props.circuits.count {
            let s = props.circuits[m.ai.breaker].site
            var dx = m.x - s.x, dz = m.z - s.z
            let d = hypotf2(dx, dz)
            if d > 0.05 { dx /= d; dz /= d } else { dx = 1; dz = 0 }
            var g = Vec2(s.x + dx * 1.1, s.z + dz * 1.1)
            if !level.canStand(g.x, g.y) { g = Vec2(s.x + 1.1, s.z) }
            return g
        }
        return nil
    }

    /// A bot steps out of a hot curtain (sideways from its centre line).
    func curtainDodge(_ m: Marine) {
        for v in props.valves where v.hot {
            let s = v.site
            if !s.covers(m.x, m.z, pad: 0.3) { continue }
            let dx = s.bx - s.ax, dz = s.bz - s.az, l = max(0.01, hypotf2(dx, dz))
            var nx = -dz / l, nz = dx / l
            // to the side of the line it stands on (and onto the deck: the far side of a rail curtain is the void)
            let sd: Float = ((m.x - s.ax) * nx + (m.z - s.az) * nz) >= 0 ? 1 : -1
            nx *= sd; nz *= sd
            if !level.canStand(m.x + nx * 1.2, m.z + nz * 1.2) { nx = -nx; nz = -nz }
            m.ai.sideX = nx; m.ai.sideZ = nz; m.ai.sideT = 0.3
        }
    }

    /// Aim assist (the player): the ready valve the stick points at where it is DRAWN (≈ 0.75 h up-screen of its footprint,
    /// like a bug up on a route), when it is better aligned than the bug the assist found (`bugCos`). Returns its footprint
    /// (playerCommands pulls the aim onto it a quarter harder than onto a bug: a valve does not move).
    func valveAssist(_ m: Marine, _ dx: Float, _ dz: Float, _ bugCos: Float) -> Vec2? {
        var best: Vec2? = nil
        var bc = maxf(0.95, bugCos)
        for v in props.valves where v.phase == .ready {
            let s = v.site
            let lift = 0.75 * maxf(0, s.y - level.groundY(s.x, s.z))
            let vx = s.x + FWD_X * lift - m.x, vz = s.z + FWD_Z * lift - m.z, d = hypotf2(vx, vz)
            if d < 1.5 || d > 20 { continue }
            let cs = (vx * dx + vz * dz) / d
            if cs <= bc || !isVisible(s.x, s.z) { continue }
            bc = cs; best = Vec2(s.x, s.z)
        }
        return best
    }

    // ---------------------------------------------------------------- debug / demo / tests
    /// Burst valve `k` now (as if shot by marine `by`).
    public func debugBurstValve(_ k: Int, by src: Int = -1) {
        guard k >= 0 && k < props.valves.count, props.valves[k].phase == .ready else { return }
        burstValve(k, src)
        rebuildNoDrop()
    }
    /// Cut circuit `k`'s power / bring it back.
    public func debugCutCircuit(_ k: Int) { cutCircuit(k); if props.dirty { rebuildNoDrop() } }
    public func debugRestoreCircuit(_ k: Int) { restoreCircuit(k); if props.dirty { rebuildNoDrop() } }
    /// Break lamp `k` (as the hive would).
    public func debugBreakLamp(_ k: Int) { breakLamp(k); if props.dirty { rebuildNoDrop() } }
    /// The lamp-spit clock: the hive may spit on a lamp again from now (tests).
    public func debugAllowLampSpit() { props.lampSpitAt = simTime }
    /// `n` bugs of `type` spread evenly along a → b where the deck is walkable (demo staging; the live cap holds). Returns
    /// how many were made.
    @discardableResult
    public func debugSpawnLine(_ n: Int, type: BugType, from a: Vec2, to b: Vec2) -> Int {
        var made = 0
        for k in 0..<max(1, n) {
            let u: Float = n > 1 ? Float(k) / Float(n - 1) : 0.5
            let x = a.x + (b.x - a.x) * u, z = a.y + (b.y - a.y) * u
            if level.walkable(x, z) && capLeft() > 0 && spawnBug(UInt8(type.rawValue), x, z) >= 0 { made += 1 }
        }
        return made
    }
}
