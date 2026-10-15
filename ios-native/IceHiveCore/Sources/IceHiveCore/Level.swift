import Foundation

// ================================================================
//  LEVEL — «Станция Кельвин-9» (port of 04-level.js, simulation part)
//  The layout is plain data (`LevelLayout`) produced by a `LevelSource`;
//  `Level` rasterises it into the 128×128 walk grid + height field and
//  answers the queries the simulation and the renderer need.
//  A procedural station generator (v1.1) only has to implement
//  `LevelSource` and return another `LevelLayout`.
// ================================================================

public enum FloorKind: Int {
    /// Grated metal deck.
    case grating
    /// Snowy concrete slab.
    case slab
}

/// Height of a floor rect: flat, or a ramp along z (`ha` for z <= a, `hb` for z >= b, linear between).
public enum FloorHeight {
    case flat(Float)
    case ramp(a: Float, ha: Float, b: Float, hb: Float, stairs: Bool)

    public func height(atZ z: Float) -> Float {
        switch self {
        case .flat(let h): return h
        case .ramp(let a, let ha, let b, let hb, _):
            if z <= a { return ha }
            if z >= b { return hb }
            return ha + (hb - ha) * (z - a) / (b - a)
        }
    }
    /// dy/dz at z.
    public func slope(atZ z: Float) -> Float {
        switch self {
        case .flat: return 0
        case .ramp(let a, let ha, let b, let hb, _):
            if z <= a || z >= b { return 0 }
            return (hb - ha) / (b - a)
        }
    }
    public var minHeight: Float {
        switch self {
        case .flat(let h): return h
        case .ramp(_, let ha, _, let hb, _): return min(ha, hb)
        }
    }
    public var isStairs: Bool {
        if case .ramp(_, _, _, _, let s) = self { return s }
        return false
    }
}

/// Axis-aligned floor rectangle (cells whose centre lies strictly inside become floor).
public struct FloorRect {
    public var x0: Float, z0: Float, x1: Float, z1: Float
    public var kind: FloorKind
    public var hazard: Bool
    public var height: FloorHeight
    public init(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float, _ kind: FloorKind, _ hazard: Bool, _ height: FloorHeight) {
        self.x0 = x0; self.z0 = z0; self.x1 = x1; self.z1 = z1; self.kind = kind; self.hazard = hazard; self.height = height
    }
}

/// Crate: x0, z0 (cell corner), w × d cells, visual height h. Covered cells are blocked.
public struct CrateSpec {
    public var x0: Float, z0: Float, w: Int, d: Int, h: Float
    public init(_ x0: Float, _ z0: Float, _ w: Int, _ d: Int, _ h: Float) { self.x0 = x0; self.z0 = z0; self.w = w; self.d = d; self.h = h }
}

public struct BeaconSite {
    public var x: Float, z: Float
    public var name: String
    public init(x: Float, z: Float, name: String) { self.x = x; self.z = z; self.name = name }
}

public struct LiftSpec {
    public var x: Float, z: Float, r: Float, y: Float
    public init(x: Float, z: Float, r: Float, y: Float) { self.x = x; self.z = z; self.r = r; self.y = y }
}

/// Visual-only pipe bundle hanging off a platform side: x0, z0, x1, z1, platform height.
public struct PipeRun {
    public var x0: Float, z0: Float, x1: Float, z1: Float, h: Float
    public init(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float, _ h: Float) { self.x0 = x0; self.z0 = z0; self.x1 = x1; self.z1 = z1; self.h = h }
}

/// Everything that defines a station. Pure data: the renderer builds its geometry from the same values.
public struct LevelLayout {
    public var name: String
    public var seed: UInt32
    public var rects: [FloorRect]
    public var crates: [CrateSpec]
    public var pillars: [Vec2]
    public var start: Vec2
    public var lift: LiftSpec
    public var beacons: [BeaconSite]
    public var vents: [Vec2]
    public var pipes: [PipeRun]
    /// Stair tread depth (visual).
    public var stepDepth: Float = 0.5
}

/// Source of a station layout. v1.0 ships the fixed «Кельвин-9»; v1.1 adds a seeded generator.
public protocol LevelSource {
    func makeLayout(seed: UInt32) -> LevelLayout
}

/// The hand-made v1.0 station (04-level.js RECTS / CRATES / PILLARS / LV).
public struct KelvinStation: LevelSource {
    public init() {}
    public static let liftY: Float = -6

