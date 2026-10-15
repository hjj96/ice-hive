import Foundation

// ================================================================
//  SPATIAL HASH — uniform 1 m grid rebuilt every tick with a counting sort
//  (hStart / hItems / hCell of 05-sim.js), plus circle / ray / segment queries.
// ================================================================
final class SpatialHash {
    /// hStart[c] ..< hStart[c+1] = slice of `items` for cell c.
    let start: UnsafeMutablePointer<Int>
    let cursor: UnsafeMutablePointer<Int>
    let items: UnsafeMutablePointer<Int>
    /// Cell of bug i at the last rebuild.
    let cell: UnsafeMutablePointer<Int>
    /// Bugs hashed at the last rebuild (bugs spawned later have no cell yet).
    var hashedCount: Int = 0
    /// Shared query result buffer (queries never nest).
    let qb: UnsafeMutablePointer<Int>
    let capacity: Int

    init(capacity: Int = MAX_BUGS) {
        self.capacity = capacity
        let n = GRID * GRID
        start = .allocate(capacity: n + 1); start.initialize(repeating: 0, count: n + 1)
        cursor = .allocate(capacity: n); cursor.initialize(repeating: 0, count: n)
        items = .allocate(capacity: capacity); items.initialize(repeating: 0, count: capacity)
        cell = .allocate(capacity: capacity); cell.initialize(repeating: 0, count: capacity)
        qb = .allocate(capacity: capacity); qb.initialize(repeating: 0, count: capacity)
    }
    deinit { start.deallocate(); cursor.deallocate(); items.deallocate(); cell.deallocate(); qb.deallocate() }

    func clear() {
        start.update(repeating: 0, count: GRID * GRID + 1)
        hashedCount = 0
    }

    func rebuild(_ S: Swarm) {
        let GG = GRID * GRID
        let hs = start, hc = cell, cur = cursor, it = items
        hs.update(repeating: 0, count: GG + 1)
        let n = S.count
        let X = S.x, Z = S.z
        var i = 0
        while i < n {
            let c = Level.cellClamp(X[i], Z[i])
            hc[i] = c
            hs[c + 1] += 1
            i += 1
        }
        var acc = 0
        var c = 0
        while c <= GG { acc += hs[c]; hs[c] = acc; c += 1 }
        cur.update(from: hs, count: GG)
        i = 0
        while i < n {
            let cc = hc[i]
            it[cur[cc]] = i
            cur[cc] += 1
            i += 1
        }
        hashedCount = n
    }

    /// All live bugs whose body overlaps the circle -> qb[0..<count).
    func queryCircle(_ S: Swarm, _ x: Float, _ z: Float, _ r: Float) -> Int {
        var cnt = 0
        let i0 = maxi(0, floorInt(x - r - 1 + GRID_HALF)), i1 = mini(GRID - 1, floorInt(x + r + 1 + GRID_HALF))
        let j0 = maxi(0, floorInt(z - r - 1 + GRID_HALF)), j1 = mini(GRID - 1, floorInt(z + r + 1 + GRID_HALF))
        if i0 > i1 || j0 > j1 { return 0 }
        let hs = start, it = items, D = S.dead, X = S.x, Z = S.z, R = S.r, out = qb
        var j = j0
        while j <= j1 {
            defer { j += 1 }
            var i = i0
            while i <= i1 {
                defer { i += 1 }
                let c = j * GRID + i
                let e = hs[c + 1]
                var k = hs[c]
                while k < e {
                    let b = it[k]
                    k += 1
                    if D[b] != 0 { continue }
                    let dx = X[b] - x, dz = Z[b] - z, rr = r + R[b]
                    if dx * dx + dz * dz < rr * rr { out[cnt] = b; cnt += 1 }
                }
            }
        }
        return cnt
    }

    /// Number of hashed bugs in the 3×3 cells around c (aim-assist density).
    func cellDensity(_ c: Int) -> Int {
        var n = 0
        let i = c % GRID, j = c / GRID
        for dj in -1...1 {
            let jj = j + dj
            if jj < 0 || jj >= GRID { continue }
            for di in -1...1 {
                let ii = i + di
                if ii < 0 || ii >= GRID { continue }
                let cc = jj * GRID + ii
                n += start[cc + 1] - start[cc]
            }
        }
        return n
    }

