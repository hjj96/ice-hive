import SpriteKit
import IceHiveCore

// ================================================================
//  LEVEL LAYER — the station assembled from the 1 m tile kit
//  (manifest.level rules; reference: tools/lib/level.mjs assembly()
//  and the web builders buildRailings / buildSupports / buildProps).
//  Static nodes are grouped into 4 × 4 m chunks that are hidden when
//  off screen; the lift pieces sit in their own node so they can rise.
// ================================================================
final class LevelLayer {
    let root = SKNode()
    /// Lift deck, shaft, rails, centre: moved up during the extraction.
    let liftNode = SKNode()
    /// Distant towers (outside the grid, always drawn).
    let backgroundNode = SKNode()
    private let assets: SpriteAssets
    private let level: Level
    /// Shared squashed container for flat (top-down) textures.
    private let groundRoot: SKNode

    private final class Chunk {
        let node = SKNode()
        var bounds = CGRect.null
        var nodes = 0
    }
    private var chunks: [Int: Chunk] = [:]
    private var chunkList: [Chunk] = []
    private var liftBounds = CGRect.null
    private(set) var nodeCount = 0
    private(set) var visibleChunks = 0
    /// Level nodes SpriteKit actually walks this frame (visible chunks + lift + background).
    private(set) var liveNodeCount = 0
    private var liftNodes = 0
    private var fixedNodes = 0

    /// Static lights for the darkness overlay / glow pools: (x, z, diameter m, colour hex).
    private(set) var glowPools: [(Float, Float, Float, UInt32)] = []

    /// Draw bands. Static pieces get constant z per band wherever the order inside does not matter, so SpriteKit
    /// can batch them by atlas page: railings on far (N / W) edges are always behind whatever stands on the deck,
    /// railings on near (S / E) edges always in front of it.
    private enum Band { case underBack, underMid, underFront, floor, floorDecal, farEdge, object, nearEdge, background }

    // per-cell data rebuilt from the layout (FloorRect raster order: later rects win)
    private var kind = [UInt8](repeating: 0, count: GRID * GRID)       // 0 grating, 1 slab
    private var rectOf = [Int16](repeating: -1, count: GRID * GRID)

    init(level: Level, assets: SpriteAssets, groundRoot: SKNode) {
        self.level = level
        self.assets = assets
        self.groundRoot = groundRoot
        root.addChild(backgroundNode)
        root.addChild(liftNode)
        let t0 = Date()
        rasterKinds()
        buildFloors()
        buildEdges()
        buildRailRunsAndLamps()
        buildSupports()
        buildProps()
        buildLift()
        buildBackground()
        AppLog.info(String(format: "level built: %d nodes in %d chunks (%.0f ms)", nodeCount, chunkList.count, Date().timeIntervalSince(t0) * 1000))
    }

    // ---------------------------------------------------------------- helpers
    private static func code(_ g: Float) -> String {
        let v = Int((abs(g) * 1000).rounded())
        let s = v < 10 ? "00\(v)" : (v < 100 ? "0\(v)" : "\(v)")
        return (g < -1e-6 ? "m" : "") + s
    }
    private static func two(_ k: Int) -> String { k < 10 ? "0\(k)" : "\(k)" }

    private func chunk(for x: Float, _ z: Float) -> Chunk {
        let ci = max(0, min(31, Int((x + 64) / 4)))
        let cj = max(0, min(31, Int((z + 64) / 4)))
        let key = cj * 32 + ci
        if let c = chunks[key] { return c }
        let c = Chunk()
        chunks[key] = c
        chunkList.append(c)
        root.addChild(c.node)
        return c
    }

