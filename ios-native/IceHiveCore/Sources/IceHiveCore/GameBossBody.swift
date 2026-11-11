import Foundation

// ================================================================
//  BOSS FRAMEWORK — the chain body (Stage 2 B1; design §1.5: «a multi-part
//  boss entity: N segments that follow the head's path history by arc
//  length (cheap and deterministic), a hit circle per part at its height,
//  damage routed to one boss bar»).
//    the head      steered by the boss's own file (`bossSetHead`) or along
//                  a track (`bossSetTrack`) at the boss's speed × its
//                  phase's; it stops while the body is locked or staggered
//    the history   a ring buffer of the head's points every `sampleStep` m
//                  (x, absolute y, z) with their arc length
//    the parts     segment j stands `lead + (j − 1) × spacing` m of path
//                  behind the head (interpolated between the two points
//                  that bracket that arc length), a node rides its segment;
//                  each is a swarm slot (state BugState.boss, an absolute
//                  height, `Swarm.boss` = its index + 1) with its own hit
//                  circle — up out of the deck weapons' reach above
//                  BOSS_REACH (the overhead's sentinel bucket), and every
//                  hit routed to the head's health (GameBoss.bossPartHit)
//  Fixed buffers only: nothing here allocates during a tick.
// ================================================================
extension Game {

    // ---------------------------------------------------------------- spawn

    /// The chain's parts at the spawn place (BossRuntime.spawnX/Z/Y/Hd): the head there, the body trailing straight
    /// behind it (its history seeded back along the heading). Returns the head's slot, -1 when the swarm has no room.
    func bossSpawnChain(_ c: BossChainSpec) -> Int {
        let R = bossRT, S = bugs
        let n = c.partCount
        if n > BOSS_PARTS || c.segments < 0 || S.count + n > S.capacity { return -1 }
        // the history must cover the body (a coarser step on a very long one)
        let need = c.length + 2 * c.spacing + 2
        R.hStep = maxf(0.05, maxf(c.sampleStep, need / Float(BOSS_PATH - 16)))
        R.headX = R.spawnX; R.headY = R.spawnY; R.headZ = R.spawnZ; R.headHd = R.spawnHd
        let sx = sinf2(R.spawnHd), sz = cosf2(R.spawnHd)
        R.hHead = -1; R.hCount = 0
        let k = Int((need / R.hStep).rounded(.up))
        var j = k
        while j >= 0 {
            let d = Float(j) * R.hStep
            bossPathPush(R.spawnX - sx * d, R.spawnY, R.spawnZ - sz * d)
            j -= 1
        }
        R.headS = R.hs[R.hHead]
        // the parts: the head (its health is the boss bar), the segments, the nodes
        let hp = config.bossHp ?? bossSpec.hp * hpMul
        R.parts = n
        for q in 0..<n {
            let ps = q == 0 ? c.head : (q <= c.segments ? c.segment : c.nodes[q - 1 - c.segments])
            R.role[q] = UInt8(ps.role.rawValue)
            R.seg[q] = q == 0 ? 0 : (q <= c.segments ? q : max(1, min(c.segments, ps.segment)))
            R.poolMax[q] = ps.pool > 0 ? ps.pool * hp : 0; R.pool[q] = R.poolMax[q]
            R.down[q] = 0; R.frozen[q] = 0; R.popped[q] = false; R.bonus[q] = 1
            let i = spawnBossPart(UInt8(ps.type.rawValue), R.spawnX, R.spawnZ, R.spawnY, ps.radius, ps.scale, hp: q == 0 ? hp : BOSS_PART_HP,
                                  part: q)
            R.pslot[q] = i; R.uid[q] = S.uid[i]
        }
        bossPlaceParts(c)
        for q in 0..<n { let i = R.pslot[q]; S.vx[i] = 0; S.vz[i] = 0 }
        S.spd[R.pslot[0]] = bossSpec.speed
        return R.pslot[0]
    }

    /// Part `q`'s swarm slot now (compact() moves slots: re-found by uid, one scan for all parts), -1 when gone.
    func bossPartSlot(_ q: Int) -> Int {
        let R = bossRT, S = bugs
        if q < 0 || q >= R.parts { return -1 }
        let i = R.pslot[q]
        if i >= 0 && i < S.count && S.uid[i] == R.uid[q] { return i }
        bossResyncParts()
        return R.pslot[q]
    }