    /// First bug hit by a ray (marching over cells). Returns (distance or maxD, bug index or -1).
    func raycast(_ S: Swarm, _ ox: Float, _ oz: Float, _ dx: Float, _ dz: Float, _ maxD: Float) -> (Float, Int) {
        var hit = -1
        var best = maxD
        let step: Float = 0.9
        var lastC = -1
        let hs = start, it = items, D = S.dead, ST = S.st, X = S.x, Z = S.z, R = S.r
        var s: Float = 0
        while s <= maxD + 1 {
            if s > best + 1.2 { break }
            let px = ox + dx * s, pz = oz + dz * s
            let ci = floorInt(px + GRID_HALF), cj = floorInt(pz + GRID_HALF)
            for dj in -1...1 {
                for di in -1...1 {
                    let i = ci + di, j = cj + dj
                    if i < 0 || j < 0 || i >= GRID || j >= GRID { continue }
                    let c = j * GRID + i
                    if c == lastC { continue }
                    let e = hs[c + 1]
                    var k = hs[c]
                    while k < e {
                        let b = it[k]
                        k += 1
                        if D[b] != 0 || ST[b] == S_CLIMB { continue }
                        let bx = X[b] - ox, bz = Z[b] - oz
                        let tt0 = bx * dx + bz * dz
                        if tt0 < 0 || tt0 > best { continue }
                        let px2 = bx - dx * tt0, pz2 = bz - dz * tt0, rb = R[b]
                        let d2 = px2 * px2 + pz2 * pz2
                        if d2 < rb * rb {
                            let tt = tt0 - (rb * rb - d2).squareRoot()
                            if tt < best { best = maxf(0, tt); hit = b }
                        }
                    }
                }
            }
            lastC = cj * GRID + ci
            s += step
        }
        return (best, hit)
    }

    /// Closest bug whose body (+0.08) the segment touches; excludes uid `exclude` and climbing bugs.
    /// Returns (bug index or -1, distance along the segment).
    func segmentHit(_ S: Swarm, _ sx: Float, _ sz: Float, _ dx: Float, _ dz: Float, _ len: Float, _ exclude: Int32) -> (Int, Float) {
        var best = -1
        var segT = len
        let ex = sx + dx * len, ez = sz + dz * len
        let i0 = maxi(0, floorInt(minf(sx, ex) - 1 + GRID_HALF)), i1 = mini(GRID - 1, floorInt(maxf(sx, ex) + 1 + GRID_HALF))
        let j0 = maxi(0, floorInt(minf(sz, ez) - 1 + GRID_HALF)), j1 = mini(GRID - 1, floorInt(maxf(sz, ez) + 1 + GRID_HALF))
        if i0 > i1 || j0 > j1 { return (-1, segT) }
        let hs = start, it = items, D = S.dead, ST = S.st, X = S.x, Z = S.z, R = S.r, U = S.uid
        for j in j0...j1 {
            for i in i0...i1 {
                let c = j * GRID + i
                let e = hs[c + 1]
                var k = hs[c]
                while k < e {
                    let b = it[k]
                    k += 1
                    if D[b] != 0 || U[b] == exclude || ST[b] == S_CLIMB { continue }
                    let bx = X[b] - sx, bz = Z[b] - sz, t = bx * dx + bz * dz
                    if t < -0.3 || t > segT { continue }
                    let px = bx - dx * t, pz = bz - dz * t, rb = R[b] + 0.08
                    if px * px + pz * pz < rb * rb { segT = maxf(0, t); best = b }
                }
            }
        }
        return (best, segT)
    }
}

// ================================================================
//  FLOW FIELDS — multi-source BFS over the walk grid; each cell stores
//  a unit direction toward lower distance (8-way, no corner cutting).
// ================================================================
public final class FlowField {
    public static let unreachable: Int = 65535
    /// BFS distance in cells (65535 = unreachable).
    let d: UnsafeMutablePointer<Int>
    let x: UnsafeMutablePointer<Float>
    let z: UnsafeMutablePointer<Float>

