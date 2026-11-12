import Foundation

// ================================================================
//  WAVE PACING (native-vx-feel, `Difficulty.waves`) — fewer bugs, real
//  lulls and peaks instead of a constant stream.
//   · travel / the walk to the lift: a beat — lull (trickle × 0.15),
//     build-up (rising), peak (a surge from two flanks) — and a horde
//     every 45–60 s, followed by a real lull;
//   · a beacon defence: the opening horde from 3–4 sides, three pushes of
//     the hive at 30 / 62 / 90 % charge (the last one from three sides),
//     small packs out of the vents between them, quiet after each push;
//   · the hold: an opening horde (a pack straight over the lift's rim),
//     then a horde every 18–24 s with a lull after it;
//   · bugs arrive in packs — 2–3 from one stretch of rail, 6–40 from one
//     side, staggered — over the railings, up from below the deck edge and
//     out of the vents near the squad, never as one even conveyor.
//  The legacy stream (v1.0 / v1.1, `waves == false`) is untouched: the
//  director calls in here only on the wave pacing.
// ================================================================
extension Game {

    /// One tick of the wave director's spawning (replaces the legacy trickle and periodic hordes). `stageMul`: the
    /// stage factor × the Queen's trickle factor × the hive pressure (0 while the coach holds the swarm back).
    func wavesTick(_ dt: Float, _ stageMul: Float) {
        let D = difficulty
        let minutes = time / 60, done = Float(beaconsDone)
        let defending = posture == .defend
        var beatMul: Float = 1
        if posture == .travel {
            beatT -= dt
            if beatT <= 0 {
                beat = (beat + 1) % 3
                switch beat {
                case 0: beatT = 9 + rng.next() * 5
                case 1: beatT = 11 + rng.next() * 6
                default:
                    beatT = 6 + rng.next() * 3
                    let c = squadCenter()
                    let n = Int(((13 + 5 * done + 2.5 * minutes) * D.horde * D.popK * streamK).rounded())
                    // the overhead (Stage 1 R2): the two-flank surge gets a third direction, from above (35 %)
                    let up = overheadSurgeShare(n, near: c, chance: 0.35, share: 0.33)
                    surge(n - up, sides: 2, near: c, dmin: 14, dmax: 30, rate: 8)
                }
            }
            switch beat {
            case 0: beatMul = 0.15
            case 1: beatMul = 0.35 + 1.0 * clampf(1 - beatT / 14, 0, 1)
            default: beatMul = 1.4
            }
        } else if lullT > 0 {
            beatMul = 0.2
        }
        // a squad that loiters wakes the hive (pressure past its grace): no more lulls, the stream runs on; a player who has
        // not touched the screen for 12 s draws it harder (the AFK hunt)
        if idleMul >= 1.5 { beatMul = max(beatMul, 1.2) }
        if huntAfk { beatMul = max(beatMul, 1.6) }
        if lullT > 0 { lullT -= dt }
        // the ambient trickle: two or three creatures at a time from one stretch of rail
        let rate = (0.5 + 0.12 * minutes + 0.15 * done) * stageMul * beatMul * D.trickle * D.popK
        trickle += rate * dt
        if trickle >= 2 {
            let n = min(Int(trickle), 2 + (rng.next() < 0.4 ? 1 : 0))
            trickle -= Float(n)
            if capLeft() <= 0 { trickle = 0 } else {
                let c = squadCenter()
                pack(n, near: c, dmin: D.trickleMinDist, dmax: 30, rate: 4)
            }
        }
        // periodic hordes (the clock pauses while a ring is defended and while the boss lives — the Queen: its spec)
        if !defending && !bossHoldsHordes { hordeT -= dt }
        if hordeT <= 0 {
            if posture == .hold {
                hordeT = 18 + rng.next() * 6
                startHorde(Int(((80 + rng.next() * 35) * hordeScale() * holdHordeK).rounded()), .hordeTitle, GameText(holdHordeSub), 55)
                lullT = 9
            } else {
                hordeT = 45 + rng.next() * 15
                startHorde(Int((min(150, 42 + 20 * done + 8 * minutes) * hordeScale()).rounded()))
                beat = 0; beatT = 11 + rng.next() * 4
            }
        }
    }

    /// The beacon defence of beacon `k` on the wave pacing (every tick while it charges): the hive's three pushes at
    /// 30 / 62 / 90 % charge, small packs between them.
    func wavesBeaconTick(_ k: Int, _ dt: Float) {
        let D = difficulty, b = beacons[k], done = Float(beaconsDone)
        let marks: [Float] = [0.3, 0.62, 0.9]
        if beaconPushes < 3 && b.progress >= marks[beaconPushes] {
            let last = beaconPushes == 2
            let n = ((last ? 42 + 6 * done : 30 + 5 * done) * D.horde * D.popK).rounded()
            // the overhead (Stage 1 R2): at the 62 % push one side may pour along the routes and drop in a line — «the rain»
            let up = beaconPushes == 1 ? overheadSurgeShare(Int(n), near: Vec2(b.x, b.z), chance: 0.5, share: 0.5) : 0
            surge(Int(n) - up, sides: up > 0 ? 1 : (last ? 3 : 2), near: Vec2(b.x, b.z), dmin: 12, dmax: 28, rate: 10)
            beaconPushes += 1
            lullT = 8
            waveT = max(waveT, 6)
        }
        waveT -= dt
        if waveT <= 0 {
            waveT = 7 + rng.next() * 3
            let n = Int(((7 + 2 * done) * D.horde * D.popK).rounded())
            // (R7: a vent shut by a seal pours nothing)
            let vents = level.layout.vents.indices.filter { ventOpen($0) && hypotf2(level.layout.vents[$0].x - b.x, level.layout.vents[$0].y - b.z) < 14 }
                .map { level.layout.vents[$0] }
            if !vents.isEmpty && rng.next() < 0.6 {
                queueBurst(-1, n, 6, vents[rng.int(vents.count)])
            } else {
                pack(n, near: Vec2(b.x, b.z), dmin: 9, dmax: 24, rate: 6)
            }
        }
    }