    /// Every part's slot from one scan of `Swarm.boss` (after compact() moved some).
    func bossResyncParts() {
        let R = bossRT, S = bugs
        for q in 0..<R.parts { R.pslot[q] = -1 }
        var i = 0
        while i < S.count {
            let b = S.boss[i]
            if b != 0 && b != BOSS_BUG && S.dead[i] == 0 {
                let q = Int(b) - 1
                if q < R.parts && S.uid[i] == R.uid[q] { R.pslot[q] = i }
            }
            i += 1
        }
    }

    /// The chain's other parts go with its head (no kill of their own: the head's death is the boss's).
    func bossDropParts() {
        let R = bossRT, S = bugs
        for q in 1..<max(1, R.parts) {
            let i = bossPartSlot(q)
            if i >= 0 && S.dead[i] == 0 { S.dead[i] = 1; S.deadPending += 1 }
            R.pslot[q] = -1
        }
    }

    // ---------------------------------------------------------------- the boss's file steers the head

    /// The boss's file: the head is at (x, absolute y, z) now (its heading follows the move); this tick it does not walk its
    /// track.
    public func bossSetHead(_ x: Float, _ y: Float, _ z: Float) {
        let R = bossRT
        if R.parts == 0 { return }
        let dx = x - R.headX, dz = z - R.headZ
        if dx * dx + dz * dz > 1e-8 { R.headHd = atan2f2(dx, dz) }
        R.headX = x; R.headY = y; R.headZ = z
        R.steered = true
    }

    /// The boss's file: the head walks these points (x, absolute y, z) in turn at the boss's speed (× its phase's), back to
    /// the first after the last when `loop`. (Copied into a fixed buffer: up to 64 points without allocating.)
    public func bossSetTrack(_ points: [SIMD3<Float>], loop: Bool) {
        let R = bossRT
        R.track.removeAll(keepingCapacity: true)
        R.track.append(contentsOf: points.prefix(64))
        R.trackAt = 0; R.trackLoop = loop
    }

    // ---------------------------------------------------------------- the tick

    /// One tick of the chain (from bossTick, after the boss's own file): the head moves (unless the file steered it, the
    /// body is locked or it staggers), the history records it, the parts follow; their immunities and windows.
    func bossBodyTick(_ dt: Float) {
        let R = bossRT
        guard let c = bossSpec.chain else { return }
        bossResyncIfMoved()
        if !R.steered && boss.lock <= 0 && boss.stagger <= 0 && !R.track.isEmpty { bossWalkTrack(dt) }
        R.steered = false
        bossPathRecord()
        bossPlaceParts(c)
        // the parts' windows and freezes, the boss's immunities on every part
        let S = bugs, I = bossSpec.immune
        for q in 0..<R.parts {
            if R.down[q] > 0 { R.down[q] = maxf(0, R.down[q] - dt) }
            if R.frozen[q] > 0 { R.frozen[q] = maxf(0, R.frozen[q] - dt) }
            let i = R.pslot[q]
            if i < 0 { continue }
            S.frz[i] = 0
            if S.chill[i] > I.chillCap { S.chill[i] = I.chillCap }
            if S.chill[i] > 0 { S.chill[i] = maxf(0, S.chill[i] - dt * 0.4) }
        }
        boss.height = R.headY; boss.heading = R.headHd
    }

    /// A slot moved since the last tick: re-find them all.
    func bossResyncIfMoved() {
        let R = bossRT, S = bugs
        for q in 0..<R.parts {
            let i = R.pslot[q]
            if i < 0 || i >= S.count || S.uid[i] != R.uid[q] { bossResyncParts(); return }
        }
    }

    /// The head walks toward its track's current point at the boss's speed × its phase's (3-D), on to the next.
    func bossWalkTrack(_ dt: Float) {
        let R = bossRT
        var budget = bossSpec.speed * bossSpec.phases[min(boss.phase, bossSpec.phases.count - 1)].speedK * dt
        var guardN = 4
        while budget > 0 && guardN > 0 && R.trackAt < R.track.count {
            guardN -= 1
            let p = R.track[R.trackAt]
            let dx = p.x - R.headX, dy = p.y - R.headY, dz = p.z - R.headZ
            let d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d <= budget {
                R.headX = p.x; R.headY = p.y; R.headZ = p.z
                if dx * dx + dz * dz > 1e-8 { R.headHd = atan2f2(dx, dz) }
                budget -= d
                R.trackAt += 1
                if R.trackAt >= R.track.count && R.trackLoop { R.trackAt = 0 }
            } else {
                let k = budget / d
                R.headX += dx * k; R.headY += dy * k; R.headZ += dz * k
                if dx * dx + dz * dz > 1e-8 { R.headHd = atan2f2(dx, dz) }
                budget = 0
            }
        }
    }

