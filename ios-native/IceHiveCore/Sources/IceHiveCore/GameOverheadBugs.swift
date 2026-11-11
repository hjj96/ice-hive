import Foundation

// ================================================================
//  THE OVERHEAD'S BUGS (Stage 1 R4 «Overhead bugs»; design.md §1.1.3–1.1.6)
//   · THE DROPPER (BugType.dropper): rides the routes (5.5 m/s; slow on
//     cables), waits above its marine's path, telegraphs like every drop
//     (`dropWarn`: 0.9 s, Recruit 1.2 s — the ring, the frost column, the
//     eye glint), lands for 14 × the damage multiplier and PINS the marine
//     for up to 1.2 s (Recruit 0.8 s; approved by the owner): no move, no
//     fire, no ability, and it gnaws. A dash breaks the pin at once; so does
//     PIN_BREAK (15) damage on the Dropper — the squad's fire, any weapon —,
//     the pin running out, or the marine going down. The bots shoot a
//     pinning Dropper before anything else (after a reaction time) and dash
//     out of a pin of their own; the HUD says «Pinned — dash!». Live
//     Droppers 4 / 5 / 6 by tier; R2's fairness rules hold (≤ dropCap
//     telegraphs, ≤ 2 per marine in 3 s, grace after a dash, a revive — and
//     a pin —, no drop onto lit deck), and never a second pin on a marine.
//   · PERCHED SPITTERS: a spitter sent up climbs to a free perch point (an
//     authored `.perch` node, or a gantry / joint against the void near a
//     deck; at most PERCH_MAX within PERCH_SPACING m) and spits from there —
//     14 m, a 0.65 s wind-up, a 1.1 s glob, the same lime ring and fill —
//     standing still against the void: a priority target (the turret first,
//     the bots while it winds up or when the deck near them is clear, the
//     aim assist like a coiling bug).
//   · DUCT MOUTHS: a pack bound for a duct mouth waits DUCT_RATTLE s while
//     the grille rattles (`.ductRattle`, the amber glow and frost puffs);
//     rounds aimed up, the torch, the beam and the squad's blasts strike the
//     grille (DUCT_HP): it slams shut for DUCT_SHUT s (`.ductSealed`), the
//     packs bound for it are lost and nothing is sent there until the hive
//     chews through (`.ductOpened`). The aim assist finds a mouth where it is
//     drawn; the calibration autopilot shoots a rattling one (the squad bots
//     leave the ducts alone: design §1.4).
//   · the director's channels (Difficulty.dropperGap / perchGap, 0 on every
//     tier until package R5): now and then a Dropper, or a spitter for a
//     perch near the squad, while the overhead channel is open; anti-camping
//     draws Droppers then.
//  Nothing here runs or draws a random number on a station without routes,
//  and none of it without a bug of these kinds up there: the classic mission
//  replays byte for byte.
// ================================================================

/// A duct mouth of the overhead (design §1.1.3): its grille's health, the shut and rattle clocks (`Game.ducts`).
public struct DuctState {
    /// Its route node and position (x, ABSOLUTE y, z).
    public let node: Int
    public let pos: SIMD3<Float>
    /// What is left of the grille (DUCT_HP when whole).
    public internal(set) var hp: Float = DUCT_HP
    /// Seconds it stays shut (0 = open), seconds of rattle left before a pack pours out (0 = quiet).
    public internal(set) var shutT: Float = 0
    public internal(set) var rattleT: Float = 0
    /// Seconds since a bug last came out of it, since a round or a blast last struck it (render; large = none lately).
    public internal(set) var pourAge: Float = 99
    public internal(set) var hitAge: Float = 99
    public var open: Bool { shutT <= 0 }
    /// 0…1 of the grille left.
    public var health: Float { max(0, min(1, hp / DUCT_HP)) }

    init(node: Int, pos: SIMD3<Float>) { self.node = node; self.pos = pos }
}

extension Game {

    // ================================================================ public views
    /// The station's duct mouths (Stage 1 R4): grille health, shut / rattle clocks.
    public var ducts: [DuctState] { oh.ducts }
    /// The perch points' route nodes (`OverheadGraph.perches`) and whether each is taken (or a spitter is on its way there).
    public var perchPoints: [Int] { level.overhead?.perches ?? [] }
    public func perchTaken(_ k: Int) -> Bool { k >= 0 && k < oh.perchUid.count && oh.perchUid[k] != 0 }
    /// Live Droppers now.
    public var droppersAlive: Int { typeAlive.count > Int(T_DROP) ? typeAlive[Int(T_DROP)] : 0 }