    public func makeLayout(seed: UInt32) -> LevelLayout {
        let LY = KelvinStation.liftY
        let rects: [FloorRect] = [
            FloorRect(22, 22, 38, 38, .slab, true, .flat(0)),        // landing pad
            FloorRect(6, 27, 22, 33, .grating, false, .flat(0)),
            FloorRect(-8, 18, 6, 38, .grating, false, .flat(0)),     // hub
            FloorRect(-24, 25, -8, 31, .grating, false, .flat(0)),
            FloorRect(-40, 18, -24, 36, .grating, true, .flat(0)),   // beacon A
            FloorRect(-4, 2, 2, 18, .slab, false, .ramp(a: 5, ha: -3, b: 15, hb: 0, stairs: true)),     // staircase hub -> plaza
            FloorRect(-12, -12, 10, 2, .grating, false, .flat(-3)),  // plaza
            FloorRect(10, -8, 22, -2, .grating, false, .flat(-3)),
            FloorRect(22, -16, 38, 0, .grating, true, .flat(-3)),    // beacon B
            FloorRect(-26, -9, -12, -3, .grating, false, .flat(-3)),
            FloorRect(-42, -18, -26, 0, .grating, true, .flat(-3)),  // beacon C
            FloorRect(-6, -32.5, 0, -12, .slab, false, .ramp(a: -29, ha: LY, b: -15, hb: -3, stairs: true)),  // staircase down to the lift
            FloorRect(-36, 0, -32, 18, .grating, false, .ramp(a: 1, ha: -3, b: 17, hb: 0, stairs: false)),   // west loop catwalk (sloped)
            FloorRect(30, 0, 34, 22, .grating, false, .ramp(a: 1, ha: -3, b: 21, hb: 0, stairs: false)),     // east loop catwalk (sloped)
        ]
        let crates: [CrateSpec] = [
            CrateSpec(24, 35, 1, 1, 1.2), CrateSpec(25, 35, 1, 1, 0.9), CrateSpec(24, 34, 1, 1, 0.9), CrateSpec(35, 23, 2, 1, 1.0), CrateSpec(36, 24, 1, 1, 1.3),
            CrateSpec(-7, 20, 1, 1, 1.1), CrateSpec(-6, 20, 1, 1, 0.8), CrateSpec(4, 35, 2, 1, 1.0), CrateSpec(3, 22, 1, 2, 1.2),
            CrateSpec(-10, -10, 2, 1, 1.1), CrateSpec(-10, -9, 1, 1, 0.8), CrateSpec(7, -10, 1, 1, 1.2), CrateSpec(8, -1, 2, 1, 0.9), CrateSpec(-11, 0, 1, 1, 1.0),
            CrateSpec(3, -6, 1, 1, 0.9), CrateSpec(-4, -4, 2, 2, 1.4),
            CrateSpec(-39, 19, 1, 1, 1.0), CrateSpec(-26, 34, 2, 1, 1.1), CrateSpec(-38, 33, 1, 2, 1.2),
            CrateSpec(23, -15, 1, 1, 1.1), CrateSpec(36, -2, 1, 1, 0.9), CrateSpec(35, -15, 2, 1, 1.0),
            CrateSpec(-41, -17, 1, 1, 1.2), CrateSpec(-28, -2, 1, 1, 1.0), CrateSpec(-40, -3, 2, 1, 0.9),
        ]
        let pillars: [Vec2] = [
            Vec2(23.5, 23.5), Vec2(36.5, 36.5), Vec2(-6.5, 36.5), Vec2(-11.5, -11.5), Vec2(9.5, -11.5), Vec2(9.5, 1.5), Vec2(-11.5, 1.5),
            Vec2(-39.5, 35.5), Vec2(-24.5, 18.5), Vec2(37.5, -15.5), Vec2(22.5, -0.5), Vec2(-41.5, -17.5), Vec2(-26.5, -0.5),
        ]
        let vents: [Vec2] = [Vec2(-27, 21), Vec2(-37, 33), Vec2(26, -13), Vec2(35, -3), Vec2(-39, -14), Vec2(-29, -4), Vec2(7, -9), Vec2(-9, -1)]
        let pipes: [PipeRun] = [PipeRun(-8, 38.3, 6, 38.3, 0), PipeRun(-12, -12.3, -6, -12.3, -3), PipeRun(22, -16.3, 38, -16.3, -3),
                                PipeRun(-42, -18.3, -26, -18.3, -3), PipeRun(38.3, 22, 38.3, 38, 0)]
        return LevelLayout(
            name: "Станция Кельвин-9", seed: seed, rects: rects, crates: crates, pillars: pillars,
            start: Vec2(30, 30), lift: LiftSpec(x: -3, z: -42, r: 10, y: LY),
            beacons: [BeaconSite(x: -32, z: 27, name: "Альфа"), BeaconSite(x: 30, z: -8, name: "Бета"), BeaconSite(x: -34, z: -9, name: "Гамма")],
            vents: vents, pipes: pipes)
    }
}

