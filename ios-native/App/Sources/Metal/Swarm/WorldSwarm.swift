import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD SWARM — the live bugs (owned by WP3 «Рой»; from the web's
//  05-sim.js writeBugInstances): per bug type one instanced draw of
//  BugInstance (interpolated feet, heading, climb pitch, swell / wind-up
//  scale, tint variation, gait phase, hit flash, burn, freeze), with a
//  CPU frustum cull; the optional glint dots (-glintDots); and the
//  20-triangle shadow proxies of the bugs inside the player's
//  flashlight cone («высокая»). Shaders: Swarm.metal, SwarmTypes.h.
// ================================================================

/// One bug of the swarm (`struct BugInstance` in SwarmTypes.h): compact transform + per-instance shading.
struct BugInstance {
    /// xyz feet position (world), w = horizontal scale.
    var pos: F4
    /// x = cos(heading), y = sin(heading), z = sin(climb pitch), w = cos(climb pitch).
    var rot: F4
    /// rgb instance tint, w = vertical scale.
    var color: F4
    /// web iAnim: gait phase, hit flash, burn, freeze.
    var anim: F4
}

final class WorldSwarm {
    static let pipelines: [PipelineSpec] = [
        .world("bug", "vs_bug", "fs_bug", .none, .ihm1, required: true),
        .world("glint", "vs_glint", "fs_glint", .alpha),
        .depthOnly("shadowProxy", "vs_shadow_proxy"),
    ]
    static let shadowProxyMax = 400

    let level: Level
    private var renderer: MetalRenderer!
    private var meshes: [GPUMesh] = []
    private var psBug: MTLRenderPipelineState?, psGlint: MTLRenderPipelineState?, psProxy: MTLRenderPipelineState?
    private var proxyVB: MTLBuffer?, proxyIB: MTLBuffer?
    private var proxyIndexCount = 0
    private var typeCounts = [Int](repeating: 0, count: 4)
    private var bugPtr = [UnsafeMutablePointer<BugInstance>?](repeating: nil, count: 4)
    private var bugCnt = [Int](repeating: 0, count: 4)
    /// This frame's instances per type, and the shadow proxies.
    private var regions = [Region](repeating: Region(), count: 4)
    private var proxies = Region()
    /// Bugs drawn this frame (heartbeat `vis`).
    private(set) var visible = 0

    init(level: Level) {
        self.level = level
    }

    /// Meshes, pipelines, the proxy blob; register the swarm's items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        meshes = ["bug_runner", "bug_spitter", "bug_brute", "bug_boomer"].map { r.store.mesh($0) }
        psBug = r.pipeline("bug"); psGlint = r.pipeline("glint"); psProxy = r.pipeline("shadowProxy")
        // the shadow proxy: IcosahedronGeometry(0.3, 0)
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var iv: [Float] = []
        for v in [F3(-1, t, 0), F3(1, t, 0), F3(-1, -t, 0), F3(1, -t, 0), F3(0, -1, t), F3(0, 1, t), F3(0, -1, -t), F3(0, 1, -t),
                  F3(t, 0, -1), F3(t, 0, 1), F3(-t, 0, -1), F3(-t, 0, 1)] {
            let n = v / (v * v).sum().squareRoot() * 0.3
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

    /// Write this frame's instances straight into the arena (05-sim.js writeBugInstances). `spot`: the player's
    /// flashlight when it casts shadows this frame (proxies for the bugs inside its cone), else nil. `fx`: embers of
    /// burning bugs.
    func build(game: Game, alpha: Float, time: Float, dt: Float, camera: MetalCamera, spot: (pos: F3, dir: F3)?, fx: MetalEffects) {
        let r = renderer!
        let S = game.bugs
        let n = S.count
        let types = S.types, dead = S.deadFlags
        for t in 0..<4 { typeCounts[t] = 0 }
        for i in 0..<n where dead[i] == 0 { typeCounts[Int(min(3, types[i]))] += 1 }
        for t in 0..<4 {
            regions[t] = Region()
            bugPtr[t] = nil
            bugCnt[t] = 0
            if typeCounts[t] > 0, let a = r.alloc(BugInstance.self, typeCounts[t]) {
                bugPtr[t] = a.0
                regions[t].offset = a.1
            }
        }
        let X = S.xs, Z = S.zs, PX = S.prevXs, PZ = S.prevZs, Y = S.heights, HD = S.headings, SC = S.scales
        let PH = S.gaitPhases, FL = S.flashes, BU = S.burnTimers, FR = S.freezeTimers, CH = S.chills
        let ST = S.states, TT = S.stateTimers, VR = S.variations
        let swell = BugState.swell.rawValue, wind = BugState.wind.rawValue, climb = BugState.climb.rawValue
        let brute = UInt8(BugType.brute.rawValue)
        var vis = 0
        // shadow proxies: bugs inside the player's flashlight cone (cos 0.6, 32 m), «высокая» only
        proxies = Region()
        var proxyPtr: UnsafeMutablePointer<BugInstance>? = nil
        var proxyN = 0
        if spot != nil, let a = r.alloc(BugInstance.self, WorldSwarm.shadowProxyMax) {
            proxyPtr = a.0
            proxies.offset = a.1
        }
        let sp0 = spot?.pos ?? F3(0, -50, 0), sd0 = spot?.dir ?? F3(0, -1, 0), cosCone = cosf(0.6)
        for i in 0..<n where dead[i] == 0 {
            let t = Int(min(3, types[i]))
            guard let out = bugPtr[t] else { continue }
            let bx = PX[i] + (X[i] - PX[i]) * alpha, bz = PZ[i] + (Z[i] - PZ[i]) * alpha
            let gy = level.groundY(bx, bz) + Y[i]
            let sc = SC[i]
            // CPU frustum cull: clip-space test of a point at mid-body height (15 % margin covers the body size)
            if !camera.visible(bx, gy + 0.3 * sc, bz) { continue }
            var s = sc, sy = sc
            let st = ST[i]
            if st == swell {
                let p = 1 - TT[i] / 0.8
                s *= 1 + p * 0.45 + sinf(time * 40) * 0.04 * p
                sy = s
            }
            if st == wind && types[i] == brute { sy = s * (1 + sinf(time * 30) * 0.05) }
            var sp: Float = 0, cp: Float = 1
            if st == climb && Y[i] < -0.1 {
                // nose up while scaling the wall, levelling out as it crests the edge
                let p = clampf((-Y[i] - 0.1) / 0.7, 0, 1) * 1.4
                sp = sinf(p); cp = cosf(p)
            }
            let vr = VR[i], v = 0.55 + vr * 0.75
            var flash = max(0, FL[i])
            if st == swell { flash = max(FL[i], (0.5 + 0.5 * sinf(time * (18 + 30 * (1 - TT[i] / 0.8)))) * 0.9) }
            var burn: Float = 0
            if BU[i] > 0 {
                burn = 0.55 + 0.45 * sinf(time * 23 + Float(i) * 1.7)
                if dt > 0 { fx.burningBug(bx, bz, sc, dt: dt) }
            }
            let frz: Float = FR[i] > 0 ? 1 : CH[i] * 0.55
            let k = bugCnt[t]
            // built once and written to both slots: the arena is write-combined memory, never read it back
            let inst = BugInstance(pos: F4(bx, gy, bz, s), rot: F4(cosf(HD[i]), sinf(HD[i]), sp, cp),
                                   color: F4(v, v * (0.92 + vr * 0.1), v, sy), anim: F4(PH[i], flash, burn, frz))
            out[k] = inst
            if let pp = proxyPtr, proxyN < WorldSwarm.shadowProxyMax {
                let o = F3(bx, gy + 0.3 * sc, bz) - sp0
                let d2 = (o * o).sum()
                if d2 < 32 * 32 && (o * sd0).sum() > cosCone * d2.squareRoot() { pp[proxyN] = inst; proxyN += 1 }
            }
            bugCnt[t] = k + 1
            vis += 1
        }
        for t in 0..<4 { regions[t].count = bugPtr[t] == nil ? 0 : bugCnt[t] }
        proxies.count = proxyN
        visible = vis
    }

    /// Opaque item 300: one instanced draw per bug type.
    private func encodeBugs(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psBug else { return }
        let r = renderer!
        r.use(enc, ps)
        for t in 0..<4 where regions[t].count > 0 {
            enc.setVertexBuffer(r.arena, offset: regions[t].offset, index: BufferIndex.instances)
            r.drawMesh(enc, meshes[t], instances: regions[t].count)
        }
    }

    /// Transparent item 400 (-glintDots): one soft dot per speckle of every visible bug (instance = bug × speckle).
    private func encodeGlints(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psGlint, MetalRenderer.glintDots else { return }
        let r = renderer!
        for t in 0..<4 where regions[t].count > 0 && !meshes[t].glints.isEmpty {
            r.use(enc, ps)
            let g = meshes[t].glints
            var n = UInt32(g.count / 2)
            enc.setVertexBuffer(r.arena, offset: regions[t].offset, index: BufferIndex.instances)
            g.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: BufferIndex.material) }
            enc.setVertexBytes(&n, length: 4, index: 4)
            r.drawQuads(enc, regions[t].count * Int(n))
        }
    }

    /// Shadow caster item 200: the proxy blobs of the bugs inside the player's cone.
    private func encodeProxies(_ enc: MTLRenderCommandEncoder) {
        guard proxies.count > 0, let ps = psProxy, let vb = proxyVB, let ib = proxyIB else { return }
        let r = renderer!
        enc.setRenderPipelineState(ps)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.setVertexBuffer(r.arena, offset: proxies.offset, index: BufferIndex.instances)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: proxyIndexCount, indexType: .uint16, indexBuffer: ib,
                                  indexBufferOffset: 0, instanceCount: proxies.count)
        r.count(instances: proxies.count, triangles: 20 * proxies.count)
    }
}
