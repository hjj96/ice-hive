import Foundation
import Metal
import IceHiveCore

// ================================================================
//  GPU PARTICLES — the particle system of the effects (owned by WP5
//  «Эффекты»; replaces the CPU pool MetalParticles). The particles
//  live in one device buffer and are never touched by the CPU after
//  they are born: the CPU only writes EMITTER RECORDS (one record →
//  N particles whose positions / velocities / sizes / colours the GPU
//  draws from the record's ranges), so its cost does not grow with the
//  particle count. Every built frame:
//    upload()   the frame's records into the upload arena; the ring
//               slots of the new particles; this arena slot's counters
//               of three frames ago are read back (live counts for the
//               `hb fx` line and the cap counters) and reset;
//    pre-pass 100  (compute, Shaders/Particles.metal) fx_emit writes the
//               new particles, fx_sim ages / moves / bounces / lights
//               every slot and appends the live ones to two draw lists
//               — their lengths are the instance counts of two indirect
//               draws;
//    transparent 500 / 510  the alpha list (smoke, steam, gibs, ichor,
//               casings: lit by the flashlights and the light grid in the
//               simulation) and the additive list (fire, blasts, sparks,
//               embers, ice, glows, flashes, dots), one indirect draw
//               each.
//  Capacities per tier (the plan's caps): High 32k, Efficient 12k,
//  «низкая» 6k slots in the ring (the buffer is allocated once for the
//  largest; the simulation covers all of it, so particles of a larger
//  tier die out naturally after a downgrade). The ring overwrites its
//  oldest slots when the emission outruns the cap. Live flames
//  (fire + blast flipbook particles) are counted on the GPU; the
//  effects throttle new flames when the count reaches the tier's cap.
//  Flipbooks (Resources/FX/fx_fire.iht, fx_blast.iht, fx_smoke.iht —
//  8 × 8 frames, ASTC 6×6, tools/fx/make_fx_textures.py) load off the
//  main thread with the compute pipelines; until both are ready
//  nothing is simulated or drawn (behind the loading cover).
//  Launch option `-fxSim off` (device A/B of the particle cost: the
//  compute pass and both draws skipped, emission kept).
// ================================================================

/// Particle kinds (`PK_*` in Particles.metal).
enum PK: UInt32 {
    case glow = 0, fire, smoke, spark, ember, ice, debris, ichor, steam, casing, flash, blast, dot

    /// Drawn in the alpha list (lit by the simulation) rather than the additive one.
    var alpha: Bool { self == .smoke || self == .debris || self == .ichor || self == .steam || self == .casing }
}

/// One emitter record (`struct Emitter` in Particles.metal), 144 bytes.
struct GPUEmitter {
    /// xyz centre, w = ring radius (> 0: spawned on a horizontal ring around the centre).
    var pos: F4
    /// xyz box half extents around the spawn point, w = max start delay (s).
    var posJitter: F4
    /// xyz base velocity, w = radial speed (outward in xz from the centre).
    var vel: F4
    /// xyz box half extents of the velocity, w = spherical random speed.
    var velJitter: F4
    /// x min, y max life (s), z size at birth, w size at death (m).
    var life: F4
    /// rgba: HDR colour (additive kinds) or albedo (lit kinds).
    var color: F4
    /// x gravity (m/s²), y drag (1/s), z size jitter (fraction), w radial-speed jitter (fraction).
    var phys: F4
    /// x spin (rad/s), y colour jitter (fraction), z bounce (0 = the kind's), w unused.
    var extra: F4
    /// x first spawn index of the frame, y count, z seed, w kind | flags << 8.
    var meta: SIMD4<UInt32>
}

/// The simulation's constants (`struct SimParams` in Particles.metal), 64 bytes.
struct GPUParticleParams {
    /// x slots simulated, y ring size (tier cap), z first ring slot of this frame's spawns, w spawns.
    var counts = SIMD4<UInt32>(0, 0, 0, 0)
    /// x emitter records, y 1 = clear every particle, z 1 = High tier, w frame.
    var flags = SIMD4<UInt32>(0, 0, 0, 0)
    /// x dt, y time, z lift rise, w unused.
    var time = F4(0, 0, 0, 0)
    /// xyz lift centre, w radius (0 = no lift).
    var lift = F4(0, 0, 0, 0)
}