/// Walk-grid cell values.
public enum WalkCell: UInt8 {
    case abyss = 0, floor = 1, blocked = 2
}

/// Rasterised station: walk grid, height field, spawn edges and queries.
public final class Level {
    public let layout: LevelLayout
    /// 0 abyss, 1 floor, 2 floor blocked by a prop (G*G).
    let walk: UnsafeMutablePointer<UInt8>
    /// 1 = part of the lift disc.
    let liftCell: UnsafeMutablePointer<UInt8>
    /// 1 = hazard-striped platform (beacons / pad).
    let hazCell: UnsafeMutablePointer<UInt8>
    /// 1 = stepped staircase.
    let stairCell: UnsafeMutablePointer<UInt8>
    /// Floor height at the cell centre.
    let hgt: UnsafeMutablePointer<Float>
    /// dy/dz inside the cell (ramps run along z).
    let hgz: UnsafeMutablePointer<Float>

    /// Abyss-adjacent floor cells: bugs climb over the railing there. Normal points outward (toward the abyss).
    public private(set) var edgeX: [Float] = []
    public private(set) var edgeZ: [Float] = []
    public private(set) var edgeNX: [Float] = []
    public private(set) var edgeNZ: [Float] = []
    public var edgeCount: Int { edgeX.count }

    public var lift: LiftSpec { layout.lift }
    public var start: Vec2 { layout.start }

    public convenience init(source: LevelSource = KelvinStation(), seed: UInt32 = 0) {
        self.init(layout: source.makeLayout(seed: seed))
    }

    public init(layout: LevelLayout) {
        self.layout = layout
        let n = GRID * GRID
        walk = .allocate(capacity: n); walk.initialize(repeating: 0, count: n)
        liftCell = .allocate(capacity: n); liftCell.initialize(repeating: 0, count: n)
        hazCell = .allocate(capacity: n); hazCell.initialize(repeating: 0, count: n)
        stairCell = .allocate(capacity: n); stairCell.initialize(repeating: 0, count: n)
        hgt = .allocate(capacity: n); hgt.initialize(repeating: 0, count: n)
        hgz = .allocate(capacity: n); hgz.initialize(repeating: 0, count: n)
        raster()
    }

    deinit {
        walk.deallocate(); liftCell.deallocate(); hazCell.deallocate(); stairCell.deallocate(); hgt.deallocate(); hgz.deallocate()
    }