    init() {
        let n = GRID * GRID
        d = .allocate(capacity: n); d.initialize(repeating: FlowField.unreachable, count: n)
        x = .allocate(capacity: n); x.initialize(repeating: 0, count: n)
        z = .allocate(capacity: n); z.initialize(repeating: 0, count: n)
    }
    deinit { d.deallocate(); x.deallocate(); z.deallocate() }

    /// Distance (cells) of cell c from the nearest source.
    public func distance(_ c: Int) -> Int { (c >= 0 && c < GRID * GRID) ? d[c] : FlowField.unreachable }
    /// Unit flow direction at cell c (zero at sources and unreachable cells).
    public func direction(_ c: Int) -> Vec2 { (c >= 0 && c < GRID * GRID) ? Vec2(x[c], z[c]) : Vec2(0, 0) }

    /// `queue` is scratch space of G*G Int.
    func compute(level: Level, sources: UnsafeBufferPointer<Float>, queue fq: UnsafeMutablePointer<Int>) {
        let G = GRID, GG = G * G
        let D = d, FX = x, FZ = z, walk = level.walk
        D.update(repeating: FlowField.unreachable, count: GG)
        FX.update(repeating: 0, count: GG)
        FZ.update(repeating: 0, count: GG)
        var qh = 0, qt = 0
        var k = 0
        while k + 1 < sources.count {
            let c = level.cellOf(sources[k], sources[k + 1])
            if c >= 0 && D[c] != 0 { D[c] = 0; fq[qt] = c; qt += 1 }
            k += 2
        }
        while qh < qt {
            let c = fq[qh]; qh += 1
            let nd = D[c] + 1, i = c % G
            if i > 0 && walk[c - 1] == 1 && D[c - 1] > nd { D[c - 1] = nd; fq[qt] = c - 1; qt += 1 }
            if i < G - 1 && walk[c + 1] == 1 && D[c + 1] > nd { D[c + 1] = nd; fq[qt] = c + 1; qt += 1 }
            if c >= G && walk[c - G] == 1 && D[c - G] > nd { D[c - G] = nd; fq[qt] = c - G; qt += 1 }
            if c < G * (G - 1) && walk[c + G] == 1 && D[c + G] > nd { D[c + G] = nd; fq[qt] = c + G; qt += 1 }
        }
        // direction = weighted sum toward lower-distance neighbours (8-way, no corner cutting)
        for q in 0..<qt {
            let c = fq[q], d0 = D[c], i = c % G, j = c / G
            if d0 == 0 { continue }
            var vx: Float = 0, vz: Float = 0
            for n8 in 0..<8 {
                let dx: Int, dz: Int
                switch n8 {
                case 0: dx = 1; dz = 0
                case 1: dx = -1; dz = 0
                case 2: dx = 0; dz = 1
                case 3: dx = 0; dz = -1
                case 4: dx = 1; dz = 1
                case 5: dx = 1; dz = -1
                case 6: dx = -1; dz = 1
                default: dx = -1; dz = -1
                }
                let ni = i + dx, nj = j + dz
                if ni < 0 || nj < 0 || ni >= G || nj >= G { continue }
                let n = nj * G + ni
                if walk[n] != 1 { continue }
                if dx != 0 && dz != 0 && (walk[j * G + ni] != 1 || walk[nj * G + i] != 1) { continue }
                let dn = D[n]
                if dn < d0 {
                    let dd = Float(d0 - dn)
                    let w = (dx != 0 && dz != 0) ? dd * 0.7071 : dd
                    vx += Float(dx) * w; vz += Float(dz) * w
                }
            }
            // never point diagonally into a blocked corner cell (crates, beacon bases): keep the dominant axis
            if vx != 0 && vz != 0 {
                let ci = i + (vx > 0 ? 1 : -1), cj = j + (vz > 0 ? 1 : -1)
                if ci < 0 || cj < 0 || ci >= G || cj >= G || walk[cj * G + ci] != 1 {
                    if absf(vx) >= absf(vz) { vz = 0 } else { vx = 0 }
                }
            }
            let l = hypotf2(vx, vz)
            if l > 0 { FX[c] = vx / l; FZ[c] = vz / l }
        }
    }
}
