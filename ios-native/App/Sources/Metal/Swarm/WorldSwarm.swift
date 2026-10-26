import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD SWARM — the live bugs and their corpses (owned by WP3 «Рой»).
//  Every frame: each visible bug of the core's swarm (CPU frustum cull)
//  gets its clip rows from SwarmAnimator (gait synced to the distance
//  walked, attack lunge, hit recoil with a lean away from the impact,
//  wind-up / charge / spit / swell on the core's state timers), its
//  value / hue variation, hit flash, burn, frost; each corpse its death
//  clip (Corpses.swift). Then one LOD per instance (IHV1 LOD0 ≤ 3000 /
//  LOD1 ≤ 450 / LOD2 ≤ 150 triangles) by its size on screen under the
//  tier's caps — High: LOD0 for ≤ 32 of the largest (close-ups,
//  brutes), LOD1 for ≤ 600, LOD2 beyond; Efficient: LOD1 ≤ 300, the
//  rest LOD2; both under a triangle budget of 250 / 170 per bug at
//  1400 bugs (350k / 238k), with hysteresis so nothing flickers. A
//  bug that dies keeps its mesh and LOD into its death clip.
//  Draws: opaque item 300 one instanced draw per type × LOD (≤ 12;
//  creature buffers from IHVLoader, Swarm.metal vs_creature /
//  fs_chitin); transparent item 400 ONE draw of gland glints (the
//  dorsal pores of every live bug as HDR dots at their socket points);
//  shadow casters item 200 the 20-triangle proxies of the bugs inside
//  the flashlight cones (the player's on every tier, the squad's when
//  the world says shadows are on). Once a second (diagnostics):
//  `hb swarm vis=… lod=a/b/c tris=…k corpses=… glints=… proxies=…`.
//  Look-dev: `-bugsheet [scale]` every type × clip around the camera
//  focus (studio light; `-bugsheetGame` without; `-bugsheetT <s>` holds
//  the clips at s), `-bugstrip <type> [scale]` one type's clips × 8
//  frames — both at LOD0 —, `-swarmLOD 0|1|2` forces a LOD (pop A/B),
//  `-noGlints`.
// ================================================================

/// One creature in a draw (`struct CreatureInstance` in SwarmTypes.h, 80 bytes).
struct CreatureInstance {
    /// xyz feet (world), w = horizontal scale.
    var pos: F4
    /// cos(heading), sin(heading), sin(pitch), cos(pitch).
    var rot: F4
    /// rgb albedo tint, w = vertical scale.
    var tint: F4
    /// x clip A rows, y clip B rows, z fracs (unorm16 ×2), w = weight B | type << 16 | flags << 24.
    var anim: SIMD4<UInt32>
    /// x state unorm8 ×4 (hit, burn, frost, dead), y lean snorm16 ×2, z seed | glow boost, w 0.
    var fx: SIMD4<UInt32>
}

/// Per type constants (`struct SwarmType`, 96 bytes).
struct SwarmTypeGPU {
    var rim: F4, eye: F4, sac: F4, gland: F4, proxy: F4
    var glint: SIMD4<UInt32>
}

/// `struct SwarmParams` (416 bytes).
struct SwarmParams {
    var types: (SwarmTypeGPU, SwarmTypeGPU, SwarmTypeGPU, SwarmTypeGPU)
    var info: F4
    var queen: F4
}

/// `struct GlintSocket` (32 bytes).
struct GlintSocket {
    var pos: F4
    var info: F4
}

final class WorldSwarm {
    static let pipelines: [PipelineSpec] = [
        .world("creature", "vs_creature", "fs_chitin", .none, nil, required: true),
        .world("swarmGlint", "vs_swarm_glint", "fs_swarm_glint", .add),
        .depthOnly("creatureProxy", "vs_creature_proxy"),
    ]
    /// Instances per type the scratch holds (live bugs + corpses + sheet).
    static let scratchCap = MAX_BUGS + 640
    /// Glint sprites per bug at most (the brightest dorsal pores), and per frame.
    static let glintsPerBug = 6
    static let glintCap = (high: 16000, efficient: 8000)
    /// LOD caps (High: LOD0 32 largest, LOD1 600; Efficient: LOD1 300) and the triangle budget (per bug at 1400).
    static let lod0Cap = 32, lod1Cap = (high: 600, efficient: 300)
    static let triBudget = (high: 250 * 1400, efficient: 170 * 1400)
    /// LOD0 only at ≥ this body length on screen (drawable px); LOD1 not below this.
    static let lod0MinPx: Float = 64, lod1MinPx: Float = 9
    static let shadowProxyMax = (high: 600, efficient: 300)