    private func zFor(_ band: Band, _ x: Float, _ y: Float, _ z: Float) -> CGFloat {
        switch band {
        case .background: return ZBand.background + 5
        case .underBack: return ZBand.under
        case .underMid: return ZBand.under + 10
        case .underFront: return ZBand.under + 20
        // higher floors draw later; ramps / stairs in 0.25 m steps so a sloped run is a handful of draw calls
        case .floor: return ZBand.floor + (CGFloat(y) * 4).rounded() * 2.5
        case .floorDecal: return ZBand.floorDecal + 10
        case .farEdge: return ZBand.farEdge
        case .object: return ZBand.slice(Iso.nearness(x, y, z))
        case .nearEdge: return ZBand.nearEdge
        }
    }

    /// Place one lit piece (+ its LevelGlow layer when there is one). Returns nil if the frame is missing.
    @discardableResult
    private func place(_ name: String, set: String, _ x: Float, _ y: Float, _ z: Float, _ band: Band,
                       parent: SKNode? = nil, scale: CGFloat = 1) -> SKSpriteNode? {
        if !assets.has(name) {
            AppLog.error("level: missing piece \(name)")
            return nil
        }
        let info = assets.manifest.info(set)
        let full = CGSize(width: info.size.width * scale, height: info.size.height * scale)
        let node = SKSpriteNode(texture: nil)
        node.show(assets.sprite(name), size: full, anchor: info.anchor)
        if name.hasPrefix("girder_") || name.hasPrefix("pipes_") {
            // hang below the deck, outside the darkness overlay's station mask: darken them like the unlit deck
            node.color = LevelLayer.underTint
            node.colorBlendFactor = 1
        }
        let p = Iso.point(x, y, z)
        node.position = p
        node.zPosition = zFor(band, x, y, z)
        let frame = CGRect(x: p.x - node.anchorPoint.x * node.size.width, y: p.y - node.anchorPoint.y * node.size.height,
                           width: node.size.width, height: node.size.height)
        let target: SKNode
        var owner: Chunk? = nil
        if let parent = parent {
            target = parent
            if parent === liftNode { liftBounds = liftBounds.union(frame) }
        } else {
            let c = chunk(for: x, z)
            c.bounds = c.bounds.union(frame)
            target = c.node
            owner = c
        }
        target.addChild(node)
        nodeCount += 1
        let added = assets.has(name + "_g") ? 2 : 1
        if let c = owner { c.nodes += added } else if parent === liftNode { liftNodes += added } else { fixedNodes += added }
        if assets.has(name + "_g") {
            let g = SKSpriteNode(texture: nil)
            g.show(assets.sprite(name + "_g"), size: full, anchor: info.anchor)
            g.position = p
            g.blendMode = .add
            g.zPosition = band == .background ? node.zPosition + 0.5 : ZBand.glow
            // deck studs: small dim amber points in the web game, not white lamps
            if name.hasPrefix("stud_") { g.alpha = 0.35 }
            target.addChild(g)
            nodeCount += 1
        }
        return node
    }

    /// Flat glow pool on the floor (additive, above the darkness).
    private func pool(_ x: Float, _ z: Float, _ size: Float, _ hex: UInt32, _ k: Float) {
        glowPools.append((x, z, size, hex))
        let s = SKSpriteNode(texture: assets.texture("glow"))
        let gy = level.groundY(x, z)
        let p = Iso.point(x, gy, z)
        s.position = CGPoint(x: p.x, y: p.y / Iso.groundSquash)
        let d = CGFloat(size) * Iso.ppm
        s.size = CGSize(width: d, height: d)
        let c = Tone.linear(hex)
        s.color = Tone.color(c.0 * k, c.1 * k, c.2 * k)
        s.colorBlendFactor = 1
        s.blendMode = .add
        s.zPosition = ZBand.floorGlow
        groundRoot.addChild(s)
        nodeCount += 1
    }

    // ---------------------------------------------------------------- per-cell kinds
    private func rasterKinds() {
        let rects = level.layout.rects
        for (k, r) in rects.enumerated() {
            for j in 0..<GRID {
                let z = Float(j) - GRID_HALF + 0.5
                if !(z > r.z0 && z < r.z1) { continue }
                for i in 0..<GRID {
                    let x = Float(i) - GRID_HALF + 0.5
                    if x > r.x0 && x < r.x1 {
                        let c = j * GRID + i
                        kind[c] = r.kind == .slab ? 1 : 0
                        rectOf[c] = Int16(k)
                    }
                }
            }
        }
    }