/// The old CPU pool's emit() for callers outside the effects (WorldLevel: beacon / glob motes): one particle per call,
/// kinds of 07-fx.js (0 fade, 1 fire, 2 smoke, 3 spark) mapped onto the GPU kinds.
final class ParticlePool {
    private unowned let gpu: GPUParticles
    private let additive: Bool

    init(_ gpu: GPUParticles, additive: Bool) {
        self.gpu = gpu
        self.additive = additive
    }

    /// y is relative to the deck under (x, z) unless `absolute`.
    func emit(_ x: Float, _ y0: Float, _ z: Float, _ vx: Float, _ vy: Float, _ vz: Float, _ life: Float, _ s0: Float, _ s1: Float,
              _ r: Float, _ g: Float, _ b: Float, _ a: Float, _ grav: Float, _ drag: Float, _ kind: Float, absolute: Bool = false) {
        let y = absolute ? y0 : y0 + gpu.level.groundY(x, z)
        let k: PK
        switch Int(kind) {
        case 1: k = .fire
        case 2: k = additive ? .glow : .smoke
        case 3: k = .spark
        default: k = additive ? .glow : .debris
        }
        gpu.burst(k, 1, at: F3(x, y, z), vel: F3(vx, vy, vz), life: (life, life), size: (s0, s1), color: F4(r, g, b, a),
                  gravity: grav, drag: drag, sizeJitter: 0)
    }
}

final class GPUParticles {
    /// Ring sizes of the tiers (High / Efficient / «низкая»).
    static let capHigh = 32768, capEfficient = 12288, capLow = 6144
    /// Live flames (fire + blast flipbook particles) per tier: new flames are thinned once the count reaches it.
    static let flameCapHigh = 1400, flameCapEfficient = 600
    /// Records / spawns of one frame at most (the rest waits for the next frame).
    static let maxRecords = 2048
    static let threadsPerGroup = 256
    /// Flipbook atlases (Resources/FX), bound at texture 6 (fire), 7 (blast), 8 (smoke) of the particle draws.
    static let atlasNames = ["fx_fire", "fx_blast", "fx_smoke"]

    static let pipelines: [PipelineSpec] = [
        .world("gpartAlpha", "vs_gpart", "fs_gpart_alpha", .alpha),
        .world("gpartAdd", "vs_gpart", "fs_gpart_add", .add),
    ]

    let level: Level
    /// `-fxSim off`: emission kept, simulation and draws skipped (device A/B of the particle cost).
    let simOff: Bool
    private(set) lazy var additivePool = ParticlePool(self, additive: true)
    private(set) lazy var alphaPool = ParticlePool(self, additive: false)

    private var renderer: MetalRenderer?
    private var particles: MTLBuffer?
    private var lists: MTLBuffer?
    private var args: MTLBuffer?
    private var ground: MTLBuffer?
    private var fallbackLight: MTLBuffer?
    private var psEmit: MTLComputePipelineState?
    private var psSim: MTLComputePipelineState?
    private var psAlpha: MTLRenderPipelineState?
    private var psAdd: MTLRenderPipelineState?
    private var atlases: [MTLTexture?] = [nil, nil, nil]
    private var ready = false
    private(set) var capacity = 0
    /// Bytes of one arena slot's counters (two indirect draw records + stats), 256-aligned.
    private static let argsStride = 256

    // this frame's emission
    private var records: [GPUEmitter] = []
    private var spawns = 0
    private var rng = SeededRNG(seed: 4242)
    // per built frame (upload → pre-pass → draws)
    private var head = 0
    private(set) var ringCap = GPUParticles.capEfficient
    private var frameRegion = Region()
    private var frameSpawns = 0
    private var frameRecords = 0
    private var frameHead = 0
    private var frameDt: Float = 0
    private var frameIndex: UInt32 = 0
    private var frameSlot = 0
    private var frameReady = false
    private var clearPending = false
    private var liftRise: Float = 0
    private let lift: F4