    // ---------- raster (rasterLevel + the beacon bases from buildProps) ----------
    private func raster() {
        let G = GRID
        let n = G * G
        var hset = [UInt8](repeating: 0, count: n)
        for r in layout.rects {
            for j in 0..<G {
                let z = Float(j) - GRID_HALF + 0.5
                if !(z > r.z0 && z < r.z1) { continue }
                for i in 0..<G {
                    let x = Float(i) - GRID_HALF + 0.5
                    if x > r.x0 && x < r.x1 {
                        let c = j * G + i
                        walk[c] = 1
                        if r.hazard { hazCell[c] = 1 }
                        hgt[c] = r.height.height(atZ: z); hgz[c] = r.height.slope(atZ: z); hset[c] = 1
                        if case .ramp(let a, _, let b, _, let stairs) = r.height, stairs, z > a, z < b { stairCell[c] = 1 }
                    }
                }
            }
        }
        let L = layout.lift
        let lr = (L.r - 0.3) * (L.r - 0.3)
        for j in 0..<G {
            for i in 0..<G {
                let x = Float(i) - GRID_HALF + 0.5, z = Float(j) - GRID_HALF + 0.5
                if (x - L.x) * (x - L.x) + (z - L.z) * (z - L.z) < lr {
                    let c = j * G + i
                    walk[c] = 1; liftCell[c] = 1; hgt[c] = L.y; hgz[c] = 0; hset[c] = 1
                }
            }
        }
        // abyss cells next to floors inherit the floor height (climbing bugs, effects and lasers at the edges)
        for _ in 0..<4 {
            var add: [(Int, Int)] = []
            for c in G..<(G * (G - 1)) {
                if hset[c] != 0 { continue }
                for nb in [c - 1, c + 1, c - G, c + G] where hset[nb] != 0 {
                    add.append((c, nb)); break
                }
            }
            for (c, nb) in add {
                hgt[c] = hgt[nb] + hgz[nb] * (Level.cellZ(c) - Level.cellZ(nb)); hgz[c] = hgz[nb]; hset[c] = 1
            }
        }
        for cr in layout.crates {
            for a in 0..<cr.w {
                for b in 0..<cr.d {
                    let c = cellOf(cr.x0 + Float(a) + 0.5, cr.z0 + Float(b) + 0.5)
                    if c >= 0 { walk[c] = 2 }
                }
            }
        }
        for p in layout.pillars { let c = cellOf(p.x, p.y); if c >= 0 { walk[c] = 2 } }
        // abyss-adjacent floor cells become spawn edges
        var ex: [Float] = [], ez: [Float] = [], enx: [Float] = [], enz: [Float] = []
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if walk[c] != 1 { continue }
                var nx: Float = 0, nz: Float = 0
                if walk[c - 1] == 0 { nx -= 1 }
                if walk[c + 1] == 0 { nx += 1 }
                if walk[c - G] == 0 { nz -= 1 }
                if walk[c + G] == 0 { nz += 1 }
                if nx == 0 && nz == 0 { continue }
                let l = hypotf2(nx, nz)
                ex.append(Float(i) - GRID_HALF + 0.5); ez.append(Float(j) - GRID_HALF + 0.5); enx.append(nx / l); enz.append(nz / l)
            }
        }
        edgeX = ex; edgeZ = ez; edgeNX = enx; edgeNZ = enz
        // beacon bases (2×2 cells) block movement (buildProps in the web game, after the edge pass)
        for b in layout.beacons {
            for (ox, oz) in [(-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5)] as [(Float, Float)] {
                let c = cellOf(b.x + ox, b.z + oz)
                if c >= 0 { walk[c] = 2 }
            }
        }
    }

    // ---------- queries ----------
    /// Cell index of a world point, or -1 outside the grid.
    @inline(__always) public func cellOf(_ x: Float, _ z: Float) -> Int {
        let fx = x + GRID_HALF, fz = z + GRID_HALF
        if !(fx >= 0 && fx < Float(GRID) && fz >= 0 && fz < Float(GRID)) { return -1 }
        return Int(fz) * GRID + Int(fx)
    }
    /// Cell index clamped into the grid (NaN-safe).
    @inline(__always) public func cellClamp(_ x: Float, _ z: Float) -> Int { Level.cellClamp(x, z) }
    @inline(__always) static func cellClamp(_ x: Float, _ z: Float) -> Int {
        let fx = x + GRID_HALF, fz = z + GRID_HALF
        let i: Int = !(fx >= 0) ? 0 : (fx >= Float(GRID - 1) ? GRID - 1 : Int(fx))
        let j: Int = !(fz >= 0) ? 0 : (fz >= Float(GRID - 1) ? GRID - 1 : Int(fz))
        return j * GRID + i
    }
    @inline(__always) public static func cellX(_ c: Int) -> Float { Float(c % GRID) - GRID_HALF + 0.5 }
    @inline(__always) public static func cellZ(_ c: Int) -> Float { Float(c / GRID) - GRID_HALF + 0.5 }

    /// Raw walk value of a cell (0 abyss, 1 floor, 2 blocked).
    @inline(__always) public func walkValue(_ c: Int) -> UInt8 { (c >= 0 && c < GRID * GRID) ? walk[c] : 0 }
    @inline(__always) public func walkable(_ x: Float, _ z: Float) -> Bool {
        let c = cellOf(x, z)
        return c >= 0 && walk[c] == 1
    }
    /// Floor or prop (anything that is not abyss).
    @inline(__always) public func solid(_ x: Float, _ z: Float) -> Bool {
        let c = cellOf(x, z)
        return c >= 0 && walk[c] != 0
    }
    /// A marine (radius ~0.32) fits here.
    @inline(__always) public func canStand(_ x: Float, _ z: Float) -> Bool {
        walkable(x, z) && walkable(x + 0.32, z) && walkable(x - 0.32, z) && walkable(x, z + 0.32) && walkable(x, z - 0.32)
    }
    /// Visual ground height at any world point (exact on ramps; abyss cells near floors inherit the floor height).
    @inline(__always) public func groundY(_ x: Float, _ z: Float) -> Float {
        let c = cellOf(x, z)
        if c < 0 { return 0 }
        return hgt[c] + hgz[c] * (z - (Float(c / GRID) - GRID_HALF + 0.5))
    }
    public func isLiftCell(_ c: Int) -> Bool { c >= 0 && c < GRID * GRID && liftCell[c] != 0 }
    public func isHazardCell(_ c: Int) -> Bool { c >= 0 && c < GRID * GRID && hazCell[c] != 0 }
    public func isStairCell(_ c: Int) -> Bool { c >= 0 && c < GRID * GRID && stairCell[c] != 0 }
    /// Inside the lift deck (the lift leaves with whoever stands here).
    @inline(__always) public func onLift(_ x: Float, _ z: Float) -> Bool {
        let L = layout.lift
        return (x - L.x) * (x - L.x) + (z - L.z) * (z - L.z) < (L.r - 0.6) * (L.r - 0.6)
    }
}