    private func slopeAt(_ c: Int) -> Float {
        let k = Int(rectOf[c])
        if k < 0 || level.isLiftCell(c) { return 0 }
        return level.layout.rects[k].height.slope(atZ: Level.cellZ(c))
    }

    private func isAbyss(_ c: Int) -> Bool { level.walkValue(c) == 0 }

    // ---------------------------------------------------------------- snow mask (web buildSnowMask)
    private struct ValueNoise {
        var P: [Float]
        init(seed: UInt32) {
            var r = SeededRNG(seed: seed)
            var p = [Float](repeating: 0, count: 65536)
            for i in 0..<65536 { p[i] = r.next() }
            P = p
        }
        func sample(_ x: Float, _ z: Float) -> Float {
            let xf = x.rounded(.down), zf = z.rounded(.down)
            let xi = Int(xf), zi = Int(zf)
            let fx = x - xf, fz = z - zf
            let u = fx * fx * (3 - 2 * fx), v = fz * fz * (3 - 2 * fz)
            let a = P[((zi & 255) << 8) | (xi & 255)], b = P[((zi & 255) << 8) | ((xi + 1) & 255)]
            let c = P[(((zi + 1) & 255) << 8) | (xi & 255)], d = P[(((zi + 1) & 255) << 8) | ((xi + 1) & 255)]
            let ab = a + (b - a) * u, cd = c + (d - c) * u
            return ab + (cd - ab) * v
        }
    }

    /// Snow flag per grid vertex ((GRID+1)²).
    private func snowVertices() -> [UInt8] {
        let G = GRID
        var dist = [Float](repeating: 99, count: G * G)
        var q = [Int](repeating: 0, count: G * G)
        var qh = 0, qt = 0
        for c in 0..<(G * G) {
            let w = level.walkValue(c)
            if w == 0 { continue }
            let i = c % G, j = c / G
            var edge = w == 2
            if !edge {
                if i > 0 && level.walkValue(c - 1) == 0 { edge = true }
                if i < G - 1 && level.walkValue(c + 1) == 0 { edge = true }
                if j > 0 && level.walkValue(c - G) == 0 { edge = true }
                if j < G - 1 && level.walkValue(c + G) == 0 { edge = true }
            }
            if edge { dist[c] = 0; q[qt] = c; qt += 1 }
        }
        while qh < qt {
            let c = q[qh]; qh += 1
            let d = dist[c] + 1
            let i = c % G
            let nbs = [i > 0 ? c - 1 : -1, i < G - 1 ? c + 1 : -1, c - G, c + G]
            for n in nbs {
                if n < 0 || n >= G * G || level.walkValue(n) == 0 || dist[n] <= d { continue }
                dist[n] = d; q[qt] = n; qt += 1
            }
        }
        let n1 = ValueNoise(seed: 4), n2 = ValueNoise(seed: 9)
        var out = [UInt8](repeating: 0, count: (G + 1) * (G + 1))
        for vj in 1..<G {
            for vi in 1..<G {
                let x = Float(vi) - GRID_HALF, z = Float(vj) - GRID_HALF
                var sum: Float = 0, n: Float = 0
                for (di, dj) in [(-1, -1), (0, -1), (-1, 0), (0, 0)] {
                    let c = (vj + dj) * G + (vi + di)
                    if level.walkValue(c) == 0 { continue }
                    let d = min(dist[c] + 0.5, 12)
                    var v = n1.sample(x * 0.16, z * 0.16) * 0.55 + n2.sample(x * 0.6, z * 0.6) * 0.25 - 0.12
                    let t = max(0, min(1, d / 3.2))
                    v += (1 - t * t * (3 - 2 * t)) * 0.5
                    if kind[c] == 1 { v += 0.38 }
                    if level.isLiftCell(c) { v -= 0.25 }
                    sum += v; n += 1
                }
                if n > 0 && sum / n >= 0.5 { out[vj * (G + 1) + vi] = 1 }
            }
        }
        return out
    }