    /// The look of each type (linear radiance): cold Fresnel rim, eyes, sac, pores, shadow proxy (half size, centre
    /// height, model m). Crisp's one-hue-per-type rims on dark wet chitin: runner plum-pink, spitter acid chartreuse,
    /// brute ember, boomer amber; the pores pink-white on every type. Class hues never appear on a bug.
    static let looks: [(rim: F4, eye: F4, sac: F4, gland: F4, proxy: F4)] = [
        (F4(0.62, 0.14, 0.36, 0.22), F4(1.0, 0.16, 0.42, 1.3), F4(0.6, 0.05, 0.16, 0.0), F4(1.0, 0.16, 0.46, 2.0), F4(0.22, 0.12, 0.55, 0.27)),
        (F4(0.42, 0.62, 0.06, 0.2), F4(0.75, 1.0, 0.18, 1.3), F4(0.42, 0.78, 0.05, 0.3), F4(1.0, 0.16, 0.46, 2.0), F4(0.3, 0.22, 0.5, 0.45)),
        (F4(0.78, 0.30, 0.07, 0.18), F4(1.0, 0.42, 0.08, 1.5), F4(0.7, 0.1, 0.2, 0.15), F4(1.0, 0.16, 0.46, 2.0), F4(0.42, 0.3, 0.62, 0.4)),
        (F4(0.85, 0.46, 0.09, 0.17), F4(1.0, 0.6, 0.14, 1.3), F4(0.95, 0.4, 0.07, 0.25), F4(1.0, 0.16, 0.46, 2.0), F4(0.4, 0.36, 0.46, 0.45)),
    ]
    /// Ichor of each type (WP5's impact sparks / splashes; MetalEffects.ichor).
    static let ichor: [F3] = [F3(0.62, 0.1, 0.22), F3(0.5, 0.58, 0.1), F3(0.58, 0.12, 0.15), F3(0.62, 0.24, 0.08)]

    let level: Level
    private var renderer: MetalRenderer!
    private(set) var library: CreatureLibrary?
    private var animator: SwarmAnimator?
    private var psCreature: MTLRenderPipelineState?, psGlint: MTLRenderPipelineState?, psProxy: MTLRenderPipelineState?
    private var proxyVB: MTLBuffer?, proxyIB: MTLBuffer?
    private var proxyIndexCount = 0
    // per type scratch: instances, screen size, LOD hint / choice, animator slot (-1 corpse)
    private var scratch: [UnsafeMutablePointer<CreatureInstance>] = []
    private var pxs: [UnsafeMutablePointer<Float>] = []
    private var lodHint: [UnsafeMutablePointer<UInt8>] = []
    /// This frame's LOD before the hysteresis pass (assignLODs scratch).
    private var pxLod: [UnsafeMutablePointer<UInt8>] = []
    private var slots: [UnsafeMutablePointer<Int32>] = []
    private var liveN = [Int](repeating: 0, count: 4), allN = [Int](repeating: 0, count: 4)
    private var hist = [Int32](repeating: 0, count: 160)
    /// This frame's draws: [type][lod], the glint block (live bugs by type), the proxies.
    private var regions = [[Region]](repeating: [Region](repeating: Region(), count: 3), count: 4)
    private var glintRegion = Region()
    private var glintCount = 0
    private var proxies = Region()
    private var params: SwarmParams
    private var glintTable: [GlintSocket] = []
    private var glintFirst = [Int](repeating: 0, count: 4), glintPer = [Int](repeating: 0, count: 4)
    private var coreSocket = [Int](repeating: -1, count: 4)
    /// Recent bullet hits (MetalWorld.handle → noteHit): the recoil direction of the bug they hit.
    private var hits = [(x: Float, z: Float, dx: Float, dz: Float, t: Float)](repeating: (0, 0, 0, 0, -9), count: 32)
    private var hitHead = 0
    private var clock: Float = 0
    private var deadList: [(x: Float, z: Float, type: UInt8, uid: Int32, value: Float)] = []
    // stats
    /// Bugs drawn this frame (heartbeat `vis`).
    private(set) var visible = 0
    private(set) var lodCounts = [0, 0, 0]
    private(set) var swarmTriangles = 0
    private(set) var corpsesDrawn = 0
    private var lastLog: Double = 0
    /// Body length of each type (model m): the LOD size measure.
    private var lens: [Float] = [1, 1, 1, 1]
    private var buildMs: Double = 0
    // look-dev options
    private let forcedLOD: Int?
    private let glintsOff: Bool
    private let sheet: (strip: Int?, scale: Float, studio: Bool)?
    /// `-bugsheetT <s>`: the sheet's clips held at this time (a LOD A/B of identical poses).
    private let sheetT: Float?

