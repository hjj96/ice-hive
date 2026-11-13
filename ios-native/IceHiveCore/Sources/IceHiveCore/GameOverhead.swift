import Foundation

// ================================================================
//  THE OVERHEAD AT RUN TIME (Stage 1 R2 «Overhead core»; design.md §1.1,
//  tech.md §2.3) — bugs up on the routes of `Level.overhead`:
//   · states high / riser / coil / drop / fall (BugState 6…10; absolute
//     heights), filed under the spatial hash's sentinel bucket while up, so
//     every deck query ignores them (Spatial.swift);
//   · they ride ON TOP of the routes toward their marine (the favourite,
//     uid % 4, unless another is much closer) and wait above it;
//   · the drop: a fixed landing point, the `.dropZone` telegraph for
//     `dropWarn` s (the coil, then DROP_T of flight), the runner's bite ×
//     `dropK` on a marine still inside the ring. Fairness (design §1.1.6):
//     at most `dropCap` telegraphs at once and `dropGap` s apart, ≤ 2 per
//     marine in 3 s, 2 s of grace after a dash or a revive, none while the
//     wave director holds a lull, none onto a no-drop circle (R6's lit deck);
//   · counterplay — «bullets kill them up there; fire, frost and blasts bring
//     them down»: footprint hits (radius × 1.3), the torch sets them alight
//     (they let go after 0.8 s), frost freezes them (they fall and shatter),
//     blasts reach up at 0.6 r and knock them down;
//   · the director's overhead channel (a share of the packs, the third flank
//     of a travel peak, the rain at a beacon's 62 % push, the hold's share,
//     anti-camping) under the tier's caps — never the graphics tier's;
//   · the bots step out of drop rings and shoot coiling bugs first.
//  Nothing here runs, or draws a random number, unless the station has
//  routes AND the tier sends packs up (`routes` > 0) or a debug pack asks:
//  the classic mission replays byte for byte.
// ================================================================
// (loops over the sentinel bucket are `while` loops: `for … in` is slow in unoptimised builds)
extension Game {

    // ---------- the channel ----------
    /// The director's overhead channel is open: the station has spawn entries, the tier sends packs up, wave pacing.
    var overheadOn: Bool {
        difficulty.routes > 0 && difficulty.waves && !attract && (level.overhead.map { !$0.entries.isEmpty } ?? false)
    }

    /// The wave director holds a lull: no drop telegraph starts (design §1.1.6 — the lull stays a lull: bugs up there
    /// creep and wait; the build-up and the peaks bring the drops). Travel = the mission plan's posture between objectives.
    var overheadQuiet: Bool {
        guard directorEnabled && difficulty.waves && !attract else { return false }
        if lullT > 0 { return true }
        return beat == 0 && posture == .travel
    }

    /// The lift is leaving: whatever is up leaps off into the void.
    var overheadExtracting: Bool { stage == .extract }

    /// Bugs up on the overhead now (the sentinel bucket of the last rebuild + the ones spawned since).
    public var routeAlive: Int { hash.overheadCount - bossPartsUp + oh.tickSpawns }
    /// The drop telegraphs (slots; `active` ones are live).
    public var dropZones: [DropZone] { oh.zones }
    /// Live drop telegraphs.
    public var activeDropZones: Int {
        var n = 0
        for z in oh.zones where z.active { n += 1 }
        return n
    }
    public var overheadStats: OverheadStats { oh.stats }
    /// Bugs per overhead state: high, riser, coil, drop, fall; Stage 1 R4: pin, perch (debug logs).
    public var overheadStateCounts: [Int] {
        var c = [0, 0, 0, 0, 0, 0, 0]
        let S = bugs
        for i in 0..<S.count where S.dead[i] == 0 && S.st[i] >= S_HIGH && S.st[i] <= S_PERCH { c[Int(S.st[i] - S_HIGH)] += 1 }
        return c
    }

    @inline(__always) func routeEnc(_ e: Int, _ fwd: Bool) -> Int16 { Int16(truncatingIfNeeded: fwd ? e + 1 : -(e + 1)) }
    @inline(__always) func routeDec(_ v: Int16) -> (e: Int, fwd: Bool) { v > 0 ? (Int(v) - 1, true) : (Int(-Int32(v)) - 1, false) }

    // ---------- spawning ----------
    /// A route bug at entry node `n`: up the riser (abyss column, deck post, mast) from its foot, or straight onto the
    /// route out of a duct mouth, on the edge that leads toward the squad. The director sends runners («cable runners»;
    /// the Dropper and the perched spitter are package R4's `type`s). Returns its slot, -1 when the arrays are full.
    @discardableResult
    func spawnRouteBug(entry n: Int, type: UInt8 = T_RUN) -> Int {
        guard let G = level.overhead, n >= 0 && n < G.nodeCount, !G.nodeEdges[n].isEmpty else { return -1 }
        let node = G.layout.nodes[n]
        let c = squadCenter()
        let e = G.bestEdge(at: n, c.x, c.y)
        // (Stage 2 B4: an entry whose routes were all pulled down takes nobody)
        if e < 0 { return -1 }
        let i = spawnBug(type, node.p.x, node.p.z, mode: 0)
        if i < 0 { return -1 }
        let S = bugs
        let fwd = G.ea[e] == n
        S.re[i] = routeEnc(e, fwd); S.rs[i] = fwd ? 0 : G.length[e]
        S.up[i] = 1; S.vx[i] = 0; S.vz[i] = 0; S.t[i] = 0; S.mood[i] = M_CALM; S.mt[i] = 0; S.hit[i] = 0
        // (Stage 1 R4: a Dropper waits longer for its drop; a spitter goes for a perch — none bound yet)
        S.lt[i] = type == T_DROP ? DROPPER_PATIENCE : ROUTE_PATIENCE; S.rz[i] = 0
        if type == T_DROP { typeAlive[Int(T_DROP)] += 1; oh.stats.droppers += 1 }
        if node.kind.climbs { S.st[i] = S_RISER; S.y[i] = node.riserFrom } else { S.st[i] = S_HIGH; S.y[i] = node.p.y }
        S.ax[i] = S.rs[i]; S.az[i] = 0
        let q = G.point(e, fwd ? minf(0.5, G.length[e]) : maxf(0, G.length[e] - 0.5))
        S.hd[i] = atan2f2(q.x - node.p.x, q.z - node.p.z)
        oh.tickSpawns += 1; oh.stats.spawns += 1
        return i
    }