    /// A point of the history (the newest at `hHead`), its arc length the last one's + the distance.
    func bossPathPush(_ x: Float, _ y: Float, _ z: Float) {
        let R = bossRT
        var s: Float = 0
        if R.hCount > 0 {
            let l = R.hHead
            let dx = x - R.hx[l], dy = y - R.hy[l], dz = z - R.hz[l]
            s = R.hs[l] + (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        R.hHead = (R.hHead + 1) & (BOSS_PATH - 1)
        R.hx[R.hHead] = x; R.hy[R.hHead] = y; R.hz[R.hHead] = z; R.hs[R.hHead] = s
        if R.hCount < BOSS_PATH { R.hCount += 1 }
    }

    /// The head moved `sampleStep` m or more from the newest point: it is the newest point now. Its own arc length.
    func bossPathRecord() {
        let R = bossRT
        let l = R.hHead
        let dx = R.headX - R.hx[l], dy = R.headY - R.hy[l], dz = R.headZ - R.hz[l]
        let d = (dx * dx + dy * dy + dz * dz).squareRoot()
        if d >= R.hStep { bossPathPush(R.headX, R.headY, R.headZ); R.headS = R.hs[R.hHead] }
        else { R.headS = R.hs[l] + d }
    }

    /// The point of the body `d` m of path behind the head (x, absolute y, z) and its heading (toward the head).
    func bossPathPoint(behind d: Float) -> (SIMD3<Float>, Float) {
        let R = bossRT
        let a = R.headS - d
        let l = R.hHead
        // between the newest point and the head
        if a >= R.hs[l] {
            let span = R.headS - R.hs[l]
            let t = span > 1e-6 ? (a - R.hs[l]) / span : 1
            let x = R.hx[l] + (R.headX - R.hx[l]) * t, y = R.hy[l] + (R.headY - R.hy[l]) * t, z = R.hz[l] + (R.headZ - R.hz[l]) * t
            let hx = R.headX - R.hx[l], hz = R.headZ - R.hz[l]
            return (SIMD3(x, y, z), hx * hx + hz * hz > 1e-8 ? atan2f2(hx, hz) : R.headHd)
        }
        // walk back to the two points that bracket it (the oldest one ends the walk)
        var i1 = l, n = 1
        while n < R.hCount {
            let i0 = (i1 - 1) & (BOSS_PATH - 1)
            if R.hs[i0] <= a {
                let span = R.hs[i1] - R.hs[i0]
                let t = span > 1e-6 ? (a - R.hs[i0]) / span : 0
                let x = R.hx[i0] + (R.hx[i1] - R.hx[i0]) * t, y = R.hy[i0] + (R.hy[i1] - R.hy[i0]) * t
                let z = R.hz[i0] + (R.hz[i1] - R.hz[i0]) * t
                let ex = R.hx[i1] - R.hx[i0], ez = R.hz[i1] - R.hz[i0]
                return (SIMD3(x, y, z), ex * ex + ez * ez > 1e-8 ? atan2f2(ex, ez) : R.headHd)
            }
            i1 = i0; n += 1
        }
        return (SIMD3(R.hx[i1], R.hy[i1], R.hz[i1]), R.headHd)
    }

    /// Every part to its place: the head at the head, segment j `lead + (j − 1) × spacing` m behind it, a node on its
    /// segment; their slots' position, absolute height, heading, motion, and reach (up above BOSS_REACH).
    func bossPlaceParts(_ c: BossChainSpec) {
        let R = bossRT
        // the head
        R.px[0] = R.headX; R.py[0] = R.headY + c.head.lift; R.pz[0] = R.headZ; R.phd[0] = R.headHd
        // the segments in order (their arc lengths fall): one walk back over the history
        let l = R.hHead
        var i1 = l, n = 1
        var j = 1
        while j <= c.segments && j < R.parts {
            let a = R.headS - (c.lead + Float(j - 1) * c.spacing)
            var x: Float, y: Float, z: Float, hd: Float
            if a >= R.hs[l] {
                let span = R.headS - R.hs[l]
                let t = span > 1e-6 ? (a - R.hs[l]) / span : 1
                x = R.hx[l] + (R.headX - R.hx[l]) * t; y = R.hy[l] + (R.headY - R.hy[l]) * t; z = R.hz[l] + (R.headZ - R.hz[l]) * t
                let ex = R.headX - R.hx[l], ez = R.headZ - R.hz[l]
                hd = ex * ex + ez * ez > 1e-8 ? atan2f2(ex, ez) : R.headHd
            } else {
                // (back to the older point at or before it; the oldest one ends the walk)
                var i0 = (i1 - 1) & (BOSS_PATH - 1)
                while n < R.hCount && R.hs[i0] > a { i1 = i0; i0 = (i1 - 1) & (BOSS_PATH - 1); n += 1 }
                if n >= R.hCount {
                    x = R.hx[i1]; y = R.hy[i1]; z = R.hz[i1]; hd = R.phd[max(0, j - 1)]
                } else {
                    let span = R.hs[i1] - R.hs[i0]
                    let t = span > 1e-6 ? (a - R.hs[i0]) / span : 0
                    x = R.hx[i0] + (R.hx[i1] - R.hx[i0]) * t; y = R.hy[i0] + (R.hy[i1] - R.hy[i0]) * t; z = R.hz[i0] + (R.hz[i1] - R.hz[i0]) * t
                    let ex = R.hx[i1] - R.hx[i0], ez = R.hz[i1] - R.hz[i0]
                    hd = ex * ex + ez * ez > 1e-8 ? atan2f2(ex, ez) : R.phd[max(0, j - 1)]
                }
            }
            R.px[j] = x; R.py[j] = y + c.segment.lift; R.pz[j] = z; R.phd[j] = hd
            j += 1
        }
        // the nodes on their segments
        var q = 1 + c.segments
        while q < R.parts {
            let s = max(1, min(c.segments, R.seg[q]))
            R.px[q] = R.px[s]; R.py[q] = R.py[s] - c.segment.lift + c.nodes[q - 1 - c.segments].lift; R.pz[q] = R.pz[s]; R.phd[q] = R.phd[s]
            q += 1
        }
        // their slots: position, absolute height, heading, motion, reach
        let S = bugs
        let inv: Float = 1 / SIM_DT
        for k in 0..<R.parts {
            let i = R.pslot[k]
            if i < 0 || i >= S.count || S.dead[i] != 0 { continue }
            S.vx[i] = (R.px[k] - S.x[i]) * inv; S.vz[i] = (R.pz[k] - S.z[i]) * inv
            S.x[i] = R.px[k]; S.z[i] = R.pz[k]; S.y[i] = R.py[k]; S.hd[i] = R.phd[k]
            let isUp = R.py[k] - level.groundY(R.px[k], R.pz[k]) > BOSS_REACH
            R.up[k] = isUp
            S.up[i] = isUp ? 1 : 0
        }
    }

    // ---------------------------------------------------------------- the renderer's and the tests' view

    /// Parts of the chain body (0: a bug body, or no boss).
    public var bossPartCount: Int { boss.alive ? bossRT.parts : 0 }

    /// Part `k` (0 the head, 1… the segments, then the nodes).
    public func bossPart(_ k: Int) -> BossPartView {
        let R = bossRT
        let q = max(0, min(BOSS_PARTS - 1, k))
        let ps: BossPartSpec? = bossSpec.chain.map { c in q == 0 ? c.head : (q <= c.segments ? c.segment : c.nodes[min(c.nodes.count - 1, q - 1 - c.segments)]) }
        return BossPartView(role: BossPartRole(rawValue: Int(R.role[q])) ?? .segment, segment: R.seg[q],
                            position: SIMD3(R.px[q], R.py[q], R.pz[q]), heading: R.phd[q], radius: ps?.radius ?? 0, scale: ps?.scale ?? 1,
                            slot: q < R.parts ? bossPartSlot(q) : -1, down: R.down[q], popped: R.popped[q],
                            pool: R.poolMax[q] > 0 ? R.pool[q] / R.poolMax[q] : 1, up: R.up[q])
    }

    /// The body's path `d` m behind the head (x, absolute y, z) and its heading: the renderer lays meshes along it.
    public func bossBodyPoint(behind d: Float) -> (position: SIMD3<Float>, heading: Float)? {
        if !boss.alive || bossRT.parts == 0 { return nil }
        let p = bossPathPoint(behind: max(0, d))
        return (p.0, p.1)
    }

    /// The chain's parts filed under the overhead's sentinel bucket at the last hash rebuild (they are not the overhead's
    /// route bugs: its caps and stats leave them out).
    var bossPartsUp: Int {
        let R = bossRT
        if R.parts == 0 { return 0 }
        var n = 0
        for q in 0..<R.parts {
            let i = R.pslot[q]
            if i >= 0 && i < hash.hashedCount && hash.cell[i] == SpatialHash.sentinel { n += 1 }
        }
        return n
    }
}

/// A chain part's own health (never spent: the head's is the boss bar).
let BOSS_PART_HP: Float = 1e9