    // ================================================================ setup
    /// The duct mouths, perch points and the channels' clocks of this station (resetWorld; nothing without routes).
    func resetOverheadBugs() {
        guard let G = level.overhead else { return }
        var of = [Int](repeating: -1, count: G.nodeCount)
        var ds: [DuctState] = []
        for n in G.ducts {
            of[n] = ds.count
            ds.append(DuctState(node: n, pos: G.nodePos(n)))
        }
        oh.ducts = ds
        oh.ductOf = of
        oh.perchUid = [Int32](repeating: 0, count: G.perches.count)
        oh.perchDist = G.perches.map { routeDistances(G, from: $0) }
        oh.dropperT = difficulty.dropperGap
        oh.perchT = difficulty.perchGap * 0.6
    }

    /// Route distance (m along the edges) from node `n` to every node (∞ = another component). Dijkstra, O(N²): a station's
    /// route set has tens of nodes.
    func routeDistances(_ G: OverheadGraph, from n: Int) -> [Float] {
        let N = G.nodeCount
        var dist = [Float](repeating: .infinity, count: N)
        var done = [Bool](repeating: false, count: N)
        dist[n] = 0
        for _ in 0..<N {
            var u = -1
            var bd: Float = .infinity
            for k in 0..<N where !done[k] && dist[k] < bd { bd = dist[k]; u = k }
            if u < 0 { break }
            done[u] = true
            for e in G.nodeEdges[u] {
                let o = G.ea[e] == u ? G.eb[e] : G.ea[e]
                let d = bd + G.length[e]
                if d < dist[o] { dist[o] = d }
            }
        }
        return dist
    }

    /// Route bugs of `type` still queued.
    func queuedRouteBugs(of type: UInt8) -> Int {
        var n = 0
        for b in oh.queue where b.type == type { n += b.n }
        return n
    }

    /// × a route bug's deck speed along a route of `kind`: the Dropper 5.5 m/s on racks (slow on a cable), the rest as R2.
    @inline(__always) func routeSpeedK(_ i: Int, _ kind: RouteKind) -> Float {
        if bugs.type[i] == T_DROP { return kind == .cable ? DROPPER_CABLE_K : DROPPER_ROUTE_K }
        return kind.speedK
    }

    // ================================================================ the director's channels
    /// The Dropper and perch channels (Difficulty.dropperGap / perchGap; only while the overhead channel is open).
    func channelTick(_ dt: Float) {
        let D = difficulty
        if D.dropperGap > 0 {
            oh.dropperT -= dt
            if oh.dropperT <= 0 {
                oh.dropperT = D.dropperGap * (0.7 + 0.6 * rng.next())
                if droppersAlive + queuedRouteBugs(of: T_DROP) < D.dropperCap {
                    let e = routeEntry(near: squadCenter())
                    if e >= 0 { queueRoutePack(1, entry: e, rate: 1, type: T_DROP) }
                }
            }
        }
        if D.perchGap > 0 && !oh.perchUid.isEmpty {
            oh.perchT -= dt
            if oh.perchT <= 0 {
                oh.perchT = D.perchGap * (0.7 + 0.6 * rng.next())
                let c = squadCenter()
                if freePerch(near: c) >= 0 {
                    let e = routeEntry(near: c)
                    if e >= 0 { queueRoutePack(1, entry: e, rate: 1, type: T_SPIT) }
                }
            }
        }
    }

    // ================================================================ THE DROPPER'S PIN
    /// The Dropper lands on marine `m` (inside its ring): 14 × the damage multiplier, then the pin — not through a dash (or
    /// the blink after a revive), never a second one; the demo's god squad is pinned too (no damage). (fx, fz): its flight.
    func dropperLands(_ i: Int, _ m: Marine, _ fx: Float, _ fz: Float) {
        let S = bugs
        let hp0 = m.hp
        hurtMarine(m, DROPPER_LAND * dmgMul, fx * 2, fz * 2, .dropper)
        oh.stats.hits += 1
        oh.stats.hurt += maxf(0, hp0 - maxf(0, m.hp))
        if m.downed { oh.stats.downs += 1 }
        if m.downed || m.pinT > 0 || m.dashT > 0 || m.inv > 0 || attract {
            S.cd[i] = BUG_SPECS[Int(T_DROP)].atkCd
            return
        }
        pinMarine(i, m, fx, fz)
    }