    /// Bugs still queued for the overhead.
    var queuedRouteBugs: Int {
        var n = 0
        for b in oh.queue { n += b.n }
        return n
    }

    /// Queue `n` runners up entry node `entry` at `rate` per second (the overhead's own queue: it pours with or without the
    /// director). The tier's route cap holds: returns how many were queued.
    @discardableResult
    func queueRoutePack(_ n: Int, entry: Int, rate: Float, delay: Float = 0, type: UInt8 = T_RUN) -> Int {
        var k = min(n, difficulty.routeCap - routeAlive - queuedRouteBugs)
        // Stage 1 R4: the tier's live Dropper cap (4 / 5 / 6)
        if type == T_DROP { k = min(k, difficulty.dropperCap - typeAlive[Int(T_DROP)] - queuedRouteBugs(of: T_DROP)) }
        if k <= 0 { return 0 }
        // Stage 1 R4: a duct mouth that is shot shut takes nothing; an open one rattles DUCT_RATTLE s before the pack pours
        var wait = delay
        let d = ductIndex(entry)
        if d >= 0 {
            if !oh.ducts[d].open { return 0 }
            wait = max(wait, DUCT_RATTLE)
        }
        oh.queue.append(RouteBurst(entry: entry, n: k, rate: rate, acc: -rate * wait, type: type))
        oh.stats.packs += 1
        return k
    }

    func processRouteQueue(_ dt: Float) {
        var q = 0
        while q < oh.queue.count {
            // Stage 1 R4: the packs bound for a duct mouth that was shot shut are lost; an open one rattles before the pour
            let d = ductIndex(oh.queue[q].entry)
            if d >= 0 && !oh.ducts[d].open {
                oh.stats.ductLost += oh.queue[q].n
                oh.queue.remove(at: q)
                continue
            }
            oh.queue[q].acc += oh.queue[q].rate * dt
            if d >= 0 && !oh.queue[q].rattled && ductRattleCheck(d, oh.queue[q].acc, oh.queue[q].rate) { oh.queue[q].rattled = true }
            while oh.queue[q].acc >= 1 && oh.queue[q].n > 0 {
                oh.queue[q].acc -= 1; oh.queue[q].n -= 1
                if capLeft() <= 0 || routeAlive >= difficulty.routeCap { continue }
                if spawnRouteBug(entry: oh.queue[q].entry, type: oh.queue[q].type) >= 0 && d >= 0 { oh.ducts[d].pourAge = 0 }
            }
            if oh.queue[q].n <= 0 { oh.queue.remove(at: q) } else { q += 1 }
        }
    }

    /// A spawn entry 8–20 m from `c` whose routes pass within 10 m of it (design §1.1.6), else 5–28 m / 14 m; one random
    /// draw per candidate (a reservoir pick). -1 = none.
    func routeEntry(near c: Vec2) -> Int {
        guard let G = level.overhead, !G.entries.isEmpty else { return -1 }
        let bands: [(Float, Float, Float)] = [(8, 20, 10), (5, 28, 14)]
        for (d0, d1, pass) in bands {
            var pick = -1, seen = 0
            for n in G.entries {
                // (Stage 1 R4: a duct mouth shot shut is no way in; Stage 2 B4: nor an entry whose routes were all pulled down)
                if !ductOpen(node: n) { continue }
                if G.anyBlocked && !G.nodeEdges[n].contains(where: { !G.isBlocked($0) }) { continue }
                let p = G.nodePos(n)
                let d = hypotf2(p.x - c.x, p.z - c.y)
                if d < d0 || d > d1 { continue }
                if G.componentDistance(G.component(ofNode: n), c.x, c.y) > pass { continue }
                seen += 1
                if rng.next() * Float(seen) < 1 { pick = n }
            }
            if pick >= 0 { return pick }
        }
        return -1
    }

    // ---------- the director's hooks (GameWaves) ----------
    /// The overhead's share of a pack: with chance `routes` the pack climbs an entry near `c` instead. Returns how many
    /// went up (0, without a random draw, while the channel is closed).
    func overheadPackShare(_ n: Int, near c: Vec2, rate: Float, delay: Float) -> Int {
        guard n > 0 && overheadOn else { return 0 }
        if rng.next() >= difficulty.routes { return 0 }
        let e = routeEntry(near: c)
        if e < 0 { return 0 }
        return queueRoutePack(n, entry: e, rate: minf(rate, 3), delay: delay)
    }

    /// `share` of a surge sent overhead with `chance` (the third flank of a travel peak 35 %, the rain of a beacon's 62 %
    /// push 50 %, the hold's 15 % of every horde). Returns how many went up (0 without a draw while the channel is closed).
    func overheadSurgeShare(_ n: Int, near c: Vec2, chance: Float, share: Float) -> Int {
        guard n > 0 && overheadOn else { return 0 }
        if chance < 1 && rng.next() >= chance { return 0 }
        let k = Int((Float(n) * share).rounded())
        if k <= 0 { return 0 }
        let e = routeEntry(near: c)
        if e < 0 { return 0 }
        return queueRoutePack(k, entry: e, rate: 3)
    }

    /// Once per tick after the swarm (Game.tick, stations with routes): the telegraphs' clocks, the anti-camping clock,
    /// the route queue, the stats.
    func overheadTick(_ dt: Float) {
        oh.tickSpawns = 0
        var zn = 0
        for k in oh.zones.indices where oh.zones[k].active {
            oh.zones[k].t -= dt
            if oh.zones[k].t < -0.5 { oh.zones[k].active = false } else { zn += 1 }
        }
        if zn > oh.stats.maxZones { oh.stats.maxZones = zn }
        let upNow = hash.overheadCount - bossPartsUp
        if upNow > oh.stats.maxUp { oh.stats.maxUp = upNow }
        if overheadOn && directorEnabled && !calm { campTick(dt); channelTick(dt) }
        // Stage 1 R4: the duct mouths' clocks (shut → the hive chews through, rattles, pours)
        if !oh.ducts.isEmpty { ductTick(dt) }
        processRouteQueue(dt)
    }