    init(level: Level) {
        self.level = level
        let a = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = a.firstIndex(of: flag), i + 1 < a.count, !a[i + 1].hasPrefix("-") else { return nil }
            return a[i + 1]
        }
        sheetT = value("-bugsheetT").flatMap { Float($0) }
        forcedLOD = value("-swarmLOD").flatMap { Int($0) }.map { max(0, min(2, $0)) }
        glintsOff = a.contains("-noGlints")
        // `-demo bugsheet` (WP7's demo name; until DemoScript knows it, `-demo calm -bugsheet`)
        if a.contains("-bugsheet") || value("-demo") == "bugsheet" {
            sheet = (nil, value("-bugsheet").flatMap { Float($0) } ?? 1, !a.contains("-bugsheetGame"))
        } else if let s = value("-bugstrip") {
            let t = CreatureLibrary.names.firstIndex(of: s) ?? Int(s) ?? 0
            let i = a.firstIndex(of: "-bugstrip")! + 2
            sheet = (max(0, min(3, t)), i < a.count ? Float(a[i]) ?? 2.4 : 2.4, !a.contains("-bugsheetGame"))
        } else {
            sheet = nil
        }
        let z = SwarmTypeGPU(rim: .zero, eye: .zero, sac: .zero, gland: .zero, proxy: .zero, glint: .zero)
        params = SwarmParams(types: (z, z, z, z), info: .zero, queen: F4(0.5, 0.25, 1.0, 0))
        assert(MemoryLayout<CreatureInstance>.stride == 80 && MemoryLayout<SwarmTypeGPU>.stride == 96
               && MemoryLayout<SwarmParams>.stride == 416 && MemoryLayout<GlintSocket>.stride == 32)
    }

    deinit {
        for p in scratch { p.deallocate() }
        for p in pxs { p.deallocate() }
        for p in lodHint { p.deallocate() }
        for p in pxLod { p.deallocate() }
        for p in slots { p.deallocate() }
    }

    /// Creature files, pipelines, the proxy blob, the glint table; register the swarm's items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        psCreature = r.pipeline("creature"); psGlint = r.pipeline("swarmGlint"); psProxy = r.pipeline("creatureProxy")
        library = CreatureLibrary.shared(r.device)
        if let lib = library {
            animator = SwarmAnimator(library: lib)
            AppLog.info("swarm: " + lib.summary)
            buildGlintTable(lib)
            lens = lib.types.map { max(0.3, $0.length) }
        }
        for _ in 0..<4 {
            scratch.append(.allocate(capacity: WorldSwarm.scratchCap))
            pxLod.append(.allocate(capacity: WorldSwarm.scratchCap))
            pxs.append(.allocate(capacity: WorldSwarm.scratchCap))
            lodHint.append(.allocate(capacity: WorldSwarm.scratchCap))
            slots.append(.allocate(capacity: WorldSwarm.scratchCap))
        }
        deadList.reserveCapacity(64)
        // the shadow proxy: a unit icosahedron (SwarmType.proxy scales it to the type's body)
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var iv: [Float] = []
        for v in [F3(-1, t, 0), F3(1, t, 0), F3(-1, -t, 0), F3(1, -t, 0), F3(0, -1, t), F3(0, 1, t), F3(0, -1, -t), F3(0, 1, -t),
                  F3(t, 0, -1), F3(t, 0, 1), F3(-t, 0, -1), F3(-t, 0, 1)] {
            let n = v / (v * v).sum().squareRoot()
            iv += [n.x, n.y, n.z]
        }
        let ii: [UInt16] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                            3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        proxyVB = r.device.makeBuffer(bytes: iv, length: iv.count * 4, options: [])
        proxyIB = r.device.makeBuffer(bytes: ii, length: ii.count * 2, options: [])
        proxyIndexCount = ii.count
        r.register(.opaque, order: 300, "swarm") { [unowned self] enc in self.encodeBugs(enc) }
        r.register(.transparent, order: 400, "glints") { [unowned self] enc in self.encodeGlints(enc) }
        r.register(.shadowCasters, order: 200, "swarm proxies") { [unowned self] enc in self.encodeProxies(enc) }
    }

    /// The glinting sockets of each type, brightest first (≤ glintsPerBug), and the type constants.
    private func buildGlintTable(_ lib: CreatureLibrary) {
        glintTable.removeAll()
        for t in 0..<4 {
            let c = lib.types[t]
            let g = c.sockets.filter { $0.glint }.sorted { ($0.intensity, $0.radius) > ($1.intensity, $1.radius) }.prefix(WorldSwarm.glintsPerBug)
            glintFirst[t] = glintTable.count
            glintPer[t] = g.count
            for s in g {
                let phase = Float(s.name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } & 1023) / 1023
                glintTable.append(GlintSocket(pos: F4(s.rest.x, s.rest.y, s.rest.z, Float(s.bone)),
                                              info: F4(s.radius, s.intensity, s.hot ? 1 : 0, phase)))
            }
            coreSocket[t] = c.sockets.firstIndex { $0.name == "core" } ?? -1
        }
    }

    /// A bullet hit (MetalWorld forwards GameEvent.bulletHit): the bug it struck recoils along `dir`.
    func noteHit(_ pos: Vec2, _ dir: Vec2) {
        hits[hitHead] = (pos.x, pos.y, dir.x, dir.y, clock)
        hitHead = (hitHead + 1) % hits.count
    }

    // ---------------------------------------------------------------- build
    /// Write this frame's instances into the arena. `spot`: the player's flashlight when the squad's flashlights cast
    /// shadows this frame (proxies for every lit cone of the last frame), nil = only the player's cone. `fx`: embers of
    /// burning bugs.
    func build(game: Game, alpha: Float, time: Float, dt: Float, camera: MetalCamera, spot: (pos: F3, dir: F3)?, fx: MetalEffects) {
        let t0 = FrameTimer.now()
        for t in 0..<4 { for l in 0..<3 { regions[t][l] = Region() }; liveN[t] = 0; allN[t] = 0 }
        glintRegion = Region(); glintCount = 0; proxies = Region()
        visible = 0; corpsesDrawn = 0; swarmTriangles = 0; lodCounts = [0, 0, 0]
        guard let lib = library, let A = animator, let r = renderer else { return }
        clock += dt
        A.beginFrame()
        let high = r.frameTier == .high
        let eye = camera.eye, fwd = camera.forward, pxScale = camera.pxScale
        let corps: Corpses? = Corpses.active.flatMap { $0.level === level ? $0 : nil }
        corps?.advance(dt)

        if let sh = sheet {
            buildSheet(lib, A, camera: camera, time: sheetT ?? time, sh)
        } else {
            buildLive(game, A, alpha: alpha, time: time, dt: dt, camera: camera, fx: fx, lens: lens, eye: eye, fwd: fwd, pxScale: pxScale)
            if let C = corps { buildCorpses(C, A, camera: camera, lens: lens, eye: eye, fwd: fwd, pxScale: pxScale) }
        }
        assignLODs(lib, high: high)
        writeRegions(lib, high: high)
        if sheet == nil { buildProxies(r, high: high, squad: spot != nil) }
        buildParams(time: time)
        buildMs += ((FrameTimer.now() - t0) * 1000 - buildMs) * 0.1
        heartbeat(corps, high: high)
    }

    private func buildLive(_ game: Game, _ A: SwarmAnimator, alpha: Float, time: Float, dt: Float, camera: MetalCamera, fx: MetalEffects,
                           lens: [Float], eye: F3, fwd: F3, pxScale: Float) {
        let S = game.bugs
        let n = S.count
        let types = S.types, dead = S.deadFlags
        let X = S.xs, Z = S.zs, PX = S.prevXs, PZ = S.prevZs, Y = S.heights, HD = S.headings, SC = S.scales
        let PH = S.gaitPhases, FL = S.flashes, BU = S.burnTimers, FR = S.freezeTimers, CH = S.chills
        let ST = S.states, TT = S.stateTimers, VR = S.variations, U = S.uids
        let swell = BugState.swell.rawValue, wind = BugState.wind.rawValue, climb = BugState.climb.rawValue
        let brute = UInt8(BugType.brute.rawValue)
        let queenUid: Int32 = game.queen.alive ? game.queen.uid : -1
        let marines = game.marines
        deadList.removeAll(keepingCapacity: true)
        var i = 0
        while i < n {
            defer { i += 1 }
            let t = Int(min(3, types[i]))
            if dead[i] != 0 {
                if deadList.count < 64 { deadList.append((X[i], Z[i], UInt8(t), U[i], VR[i])) }
                continue
            }
            let bx = PX[i] + (X[i] - PX[i]) * alpha, bz = PZ[i] + (Z[i] - PZ[i]) * alpha
            let gy = level.groundY(bx, bz) + Y[i]
            let sc = SC[i]
            // CPU frustum cull: a point at mid-body height (15 % margin covers the body size)
            if !camera.visible(bx, gy + 0.3 * sc, bz) { continue }
            var s = sc, sy = sc
            let st = ST[i]
            if st == swell {
                let p = 1 - TT[i] / 0.8
                s *= 1 + p * 0.3 + sinf(time * 40) * 0.03 * p
                sy = s
            }
            var sp: Float = 0, cp: Float = 1
            if st == climb && Y[i] < -0.1 {
                // nose up while scaling the wall, levelling out as it crests the edge
                let p = max(0, min(1, (-Y[i] - 0.1) / 0.7)) * 1.4
                sp = sinf(p); cp = cosf(p)
            }
            let vr = VR[i]
            var flash = max(0, FL[i]) / 0.6
            if st == swell { flash = max(flash, (0.5 + 0.5 * sinf(time * (18 + 30 * (1 - TT[i] / 0.8)))) * 0.7) }
            var burn: Float = 0
            if BU[i] > 0 {
                burn = 0.55 + 0.45 * sinf(time * 23 + Float(i) * 1.7)
                if dt > 0 { fx.burningBug(bx, bz, sc, dt: dt) }
            }
            let frozen = FR[i] > 0
            let frz: Float = frozen ? 1 : CH[i] * 0.55
            let o = A.live(type: t, uid: U[i], st: st, stT: TT[i], ph: PH[i], x: bx, z: bz, y: Y[i], hd: HD[i], scale: s, flash: FL[i],
                           frozen: frozen, dt: dt) { self.impactDir(bx, bz, marines) }
            // per-bug value / hue (no even «carpet»): ±28 % value, a slight warm / cool shift
            let v = 0.72 + vr * 0.56
            let h = (vr * 7.31 - floorf(vr * 7.31)) - 0.5
            let queen = U[i] == queenUid
            let flags: UInt32 = queen ? 1 : 0
            if st == wind && types[i] == brute { sy = s * (1 + sinf(time * 30) * 0.04) }
            let tint = queen ? F4(0.75, 0.40, 2.6, sy) : F4(v * (1 + 0.14 * h), v, v * (1 - 0.14 * h), sy)
            let k = allN[t]
            scratch[t][k] = CreatureInstance(
                pos: F4(bx, gy, bz, s), rot: F4(cosf(HD[i]), sinf(HD[i]), sp, cp), tint: tint,
                anim: SIMD4(o.a.rows, o.b.rows, unorm16(o.a.frac) | unorm16(o.b.frac) << 16, unorm16(o.wB) | UInt32(t) << 16 | flags << 24),
                fx: SIMD4(unorm8(flash) | unorm8(burn) << 8 | unorm8(frz) << 16, snorm16(o.leanX) | snorm16(o.leanZ) << 16,
                          unorm16(vr) | unorm16(o.boost) << 16, 0))
            let depth = max(0.5, (F3(bx - eye.x, gy - eye.y, bz - eye.z) * fwd).sum())
            pxs[t][k] = s * lens[t] * pxScale / depth
            lodHint[t][k] = o.lodPrev
            slots[t][k] = Int32(o.slot)
            allN[t] = k + 1
            visible += 1
        }
        for t in 0..<4 { liveN[t] = allN[t] }
    }

    /// The recoil direction of a bug hit at (x, z): the shot that hit it (noteHit), else away from the nearest marine.
    private func impactDir(_ x: Float, _ z: Float, _ marines: [Marine]) -> (Float, Float) {
        var best: Float = 1.2 * 1.2
        var dir: (Float, Float)? = nil
        for h in hits where clock - h.t < 0.15 {
            let dx = h.x - x, dz = h.z - z, d2 = dx * dx + dz * dz
            if d2 < best { best = d2; dir = (h.dx, h.dz) }
        }
        if let d = dir {
            let l = max(1e-4, (d.0 * d.0 + d.1 * d.1).squareRoot())
            return (d.0 / l, d.1 / l)
        }
        var bd: Float = 1e9
        var res: (Float, Float) = (0, 0)
        for m in marines where !m.downed {
            let dx = x - m.x, dz = z - m.z, d2 = dx * dx + dz * dz
            if d2 < bd { bd = d2; let l = max(1e-4, d2.squareRoot()); res = (dx / l, dz / l) }
        }
        return res
    }

    private func buildCorpses(_ C: Corpses, _ A: SwarmAnimator, camera: MetalCamera, lens: [Float], eye: F3, fwd: F3, pxScale: Float) {
        // the bugs that died this frame hand their last pose to the corpse born at exactly their position
        C.link { x, z, ty in
            guard let d = self.deadList.first(where: { $0.x == x && $0.z == z && $0.type == ty }) else { return nil }
            let v = 0.72 + d.value * 0.56
            if let (pose, lod) = A.lastPose(uid: d.uid) { return (pose, v, lod) }
            return (ClipSample.zero, v, 255)
        }
        let clockC = C.clock
        for ring in C.rings {
            for c in ring {
                if !camera.visible(c.x, c.y + 0.2 * c.scale, c.z) { continue }
                let t = Int(min(3, c.type))
                let k = allN[t]
                if k >= WorldSwarm.scratchCap { continue }
                let age = clockC - c.born
                let dur = A.deathDuration(type: t, variant: Int(c.variant))
                let o = A.corpse(type: t, variant: Int(c.variant), age: age, from: c.from, hasFrom: c.hasFrom && c.from.rows != 0)
                let dead = smoothf(0, max(0.3, dur), age)
                scratch[t][k] = CreatureInstance(
                    pos: F4(c.x, c.y, c.z, c.scale), rot: F4(cosf(c.heading), sinf(c.heading), c.pitchS, c.pitchC),
                    tint: F4(c.value, c.value * 0.97, c.value * 0.95, c.scale),
                    anim: SIMD4(o.a.rows, o.b.rows, unorm16(o.a.frac) | unorm16(o.b.frac) << 16, unorm16(o.wB) | UInt32(t) << 16 | 2 << 24),
                    fx: SIMD4(unorm8(dead) << 24, 0, unorm16(c.seed), 0))
                let depth = max(0.5, (F3(c.x - eye.x, c.y - eye.y, c.z - eye.z) * fwd).sum())
                pxs[t][k] = c.scale * lens[t] * pxScale / depth
                // settled bodies drop to LOD2; until then the LOD the bug died with (no mesh change while it dies)
                lodHint[t][k] = age > dur + 0.6 ? 2 : (c.lod <= 2 ? c.lod : 254)
                slots[t][k] = -1
                allN[t] = k + 1
                corpsesDrawn += 1
            }
        }
    }

    /// Look-dev specimens around the camera focus: every type × clip (grid), or one type's clips × 8 frames (strip).
    private func buildSheet(_ lib: CreatureLibrary, _ A: SwarmAnimator, camera: MetalCamera, time: Float, _ sh: (strip: Int?, scale: Float, studio: Bool)) {
        let f0 = camera.focus
        let rx0 = F3(camera.right.x, 0, camera.right.z), ux0 = F3(camera.up.x, 0, camera.up.z)
        let rr = rx0 / max(1e-4, (rx0 * rx0).sum().squareRoot()), uu = ux0 / max(1e-4, (ux0 * ux0).sum().squareRoot())
        let gy = level.groundY(f0.x, f0.z)
        // noses to screen-left, a little toward the viewer: a 3/4 profile
        let face = -rr * 0.9 - uu * 0.42
        let hd = atan2f(face.x, face.z)
        func put(_ t: Int, _ c: Int, _ at: F3, _ o: AnimOut, _ scale: Float) {
            let k = allN[t]
            scratch[t][k] = CreatureInstance(
                pos: F4(at.x, gy, at.z, scale), rot: F4(cosf(hd), sinf(hd), 0, 1), tint: F4(1, 1, 1, scale),
                anim: SIMD4(o.a.rows, o.b.rows, unorm16(o.a.frac) | unorm16(o.b.frac) << 16, unorm16(o.wB) | UInt32(t) << 16),
                fx: SIMD4(0, 0, unorm16(Float(c) * 0.13), 0))
            pxs[t][k] = scale * lib.types[t].length * camera.pxScale / max(1, ((at - camera.eye) * camera.forward).sum())
            lodHint[t][k] = 255
            slots[t][k] = -1
            allN[t] = k + 1
            liveN[t] = k + 1
            visible += 1
        }
        let base: [Float] = [0.8, 1.02, 2.0, 1.15]          // BUG_SPECS scales
        if let st = sh.strip {
            let clips = lib.types[st].clips
            let sc = base[st] * sh.scale
            let colW = lib.types[st].length * sc * 1.05 + 0.4, rowH = max(2.2, lib.types[st].length * sc * 0.55)
            for (ci, c) in clips.enumerated() {
                for col in 0..<8 {
                    let tt = c.loop ? c.duration * Float(col) / 8 : c.duration * Float(col) / 7
                    var o = AnimOut()
                    o.a = c.loop ? clipLoop(c, tt / max(c.duration, 0.05)) : clipShot(c, tt)
                    let at = f0 + rr * ((Float(col) - 3.5) * colW) + uu * ((Float(clips.count - 1) * 0.5 - Float(ci)) * rowH)
                    put(st, ci, at, o, sc)
                }
            }
        } else {
            let rows: [Float] = [2.0, 2.4, 4.4, 2.6]
            let total = rows.reduce(0, +) * sh.scale
            var y = total * 0.5
            for t in 0..<4 {
                let h = rows[t] * sh.scale
                y -= h * 0.5
                let clips = lib.types[t].clips
                let colW = max(2.2, lib.types[t].length * base[t] * 1.15) * sh.scale
                for c in 0..<clips.count {
                    let at = f0 + rr * ((Float(c) - Float(clips.count - 1) * 0.5) * colW) + uu * y
                    put(t, c, at, A.sheet(type: t, clip: c, time: time + Float(c) * 0.37), base[t] * sh.scale)
                }
                y -= h * 0.5
            }
        }
    }

    // ---------------------------------------------------------------- LOD
    /// Thresholds from a histogram of screen sizes (2 px bins): LOD0 for the largest ≤ 32 (High, ≥ 64 px), LOD1 for the
    /// next ≤ 600 / 300 under the triangle budget, LOD2 for the rest; ±12 % hysteresis on the bug's last LOD.
    private func assignLODs(_ lib: CreatureLibrary, high: Bool) {
        for b in 0..<hist.count { hist[b] = 0 }
        var nAll = 0
        var t2sum = 0, t1sum = 0, t0sum = 0
        for t in 0..<4 {
            let L = lib.types[t].lods
            let tr0 = L[0].triangles, tr1 = L[min(1, L.count - 1)].triangles, tr2 = L[min(2, L.count - 1)].triangles
            t0sum += (tr0 - tr2) * allN[t]; t1sum += (tr1 - tr2) * allN[t]; t2sum += tr2 * allN[t]
            nAll += allN[t]
            for k in 0..<allN[t] {
                hist[min(hist.count - 1, Int(pxs[t][k] * 0.5))] += 1
            }
        }
        if nAll == 0 { return }
        let avgD0 = Float(t0sum) / Float(nAll), avgD1 = max(1, Float(t1sum) / Float(nAll))
        // LOD0: the 32 largest at ≥ 64 px (High only)
        var th0: Float = .greatestFiniteMagnitude
        var n0 = 0
        if high {
            var acc = 0
            var b = hist.count - 1
            while b >= 0 {
                let next = acc + Int(hist[b])
                if next > WorldSwarm.lod0Cap { break }
                acc = next
                b -= 1
            }
            th0 = max(WorldSwarm.lod0MinPx, Float(b + 1) * 2)
            n0 = 0
            var bb = hist.count - 1
            while bb >= 0 && Float(bb) * 2 >= th0 { n0 += Int(hist[bb]); bb -= 1 }
        }
        // LOD1: as many as the cap and the triangle budget allow
        let budget = high ? WorldSwarm.triBudget.high : WorldSwarm.triBudget.efficient
        let room = Float(budget - t2sum) - Float(n0) * avgD0
        let cap1 = min(high ? WorldSwarm.lod1Cap.high : WorldSwarm.lod1Cap.efficient, max(0, Int(room / avgD1)))
        var acc = 0
        var b = high ? min(hist.count - 1, Int(th0 * 0.5) - 1) : hist.count - 1
        while b >= 0 {
            let next = acc + Int(hist[b])
            if next > cap1 { break }
            acc = next
            b -= 1
        }
        let th1 = max(WorldSwarm.lod1MinPx, Float(b + 1) * 2)
        // pass 1: the thresholds (corpses keep the LOD they died with, then LOD2), counted
        let cap0 = high ? WorldSwarm.lod0Cap : 0
        var c0 = 0, c1 = 0
        for t in 0..<4 {
            for k in 0..<allN[t] {
                let px = pxs[t][k]
                var l: UInt8 = px >= th0 ? 0 : (px >= th1 ? 1 : 2)
                let prev = lodHint[t][k]
                if slots[t][k] < 0 && prev <= 2 { l = (prev == 0 && !high) ? 1 : prev }
                if l == 0 { c0 += 1 } else if l == 1 { c1 += 1 }
                pxLod[t][k] = l
            }
        }
        // pass 2: ±12 % hysteresis on a live bug's last LOD, only inside the caps (LOD0 ≤ 32, LOD1 under the budget)
        for t in 0..<4 {
            for k in 0..<allN[t] where slots[t][k] >= 0 {
                let px = pxs[t][k], prev = lodHint[t][k]
                let l = pxLod[t][k]
                if prev == 0 && l != 0 && high && px >= th0 * 0.88 && c0 < cap0 {
                    pxLod[t][k] = 0; c0 += 1; if l == 1 { c1 -= 1 }
                } else if prev == 1 && l == 2 && px >= th1 * 0.88 && c1 < cap1 {
                    pxLod[t][k] = 1; c1 += 1
                } else if prev == 2 && l == 1 && px < th1 * 1.12 {
                    pxLod[t][k] = 2; c1 -= 1
                }
            }
        }
        for t in 0..<4 {
            for k in 0..<allN[t] {
                // look-dev sheets: the close-up mesh unless -swarmLOD says otherwise
                lodHint[t][k] = forcedLOD.map { UInt8($0) } ?? (sheet != nil ? 0 : pxLod[t][k])
            }
        }
    }

    private func writeRegions(_ lib: CreatureLibrary, high: Bool) {
        let r = renderer!
        var counts = [[Int]](repeating: [0, 0, 0], count: 4)
        for t in 0..<4 { for k in 0..<allN[t] { counts[t][Int(lodHint[t][k])] += 1 } }
        var ptrs = [[UnsafeMutablePointer<CreatureInstance>?]](repeating: [nil, nil, nil], count: 4)
        for t in 0..<4 {
            for l in 0..<3 where counts[t][l] > 0 {
                if let a = r.alloc(CreatureInstance.self, counts[t][l]) { ptrs[t][l] = a.0; regions[t][l] = Region(offset: a.1, count: 0) }
            }
        }
        for t in 0..<4 {
            let L = lib.types[t].lods
            for k in 0..<allN[t] {
                let l = Int(lodHint[t][k])
                guard let p = ptrs[t][l] else { continue }
                p[regions[t][l].count] = scratch[t][k]
                regions[t][l].count += 1
                if slots[t][k] >= 0 { animator?.setLOD(Int(slots[t][k]), UInt8(l)) }
            }
            for l in 0..<3 {
                lodCounts[l] += regions[t][l].count
                swarmTriangles += regions[t][l].count * L[min(l, L.count - 1)].triangles
            }
        }
        // the glint block: the live bugs of each type again, contiguous by type (all LODs)
        if glintsOff || psGlint == nil { return }
        let cap = high ? WorldSwarm.glintCap.high : WorldSwarm.glintCap.efficient
        var want = 0
        for t in 0..<4 { want += liveN[t] * glintPer[t] }
        let k = want > cap ? Float(cap) / Float(want) : 1
        let live = liveN.reduce(0, +)
        guard live > 0, let a = r.alloc(CreatureInstance.self, live) else { return }
        glintRegion = Region(offset: a.1, count: live)
        var o = 0, g = 0
        for t in 0..<4 {
            let per = glintPer[t] == 0 ? 0 : max(min(3, glintPer[t]), Int(Float(glintPer[t]) * k))
            (a.0 + o).update(from: scratch[t], count: liveN[t])
            setGlint(t, first: UInt32(glintFirst[t]), per: UInt32(per), start: UInt32(g), bug: UInt32(o))
            o += liveN[t]
            g += liveN[t] * per
        }
        glintCount = g
    }

    private func setGlint(_ t: Int, first: UInt32, per: UInt32, start: UInt32, bug: UInt32) {
        let v = SIMD4<UInt32>(first, per, start, bug)
        switch t {
        case 0: params.types.0.glint = v
        case 1: params.types.1.glint = v
        case 2: params.types.2.glint = v
        default: params.types.3.glint = v
        }
    }

    /// Shadow proxies: the live bugs inside a lit flashlight cone of the last frame (cos 0.6, 32 m): the player's always
    /// (its atlas tile exists on every tier), the squad's when `squad`.
    private func buildProxies(_ r: MetalRenderer, high: Bool, squad: Bool) {
        let F = r.frame
        let sp = [F.spotPos.0, F.spotPos.1, F.spotPos.2, F.spotPos.3], sd = [F.spotDir.0, F.spotDir.1, F.spotDir.2, F.spotDir.3]
        var cones: [(F3, F3)] = []
        for k in 0..<(squad ? 4 : 1) where sp[k].w > 0 { cones.append((F3(sp[k].x, sp[k].y, sp[k].z), F3(sd[k].x, sd[k].y, sd[k].z))) }
        if cones.isEmpty { return }
        let cap = high ? WorldSwarm.shadowProxyMax.high : WorldSwarm.shadowProxyMax.efficient
        guard let a = r.alloc(CreatureInstance.self, cap) else { return }
        let cosCone = cosf(0.6)
        var n = 0
        outer: for t in 0..<4 {
            for k in 0..<liveN[t] {
                let p = scratch[t][k].pos
                let c = F3(p.x, p.y + 0.3 * p.w, p.z)
                for (pos, dir) in cones {
                    let o = c - pos
                    let d2 = (o * o).sum()
                    if d2 < 32 * 32 && (o * dir).sum() > cosCone * d2.squareRoot() {
                        a.0[n] = scratch[t][k]
                        n += 1
                        if n >= cap { break outer }
                        break
                    }
                }
            }
        }
        proxies = Region(offset: a.1, count: n)
    }

    private func buildParams(time: Float) {
        func ty(_ t: Int, _ g: SIMD4<UInt32>) -> SwarmTypeGPU {
            let L = WorldSwarm.looks[t]
            return SwarmTypeGPU(rim: L.rim, eye: L.eye, sac: L.sac, gland: L.gland, proxy: L.proxy, glint: g)
        }
        params.types = (ty(0, params.types.0.glint), ty(1, params.types.1.glint), ty(2, params.types.2.glint), ty(3, params.types.3.glint))
        if glintCount == 0 { for t in 0..<4 { setGlint(t, first: 0, per: 0, start: 0, bug: 0) } }
        params.info = F4(time, (sheet?.studio ?? false) ? 1 : 0, 1.7, 1.25)
        params.queen = F4(0.55, 0.22, 1.1, 0)
    }

    private func heartbeat(_ corps: Corpses?, high: Bool) {
        guard AppLog.diagnostics else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        AppLog.info("hb swarm vis=\(visible) lod=\(lodCounts[0])/\(lodCounts[1])/\(lodCounts[2]) tris=\(swarmTriangles / 1000)k"
                    + " corpses=\(corpsesDrawn)/\(corps?.count ?? 0) glints=\(glintCount) proxies=\(proxies.count)"
                    + String(format: " build=%.2fms tier=", buildMs) + (high ? "high" : "efficient")
                    + (sheet != nil ? " sheet" : "") + (forcedLOD.map { " forced=LOD\($0)" } ?? ""))
    }

    // ---------------------------------------------------------------- WP5: where a shot meets the chitin
    /// The point on a bug a bullet that hit near (x, z) along (dx, dz) strikes: the nearest live bug drawn this frame
    /// (within its body), its `core` socket at its current pose, pushed toward the shooter by the body's half width;
    /// the surface normal faces the shooter; the type's ichor colour. nil: no drawn bug there (culled or already gone).
    func impactPoint(x: Float, z: Float, dx: Float, dz: Float) -> (pos: F3, normal: F3, ichor: F3)? {
        guard let lib = library else { return nil }
        var best: Float = .greatestFiniteMagnitude
        var bt = -1, bk = -1
        for t in 0..<4 {
            let reach = lib.types[t].length * 0.6
            for k in 0..<liveN[t] {
                let p = scratch[t][k].pos
                let ex = p.x - x, ez = p.z - z, d2 = ex * ex + ez * ez
                let rr = reach * p.w
                if d2 < rr * rr && d2 < best { best = d2; bt = t; bk = k }
            }
        }
        guard bt >= 0 else { return nil }
        let inst = scratch[bt][bk], c = lib.types[bt]
        let s = inst.pos.w
        var local = F3(0, 0.3, 0)
        if coreSocket[bt] >= 0 {
            let a = inst.anim
            local = c.socketPoint(c.sockets[coreSocket[bt]], Int(a.x & 0xffff), Int(a.x >> 16), Float(a.z & 0xffff) / 65535)
        }
        let cs = inst.rot.x, sn = inst.rot.y
        let w = F3(inst.pos.x + (cs * local.x + sn * local.z) * s, inst.pos.y + local.y * inst.tint.w, inst.pos.z + (-sn * local.x + cs * local.z) * s)
        let l = max(1e-4, (dx * dx + dz * dz).squareRoot())
        let n = F3(-dx / l, 0.25, -dz / l)
        let half = (c.boundsMax.x - c.boundsMin.x) * 0.25 * s
        return (w + F3(-dx / l * half, 0, -dz / l * half), n / (n * n).sum().squareRoot(), WorldSwarm.ichor[bt])
    }

    // ---------------------------------------------------------------- draws
    /// Opaque item 300: one instanced draw per type × LOD (live bugs and corpses together).
    private func encodeBugs(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psCreature, let lib = library else { return }
        let r = renderer!
        r.use(enc, ps)
        var P = params
        enc.setVertexBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        enc.setFragmentBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        for t in 0..<4 {
            let c = lib.types[t]
            var bound = false
            for l in 0..<3 where regions[t][l].count > 0 {
                let L = c.lods[min(l, c.lods.count - 1)]
                if !bound {
                    enc.setVertexTexture(c.boneTexture, index: 6)
                    enc.setVertexBuffer(c.buffer, offset: c.glowOffset, index: 4)
                    bound = true
                }
                enc.setVertexBuffer(c.buffer, offset: L.vertexOffset, index: BufferIndex.vertices)
                enc.setVertexBuffer(r.arena, offset: regions[t][l].offset, index: BufferIndex.instances)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: L.indexCount, indexType: L.indexType, indexBuffer: c.buffer,
                                          indexBufferOffset: L.indexOffset, instanceCount: regions[t][l].count)
                r.count(instances: regions[t][l].count, triangles: L.triangles * regions[t][l].count)
            }
        }
    }

    /// Transparent item 400: every live bug's glinting pores, one draw for all types.
    private func encodeGlints(_ enc: MTLRenderCommandEncoder) {
        guard glintCount > 0, let ps = psGlint, let lib = library, !glintTable.isEmpty else { return }
        let r = renderer!
        r.use(enc, ps)
        var P = params
        enc.setVertexBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        glintTable.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 10) }
        for t in 0..<4 {
            let c = lib.types[t]
            enc.setVertexTexture(c.boneTexture, index: 6 + t)
            enc.setVertexBuffer(c.buffer, offset: c.glowOffset, index: 11 + t)
        }
        enc.setVertexBuffer(r.arena, offset: glintRegion.offset, index: BufferIndex.instances)
        r.drawQuads(enc, glintCount)
    }

    /// Shadow caster item 200: the proxy blobs of the bugs inside the cones.
    private func encodeProxies(_ enc: MTLRenderCommandEncoder) {
        guard proxies.count > 0, let ps = psProxy, let vb = proxyVB, let ib = proxyIB else { return }
        let r = renderer!
        enc.setRenderPipelineState(ps)
        var P = params
        enc.setVertexBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.setVertexBuffer(r.arena, offset: proxies.offset, index: BufferIndex.instances)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: proxyIndexCount, indexType: .uint16, indexBuffer: ib,
                                  indexBufferOffset: 0, instanceCount: proxies.count)
        r.count(instances: proxies.count, triangles: 20 * proxies.count)
    }
}