    /// Pin marine `m` under Dropper `i` (which came along (fx, fz)): it clings on that side, beside the marine, facing it.
    func pinMarine(_ i: Int, _ m: Marine, _ fx: Float, _ fz: Float) {
        let S = bugs
        m.pinT = difficulty.pinT; m.pinBy = S.uid[i]; m.pinAt = simTime
        m.vx = 0; m.vz = 0
        var cx = -fx, cz = -fz
        let cl = hypotf2(cx, cz)
        if cl < 1e-3 { cx = -FWD_X; cz = -FWD_Z } else { cx /= cl; cz /= cl }
        S.st[i] = S_PIN; S.t[i] = PIN_BITE_T; S.rs[i] = 0; S.hit[i] = UInt8(m.index); S.up[i] = 0; S.re[i] = 0
        S.ax[i] = cx; S.az[i] = cz; S.vx[i] = 0; S.vz[i] = 0
        S.hd[i] = atan2f2(-cx, -cz)
        holdPin(i, m)
        oh.stats.pins += 1
        if !simOnly {
            emit(.pinned(marine: m.index, pos: Vec2(S.x[i], S.z[i]), time: m.pinT))
            if m.isPlayer { haptic(.heavy) } else { toast(GameText.matePinned(m.name), .warn) }
        }
    }

    /// Keep a pinning Dropper on its marine: PIN_REACH out on its side (the other side when that is off the deck).
    func holdPin(_ i: Int, _ m: Marine) {
        let S = bugs
        var x = m.x + S.ax[i] * PIN_REACH, z = m.z + S.az[i] * PIN_REACH
        if !level.walkable(x, z) {
            let x2 = m.x - S.ax[i] * PIN_REACH, z2 = m.z - S.az[i] * PIN_REACH
            if level.walkable(x2, z2) {
                S.ax[i] = -S.ax[i]; S.az[i] = -S.az[i]; x = x2; z = z2
                S.hd[i] = atan2f2(-S.ax[i], -S.az[i])
            } else {
                x = m.x; z = m.z
            }
        }
        S.x[i] = x; S.z[i] = z; S.y[i] = level.groundY(x, z)
    }

    /// The per-tick update of a pinning Dropper (routeTick hands S_PIN here): it lets go when the pin ran out, the marine
    /// went down or dashed, it froze; it burns like any bug; it gnaws every PIN_BITE_T s.
    func pinTick(_ i: Int, _ dt: Float) {
        let S = bugs
        let m = marines[Int(S.hit[i] & 3)]
        if m.pinBy != S.uid[i] || m.pinT <= 0 || m.downed || overheadExtracting || S.frz[i] > 0 {
            let cause: PinBreak = m.downed ? .down : (S.frz[i] > 0 ? .fire
                : (m.pinBy == S.uid[i] && m.pinT <= 0 && !overheadExtracting ? .timeout : .release))
            releasePin(i, m, cause, -1)
            return
        }
        if S.burn[i] > 0 {
            S.burn[i] -= dt
            let src = Int(S.bsrc[i])
            if hitBug(i, CLASS_SPECS[1].burnDps * pyroBurnMul(src) * dt, src, true) { return }
            if S.st[i] != S_PIN { return }
        }
        if S.chill[i] > 0 { S.chill[i] = maxf(0, S.chill[i] - dt * 0.4) }
        holdPin(i, m)
        S.ph[i] += dt * 9
        oh.stats.pinTime += dt
        S.t[i] -= dt
        if S.t[i] <= 0 {
            S.t[i] = PIN_BITE_T
            hurtMarine(m, difficulty.pinGnaw * PIN_BITE_T * dmgMul, 0, 0, .dropper)
            if m.downed { releasePin(i, m, .down, -1) }
        }
    }

    /// Damage on a pinning Dropper (hitBug): PIN_BREAK of it since the landing and it lets go — the squad got it off.
    func pinDamage(_ i: Int, _ dmg: Float, _ src: Int) {
        let S = bugs
        S.rs[i] += dmg
        if S.rs[i] >= PIN_BREAK { releasePin(i, marines[Int(S.hit[i] & 3)], .fire, src) }
    }

    /// A pinning Dropper killed (killBug, before its slot is flagged dead): its marine is free.
    func pinBugDied(_ i: Int, _ src: Int) {
        releasePin(i, marines[Int(bugs.hit[i] & 3)], .fire, src)
    }

    /// The pinned marine dashed (tryDash): the Dropper is thrown off.
    func breakPinByDash(_ m: Marine) {
        let p = pinnerSlot(m)
        if p >= 0 { releasePin(p, m, .dash, m.index) } else { m.pinT = 0; m.pinBy = 0 }
    }