    // read back (three frames old)
    private(set) var liveAdditive = 0
    private(set) var liveAlpha = 0
    private(set) var liveFlames = 0
    var liveCount: Int { liveAdditive + liveAlpha }
    var flameCap: Int { ringCap >= GPUParticles.capHigh ? GPUParticles.flameCapHigh : GPUParticles.flameCapEfficient }
    // heartbeat
    private(set) var spawnsPerSecond = 0
    private(set) var recordsPerSecond = 0
    private var spawnAcc = 0, recordAcc = 0
    private(set) var maxLiveSeen = 0
    private(set) var maxFlamesSeen = 0

    init(level: Level) {
        self.level = level
        let u = LaunchOptions.current.unknown
        simOff = u.firstIndex(of: "-fxSim").map { $0 + 1 < u.count && u[$0 + 1] == "off" } ?? false
        let L = level.layout.lift
        lift = F4(L.x, 0, L.z, max(0, L.r - 0.6))
        records.reserveCapacity(256)
        assert(MemoryLayout<GPUEmitter>.stride == 144, "Emitter is 144 bytes in Particles.metal")
        assert(MemoryLayout<GPUParticleParams>.stride == 64, "SimParams is 64 bytes in Particles.metal")
        assert(GRID == 128, "Particles.metal GROUND_N is 128")
    }