    /// Anti-camping (design §1.1.6): a squad within 6 m of one spot for 25 s outside an objective draws a pair overhead
    /// («They're in the racks above us»; runners until package R4's Dropper).
    func campTick(_ dt: Float) {
        let c = squadCenter()
        // (outside an objective: the plan's travel posture — not a ring, a hold, a boss fight or the ride)
        let objective = posture != .travel
        let dx = c.x - oh.campX, dz = c.y - oh.campZ
        if objective || dx * dx + dz * dz > 36 { oh.campX = c.x; oh.campZ = c.y; oh.campT = 0; return }
        oh.campT += dt
        if oh.campT >= 25 {
            oh.campT = 0
            let e = routeEntry(near: c)
            // (Stage 1 R4: Droppers when the tier's Dropper channel is on — design §1.1.6 «draws 2 Droppers overhead»)
            if e >= 0 { queueRoutePack(2, entry: e, rate: 2, type: difficulty.dropperGap > 0 ? T_DROP : T_RUN) }
        }
    }

    // ---------- the per-tick update of a bug up there (simBugs hands every bug with state ≥ high here) ----------
    func routeTick(_ i: Int, _ dt: Float) {
        let S = bugs
        // Stage 1 R4: a Dropper's pin is down on the deck (its own rules: GameOverheadBugs.pinTick)
        if S.st[i] == S_PIN { pinTick(i, dt); return }
        guard let G = level.overhead else { settleOnDeck(i, S.x[i], S.z[i], vx: 0, vz: 0); return }
        // the extraction: whatever is up leaps off into the void and is gone (like the bugs falling with the lift)
        if overheadExtracting && S.st[i] != S_FALL { knockDown(i, src: -2) }
        let st0 = S.st[i]
        // burning: no spread up here (the sentinel bucket has no neighbours); it loses its grip after GRIP_T s and falls
        if S.burn[i] > 0 {
            S.burn[i] -= dt
            let src = Int(S.bsrc[i])
            if hitBug(i, CLASS_SPECS[1].burnDps * pyroBurnMul(src) * dt, src, true) { return }
            if st0 != S_FALL && st0 != S_DROP {
                if S.mood[i] != M_PANIC { S.mood[i] = M_PANIC; S.mt[i] = GRIP_T }
                else {
                    S.mt[i] -= dt
                    if S.mt[i] <= 0 { knockDown(i, src: src) }
                }
            }
        }
        if S.frz[i] > 0 {
            S.frz[i] -= dt
            if S.frz[i] <= 0 { S.chill[i] = 0.5 }
            // (the weapon that froze it knocked it down already, with its owner; this is the safety net)
            if S.st[i] != S_FALL { knockDown(i, src: -1) }
        } else if S.chill[i] > 0 {
            S.chill[i] = maxf(0, S.chill[i] - dt * 0.4)
        }
        switch S.st[i] {
        case S_RISER: riserTick(i, G, dt)
        case S_HIGH: highTick(i, G, dt)
        case S_COIL: coilTick(i, dt)
        case S_DROP: dropTick(i, dt)
        case S_PERCH: perchTick(i, G, dt)
        default: fallTick(i, dt)
        }
    }

    /// Climbing a riser up to its route (nose up, ≈ 2.4 m/s like a bug scaling a deck edge), then onto the route.
    func riserTick(_ i: Int, _ G: OverheadGraph, _ dt: Float) {
        let S = bugs
        let (e, fwd) = routeDec(S.re[i])
        let top = G.nodePos(fwd ? G.ea[e] : G.eb[e]).y
        S.y[i] += dt * (2.4 + S.vr[i]); S.ph[i] += dt * 14
        if S.y[i] >= top { S.y[i] = top; S.st[i] = S_HIGH; S.t[i] = 0 }
    }

    /// On a route: think every 0.1 s (its marine, where to wait, a drop, a hop down), move along the graph toward the goal.
    func highTick(_ i: Int, _ G: OverheadGraph, _ dt: Float) {
        let S = bugs
        S.t[i] -= dt; S.lt[i] -= dt
        if S.cd[i] > 0 { S.cd[i] -= dt }
        if S.t[i] <= 0 {
            S.t[i] = 0.1
            let (e, _) = routeDec(S.re[i])
            if routeThink(i, G, e, S.rs[i]) { return }
        }
        var (e, fwd) = routeDec(S.re[i])
        var s = S.rs[i]
        // AX: the goal along this edge; AZ ≠ 0: go on through that end node
        var remaining = S.spd[i] * routeSpeedK(i, G.kind(e)) * (1 - 0.6 * S.chill[i]) * dt
        var moved: Float = 0
        var guardN = 3
        while remaining > 1e-5 && guardN > 0 {
            guardN -= 1
            let len = G.length[e]
            let goal = clampf(S.ax[i], 0, len)
            let ds = goal - s
            if absf(ds) <= 1e-4 {
                if S.az[i] == 0 { break }   // waiting at the goal
                // at the end node: on along the edge that leads toward its marine (not back the way it came)
                let node = goal >= len * 0.5 ? G.eb[e] : G.ea[e]
                // (Stage 1 R4: a spitter bound for a perch takes the edge on its way there)
                let pk = perchBound(i)
                let m = marines[Int(S.hit[i] & 3)]
                let ne = pk >= 0 ? nextEdgeToPerch(G, node, pk, exclude: e) : G.bestEdge(at: node, m.x, m.z, exclude: e)
                if ne < 0 || ne == e { S.az[i] = 0; break }   // a dead end: wait there
                e = ne; fwd = G.ea[ne] == node; s = fwd ? 0 : G.length[ne]
                S.ax[i] = fwd ? G.length[ne] : 0; S.az[i] = 0
                continue
            }
            fwd = ds > 0
            let st = minf(remaining, absf(ds))
            s += fwd ? st : -st
            remaining -= st
            moved += st
        }
        S.re[i] = routeEnc(e, fwd); S.rs[i] = s
        let p = G.point(e, s)
        S.x[i] = p.x; S.z[i] = p.z; S.y[i] = p.y
        // heading along the travel direction, turned smoothly (the renderer lays the bug along the route)
        let A = G.nodePos(G.ea[e]), B = G.nodePos(G.eb[e])
        var hx = B.x - A.x, hz = B.z - A.z
        if !fwd { hx = -hx; hz = -hz }
        let hl = hypotf2(hx, hz)
        if moved > 0 && hl > 1e-4 { S.hd[i] += angDiff(S.hd[i], atan2f2(hx, hz)) * minf(1, 10 * dt) }
        let v = hl > 1e-4 ? moved / dt / hl : 0
        S.vx[i] = hx * v; S.vz[i] = hz * v
        S.ph[i] += moved * 8 / S.sc[i]
    }