    /// The slot of the Dropper pinning `m` (-1 none).
    func pinnerSlot(_ m: Marine) -> Int {
        if m.pinT <= 0 { return -1 }
        let S = bugs, uid = m.pinBy
        var i = 0
        while i < S.count {
            if S.dead[i] == 0 && S.uid[i] == uid && S.st[i] == S_PIN { return i }
            i += 1
        }
        return -1
    }

    /// The pin of Dropper `i` on `m` ends (`cause`; `freer`: whose damage got it off, -1 none). The marine is free (and gets
    /// a drop grace, like after a dash); the Dropper is thrown back off it — a frozen or dying one just drops — and fights on
    /// as a fast deck biter.
    func releasePin(_ i: Int, _ m: Marine, _ cause: PinBreak, _ freer: Int) {
        let S = bugs
        if m.pinBy == S.uid[i] {
            m.pinT = 0; m.pinBy = 0
            m.dropGrace = maxf(m.dropGrace, DROP_GRACE)
        }
        switch cause {
        case .dash: oh.stats.pinDash += 1
        case .fire: oh.stats.pinFire += 1
        case .timeout: oh.stats.pinTimeout += 1
        case .down: oh.stats.pinDown += 1
        case .release: break
        }
        let x = S.x[i], z = S.z[i]
        S.y[i] = 0; S.up[i] = 0; S.re[i] = 0; S.hit[i] = 0; S.rs[i] = 0; S.mt[i] = 0.4
        if S.mood[i] == M_PANIC && S.burn[i] <= 0 { S.mood[i] = M_CALM }
        if S.frz[i] > 0 || S.hp[i] <= 0 {
            S.st[i] = S_MOVE; S.t[i] = 0; S.vx[i] = 0; S.vz[i] = 0
        } else {
            let k: Float = cause == .dash ? 6.5 : 4.5
            S.st[i] = S_LEAP; S.t[i] = LEAP_T; S.vx[i] = S.ax[i] * k; S.vz[i] = S.az[i] * k
            S.cd[i] = BUG_SPECS[Int(T_DROP)].atkCd
        }
        S.ax[i] = 0; S.az[i] = 0
        S.lt[i] = 2.5
        if !simOnly {
            emit(.pinBroken(marine: m.index, pos: Vec2(x, z), cause: cause, freer: freer))
            // «Got it off you» (design radio): a squadmate's fire freed the player
            if cause == .fire && m.isPlayer && freer > 0 && freer < marines.count { toast(GameText.pinFreed(marines[freer].name), .gold) }
        }
    }

    /// When the calibration autopilot (the player's seat) starts reading a Dropper's ring: AUTOPILOT_DROP_REACT spread over
    /// the drops by the bug's uid (deterministic, no random draw) — a person reacts late to some, and gets pinned.
    @inline(__always) func autopilotDropReact(_ uid: Int32) -> Float {
        let h = Float((UInt32(bitPattern: uid) &* 2_654_435_761) >> 8) / Float(1 << 24)
        return AUTOPILOT_DROP_REACT.lowerBound + (AUTOPILOT_DROP_REACT.upperBound - AUTOPILOT_DROP_REACT.lowerBound) * h
    }

    /// A bot aims at a pinning Dropper this long into the pin (a human reaction, like a coil's).
    @inline(__always) func pinSeen(_ b: Int) -> Bool {
        let k = Int(bugs.hit[b] & 3)
        return simTime - marines[k].pinAt >= BOT_REACT
    }

    // ================================================================ PERCHED SPITTERS
    /// The perch a spitter is on or bound for (index into `perchPoints`; -1 none).
    @inline(__always) func perchBound(_ i: Int) -> Int {
        let S = bugs
        if S.type[i] != T_SPIT { return -1 }
        let k = Int(S.rz[i]) - 1
        return k >= 0 && k < oh.perchUid.count && oh.perchUid[k] == S.uid[i] ? k : -1
    }

    /// Free whatever perch `uid` held or was bound for.
    func releasePerch(_ uid: Int32) {
        var k = 0
        while k < oh.perchUid.count {
            if oh.perchUid[k] == uid { oh.perchUid[k] = 0 }
            k += 1
        }
    }