    // ---------------------------------------------------------------- setup
    /// Buffers, the deck height grid, the draw items; the compute pipelines and the flipbooks load off the main thread.
    func attach(_ r: MetalRenderer) {
        renderer = r
        let dev = r.device
        capacity = GPUParticles.capHigh
        // 96-byte particles, zeroed (life 0 = free slot)
        particles = dev.makeBuffer(length: capacity * 96, options: .storageModeShared)
        if let p = particles { memset(p.contents(), 0, p.length); p.label = "particles" }
        lists = dev.makeBuffer(length: MetalRenderer.arenaSlots * 2 * capacity * 4, options: .storageModePrivate)
        lists?.label = "particle lists"
        args = dev.makeBuffer(length: MetalRenderer.arenaSlots * GPUParticles.argsStride, options: .storageModeShared)
        args?.label = "particle draw args"
        if let a = args { memset(a.contents(), 0, a.length) }
        fallbackLight = dev.makeBuffer(length: LightingHub.blockBytes, options: .storageModeShared)
        if let f = fallbackLight { memset(f.contents(), 0, f.length) }
        buildGround(dev)
        psAlpha = r.pipeline("gpartAlpha")
        psAdd = r.pipeline("gpartAdd")
        r.registerPrePass(order: 100, "particles") { [unowned self] cb in self.encodeCompute(cb) }
        r.register(.transparent, order: 500, "particles alpha") { [unowned self] enc in self.draw(enc, alpha: true) }
        r.register(.transparent, order: 510, "particles add") { [unowned self] enc in self.draw(enc, alpha: false) }
        let t0 = FrameTimer.now()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let lib = dev.makeDefaultLibrary() else {
                AppLog.error("particles: no default library")
                return
            }
            func compute(_ name: String) -> MTLComputePipelineState? {
                guard let f = lib.makeFunction(name: name) else { AppLog.error("particles: missing \(name)"); return nil }
                do { return try dev.makeComputePipelineState(function: f) } catch {
                    AppLog.error("particles: \(name): \(error.localizedDescription)")
                    return nil
                }
            }
            let e = compute("fx_emit"), s = compute("fx_sim")
            let tex = GPUParticles.atlasNames.map { FXTextures.load($0, device: dev) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.psEmit = e
                self.psSim = s
                self.atlases = tex.map { $0 ?? FXTextures.flat(dev, [150, 255, 0, 255]) }
                self.ready = e != nil && s != nil && self.particles != nil && self.lists != nil && self.args != nil
                AppLog.info(String(format: "particles: compute %@ in %.0f ms, %d slots (%.1f MB), flipbooks %@", self.ready ? "ready" : "FAILED",
                                   (FrameTimer.now() - t0) * 1000, self.capacity, Double(self.capacity * 96) / 1048576,
                                   zip(GPUParticles.atlasNames, tex).map { $0.0 + ($0.1 == nil ? " (missing)" : "") }.joined(separator: " "))
                            + (self.simOff ? " | -fxSim off" : ""))
            }
        }
    }

    /// The level's deck heights per 1 m cell (x = height at the cell centre, y = slope along z; abyss = −1e9).
    private func buildGround(_ dev: MTLDevice) {
        var g = [SIMD2<Float>](repeating: SIMD2(-1e9, 0), count: GRID * GRID)
        for c in 0..<(GRID * GRID) where level.walkValue(c) != 0 {
            let x = Level.cellX(c), z = Level.cellZ(c)
            let h = level.groundY(x, z)
            let s = (level.groundY(x, z + 0.25) - level.groundY(x, z - 0.25)) / 0.5
            g[c] = SIMD2(h, s)
        }
        ground = g.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        ground?.label = "deck heights"
    }

    /// The tier's ring size (RenderQuality tier and the «Графика» density).
    func setTier(high: Bool, fxK: Float) {
        let cap = fxK < 0.5 ? GPUParticles.capLow : (high ? GPUParticles.capHigh : GPUParticles.capEfficient)
        if cap != ringCap { ringCap = cap; head %= cap }
    }

    /// Kill every particle (a new mission; memory warning).
    func clear() {
        records.removeAll(keepingCapacity: true)
        spawns = 0
        clearPending = true
    }

    // ---------------------------------------------------------------- emission
    /// N particles of `kind` around `at`: `jitter` box half extents (or on a ring of radius `ring`), base velocity `vel`
    /// ± `velJitter`, `radial` speed outward in xz (± radialJitter), `sphere` random speed in all directions (`upper`:
    /// the upper half), life and size ranges (size at birth → death), HDR colour (additive kinds) or albedo (lit
    /// kinds), gravity, drag; `delay` spreads the starts over that many seconds.
    func burst(_ kind: PK, _ n: Int, at p: F3, jitter: F3 = .zero, ring: Float = 0, delay: Float = 0,
               vel: F3 = .zero, velJitter: F3 = .zero, radial: Float = 0, radialJitter: Float = 0.3, sphere: Float = 0,
               upper: Bool = false, life: (Float, Float), size: (Float, Float), color: F4, gravity: Float = 0, drag: Float = 0,
               sizeJitter: Float = 0.25, colorJitter: Float = 0, spin: Float = 0, bounce: Float = 0, noFloor: Bool = false) {
        guard n > 0, records.count < GPUParticles.maxRecords, spawns + n <= ringCap / 2 else { return }
        var flags: UInt32 = 0
        if upper { flags |= 1 }
        if noFloor { flags |= 2 }
        let seed = rng.nextUInt32()
        records.append(GPUEmitter(pos: F4(p.x, p.y, p.z, ring), posJitter: F4(jitter.x, jitter.y, jitter.z, delay),
                                  vel: F4(vel.x, vel.y, vel.z, radial), velJitter: F4(velJitter.x, velJitter.y, velJitter.z, sphere),
                                  life: F4(life.0, life.1, size.0, size.1), color: color,
                                  phys: F4(gravity, drag, sizeJitter, radialJitter), extra: F4(spin, colorJitter, bounce, 0),
                                  meta: SIMD4(UInt32(spawns), UInt32(n), seed, kind.rawValue | flags << 8)))
        spawns += n
    }

    // ---------------------------------------------------------------- per frame
    /// The frame's records into the arena, this slot's counters (three frames old) read and reset; `dt` the effect time
    /// of the frame, `rise` the lift's.
    func upload(_ r: MetalRenderer, dt: Float, time: Float, rise: Float) {
        frameReady = false
        liftRise = rise
        let slot = r.arenaSlot
        frameSlot = slot
        if let a = args {
            let p = (a.contents() + slot * GPUParticles.argsStride).bindMemory(to: UInt32.self, capacity: 16)
            if ready && !simOff {
                liveAdditive = Int(p[1]); liveAlpha = Int(p[5]); liveFlames = Int(p[8])
                maxLiveSeen = max(maxLiveSeen, liveCount)
                maxFlamesSeen = max(maxFlamesSeen, liveFlames)
            }
            for k in 0..<16 { p[k] = 0 }
            p[0] = 6; p[4] = 6
        }
        guard ready, !simOff else { records.removeAll(keepingCapacity: true); spawns = 0; return }
        frameRegion = Region()
        frameRecords = 0
        frameSpawns = 0
        if !records.isEmpty {
            frameRegion = r.upload(records)
            if frameRegion.count == records.count {
                frameRecords = records.count
                frameSpawns = spawns
            }
        }
        spawnAcc += frameSpawns
        recordAcc += frameRecords
        records.removeAll(keepingCapacity: true)
        spawns = 0
        frameHead = head
        head = (head + frameSpawns) % max(1, ringCap)
        frameDt = dt
        frameIndex &+= 1
        frameReady = true
    }

    /// Pre-pass 100: emission and simulation (one compute encoder; the two dispatches run in order).
    private func encodeCompute(_ cb: MTLCommandBuffer) {
        guard frameReady, let r = renderer, let eps = psEmit, let sps = psSim, let P = particles, let L = lists, let A = args,
              let G = ground, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "particles"
        var S = GPUParticleParams()
        S.counts = SIMD4(UInt32(capacity), UInt32(ringCap), UInt32(frameHead), UInt32(frameSpawns))
        S.flags = SIMD4(UInt32(frameRecords), clearPending ? 1 : 0, r.frameTier == .high ? 1 : 0, frameIndex)
        S.time = F4(frameDt, r.frame.camPos.w, liftRise, 0)
        S.lift = lift
        clearPending = false
        let argsOff = frameSlot * GPUParticles.argsStride
        if frameSpawns > 0 && frameRecords > 0 {
            enc.setComputePipelineState(eps)
            enc.setBuffer(P, offset: 0, index: 0)
            enc.setBuffer(frameRegion.buffer ?? r.arena, offset: frameRegion.offset, index: 1)
            enc.setBytes(&S, length: MemoryLayout<GPUParticleParams>.stride, index: 3)
            enc.setBuffer(G, offset: 0, index: 6)
            let tg = min(64, eps.maxTotalThreadsPerThreadgroup)
            enc.dispatchThreadgroups(MTLSize(width: (frameSpawns + tg - 1) / tg, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        }
        enc.setComputePipelineState(sps)
        enc.setBuffer(P, offset: 0, index: 0)
        enc.setBuffer(L, offset: frameSlot * 2 * capacity * 4, index: 1)
        enc.setBuffer(A, offset: argsOff, index: 2)
        enc.setBytes(&S, length: MemoryLayout<GPUParticleParams>.stride, index: 3)
        var F = r.frame
        enc.setBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: 4)
        bindLightBlock(enc, r)
        enc.setBuffer(G, offset: 0, index: 6)
        let tg = min(GPUParticles.threadsPerGroup, sps.maxTotalThreadsPerThreadgroup)
        enc.dispatchThreadgroups(MTLSize(width: (capacity + tg - 1) / tg, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// WP2's light block for the simulation's lighting: the hub's state of this frame (cones of the last one) copied into
    /// the arena, laid out like LightingHub's own upload; a zero block without the hub.
    private func bindLightBlock(_ enc: MTLComputeCommandEncoder, _ r: MetalRenderer) {
        guard let hub = LightingHub.current, let a = r.alloc(UInt8.self, LightingHub.blockBytes) else {
            enc.setBuffer(fallbackLight, offset: 0, index: 5)
            return
        }
        let base = UnsafeMutableRawPointer(a.0)
        var h = hub.header
        let n = min(hub.lights.count, LightingHub.maxLights)
        h.info.x = Float(n)
        withUnsafeBytes(of: &h) { base.copyMemory(from: $0.baseAddress!, byteCount: MemoryLayout<LightBlockHeader>.stride) }
        let cellsAt = base + MemoryLayout<LightBlockHeader>.stride
        hub.cells.withUnsafeBytes { cellsAt.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if n > 0 {
            let lightsAt = cellsAt + hub.cells.count * 4
            hub.lights.withUnsafeBytes { lightsAt.copyMemory(from: $0.baseAddress!, byteCount: n * MemoryLayout<GridLight>.stride) }
        }
        enc.setBuffer(r.arena, offset: a.1, index: 5)
    }

    /// Transparent 500 (alpha list) / 510 (additive list): one indirect draw each.
    private func draw(_ enc: MTLRenderCommandEncoder, alpha: Bool) {
        guard frameReady, let r = renderer, let ps = alpha ? psAlpha : psAdd, let P = particles, let L = lists, let A = args else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(P, offset: 0, index: BufferIndex.instances)
        enc.setVertexBuffer(L, offset: (frameSlot * 2 + (alpha ? 1 : 0)) * capacity * 4, index: 3)
        if alpha {
            if let t = atlases[2] { enc.setFragmentTexture(t, index: 8) }
        } else {
            if let t = atlases[0] { enc.setFragmentTexture(t, index: 6) }
            if let t = atlases[1] { enc.setFragmentTexture(t, index: 7) }
        }
        enc.drawPrimitives(type: .triangle, indirectBuffer: A, indirectBufferOffset: frameSlot * GPUParticles.argsStride + (alpha ? 16 : 0))
        let n = alpha ? liveAlpha : liveAdditive
        r.count(draws: 1, instances: n, triangles: 2 * n)
    }

    /// Heartbeat: spawns and records per second since the last call.
    func takeRates() -> (spawns: Int, records: Int) {
        defer { spawnAcc = 0; recordAcc = 0 }
        return (spawnAcc, recordAcc)
    }

    /// The pools' live maxima since the last call (cap counters of the `hb fx` line).
    func takeMaxima() -> (live: Int, flames: Int) {
        defer { maxLiveSeen = 0; maxFlamesSeen = 0 }
        return (maxLiveSeen, maxFlamesSeen)
    }
}

// ================================================================
//  FX TEXTURES — the effects' own textures (Resources/FX): IHT1
//  containers (tools/blender/iht.py; ASTC or RGBA8 levels) read into
//  textures with replace(region:) (no MetalKit), off the main thread.
// ================================================================
enum FXTextures {
    /// Resources/FX/<name>.iht → a 2D texture with its mips; nil when missing / unreadable / no ASTC on this GPU.
    static func load(_ name: String, device: MTLDevice) -> MTLTexture? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "iht", subdirectory: "FX")
                ?? Bundle.main.url(forResource: name, withExtension: "iht"),
              let d = try? Data(contentsOf: u) else {
            AppLog.error("fx: missing \(name).iht")
            return nil
        }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLTexture? in
            guard let base = raw.baseAddress, raw.count >= 64 else { return nil }
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            guard String(bytes: raw[0..<4], encoding: .ascii) == "IHT1", u32(4) == 1, Int(u32(8)) == raw.count else { return nil }
            let fmt = u32(16), w = Int(u32(20)), h = Int(u32(24)), mips = Int(u32(32)), tab = Int(u32(36))
            let pf: MTLPixelFormat
            switch fmt {
            case 1: pf = .astc_4x4_ldr
            case 2: pf = .astc_5x5_ldr
            case 3: pf = .astc_6x6_ldr
            case 4: pf = .astc_8x8_ldr
            case 16: pf = .rgba8Unorm
            default: return nil
            }
            if fmt < 16 && !(device.supportsFamily(.apple2)) { return nil }
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2D
            desc.pixelFormat = pf
            desc.width = w
            desc.height = h
            desc.mipmapLevelCount = mips
            desc.usage = .shaderRead
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            for m in 0..<mips {
                let rec = tab + 16 * m
                let off = Int(u32(rec)), n = Int(u32(rec + 4)), bpr = Int(u32(rec + 8))
                guard off + n <= raw.count else { return nil }
                tex.replace(region: MTLRegionMake2D(0, 0, max(1, w >> m), max(1, h >> m)), mipmapLevel: m, slice: 0,
                            withBytes: base + off, bytesPerRow: bpr, bytesPerImage: n)
            }
            tex.label = name
            return tex
        }
    }

    /// 1×1 RGBA8 stand-in.
    static func flat(_ device: MTLDevice, _ v: [UInt8]) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        v.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        return t
    }
}