    /// The think of a route bug: its marine, where on the route to wait for it, a drop, or a hop down when it found no
    /// drop for ROUTE_PATIENCE s. Returns true when the bug left the high state.
    func routeThink(_ i: Int, _ G: OverheadGraph, _ e: Int, _ s: Float) -> Bool {
        let S = bugs
        // Stage 1 R4: a spitter up here goes for a perch point (and spits from it) instead of dropping
        if S.type[i] == T_SPIT { return perchThink(i, G, e, s) }
        let k = routeTarget(i)
        if k < 0 { S.ax[i] = s; S.az[i] = 0; return false }   // nobody standing: wait
        S.hit[i] = UInt8(k)
        let m = marines[k]
        let len = G.length[e]
        let ps = G.project(e, m.x, m.z).s
        if ps > 0.05 && ps < len - 0.05 { S.ax[i] = ps; S.az[i] = 0 }
        else {
            let atB = ps >= len - 0.05
            let best = G.bestEdge(at: atB ? G.eb[e] : G.ea[e], m.x, m.z)
            S.ax[i] = atB ? len : 0
            S.az[i] = best >= 0 && best != e ? 1 : 0
        }
        if tryDrop(i, G, e, s, k) { return true }
        if S.lt[i] <= 0 { return routeHop(i) }
        return false
    }

    /// The marine a route bug goes for: the nearest standing one, or its favourite (uid % 4) unless another is 7 m or more
    /// closer (the wave pacing's rule on the deck). -1 when nobody stands.
    func routeTarget(_ i: Int) -> Int {
        let S = bugs
        // (Stage 1 R4: a demo / test focus)
        if oh.focus >= 0 && oh.focus < marines.count && !marines[oh.focus].downed { return oh.focus }
        var best = -1
        var bd: Float = .infinity
        var k = 0
        while k < 4 {
            let m = marines[k]
            if !m.downed {
                let dx = m.x - S.x[i], dz = m.z - S.z[i], d2 = dx * dx + dz * dz
                if d2 < bd { bd = d2; best = k }
            }
            k += 1
        }
        if best < 0 { return -1 }
        let pk = Int(S.uid[i] & 3)
        if pk != best && !marines[pk].downed {
            let dx = marines[pk].x - S.x[i], dz = marines[pk].z - S.z[i]
            let lim = bd.squareRoot() + 7
            if dx * dx + dz * dz < lim * lim { best = pk }
        }
        return best
    }

    /// A deck point a drop may land on: a marine fits there, no stairs, no no-drop circle (package R6's lit deck).
    func dropSpotOK(_ x: Float, _ z: Float) -> Bool {
        if !level.canStand(x, z) { return false }
        if level.isStairCell(level.cellOf(x, z)) { return false }
        for c in oh.noDrop where (x - c.x) * (x - c.x) + (z - c.y) * (z - c.y) < c.z * c.z { return false }
        return true
    }

    /// Commit to a drop on marine `k` when every rule allows it: inside the edge's drop window, the marine DROP_MIN…
    /// DROP_MAX m away in plan, the landing spot fit, the fairness rules. The landing point is fixed now (it does not home).
    func tryDrop(_ i: Int, _ G: OverheadGraph, _ e: Int, _ s: Float, _ k: Int) -> Bool {
        let D = difficulty
        if s < G.w0[e] || s > G.w1[e] { return false }
        if overheadExtracting || overheadQuiet { return false }
        if simTime - oh.lastDrop < D.dropGap { return false }
        var slot = -1, active = 0
        for z in oh.zones.indices {
            if oh.zones[z].active { active += 1 } else if slot < 0 { slot = z }
        }
        if active >= D.dropCap || slot < 0 { return false }
        let m = marines[k]
        if m.downed || m.dropGrace > 0 { return false }
        // (Stage 1 R4: a Dropper never goes for a marine another one holds already)
        if m.pinT > 0 && bugs.type[i] == T_DROP { return false }
        var recent = 0
        if simTime - m.dropT0 < DROP_WINDOW { recent += 1 }
        if simTime - m.dropT1 < DROP_WINDOW { recent += 1 }
        if recent >= DROP_PER_MARINE { return false }
        let S = bugs
        let bx = S.x[i], bz = S.z[i]
        let d = hypotf2(m.x - bx, m.z - bz)
        if d < DROP_MIN || d > DROP_MAX { return false }
        // where the marine is heading (≤ 2.5 m ahead of it), else where it stands
        let lead = 0.35 * D.dropWarn
        var lx = m.x + m.vx * lead, lz = m.z + m.vz * lead
        let ll = hypotf2(lx - m.x, lz - m.z)
        if ll > 2.5 { lx = m.x + (lx - m.x) * 2.5 / ll; lz = m.z + (lz - m.z) * 2.5 / ll }
        if hypotf2(lx - bx, lz - bz) > DROP_MAX + 1 || !dropSpotOK(lx, lz) {
            lx = m.x; lz = m.z
            if !dropSpotOK(lx, lz) { return false }
        }
        let warn = D.dropWarn
        S.st[i] = S_COIL; S.t[i] = warn - DROP_T; S.ax[i] = lx; S.az[i] = lz
        S.hit[i] = UInt8(k) | UInt8(slot << 4)
        S.vx[i] = 0; S.vz[i] = 0; S.lt[i] = ROUTE_PATIENCE
        var zn = DropZone()
        zn.active = true; zn.x = lx; zn.z = lz; zn.r = DROP_RING; zn.t = warn; zn.warn = warn; zn.uid = S.uid[i]; zn.marine = k
        zn.from = SIMD3<Float>(bx, S.y[i], bz)
        zn.dropper = S.type[i] == T_DROP
        // the closing ring, pink-white like the hive's pores (the lexicon's «lands here»; acid is lime, brutes red)
        zn.tele = teleRing(lx, lz, DROP_RING0, 1.0, 0.76, 0.9, warn, r1: DROP_RING, pulse: true, cause: .dropZone)
        oh.zones[slot] = zn
        m.dropT1 = m.dropT0; m.dropT0 = simTime
        oh.lastDrop = simTime
        oh.stats.drops += 1
        if zn.dropper { oh.stats.dropperDrops += 1 }
        emit(.dropWarned(from: zn.from, to: Vec2(lx, lz), eta: warn))
        return true
    }