    /// Perched or perch-bound spitters within PERCH_SPACING m of perch point `k` (plan).
    func perchCrowd(_ G: OverheadGraph, _ k: Int) -> Int {
        let p = G.nodePos(G.perches[k])
        var n = 0
        var j = 0
        while j < oh.perchUid.count {
            if j != k && oh.perchUid[j] != 0 {
                let q = G.nodePos(G.perches[j])
                if (q.x - p.x) * (q.x - p.x) + (q.z - p.z) * (q.z - p.z) < PERCH_SPACING * PERCH_SPACING { n += 1 }
            }
            j += 1
        }
        return n
    }

    /// A free perch point with a standing marine 4…PERCH_RANGE − 1 m away and room under the spacing rule; `from`: the bug's
    /// edge position to measure the route distance (nil: the nearest to `c` in plan). -1 none.
    func freePerch(near c: Vec2, from: (e: Int, s: Float)? = nil) -> Int {
        guard let G = level.overhead else { return -1 }
        var best = -1
        var bd: Float = .infinity
        var k = 0
        while k < G.perches.count {
            defer { k += 1 }
            if oh.perchUid[k] != 0 { continue }
            let p = G.nodePos(G.perches[k])
            var near = false
            for m in marines where !m.downed {
                let d2 = (m.x - p.x) * (m.x - p.x) + (m.z - p.z) * (m.z - p.z)
                if d2 > 16 && d2 < (PERCH_RANGE - 1) * (PERCH_RANGE - 1) { near = true }
            }
            if !near || perchCrowd(G, k) >= PERCH_MAX { continue }
            var d: Float
            if let f = from {
                let a = G.ea[f.e], b = G.eb[f.e]
                d = min(oh.perchDist[k][a] + f.s, oh.perchDist[k][b] + (G.length[f.e] - f.s))
            } else {
                d = hypotf2(p.x - c.x, p.z - c.y)
                if d > 24 { continue }
            }
            if d < bd { bd = d; best = k }
        }
        return best
    }

    /// The next edge at `node` on the way to perch point `k` (the shortest route; `exclude` skipped unless it is the only one).
    func nextEdgeToPerch(_ G: OverheadGraph, _ node: Int, _ k: Int, exclude: Int) -> Int {
        var best = -1
        var bd: Float = .infinity
        let adj = G.nodeEdges[node]
        for e in adj where e != exclude || adj.count == 1 {
            let o = G.ea[e] == node ? G.eb[e] : G.ea[e]
            let d = G.length[e] + oh.perchDist[k][o]
            if d < bd { bd = d; best = e }
        }
        return best
    }

    /// The think of a spitter up on the routes (routeThink): bind a free perch and go there; on it, perch. With no perch to
    /// take it hops down soon (a deck spitter). Returns true when it left the high state.
    func perchThink(_ i: Int, _ G: OverheadGraph, _ e: Int, _ s: Float) -> Bool {
        let S = bugs
        var k = perchBound(i)
        if k < 0 {
            k = freePerch(near: squadCenter(), from: (e, s))
            if k >= 0 { oh.perchUid[k] = S.uid[i]; S.rz[i] = Float(k + 1) } else { S.rz[i] = 0 }
        }
        if k < 0 {
            if S.lt[i] > 3 { S.lt[i] = 3 }
            S.ax[i] = s; S.az[i] = 0
            if S.lt[i] <= 0 { return routeHop(i) }
            return false
        }
        let n = G.perches[k]
        let a = G.ea[e], b = G.eb[e], len = G.length[e]
        if a == n || b == n {
            let goal: Float = a == n ? 0 : len
            S.ax[i] = goal; S.az[i] = 0
            if absf(s - goal) <= 0.06 { takePerch(i, k, G); return true }
        } else {
            let da = oh.perchDist[k][a] + s, db = oh.perchDist[k][b] + (len - s)
            if !da.isFinite && !db.isFinite { releasePerch(S.uid[i]); S.rz[i] = 0; return false }
            S.ax[i] = da <= db ? 0 : len; S.az[i] = 1
        }
        if S.lt[i] <= 0 { releasePerch(S.uid[i]); return routeHop(i) }
        return false
    }

    /// On perch point `k`: still, against the void, a beat before the first spit.
    func takePerch(_ i: Int, _ k: Int, _ G: OverheadGraph) {
        let S = bugs
        let p = G.nodePos(G.perches[k])
        S.st[i] = S_PERCH; S.t[i] = 0; S.cd[i] = maxf(S.cd[i], 0.6); S.lt[i] = PERCH_LEAVE
        S.x[i] = p.x; S.z[i] = p.z; S.y[i] = p.y; S.vx[i] = 0; S.vz[i] = 0
        oh.stats.perched += 1
        if !simOnly {
            emit(.perched(pos: p))
            if !oh.tipPerch && !attract { oh.tipPerch = true; toast(GameText.perchTip, .warn) }
        }
    }