    // ---------------------------------------------------------------- floors, ramps, stairs
    private func buildFloors() {
        let G = GRID
        let snow = snowVertices()
        for j in 0..<G {
            for i in 0..<G {
                let c = j * G + i
                if level.walkValue(c) == 0 || level.isLiftCell(c) { continue }
                let x = Level.cellX(c), z = Level.cellZ(c)
                let h = level.groundY(x, z)
                let wi = Int(x.rounded(.down)), wj = Int(z.rounded(.down))
                let phase = (wi & 1) + 2 * (wj & 1)
                let g = slopeAt(c)
                if level.isStairCell(c), rectOf[c] >= 0, case .ramp(let a, let ha, let b, let hb, _) = level.layout.rects[Int(rectOf[c])].height {
                    let asc = hb > ha ? "s" : "n"
                    let n = max(1, Int((b - a).rounded()))
                    let k = hb > ha ? Int((z - a).rounded(.down)) : Int((b - z).rounded(.down))
                    let edge = k == 0 ? "_first" : (k == n - 1 ? "_last" : "")
                    place("stair_\(asc)_\(LevelLayer.code(g))\(edge)", set: "stairs", x, h, z, .floor)
                } else if abs(g) > 1e-4 {
                    let asc = g > 0 ? "s" : "n"
                    place("ramp_\(asc)_\(LevelLayer.code(g))_p\(phase)", set: "ramp_grating", x, h, z, .floor)
                } else {
                    let V = G + 1
                    let corners = Int(snow[j * V + i]) | Int(snow[j * V + i + 1]) << 1 | Int(snow[(j + 1) * V + i]) << 2 | Int(snow[(j + 1) * V + i + 1]) << 3
                    let k = kind[c] == 1 ? "s" : "g"
                    place("floor_\(k)_p\(phase)_c\(LevelLayer.two(corners))", set: kind[c] == 1 ? "floor_slab" : "floor_grating", x, h, z, .floor)
                }
            }
        }
    }