    /// The coil: it holds on, turned toward the landing point; DROP_T before the landing it lets go.
    func coilTick(_ i: Int, _ dt: Float) {
        let S = bugs
        S.t[i] -= dt
        S.hd[i] += angDiff(S.hd[i], atan2f2(S.ax[i] - S.x[i], S.az[i] - S.z[i])) * minf(1, 10 * dt)
        if S.t[i] <= 0 {
            S.st[i] = S_DROP; S.t[i] = DROP_T
            S.rx[i] = S.x[i]; S.ry[i] = S.y[i]; S.rz[i] = S.z[i]
        }
    }

    /// The drop in flight: a short hop off the route down onto the fixed point; below 2 m it is back within the deck's
    /// reach (shootable, blastable).
    func dropTick(_ i: Int, _ dt: Float) {
        let S = bugs
        S.t[i] -= dt
        let u = clampf(1 - S.t[i] / DROP_T, 0, 1)
        let lx = S.ax[i], lz = S.az[i], yl = level.groundY(lx, lz)
        S.x[i] = S.rx[i] + (lx - S.rx[i]) * u
        S.z[i] = S.rz[i] + (lz - S.rz[i]) * u
        S.y[i] = S.ry[i] + (yl - S.ry[i]) * u + 2.4 * u * (1 - u)
        S.up[i] = S.y[i] - yl > 2 ? 1 : 0
        S.ph[i] += dt * 20
        if S.t[i] <= 0 { landDrop(i) }
    }

    /// It lands: a marine still inside the ring (the nearest standing one) takes the bug's bite (× the tier's `bite` for
    /// runners and spitters, as on the deck) × dropK and a knock along the flight; the bug fights on as a deck bug.
    /// (Package R4's pin hooks in here.)
    func landDrop(_ i: Int) {
        let S = bugs
        let lx = S.ax[i], lz = S.az[i]
        let slot = Int(S.hit[i] >> 4)
        let dx = lx - S.rx[i], dz = lz - S.rz[i], dl = hypotf2(dx, dz) + 1e-4
        if slot < oh.zones.count && oh.zones[slot].uid == S.uid[i] { oh.zones[slot].active = false }
        settleOnDeck(i, lx, lz, vx: dx / dl * 2, vz: dz / dl * 2)
        oh.stats.landed += 1
        if S.type[i] == T_DROP { oh.stats.dropperLanded += 1 }
        var hit: Marine? = nil
        var bd: Float = DROP_RING * DROP_RING
        for m in marines where !m.downed {
            let mx = m.x - lx, mz = m.z - lz, d2 = mx * mx + mz * mz
            if d2 < bd { bd = d2; hit = m }
        }
        if let m = hit, S.type[i] == T_DROP {
            // Stage 1 R4: the Dropper lands for 14 × the damage multiplier and pins the marine (GameOverheadBugs)
            dropperLands(i, m, dx / dl, dz / dl)
        } else if let m = hit {
            let ty = S.type[i]
            let bk: Float = difficulty.waves && (ty == T_RUN || ty == T_SPIT) ? difficulty.bite : 1
            let hp0 = m.hp
            hurtMarine(m, BUG_SPECS[Int(ty)].dmg * dmgMul * bk * difficulty.dropK, dx / dl * 4, dz / dl * 4, DamageSource(bugType: ty))
            oh.stats.hits += 1
            oh.stats.hurt += maxf(0, hp0 - maxf(0, m.hp))
            if m.downed { oh.stats.downs += 1 }
            S.cd[i] = BUG_SPECS[Int(ty)].atkCd
        } else {
            S.cd[i] = 0.1
        }
        emit(.dropLanded(pos: Vec2(lx, lz), hit: hit != nil))
    }

    /// Back on the deck as an ordinary bug at (x, z).
    func settleOnDeck(_ i: Int, _ x: Float, _ z: Float, vx: Float, vz: Float) {
        let S = bugs
        S.x[i] = x; S.z[i] = z; S.y[i] = 0; S.st[i] = S_MOVE; S.up[i] = 0; S.re[i] = 0; S.hit[i] = 0
        S.vx[i] = vx; S.vz[i] = vz; S.t[i] = 0
        S.lt[i] = 1.5   // (a runner's leap cooldown: it does not pounce again at once)
        if S.mood[i] == M_PANIC && S.burn[i] <= 0 { S.mood[i] = M_CALM }
        S.mt[i] = 0.4
    }

    /// Fall time from `h` m: a little faster than gravity (it is a game).
    @inline(__always) func fallTime(_ h: Float) -> Float { 0.3 + 0.06 * maxf(0, h) }