    /// Off the perch (no marine in range for PERCH_LEAVE s): back on the routes for another perch, or down.
    func leavePerch(_ i: Int) {
        let S = bugs
        releasePerch(S.uid[i])
        S.st[i] = S_HIGH; S.rz[i] = 0; S.t[i] = 0; S.lt[i] = ROUTE_PATIENCE
    }

    /// A perched spitter (routeTick hands S_PERCH here): it holds the perch, turns to the nearest standing marine within
    /// PERCH_RANGE (not right under it) and spits — PERCH_WIND s of wind-up behind the lime ring and fill, then a glob of
    /// PERCH_GLOB s flight from the perch.
    func perchTick(_ i: Int, _ G: OverheadGraph, _ dt: Float) {
        let S = bugs
        let k = perchBound(i)
        if k < 0 { leavePerch(i); return }
        let p = G.nodePos(G.perches[k])
        S.x[i] = p.x; S.z[i] = p.z; S.y[i] = p.y; S.vx[i] = 0; S.vz[i] = 0
        S.ph[i] += dt * 0.6
        if S.cd[i] > 0 { S.cd[i] -= dt }
        if S.t[i] > 0 {
            S.t[i] -= dt
            S.hd[i] += angDiff(S.hd[i], atan2f2(S.ax[i] - p.x, S.az[i] - p.z)) * minf(1, 10 * dt)
            if S.t[i] <= 0 { launchPerchGlob(i); S.cd[i] = 2.8 + rng.next() * 1.6 }
            return
        }
        var best = -1
        var bd = PERCH_RANGE * PERCH_RANGE
        var j = 0
        while j < 4 {
            let m = marines[j]
            if !m.downed {
                let dx = m.x - p.x, dz = m.z - p.z, d2 = dx * dx + dz * dz
                if d2 < bd && d2 > 3.2 * 3.2 { bd = d2; best = j }
            }
            j += 1
        }
        if best < 0 {
            S.lt[i] -= dt
            if S.lt[i] <= 0 { leavePerch(i) }
            return
        }
        S.lt[i] = PERCH_LEAVE
        let m = marines[best]
        S.hd[i] += angDiff(S.hd[i], atan2f2(m.x - p.x, m.z - p.z)) * minf(1, 8 * dt)
        if S.cd[i] <= 0 {
            let ax = m.x + m.vx * 0.8 + (rng.next() - 0.5) * 1.2
            let az = m.z + m.vz * 0.8 + (rng.next() - 0.5) * 1.2
            S.t[i] = PERCH_WIND; S.ax[i] = ax; S.az[i] = az
            teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, PERCH_WIND + PERCH_GLOB, cause: .acidTarget)
            teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, PERCH_WIND + PERCH_GLOB, cause: .acidTarget)
        }
    }

    /// A glob from a perch: PERCH_GLOB s of flight onto (ax, az); it lands like any spitter's (updateGlobs).
    func launchPerchGlob(_ i: Int) {
        let S = bugs, G = globs
        if G.count >= AcidGlobs.capacity { return }
        let k = G.count
        G.count += 1
        let x0 = S.x[i], z0 = S.z[i]
        G.x0[k] = x0; G.z0[k] = z0; G.x1[k] = S.ax[i]; G.z1[k] = S.az[i]; G.t[k] = 0; G.dur[k] = PERCH_GLOB
        G.h0[k] = maxf(0, S.y[i] - level.groundY(S.ax[i], S.az[i]) - 0.6)
        oh.stats.perchSpits += 1
        if !simOnly {
            emit(.acidFromPerch(from: SIMD3<Float>(x0, S.y[i], z0), to: Vec2(S.ax[i], S.az[i]), flight: PERCH_GLOB))
            sound(.spit, x0, z0)
        }
    }

    // ================================================================ DUCT MOUTHS
    /// The duct index of route node `n` (-1: not a duct mouth).
    @inline(__always) func ductIndex(_ n: Int) -> Int { n >= 0 && n < oh.ductOf.count ? oh.ductOf[n] : -1 }
    /// Route node `n` takes bugs: not a duct mouth shot shut.
    @inline(__always) func ductOpen(node n: Int) -> Bool {
        let d = ductIndex(n)
        return d < 0 || oh.ducts[d].open
    }

    /// A pack bound for duct `d` is `(1 − acc) / rate` s from its first bug: the grille starts rattling DUCT_RATTLE s before
    /// (a pack queued while it rattles shares that rattle). Returns true once the pack has its rattle.
    func ductRattleCheck(_ d: Int, _ acc: Float, _ rate: Float) -> Bool {
        if oh.ducts[d].rattleT > 0 { return true }
        if rate <= 0 { return false }
        let left = (1 - acc) / rate
        if left > DUCT_RATTLE + 1e-3 { return false }
        oh.ducts[d].rattleT = maxf(0.05, left)
        oh.stats.rattles += 1
        if !simOnly {
            emit(.ductRattle(index: d))
            if !oh.tipDuct && !attract { oh.tipDuct = true; toast(GameText.ductTip, .warn) }
        }
        return true
    }

    /// The ducts' clocks: a shut grille opens again after DUCT_SHUT s (the hive chews through), rattles run down.
    func ductTick(_ dt: Float) {
        var d = 0
        while d < oh.ducts.count {
            if oh.ducts[d].shutT > 0 {
                oh.ducts[d].shutT -= dt
                if oh.ducts[d].shutT <= 0 {
                    oh.ducts[d].shutT = 0; oh.ducts[d].hp = DUCT_HP
                    emit(.ductOpened(index: d))
                }
            }
            if oh.ducts[d].rattleT > 0 { oh.ducts[d].rattleT = maxf(0, oh.ducts[d].rattleT - dt) }
            oh.ducts[d].pourAge = minf(99, oh.ducts[d].pourAge + dt)
            oh.ducts[d].hitAge = minf(99, oh.ducts[d].hitAge + dt)
            d += 1
        }
    }

    /// Damage on duct `d`'s grille (a round, the torch, the beam, a blast): at 0 it slams shut for DUCT_SHUT s.
    func hurtDuct(_ d: Int, _ dmg: Float, _ src: Int, at: Vec2? = nil) {
        guard d >= 0 && d < oh.ducts.count && oh.ducts[d].open && dmg > 0 else { return }
        let fresh = oh.ducts[d].hitAge >= 0.08
        oh.ducts[d].hp -= dmg
        oh.ducts[d].hitAge = 0
        if oh.ducts[d].hp > 0 {
            if fresh && !simOnly { emit(.ductHit(index: d)) }
            return
        }
        oh.ducts[d].hp = 0; oh.ducts[d].shutT = DUCT_SHUT; oh.ducts[d].rattleT = 0
        oh.stats.seals += 1
        if !simOnly {
            emit(.ductSealed(index: d))
            let p = oh.ducts[d].pos
            sound(.thud, p.x, p.z)
        }
    }

    /// A round aimed up meets an open duct mouth's grille (within DUCT_R of the mouth in plan) nearer than `maxT`.
    func ductSegmentHit(_ sx: Float, _ sz: Float, _ dx: Float, _ dz: Float, _ maxT: Float) -> (Int, Float) {
        var best = -1
        var bt = maxT
        var d = 0
        while d < oh.ducts.count {
            defer { d += 1 }
            if !oh.ducts[d].open { continue }
            let p = oh.ducts[d].pos
            let bx = p.x - sx, bz = p.z - sz, t = bx * dx + bz * dz
            if t < -0.3 || t > bt { continue }
            let px = bx - dx * t, pz = bz - dz * t
            if px * px + pz * pz < DUCT_R * DUCT_R { bt = maxf(0, t); best = d }
        }
        return (best, bt)
    }

    /// The torch reaches a duct mouth within its range and cone (in plan).
    func ductFlame(_ m: Marine, _ ox: Float, _ oz: Float, _ range: Float, _ cosC: Float, _ dps: Float, _ dt: Float) -> Bool {
        var any = false
        var d = 0
        while d < oh.ducts.count {
            defer { d += 1 }
            if !oh.ducts[d].open { continue }
            let p = oh.ducts[d].pos
            let dx = p.x - ox, dz = p.z - oz, dl = (dx * dx + dz * dz).squareRoot() + 1e-4
            if dl > range + DUCT_R { continue }
            if dl > 0.9 && (dx * m.ax + dz * m.az) / dl < cosC { continue }
            any = true
            hurtDuct(d, dps * dt * (1 - 0.35 * minf(1, dl / range)), m.index)
        }
        return any
    }

    /// The cryo beam along a duct mouth (in plan) wears its grille down.
    func ductBeam(_ m: Marine, _ ox: Float, _ oz: Float, _ len: Float, _ dps: Float, _ dt: Float) -> Bool {
        var any = false
        var d = 0
        while d < oh.ducts.count {
            defer { d += 1 }
            if !oh.ducts[d].open { continue }
            let p = oh.ducts[d].pos
            let dx = p.x - ox, dz = p.z - oz, t = dx * m.ax + dz * m.az
            if t < -0.3 || t > len { continue }
            let perp = absf(dx * m.az - dz * m.ax), w = 0.42 + t / len * 0.75
            if perp > w + DUCT_R { continue }
            any = true
            hurtDuct(d, dps * dt, m.index)
        }
        return any
    }

    /// The squad's blasts reach a duct mouth at BLAST_UP × their radius.
    func ductBlast(_ e: Boom) {
        let R = e.r * BLAST_UP
        var d = 0
        while d < oh.ducts.count {
            defer { d += 1 }
            if !oh.ducts[d].open { continue }
            let p = oh.ducts[d].pos
            let dl = hypotf2(p.x - e.x, p.z - e.z)
            if dl >= R + DUCT_R { continue }
            hurtDuct(d, e.dmg * (1 - 0.55 * minf(1, dl / max(R, 0.01))), e.src)
        }
    }

    /// The calibration autopilot (the player on autopilot; never a squad bot — design §1.4) shoots a rattling or pouring duct
    /// mouth in its weapon's reach when no bug is in its face: the mouth's position, else nil.
    func autopilotDuct(_ m: Marine, deck: Float) -> SIMD3<Float>? {
        if deck < 4.5 { return nil }
        let reach: Float = (m.cls == .pyro || m.cls == .cryo) ? m.spec.range * m.mods.range : 18
        var best: SIMD3<Float>? = nil
        var bd = reach * reach
        for d in oh.ducts where d.open && (d.rattleT > 0 || d.pourAge < 1.5) {
            let dx = d.pos.x - m.x, dz = d.pos.z - m.z, d2 = dx * dx + dz * dz
            if d2 < bd { bd = d2; best = d.pos }
        }
        return best
    }

    /// Aim assist for duct mouths: the open mouth inside the cone around where the player SEES it (≈ 0.75 h up-screen of its
    /// plan position, like a bug up there), better aligned than the bug the assist picked (cosine `bugCos`, -2 none).
    func ductAssist(_ m: Marine, _ dx: Float, _ dz: Float, bugCos: Float) -> Vec2? {
        var best: Vec2? = nil
        var bc = max(0.92, bugCos + 0.01)
        for d in oh.ducts where d.open {
            let p = d.pos
            let lift = 0.75 * maxf(0, p.y - level.groundY(p.x, p.z))
            let vx = p.x + FWD_X * lift - m.x, vz = p.z + FWD_Z * lift - m.z, dl = hypotf2(vx, vz)
            if dl < 0.6 || dl > 17 { continue }
            let cs = (vx * dx + vz * dz) / dl
            if cs > bc && isVisible(p.x, p.z) { bc = cs; best = Vec2(p.x, p.z) }
        }
        return best
    }

    // ================================================================ debug / demo / tests
    /// Damage duct mouth `k`'s grille (as a round from marine `src` would). Returns whether it is shut now.
    @discardableResult
    public func debugHurtDuct(_ k: Int, _ dmg: Float, src: Int = 0) -> Bool {
        hurtDuct(k, dmg, src)
        return k >= 0 && k < oh.ducts.count && !oh.ducts[k].open
    }

    /// A Dropper on the deck beside marine `k` that pins it at once (demos and tests of the pin's breaks). Returns its slot.
    @discardableResult
    public func debugPinMarine(_ k: Int) -> Int {
        guard k >= 0 && k < marines.count, !marines[k].downed, marines[k].pinT <= 0 else { return -1 }
        let m = marines[k]
        let i = spawnBug(T_DROP, m.x + FWD_X * PIN_REACH, m.z + FWD_Z * PIN_REACH, mode: 0)
        if i < 0 { return -1 }
        typeAlive[Int(T_DROP)] += 1
        pinMarine(i, m, -FWD_X, -FWD_Z)
        return i
    }

    /// Demo / tests: every route bug goes for marine `k` while it stands (-1: the usual rule — the favourite, uid % 4,
    /// unless another is much closer).
    public var debugRouteFocus: Int {
        get { oh.focus }
        set { oh.focus = newValue }
    }

    /// The uid of the bug pinning marine `k` (0 none).
    public func pinnedBy(_ k: Int) -> Int32 { k >= 0 && k < marines.count && marines[k].pinT > 0 ? marines[k].pinBy : 0 }
}