    /// A pack of `n` from one entry near `c`: a vent 7–18 m away now and then (an ambush out of the grates), else one
    /// stretch of rail `dmin`…`dmax` m away.
    func pack(_ n0: Int, near c: Vec2, dmin: Float, dmax: Float, rate: Float, delay: Float = 0) {
        // the overhead (Stage 1 R2): with the tier's `routes` chance the pack climbs an overhead route instead
        let n = n0 - overheadPackShare(n0, near: c, rate: rate, delay: delay)
        if n <= 0 { return }
        if rng.next() < 0.22 {
            var pick: Vec2? = nil
            var seen = 0
            for (k, v) in level.layout.vents.enumerated() {
                // (R7: a vent shut by a seal pours nothing)
                if !ventOpen(k) { continue }
                let d = hypotf2(v.x - c.x, v.y - c.y)
                if d < 7 || d > 18 { continue }
                seen += 1
                if rng.next() * Float(seen) < 1 { pick = v }
            }
            if let v = pick { queueBurst(-1, n, rate, v, delay: delay); return }
        }
        let e = pickEdge(c.x, c.y, dmin, dmax)
        if e >= 0 { queueBurst(e, n, rate, nil, delay: delay) }
    }

    /// A surge of `n` split over `sides` well-separated directions around `c`, the packs a little apart in time.
    func surge(_ n: Int, sides: Int, near c: Vec2, dmin: Float, dmax: Float, rate: Float) {
        if n <= 0 || sides <= 0 { return }
        let a0 = rng.next() * TAU
        var left = n
        for j in 0..<sides {
            let m = j == sides - 1 ? left : Int((Float(n) / Float(sides) * (0.8 + 0.4 * rng.next())).rounded())
            left -= m
            if m <= 0 { continue }
            let ang = a0 + TAU * Float(j) / Float(sides) + (rng.next() - 0.5) * 0.7
            let e = pickEdgeToward(c.x, c.y, dmin, dmax, ang)
            if e >= 0 { queueBurst(e, m, rate * (0.8 + 0.4 * rng.next()), nil, delay: Float(j) * (0.5 + rng.next() * 1.1)) }
        }
    }

    /// An edge `dmin`…`dmax` m from (cx, cz) as close as possible to the direction `ang` (aim convention: (sin, cos)).
    func pickEdgeToward(_ cx: Float, _ cz: Float, _ dmin: Float, _ dmax: Float, _ ang: Float) -> Int {
        let L = level
        let N = L.edgeCount
        if N == 0 { return -1 }
        let ux = sinf2(ang), uz = cosf2(ang)
        var best = -1
        var bs: Float = 1e9
        for _ in 0..<48 {
            let e = rng.int(N)
            let x = L.edgeX[e], z = L.edgeZ[e]
            let dx = x - cx, dz = z - cz, d = hypotf2(dx, dz)
            if d < dmin || d > dmax { continue }
            let c = L.cellOf(x, z)
            if c < 0 || swarmFlow.d[c] == FlowField.unreachable { continue }
            let s = -(dx * ux + dz * uz) / d
            if s < bs { bs = s; best = e }
        }
        return best >= 0 ? best : pickEdge(cx, cz, dmin, dmax)
    }

    /// A horde on the wave pacing (`startHorde`): its packs from 2–4 sides, staggered, a share straight over the lift's
    /// rim in the hold, a vent pack when a grate is near. Returns the size after the tier and the population scale.
    func wavesHorde(_ size00: Int, _ rate: Float) -> Int {
        let D = difficulty
        let size0 = Int((Float(size00) * D.horde * D.popK).rounded())
        var size = Float(size0)
        let c = squadCenter()
        if posture == .hold {
            // the overhead (Stage 1 R2): 15 % of each hold horde slides down the routes over the hold's zone (the lift's cables
            // on the classic plan)
            let za = arena()
            size -= Float(overheadSurgeShare(size0, near: Vec2(za.x, za.z), chance: 1, share: 0.15))
            // a third climbs straight over the lift's rim from below, in two packs on different sides (the ramp alone made
            // the hold one long column; a hold on a deck or a boss arena: over its rim, when an edge is near)
            let L = arena()
            let n = Int((size * 0.15).rounded())
            let r1 = pickEdge(L.x, L.z, 0, L.r + 1)
            if r1 >= 0 {
                queueBurst(r1, n, 7, nil, delay: 1.2)
                var r2 = r1
                var tries = 0
                while tries < 12 {
                    tries += 1
                    let e = pickEdge(L.x, L.z, 0, L.r + 1)
                    if e < 0 { break }
                    let dx = level.edgeX[e] - level.edgeX[r1], dz = level.edgeZ[e] - level.edgeZ[r1]
                    if dx * dx + dz * dz > L.r * L.r { r2 = e; break }
                }
                queueBurst(r2, n, 7, nil, delay: 2.4)
            }
            size *= 0.7
        }
        let k = size >= 90 ? 4 : (size >= 40 ? 3 : 2)
        surge(Int(size.rounded()), sides: k, near: c, dmin: 13, dmax: 32, rate: rate * 0.28)
        return size0
    }
}