    /// Knock a bug off the overhead (fire, frost, a blast; `src`: who did it, -1 nobody, -2 the extraction — removed
    /// silently): it falls to the nearest deck cell within 2.5 m, or into the void (and dies there).
    func knockDown(_ i: Int, src: Int) {
        let S = bugs
        let st = S.st[i]
        if st < S_HIGH || st == S_FALL || st == S_PIN || st == S_BOSS || S.dead[i] != 0 { return }
        cancelDropZone(i)
        if S.type[i] == T_SPIT { releasePerch(S.uid[i]) }
        let x = S.x[i], z = S.z[i]
        S.rx[i] = x; S.ry[i] = S.y[i]; S.rz[i] = z
        var yl = S.y[i] - 12
        if src > -2, let c = nearestDeck(x, z, 2.5, clearOfMarines: 0) {
            S.ax[i] = c.x; S.az[i] = c.y; S.rs[i] = 0; yl = level.groundY(c.x, c.y)
        } else {
            S.ax[i] = x; S.az[i] = z; S.rs[i] = -1
        }
        S.st[i] = S_FALL; S.t[i] = fallTime(S.ry[i] - yl); S.re[i] = 0; S.up[i] = 1
        S.hit[i] = UInt8(bitPattern: Int8(clamping: src))
        if src > -2 {
            oh.stats.knockdowns += 1
            if S.type[i] == T_DROP { oh.stats.dropperKnocks += 1 }
            emit(.routeKnockdown(pos: Vec2(x, z), height: S.y[i] - level.groundY(x, z)))
        }
    }

    /// No drop for ROUTE_PATIENCE s: it hops down to a deck cell ≥ 2 m from every marine (no attack: not a drop).
    func routeHop(_ i: Int) -> Bool {
        let S = bugs
        guard let c = nearestDeck(S.x[i], S.z[i], 4, clearOfMarines: 2) else { S.lt[i] = 1; return false }
        if S.type[i] == T_SPIT { releasePerch(S.uid[i]) }
        S.rx[i] = S.x[i]; S.ry[i] = S.y[i]; S.rz[i] = S.z[i]
        S.ax[i] = c.x; S.az[i] = c.y; S.rs[i] = 0
        S.st[i] = S_FALL; S.t[i] = fallTime(S.y[i] - level.groundY(c.x, c.y)); S.re[i] = 0
        S.hit[i] = UInt8(bitPattern: Int8(-1))
        oh.stats.hops += 1
        if S.type[i] == T_DROP { oh.stats.dropperHops += 1 }
        return true
    }

    /// Falling: knocked off (or hopping down) onto the deck point, or into the void. A frozen bug shatters on the deck
    /// (killBug: a frost blast that hurts the bugs under it); a burning one goes on panicking down there.
    func fallTick(_ i: Int, _ dt: Float) {
        let S = bugs
        S.t[i] -= dt
        let void = S.rs[i] < 0
        let lx = S.ax[i], lz = S.az[i]
        let yl = void ? S.ry[i] - 12 : level.groundY(lx, lz)
        let u = clampf(1 - S.t[i] / fallTime(S.ry[i] - yl), 0, 1)
        S.x[i] = S.rx[i] + (lx - S.rx[i]) * u
        S.z[i] = S.rz[i] + (lz - S.rz[i]) * u
        S.y[i] = S.ry[i] + (yl - S.ry[i]) * u * u
        S.up[i] = void || S.y[i] - yl > 2 ? 1 : 0
        S.ph[i] += dt * 10
        if S.t[i] > 0 { return }
        let src = Int(Int8(bitPattern: S.hit[i]))
        if void {
            if src == -2 { S.dead[i] = 1; bugs.deadPending += 1 }   // the extraction: gone, no kill
            else { killBug(i, src) }
            return
        }
        if S.frz[i] > 0 { oh.stats.shattered += 1; killBug(i, src); return }
        settleOnDeck(i, lx, lz, vx: 0, vz: 0)
        S.cd[i] = maxf(S.cd[i], 0.4)
    }

    /// The nearest floor cell centre within `r` m of (x, z), `clearOfMarines` m from every standing marine; nil = none.
    func nearestDeck(_ x: Float, _ z: Float, _ r: Float, clearOfMarines: Float) -> Vec2? {
        let n = Int(r.rounded(.up))
        let ci = floorInt(x + GRID_HALF), cj = floorInt(z + GRID_HALF)
        var best: Vec2? = nil
        var bd = r * r
        var j = cj - n
        while j <= cj + n {
            defer { j += 1 }
            if j < 1 || j >= GRID - 1 { continue }
            var ii = ci - n
            while ii <= ci + n {
                defer { ii += 1 }
                if ii < 1 || ii >= GRID - 1 { continue }
                let c = j * GRID + ii
                if level.walk[c] != 1 { continue }
                let cx = Level.cellX(c), cz = Level.cellZ(c)
                let d2 = (cx - x) * (cx - x) + (cz - z) * (cz - z)
                if d2 >= bd { continue }
                if clearOfMarines > 0 {
                    var near = false
                    for m in marines where !m.downed && (m.x - cx) * (m.x - cx) + (m.z - cz) * (m.z - cz) < clearOfMarines * clearOfMarines { near = true }
                    if near { continue }
                }
                bd = d2; best = Vec2(cx, cz)
            }
        }
        return best
    }

    /// The drop telegraph of a coiling / dropping bug is called off (it died, it was knocked down): its ring goes too.
    func cancelDropZone(_ i: Int) {
        let S = bugs
        if S.st[i] != S_COIL && S.st[i] != S_DROP { return }
        let slot = Int(S.hit[i] >> 4)
        guard slot < oh.zones.count, oh.zones[slot].active, oh.zones[slot].uid == S.uid[i] else { return }
        let tk = oh.zones[slot].tele
        if tk >= 0 && tk < telegraphs.count && telegraphs[tk].active && telegraphs[tk].cause == .dropZone { telegraphs[tk].active = false }
        oh.zones[slot].active = false
    }

    /// killBug of a bug in an overhead state (before its slot is flagged dead). Stage 1 R4: a pinning Dropper (down on the
    /// deck) lets its marine go — the squad's fire got it off; a perched or perch-bound spitter frees its perch.
    func overheadBugDied(_ i: Int, _ src: Int = -1) {
        let S = bugs
        if S.st[i] == S_PIN { pinBugDied(i, src); return }
        cancelDropZone(i)
        if S.type[i] == T_SPIT { releasePerch(S.uid[i]) }
        oh.stats.kills += 1
        if S.type[i] == T_DROP { oh.stats.dropperKills += 1 }
    }