    // ---------------------------------------------------------------- rails, skirts, walls, hazard strips
    private func buildEdges() {
        let G = GRID
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if level.walkValue(c) == 0 || level.isLiftCell(c) { continue }
                let x = Level.cellX(c), z = Level.cellZ(c)
                let h = level.groundY(x, z)
                let g = slopeAt(c)
                let N = isAbyss(c - G), S = isAbyss(c + G), W = isAbyss(c - 1), E = isAbyss(c + 1)
                if !(N || S || W || E) { continue }
                let stairs = level.isStairCell(c)
                let k = kind[c] == 1 ? "s" : "g"
                // skirts / stair walls on the visible faces (+z, +x)
                if S {
                    let hs = h + g * 0.5
                    let name = (k == "s" && abs(g) < 1e-4) ? "side_s_s_000" : "side_s_g_000"
                    place(name, set: "sides", x, hs, z + 0.5, .underFront)
                }
                if E {
                    if stairs, rectOf[c] >= 0, case .ramp(let a, let ha, let b, let hb, _) = level.layout.rects[Int(rectOf[c])].height {
                        let asc = hb > ha ? "s" : "n"
                        let kk = hb > ha ? Int((z - a).rounded(.down)) : Int((b - z).rounded(.down))
                        let code = LevelLayer.code(abs(g))
                        place("wall_e_\(asc)_\(code)_\(LevelLayer.two(kk))", set: "wall_e_\(asc)_\(code)", x + 0.5, h, z, .underFront)
                    } else {
                        let name = (k == "s" && abs(g) < 1e-4) ? "side_e_s_000" : "side_e_g_\(LevelLayer.code(g))"
                        place(name, set: "sides", x + 0.5, h, z, .underFront)
                    }
                }
                // railings (outer corners of flat cells use one corner piece)
                var corner: String? = nil
                if abs(g) < 1e-4 {
                    if N && W { corner = "nw" } else if N && E { corner = "ne" } else if S && W { corner = "sw" } else if S && E { corner = "se" }
                }
                let rz = "rail_z_\(LevelLayer.code(g))"
                if let cn = corner {
                    let cx = x + (cn.hasSuffix("w") ? -0.38 : 0.38), cz = z + (cn.hasPrefix("n") ? -0.38 : 0.38)
                    let band: Band = cn == "nw" ? .farEdge : (cn == "se" ? .nearEdge : .object)
                    place("rail_corner_\(cn)", set: "rail_corner", cx, h, cz, band)
                    if N && S { place("rail_x_000", set: "rails", x, h, z + 0.5 - 0.12, .nearEdge) }
                    if W && E { place("rail_z_000", set: "rails", x + 0.5 - 0.12, h, z, .nearEdge) }
                } else {
                    if N { place("rail_x_000", set: "rails", x, h - g * 0.38, z - 0.5 + 0.12, .farEdge) }
                    if S { place("rail_x_000", set: "rails", x, h + g * 0.38, z + 0.5 - 0.12, .nearEdge) }
                    if W { place(rz, set: "rails", x - 0.5 + 0.12, h, z, .farEdge) }
                    if E { place(rz, set: "rails", x + 0.5 - 0.12, h, z, .nearEdge) }
                }
                // hazard stripes inside the railing of hazard platforms (flat)
                if level.isHazardCell(c) {
                    if N { place("haz_x", set: "hazard_strip", x, h, z - 0.5 + 0.54, .floorDecal) }
                    if S { place("haz_x", set: "hazard_strip", x, h, z + 0.5 - 0.54, .floorDecal) }
                    if W { place("haz_z", set: "hazard_strip", x - 0.5 + 0.54, h, z, .floorDecal) }
                    if E { place("haz_z", set: "hazard_strip", x + 0.5 - 0.54, h, z, .floorDecal) }
                }
            }
        }
    }

    // ---------------------------------------------------------------- posts + lamps along railing runs (web buildRailings)
    private struct Run { var horiz: Bool; var a: Float; var b: Float; var line: Float; var inward: Float }

    private func buildRailRunsAndLamps() {
        let G = GRID
        var hKeys: [String] = [], vKeys: [String] = []
        var hSegs: [String: [(Int, Float, Float)]] = [:], vSegs: [String: [(Int, Float, Float)]] = [:]
        func add(_ horiz: Bool, _ key: String, _ t: Int, _ line: Float, _ inward: Float) {
            if horiz {
                if hSegs[key] == nil { hSegs[key] = []; hKeys.append(key) }
                hSegs[key]!.append((t, line, inward))
            } else {
                if vSegs[key] == nil { vSegs[key] = []; vKeys.append(key) }
                vSegs[key]!.append((t, line, inward))
            }
        }
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if level.walkValue(c) == 0 || level.isLiftCell(c) { continue }
                let x = Float(i) - GRID_HALF, z = Float(j) - GRID_HALF
                if isAbyss(c - G) { add(true, "n\(j)", i, z + 0.12, 1) }
                if isAbyss(c + G) { add(true, "s\(j)", i, z + 1 - 0.12, -1) }
                if isAbyss(c - 1) { add(false, "w\(i)", j, x + 0.12, 1) }
                if isAbyss(c + 1) { add(false, "e\(i)", j, x + 1 - 0.12, -1) }
            }
        }
        var runs: [Run] = []
        for (horiz, keys) in [(true, hKeys), (false, vKeys)] {
            for key in keys {
                guard var segs = horiz ? hSegs[key] : vSegs[key], !segs.isEmpty else { continue }
                segs.sort { $0.0 < $1.0 }
                var s0 = segs[0].0, prev = s0
                var k = 1
                while k <= segs.count {
                    if k < segs.count && segs[k].0 == prev + 1 { prev = segs[k].0; k += 1; continue }
                    let last = segs[k - 1]
                    runs.append(Run(horiz: horiz, a: Float(s0) - GRID_HALF, b: Float(prev + 1) - GRID_HALF, line: last.1, inward: last.2))
                    if k < segs.count { s0 = segs[k].0; prev = s0 }
                    k += 1
                }
            }
        }
        var lampN = 0
        for r in runs {
            let len = r.b - r.a
            let band: Band = r.inward > 0 ? .farEdge : .nearEdge   // n / w runs face away from the camera
            func P(_ t: Float, _ off: Float = 0) -> (Float, Float) {
                r.horiz ? (r.a + t, r.line + off * r.inward) : (r.line + off * r.inward, r.a + t)
            }
            func H(_ t: Float) -> Float {
                let p = P(max(0.02, min(len - 0.02, t)), 0.3)
                return level.groundY(p.0, p.1)
            }
            let nPosts = max(1, Int((len / 2).rounded()))
            for k in 0...nPosts {
                let t = Float(k) * len / Float(nPosts)
                let p = P(t)
                place("rail_post", set: "rail_post", p.0, H(t), p.1, band)
            }
            if len >= 6 {
                var t: Float = 3
                while t < len - 1 {
                    let p = P(t), y = H(t)
                    let dir = r.horiz ? (r.inward > 0 ? "s" : "n") : (r.inward > 0 ? "e" : "w")
                    let green = lampN % 3 == 2
                    lampN += 1
                    place("lamp_\(dir)_\(green ? "green" : "teal")", set: "lamps", p.0, y, p.1, band)
                    let ix: Float = r.horiz ? 0 : r.inward, iz: Float = r.horiz ? r.inward : 0
                    pool(p.0 + ix * 1.5, p.1 + iz * 1.5, 3.0, green ? 0x3dff9a : 0x29f2da, 0.3)
                    t += 12
                }
            }
        }
    }

    // ---------------------------------------------------------------- supports + girders (web buildSupports)
    private var towerRng = SeededRNG(seed: 31)
    private static let underTint = SKColor(red: 0.32, green: 0.36, blue: 0.46, alpha: 1)

    private func buildSupports() {
        var R = SeededRNG(seed: 31)
        for r in level.layout.rects {
            let w = r.x1 - r.x0, d = r.z1 - r.z0
            let nx = max(1, Int((w / 9).rounded())), nz = max(1, Int((d / 9).rounded()))
            var cols: [(Float, Float)] = []
            for a in 0...nx {
                for b in 0...nz {
                    if a != 0 && a != nx && b != 0 && b != nz { continue }
                    cols.append((r.x0 + 1 + (w - 2) * Float(a) / Float(nx), r.z0 + 1 + (d - 2) * Float(b) / Float(nz)))
                }
            }
            for (x, z) in cols {
                let top = r.height.height(atZ: z) - 0.5
                _ = R.next()                      // column height
                var light = false
                if R.next() < 0.35 { light = true; _ = R.next() }
                place(light ? "support_1" : "support_0", set: "support", x, top, z, .underBack)
            }
            if w > 10 && d > 10 {
                let y = r.height.minHeight - 6
                var x = r.x0 + 1
                while x < r.x1 - 1 {
                    place("girder_x", set: "girder", x + 0.5, y, r.z0 + 1, .underBack)
                    place("girder_x", set: "girder", x + 0.5, y, r.z1 - 1, .underBack)
                    x += 1
                }
            }
        }
        towerRng = R
    }

    // ---------------------------------------------------------------- props (web buildProps)
    private func crateName(_ w: Int, _ d: Int, _ h: Float, _ col: Int) -> String? {
        let letter = ["a", "b", "c"][max(0, min(2, col))]
        let base = Int((h * 10).rounded())
        for delta in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5] {
            let name = "crate_\(w)x\(d)_\(base + delta)_\(letter)"
            if assets.has(name) { return name }
        }
        return nil
    }

    private func buildProps() {
        let L = level.layout
        var R = SeededRNG(seed: 57)
        for cr in L.crates {
            let cx = cr.x0 + Float(cr.w) / 2, cz = cr.z0 + Float(cr.d) / 2, y = level.groundY(cx, cz)
            let col = min(2, Int(R.next() * 3))
            _ = R.next()   // rotation jitter
            if let name = crateName(cr.w, cr.d, cr.h, col) {
                place(name, set: "crate_\(cr.w)x\(cr.d)", cx, y, cz, .object)
            }
            if R.next() < 0.6 {
                let ox = (R.next() - 0.5) * Float(cr.w)
                let seed = Int(R.next() * 1e6)
                place("mound_\(seed & 1)", set: "snow", cx + ox, y, cz + Float(cr.d) / 2 + 0.25, .floorDecal)
            }
        }
        for p in L.pillars {
            let y = level.groundY(p.x, p.y)
            place("pillar", set: "pillar", p.x, y, p.y, .object)
            pool(p.x, p.y, 3.2, 0x29f2da, 0.3)
        }
        // snow drifts against the railings
        let radii: [Float] = [0.7, 0.85, 1.0, 1.2]
        let en = level.edgeCount
        if en > 0 {
            for _ in 0..<90 {
                let e = min(en - 1, Int(R.next() * Float(en)))
                let x = level.edgeX[e] - level.edgeNX[e] * 0.1, z = level.edgeZ[e] - level.edgeNZ[e] * 0.1
                if level.isLiftCell(level.cellOf(x, z)) { continue }
                let r = (0.5 + R.next() * 0.5) * 1.3
                var best = 0
                for k in 1..<radii.count where abs(radii[k] - r) < abs(radii[best] - r) { best = k }
                place("drift_\(best)", set: "snow", x, level.groundY(x, z), z, .floorDecal)
            }
        }
        for v in L.vents {
            place("vent", set: "vent", v.x, level.groundY(v.x, v.y), v.y, .floorDecal)
            pool(v.x, v.y, 2.6, 0xff5a1a, 0.3)
        }
        for b in L.beacons {
            place("beacon_base", set: "beacon_base", b.x, level.groundY(b.x, b.z), b.z, .object)
        }
        // landing pad: edge studs + the painted mark
        let s = L.start
        let px0 = s.x - 7.4, pz0 = s.y - 7.4, px1 = s.x + 7.4, pz1 = s.y + 7.4
        for k in 0..<8 {
            let t = Float(k) * 2
            for (x, z) in [(px0 + t, pz0), (px0 + t, pz1), (px0, pz0 + t), (px1, pz0 + t)] {
                place("stud_amber", set: "studs", x, level.groundY(x, z), z, .floorDecal)
            }
        }
        if assets.has("pad_mark") {
            let m = SKSpriteNode(texture: assets.texture("pad_mark"))
            let p = Iso.point(s.x, level.groundY(s.x, s.y), s.y)
            m.position = CGPoint(x: p.x, y: p.y / Iso.groundSquash)
            m.size = CGSize(width: 11 * Iso.ppm, height: 11 * Iso.ppm)
            m.zRotation = Iso.groundRotation(0)
            m.zPosition = ZBand.floorDecal + 5
            groundRoot.addChild(m)
            nodeCount += 1
        }
        // pipe bundles hanging off a few platform sides
        for pr in L.pipes {
            if abs(pr.z0 - pr.z1) < 0.01 {
                let floorNorth = level.walkValue(level.cellOf((pr.x0 + pr.x1) / 2, pr.z0 - 0.5)) != 0
                let side = floorNorth ? "s" : "n"
                let edgeZ = floorNorth ? pr.z0 - 0.3 : pr.z0 + 0.3
                var x = min(pr.x0, pr.x1)
                while x < max(pr.x0, pr.x1) - 0.01 {
                    place("pipes_\(side)", set: "pipes", x + 0.5, pr.h, edgeZ, .underMid)
                    x += 1
                }
            } else {
                let floorWest = level.walkValue(level.cellOf(pr.x0 - 0.5, (pr.z0 + pr.z1) / 2)) != 0
                let side = floorWest ? "e" : "w"
                let edgeX = floorWest ? pr.x0 - 0.3 : pr.x0 + 0.3
                var z = min(pr.z0, pr.z1)
                while z < max(pr.z0, pr.z1) - 0.01 {
                    place("pipes_\(side)", set: "pipes", edgeX, pr.h, z + 0.5, .underMid)
                    z += 1
                }
            }
        }
    }

    // ---------------------------------------------------------------- the cargo lift
    private func buildLift() {
        let L = level.lift
        place("lift_shaft", set: "lift_shaft", L.x, L.y, L.z, .underMid, parent: liftNode)
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * Float.pi
            place("support_0", set: "support", L.x + cosf(a) * 10.9, L.y - 0.5, L.z + sinf(a) * 10.9, .underBack, parent: liftNode)
        }
        if let deck = place("lift_deck", set: "lift_deck", L.x, L.y, L.z, .floor, parent: liftNode) {
            deck.zPosition = ZBand.floor + CGFloat(L.y) * 10 - 1
        }
        place("lift_center", set: "lift_center", L.x, L.y, L.z, .object, parent: liftNode)
        for s in 0..<12 {
            let name = "lift_rail_\(LevelLayer.two(s))"
            let off = assets.manifest.liftRailOffsets[name] ?? (0, 0)
            place(name, set: "lift_rail", L.x + off.0, L.y, L.z + off.1, .object, parent: liftNode)
        }
    }

    // ---------------------------------------------------------------- background: haze + distant towers
    private func buildBackground() {
        let haze = SKSpriteNode(texture: assets.texture("bg_haze"))
        let hp = Iso.point(0, -16, -5)
        haze.position = CGPoint(x: hp.x, y: hp.y / Iso.groundSquash)
        haze.size = CGSize(width: 220 * Iso.ppm, height: 220 * Iso.ppm)
        haze.zRotation = Iso.groundRotation(0)
        haze.zPosition = ZBand.background
        groundRoot.addChild(haze)
        nodeCount += 1
        var R = towerRng
        for k in 0..<14 {
            let a = Float(k) / 14 * 2 * Float.pi + R.next() * 0.3
            let d = 74 + R.next() * 26
            let top = -8 + R.next() * 30
            _ = R.next(); _ = R.next(); _ = R.next()
            for _ in 0..<12 { _ = R.next() }
            let x = cosf(a) * d, z = -5 + sinf(a) * d
            place("bg_tower_\(k % 6)", set: "bg_tower", x, top, z, .background, parent: backgroundNode, scale: 4)
        }
    }

    // ---------------------------------------------------------------- per frame
    /// Hide chunks outside the visible rect (world points); `liftRise` in metres.
    func update(visible: CGRect, liftRise: Float) {
        var n = 0, live = fixedNodes
        for c in chunkList {
            let show = c.bounds.intersects(visible)
            if c.node.isHidden == show { c.node.isHidden = !show }
            if show { n += 1; live += c.nodes }
        }
        visibleChunks = n
        let dy = CGFloat(liftRise * Iso.cosPitch) * Iso.ppm
        liftNode.position = CGPoint(x: 0, y: dy)
        let lb = liftBounds.offsetBy(dx: 0, dy: dy)
        let showLift = lb.intersects(visible)
        if liftNode.isHidden == showLift { liftNode.isHidden = !showLift }
        liveNodeCount = live + (showLift ? liftNodes : 0)
    }
}