    // ---------- counterplay: the squad's weapons reach up ----------
    /// Bullets: the overhead bug whose footprint (radius × FOOTPRINT_K + 0.08) the segment touches first, nearer than
    /// `maxT` (updateProjectiles keeps the nearer of this and the deck hit). (-1, maxT) when none.
    func overheadSegmentHit(_ sx: Float, _ sz: Float, _ dx: Float, _ dz: Float, _ maxT: Float, _ exclude: Int32) -> (Int, Float) {
        let S = bugs, H = hash
        var best = -1
        var segT = maxT
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            // (a bug climbing a riser is like one scaling a deck edge: rounds fly past it)
            if S.dead[b] != 0 || S.uid[b] == exclude || S.st[b] == S_RISER { continue }
            let bx = S.x[b] - sx, bz = S.z[b] - sz, t = bx * dx + bz * dz
            if t < -0.3 || t > segT { continue }
            let px = bx - dx * t, pz = bz - dz * t, rb = S.r[b] * (S.up[b] != 0 ? FOOTPRINT_K : 1) + 0.08
            if px * px + pz * pz < rb * rb { segT = maxf(0, t); best = b }
        }
        return (best, segT)
    }

    /// The torch reaches bugs up on the overhead within its range and cone (in plan): they burn (and lose their grip).
    func overheadFlame(_ m: Marine, _ ox: Float, _ oz: Float, _ range: Float, _ cosC: Float, _ dps: Float, _ burnT: Float, _ dt: Float) -> Bool {
        let S = bugs, H = hash
        var any = false
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            if S.dead[b] != 0 || S.up[b] == 0 { continue }
            let dx = S.x[b] - ox, dz = S.z[b] - oz, d = (dx * dx + dz * dz).squareRoot() + 1e-4
            if d > range + S.r[b] { continue }
            if d > 0.9 && (dx * m.ax + dz * m.az) / d < cosC { continue }
            any = true
            S.burn[b] = burnT; S.bsrc[b] = Int8(truncatingIfNeeded: m.index)
            hitBug(b, dps * dt * (1 - 0.35 * d / range), m.index, true)
        }
        return any
    }

    /// The cryo beam chills bugs up on the overhead along it (in plan); frozen, they fall — and shatter on the deck.
    func overheadBeam(_ m: Marine, _ ox: Float, _ oz: Float, _ len: Float, _ chillRate: Float, _ dps: Float, _ dt: Float) -> Bool {
        let S = bugs, H = hash
        var any = false
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            if S.dead[b] != 0 || S.up[b] == 0 { continue }
            let dx = S.x[b] - ox, dz = S.z[b] - oz, t = dx * m.ax + dz * m.az
            if t < -0.3 || t > len { continue }
            let perp = absf(dx * m.az - dz * m.ax), w = 0.42 + t / len * 0.75
            if perp > w + S.r[b] { continue }
            any = true
            // (Stage 2 B1: a boss's part up there never freezes: GameBoss.bossBeamChill)
            if S.boss[b] != 0 { bossBeamChill(b, chillRate * dt) }
            else if S.frz[b] <= 0 {
                S.chill[b] += chillRate * dt
                if S.chill[b] >= 1 {
                    S.chill[b] = 1; S.frz[b] = 2.6
                    knockDown(b, src: m.index)
                    if !simOnly { emit(.bugFrozen(pos: Vec2(S.x[b], S.z[b]))); sound(.freeze, S.x[b], S.z[b]) }
                }
            }
            hitBug(b, dps * dt, m.index, true)
        }
        return any
    }

    /// The Ice Wave: everything up on the overhead within `r` m freezes and falls (design §1.1.5).
    func overheadNova(_ m: Marine, _ r: Float, _ dmg: Float) {
        let S = bugs, H = hash
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            if S.dead[b] != 0 || S.up[b] == 0 { continue }
            let dx = S.x[b] - m.x, dz = S.z[b] - m.z
            if dx * dx + dz * dz >= (r + S.r[b]) * (r + S.r[b]) { continue }
            if S.boss[b] != 0 { bossPartFreeze(b, nova: true); hitBug(b, dmg, m.index); continue }
            S.frz[b] = 3.2; S.chill[b] = 1
            knockDown(b, src: m.index)
            hitBug(b, dmg, m.index)
        }
    }

    /// The squad's blasts (the frag and its bomblets / explosive rounds) reach the overhead at BLAST_UP × their radius: the
    /// bugs up there take the damage and the survivors are knocked down (design §1.1.5).
    func overheadBlast(_ e: Boom) {
        let S = bugs, H = hash
        let R = e.r * BLAST_UP
        // (Stage 2 B4: a chain boss takes the blast as one creature — BossSpec.areaOnce)
        bossRT.areaHit = true
        defer { bossRT.areaHit = false }
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            if S.dead[b] != 0 || S.up[b] == 0 { continue }
            let dx = S.x[b] - e.x, dz = S.z[b] - e.z, d = (dx * dx + dz * dz).squareRoot()
            if d >= R + S.r[b] { continue }
            // (Stage 2 B4: a chain boss's part up there hears the blast — the Threader's coil lets go of a grenade on a node)
            if S.boss[b] != 0 && S.boss[b] != BOSS_BUG { bossOwnBlast(Int(S.boss[b]) - 1, e.kind, e.src) }
            if !hitBug(b, e.dmg * (1 - 0.55 * minf(1, d / R)), e.src, dir: d > 1e-3 ? Vec2(dx / d, dz / d) : nil) { knockDown(b, src: e.src) }
        }
    }

    /// The turret watches the racks: a coiling bug up there in reach before anything on the deck; one only walking the
    /// routes when the deck gives it nothing to shoot. Updates `bd` (the deck pick's score: squared distance, 1e9 = none)
    /// and returns the slot when it beats it, else -1.
    func overheadTurretTarget(_ bd: inout Float) -> Int {
        let S = bugs, H = hash
        let r = turretRange()
        let deckPick = bd < 1e8
        var best = -1
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            if S.dead[b] != 0 || S.up[b] == 0 || S.st[b] == S_RISER { continue }
            let dx = S.x[b] - turret.x, dz = S.z[b] - turret.z, d2 = dx * dx + dz * dz
            if d2 > r * r { continue }
            let coil = coilSeen(b) || S.st[b] == S_PERCH
            if !coil && (deckPick || S.st[b] == S_COIL) { continue }
            let d = d2 - (coil ? 1000 : 0)
            if d < bd { bd = d; best = b }
        }
        return best
    }

    /// A bug coiling for BOT_REACT s already: the bots and the turret answer a telegraph after a human-like reaction time
    /// (a squad that shot every coil at once would leave the drops no teeth; Recruit's longer coil gives them more time).
    @inline(__always) func coilSeen(_ b: Int) -> Bool {
        bugs.st[b] == S_COIL && (difficulty.dropWarn - DROP_T) - bugs.t[b] >= BOT_REACT
    }

    /// Bot targeting (aiPickTarget's score: lower is better): a coiling bug up there in range, before the deck's («fire at
    /// coiling Droppers first»: the squad saves you). Bugs only walking the routes are left to the player, the turret, the
    /// cones and the grenades — the bots would strip every rack before a single drop.
    func overheadAITarget(_ m: Marine, _ range: Float, _ bs: inout Float) -> Int {
        let S = bugs, H = hash
        var best = -1
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            // (Stage 1 R4: a perched spitter too — almost a coil's priority while it winds up, else when the deck is clear)
            let perch = S.st[b] == S_PERCH
            if S.dead[b] != 0 || S.up[b] == 0 || !(perch || coilSeen(b)) { continue }
            let dx = S.x[b] - m.x, dz = S.z[b] - m.z, d = (dx * dx + dz * dz).squareRoot()
            if d > range { continue }
            let s = d + abs(angDiff(m.aim, atan2f2(dx, dz))) * 2.2 - (perch ? (S.t[b] > 0 ? 6 : 1) : 8)
            if s < bs { bs = s; best = b }
        }
        return best
    }

    /// Aim assist (aimAssistTarget's score: higher is better): a bug up on a route inside the cone around where the player
    /// SEES it — drawn ≈ 0.75 h up-screen of its footprint at the 57° camera (tech.md §2.1) — so pointing the stick at the
    /// sprite finds it; the assist then turns the aim to its footprint and the rounds go up. A coiling one is preferred; one
    /// only walking the routes loses to a deck bug in the same cone.
    func overheadAssist(_ m: Marine, _ dx: Float, _ dz: Float, _ bs: inout Float) -> Int {
        let S = bugs, H = hash
        var best = -1
        var q = H.overheadStart
        let qe = H.overheadEnd
        while q < qe {
            let b = H.items[q]
            q += 1
            if S.dead[b] != 0 || S.up[b] == 0 || S.st[b] == S_RISER { continue }
            let lift = 0.75 * maxf(0, S.y[b] - level.groundY(S.x[b], S.z[b]))
            let vx = S.x[b] + FWD_X * lift - m.x, vz = S.z[b] + FWD_Z * lift - m.z, d = hypotf2(vx, vz)
            if d < 0.6 || d > 17 { continue }
            let cs = (vx * dx + vz * dz) / d
            if cs < 0.92 || !isVisible(S.x[b], S.z[b]) { continue }
            let s = cs * 5 - d * 0.1 + (S.st[b] == S_COIL || S.st[b] == S_PERCH ? 1.2 : -1.0)
            if s > bs { bs = s; best = b }
        }
        return best
    }

    /// A bot (and the calibration autopilot) steps out of a drop ring with ≤ 0.6 s left, as it does from an acid glob.
    func dropDodge(_ m: Marine) {
        for z in oh.zones where z.active && z.t <= 0.6 {
            // (Stage 1 R4: the autopilot in the player's seat answers a Dropper's ring like a person — AUTOPILOT_DROP_REACT s
            // into the warning, later for some: not every ring is dodged; the squad bots keep their sidestep)
            if z.dropper && m.isPlayer && z.warn - z.t < autopilotDropReact(z.uid) { continue }
            let dx = m.x - z.x, dz = m.z - z.z, d = hypotf2(dx, dz)
            if d >= z.r + 0.5 { continue }
            if d > 0.05 { m.ai.sideX = dx / d; m.ai.sideZ = dz / d }
            else {
                // dead centre: sideways to the flight
                let fx = z.x - z.from.x, fz = z.z - z.from.z, fl = hypotf2(fx, fz)
                if fl > 1e-3 { m.ai.sideX = -fz / fl; m.ai.sideZ = fx / fl } else { m.ai.sideX = 1; m.ai.sideZ = 0 }
            }
            m.ai.sideT = 0.4
        }
    }

    // ---------- debug / demo / tests ----------
    /// `n` runners up an overhead entry (`entry`: a node index; nil = one near the squad by the director's rule) at `rate`
    /// per second. Works with the tier's `routes` = 0 and without the director; the route cap holds. Returns how many
    /// were queued.
    @discardableResult
    public func debugRoutePack(_ n: Int, entry: Int? = nil, rate: Float = 3, type: BugType = .runner) -> Int {
        guard let G = level.overhead else { return 0 }
        let e = entry ?? routeEntry(near: squadCenter())
        guard e >= 0 && e < G.nodeCount && !G.nodeEdges[e].isEmpty else { return 0 }
        return queueRoutePack(n, entry: e, rate: rate, type: UInt8(type.rawValue))
    }

    /// One route bug at entry node `entry` now (tests). Returns its slot or -1.
    @discardableResult
    public func debugSpawnRouteBug(entry: Int, type: BugType = .runner) -> Int { spawnRouteBug(entry: entry, type: UInt8(type.rawValue)) }

    /// Deck circles (x, z, r) no drop lands in (package R6's lit deck will set these from its lamps).
    public func debugSetNoDropZones(_ circles: [SIMD3<Float>]) { oh.noDrop = circles }

    /// The bots hold their fire (the overhead demo stages its drops before the squad opens up).
    public var debugHoldFire: Bool {
        get { oh.holdFire }
        set { oh.holdFire = newValue }
    }
}
