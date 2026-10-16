import Foundation
import Metal
import MetalKit
import QuartzCore

// ================================================================
//  METAL RENDERER — device, pipelines, the per-frame upload arena
//  (three frames in flight) and the encoding of one frame in the
//  order of the web scene: opaque level, squad, swarm, corpses, props,
//  then the transparent passes (haze, pad mark, floor glows, decals,
//  splashes / telegraphs / rings, particles, ribbons, weather).
//  MetalWorld fills the arena and a DrawList, then calls draw().
// ================================================================

/// A slice of the current frame's upload arena.
struct Region {
    var offset: Int = 0
    var count: Int = 0
}

/// Which pipeline draws a mesh batch.
enum MeshPass: Int {
    /// MeshStandardMaterial with vertex colours + aGlow (marines, turret, medkits).
    case props
    /// Lambert with the instance colour (corpses).
    case lambert
    /// MeshBasicMaterial (glob, grenade, beacon tips).
    case unlit
}

/// Instanced draw of one exported mesh.
final class MeshBatch {
    let mesh: GPUMesh
    let pass: MeshPass
    /// Material constants (roughness, metalness, snow caps, glow).
    let material: MaterialUniforms
    var instances: [MeshInstance] = []
    var region = Region()

    init(mesh: GPUMesh, pass: MeshPass, roughness: Float = 0.62, metalness: Float = 0.45, glow: Float = 2.2, snow: Bool = false) {
        self.mesh = mesh
        self.pass = pass
        material = MaterialUniforms(pbr: F4(roughness, metalness, snow ? 1 : 0, glow), floor: F4(0, 0, 0, 0))
        instances.reserveCapacity(8)
    }
}

/// Everything one frame draws (offsets into the arena of that frame).
final class DrawList {
    var bugs = [Region](repeating: Region(), count: 4)
    var batches: [MeshBatch] = []
    var decals = Region()
    var glowSprites = Region()
    var ringSprites = Region()
    var fillSprites = Region()
    var laneSprites = Region()
    var indicators = Region()
    var pn = Region()
    var pa = Region()
    var ribbons = Region()
    var liftRise: Float = 0
    var weather = F4(0, 0, 0, 0)
    var snow = 0, motes = 0, mist = 0
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    static let framesInFlight = 3
    static let arenaSize = 4 * 1024 * 1024

    let device: MTLDevice
    let queue: MTLCommandQueue
    let store: MeshStore
    weak var view: MTKView?
    let colorFormat: MTLPixelFormat = .bgra8Unorm
    let depthFormat: MTLPixelFormat = .depth32Float

    // pipelines
    private var psProps: MTLRenderPipelineState?
    private var psFloor: MTLRenderPipelineState?
    private var psTexturedOpaque: MTLRenderPipelineState?
    private var psTexturedAlpha: MTLRenderPipelineState?
    private var psGlowQuads: MTLRenderPipelineState?
    private var psHaze: MTLRenderPipelineState?
    private var psMeshProps: MTLRenderPipelineState?
    private var psMeshLambert: MTLRenderPipelineState?
    private var psMeshUnlit: MTLRenderPipelineState?
    private var psBug: MTLRenderPipelineState?
    private var psGlint: MTLRenderPipelineState?
    private var psDecal: MTLRenderPipelineState?
    private var psSprite: MTLRenderPipelineState?
    private var psParticleAdd: MTLRenderPipelineState?
    private var psParticleAlpha: MTLRenderPipelineState?
    private var psRibbon: MTLRenderPipelineState?
    private var psWeatherAlpha: MTLRenderPipelineState?
    private var psWeatherAdd: MTLRenderPipelineState?
    private var dsOpaque: MTLDepthStencilState?
    private var dsTransparent: MTLDepthStencilState?
    private(set) var ready = false
    private(set) var pipelineErrors: [String] = []

    // per-frame upload arena
    private var arenas: [MTLBuffer] = []
    private var arenaIndex = 0
    private var arenaOffset = 0
    private var arenaOverflow = false
    private let inflight = DispatchSemaphore(value: MetalRenderer.framesInFlight)
    private var waitingForFrame = false

    var frame = FrameUniforms()
    let list = DrawList()

    // static level meshes and their materials
    private var levelDraws: [(GPUMesh, MaterialUniforms, Int)] = []   // kind: 0 props, 1 floor grating, 2 floor slab, 3 lift floor, 4 lift props
    private var bugMeshes: [GPUMesh] = []
    private let matProps = MaterialUniforms(pbr: F4(0.62, 0.45, 1, 2.2), floor: F4(0, 0, 0, 0))

    // stats (smoothed)
    private(set) var drawCalls = 0
    private(set) var instanceCount = 0
    private(set) var triangles = 0
    private(set) var encodeMs: Double = 0
    private(set) var waitMs: Double = 0
    private(set) var gpuMs: Double = 0
    private var gpuMsShared: Double = 0
    private let gpuLock = NSLock()
    private(set) var frames = 0
    private(set) var skippedFrames = 0

    init?(device: MTLDevice, store: MeshStore) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        self.store = store
        super.init()
        q.label = "IceHive"
        for k in 0..<MetalRenderer.framesInFlight {
            guard let b = device.makeBuffer(length: MetalRenderer.arenaSize, options: [.storageModeShared, .cpuCacheModeWriteCombined]) else { return nil }
            b.label = "arena\(k)"
            arenas.append(b)
        }
    }

    // ---------------------------------------------------------------- setup
    /// Compile every pipeline (call once, off the main thread, behind the loading cover).
    func buildPipelines() -> String {
        let t0 = FrameTimer.now()
        guard let lib = device.makeDefaultLibrary() else {
            pipelineErrors.append("no default library")
            return "pipelines: no default Metal library"
        }
        let vd = MTLVertexDescriptor()
        let attrs: [(MTLVertexFormat, Int)] = [(.float3, 0), (.float3, 12), (.float3, 24), (.float, 36), (.float3, 40)]
        for (k, a) in attrs.enumerated() {
            vd.attributes[k].format = a.0
            vd.attributes[k].offset = a.1
            vd.attributes[k].bufferIndex = BufferIndex.vertices
        }
        vd.layouts[BufferIndex.vertices].stride = MeshStore.stride
        vd.layouts[BufferIndex.vertices].stepFunction = .perVertex

        enum Blend { case none, alpha, add, multiply }
        let errLock = NSLock()
        func make(_ label: String, _ vs: String, _ fs: String, _ blend: Blend, vertexDescriptor: Bool) -> MTLRenderPipelineState? {
            guard let v = lib.makeFunction(name: vs), let f = lib.makeFunction(name: fs) else {
                errLock.lock(); pipelineErrors.append("\(label): missing function \(vs) / \(fs)"); errLock.unlock()
                return nil
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = v
            d.fragmentFunction = f
            if vertexDescriptor { d.vertexDescriptor = vd }
            d.depthAttachmentPixelFormat = depthFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = colorFormat
            switch blend {
            case .none:
                c.isBlendingEnabled = false
            case .alpha:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .add:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero
                c.destinationAlphaBlendFactor = .one
            case .multiply:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .destinationColor
                c.destinationRGBBlendFactor = .zero
                c.sourceAlphaBlendFactor = .zero
                c.destinationAlphaBlendFactor = .one
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                errLock.lock(); pipelineErrors.append("\(label): \(error.localizedDescription)"); errLock.unlock()
                return nil
            }
        }
        // the 18 pipelines compile in parallel (device-specific compilation dominates a cold first launch)
        let specs: [(String, String, String, Blend, Bool)] = [
            ("props", "vs_static", "fs_props", .none, true), ("floor", "vs_static", "fs_floor", .none, true),
            ("hazard", "vs_static", "fs_textured", .none, true), ("pad", "vs_static", "fs_textured", .alpha, true),
            ("glowQuads", "vs_static", "fs_basic_textured", .add, true), ("haze", "vs_static", "fs_basic_textured", .alpha, true),
            ("meshProps", "vs_mesh", "fs_props", .none, true), ("meshLambert", "vs_mesh", "fs_lambert", .none, true),
            ("meshUnlit", "vs_mesh", "fs_unlit", .none, true), ("bug", "vs_bug", "fs_bug", .none, true),
            ("glint", "vs_glint", "fs_glint", .add, false), ("decal", "vs_decal", "fs_decal", .multiply, false),
            ("sprite", "vs_sprite", "fs_sprite", .add, false), ("particleAdd", "vs_particle", "fs_particle_add", .add, false),
            ("particleAlpha", "vs_particle", "fs_particle_alpha", .alpha, false), ("ribbon", "vs_ribbon", "fs_ribbon", .add, false),
            ("weatherAlpha", "vs_weather", "fs_weather", .alpha, false), ("weatherAdd", "vs_weather", "fs_weather", .add, false),
        ]
        var states = [MTLRenderPipelineState?](repeating: nil, count: specs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: specs.count) { i in
            let sp = specs[i]
            let st = make(sp.0, sp.1, sp.2, sp.3, vertexDescriptor: sp.4)
            lock.lock(); states[i] = st; lock.unlock()
        }
        psProps = states[0]; psFloor = states[1]; psTexturedOpaque = states[2]; psTexturedAlpha = states[3]
        psGlowQuads = states[4]; psHaze = states[5]; psMeshProps = states[6]; psMeshLambert = states[7]
        psMeshUnlit = states[8]; psBug = states[9]; psGlint = states[10]; psDecal = states[11]
        psSprite = states[12]; psParticleAdd = states[13]; psParticleAlpha = states[14]; psRibbon = states[15]
        psWeatherAlpha = states[16]; psWeatherAdd = states[17]

        let od = MTLDepthStencilDescriptor()
        od.depthCompareFunction = .less
        od.isDepthWriteEnabled = true
        dsOpaque = device.makeDepthStencilState(descriptor: od)
        let td = MTLDepthStencilDescriptor()
        td.depthCompareFunction = .lessEqual
        td.isDepthWriteEnabled = false
        dsTransparent = device.makeDepthStencilState(descriptor: td)

        // static level: floors (grating / slab + snow mask), merged props, the lift deck and its props (they rise)
        func floorMat(_ bias: Float) -> MaterialUniforms { MaterialUniforms(pbr: F4(0.72, 0.42, 0, 0), floor: F4(bias, 1, 0, 0)) }
        levelDraws = [
            (store.mesh("level_floor_grating"), floorMat(0), 1),
            (store.mesh("level_floor_slab"), floorMat(0.18), 2),
            (store.mesh("lift_floor"), floorMat(0), 3),
            (store.mesh("level_props"), matProps, 0),
            (store.mesh("lift_props"), matProps, 4),
        ]
        bugMeshes = ["bug_runner", "bug_spitter", "bug_brute", "bug_boomer"].map { store.mesh($0) }
        ready = psProps != nil && psBug != nil && dsOpaque != nil
        return String(format: "pipelines built in %.0f ms", (FrameTimer.now() - t0) * 1000)
            + (pipelineErrors.isEmpty ? "" : " ERRORS: " + pipelineErrors.joined(separator: "; "))
    }

    // ---------------------------------------------------------------- arena
    /// Start filling the next frame: waits until the GPU has released that frame's arena.
    func beginFrame() {
        let t0 = FrameTimer.now()
        inflight.wait()
        waitingForFrame = true
        waitMs += ((FrameTimer.now() - t0) * 1000 - waitMs) * 0.1
        arenaIndex = (arenaIndex + 1) % MetalRenderer.framesInFlight
        arenaOffset = 0
        list.batches.removeAll(keepingCapacity: true)
    }

    /// Room for `count` values of T in this frame's arena (256-byte aligned); nil when the arena is full.
    func alloc<T>(_ type: T.Type, _ count: Int) -> (UnsafeMutablePointer<T>, Int)? {
        let size = MemoryLayout<T>.stride * max(1, count)
        let start = (arenaOffset + 255) & ~255
        if start + size > MetalRenderer.arenaSize {
            if !arenaOverflow { arenaOverflow = true; AppLog.error("metal: frame arena full (\(start + size) bytes)") }
            return nil
        }
        arenaOffset = start + size
        let p = (arenas[arenaIndex].contents() + start).bindMemory(to: T.self, capacity: max(1, count))
        return (p, start)
    }

    /// Copy an array into the arena.
    func upload<T>(_ values: [T]) -> Region {
        if values.isEmpty { return Region() }
        guard let a = alloc(T.self, values.count) else { return Region() }
        values.withUnsafeBufferPointer { src in a.0.update(from: src.baseAddress!, count: values.count) }
        return Region(offset: a.1, count: values.count)
    }

    /// The frame was built but will not be drawn (no drawable / not ready): release its arena.
    func cancelFrame() {
        if waitingForFrame { waitingForFrame = false; inflight.signal() }
    }

    // ---------------------------------------------------------------- MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard waitingForFrame else { return }
        let t0 = FrameTimer.now()
        guard ready, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else {
            skippedFrames += 1
            cancelFrame()
            return
        }
        cb.label = "frame"
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        let fogc = displayRGB(0x1a2737)
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(fogc.x), green: Double(fogc.y), blue: Double(fogc.z), alpha: 1)
        rpd.depthAttachment?.loadAction = .clear
        rpd.depthAttachment?.storeAction = .dontCare
        rpd.depthAttachment?.clearDepth = 1
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            skippedFrames += 1
            cancelFrame()
            return
        }
        drawCalls = 0
        instanceCount = 0
        triangles = 0
        encode(enc)
        enc.endEncoding()
        cb.present(drawable)
        let sem = inflight
        cb.addCompletedHandler { [weak self] c in
            let ms = (c.gpuEndTime - c.gpuStartTime) * 1000
            if let s = self, ms > 0 && ms < 1000 {
                s.gpuLock.lock()
                s.gpuMsShared += (ms - s.gpuMsShared) * 0.1
                s.gpuLock.unlock()
            }
            sem.signal()
        }
        waitingForFrame = false
        cb.commit()
        frames += 1
        encodeMs += ((FrameTimer.now() - t0) * 1000 - encodeMs) * 0.1
        gpuLock.lock()
        gpuMs = gpuMsShared
        gpuLock.unlock()
    }

    // ---------------------------------------------------------------- encoding
    private func encode(_ enc: MTLRenderCommandEncoder) {
        let arena = arenas[arenaIndex]
        var F = frame
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.back)
        enc.setDepthStencilState(dsOpaque)

        // ---- opaque level
        let snowTex = store.texture("snow")
        for (mesh, mat0, kind) in levelDraws {
            var mat = mat0
            if kind == 3 || kind == 4 { mat.floor.z = list.liftRise }
            switch kind {
            case 1, 2, 3:
                guard let ps = psFloor else { continue }
                enc.setRenderPipelineState(ps)
                enc.setFragmentTexture(store.texture(kind == 2 ? "slab" : "grating"), index: TextureIndex.main)
                enc.setFragmentTexture(snowTex, index: TextureIndex.snow)
            default:
                guard let ps = psProps else { continue }
                enc.setRenderPipelineState(ps)
            }
            drawStatic(enc, mesh, &mat)
        }
        // hazard strips just above the floor
        if let ps = psTexturedOpaque {
            enc.setRenderPipelineState(ps)
            enc.setFragmentTexture(store.texture("hazard"), index: TextureIndex.main)
            var mat = MaterialUniforms(pbr: F4(0.8, 0.1, 0, 0), floor: F4(0, 0, 0, 0))
            enc.setDepthBias(-1, slopeScale: -1, clamp: 0)
            drawStatic(enc, store.mesh("level_hazard"), &mat)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        // ---- squad, props, corpses (instanced meshes)
        for b in list.batches where b.region.count > 0 {
            let ps: MTLRenderPipelineState?
            switch b.pass {
            case .props: ps = psMeshProps
            case .lambert: ps = psMeshLambert
            case .unlit: ps = psMeshUnlit
            }
            guard let p = ps else { continue }
            enc.setRenderPipelineState(p)
            var mat = b.material
            enc.setVertexBuffer(arena, offset: b.region.offset, index: BufferIndex.instances)
            enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
            drawMesh(enc, b.mesh, instances: b.region.count)
        }

        // ---- swarm: one instanced draw per bug type
        if let ps = psBug {
            enc.setRenderPipelineState(ps)
            for t in 0..<4 where list.bugs[t].count > 0 {
                enc.setVertexBuffer(arena, offset: list.bugs[t].offset, index: BufferIndex.instances)
                drawMesh(enc, bugMeshes[t], instances: list.bugs[t].count)
            }
        }

        // ---- transparent passes
        enc.setDepthStencilState(dsTransparent)
        enc.setCullMode(.none)
        if let ps = psHaze {
            enc.setRenderPipelineState(ps)
            enc.setFragmentTexture(store.texture("haze"), index: TextureIndex.main)
            var mat = MaterialUniforms(pbr: .zero, floor: .zero)
            drawStatic(enc, store.mesh("level_haze"), &mat)
        }
        if let ps = psTexturedAlpha {
            enc.setRenderPipelineState(ps)
            enc.setFragmentTexture(store.texture("pad"), index: TextureIndex.main)
            var mat = MaterialUniforms(pbr: F4(0.85, 0, 0, 0), floor: .zero)
            enc.setDepthBias(-2, slopeScale: -2, clamp: 0)
            drawStatic(enc, store.mesh("level_pad_mark"), &mat)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if let ps = psGlowQuads {
            enc.setRenderPipelineState(ps)
            enc.setFragmentTexture(store.texture("glow"), index: TextureIndex.main)
            var mat = MaterialUniforms(pbr: .zero, floor: .zero)
            drawStatic(enc, store.mesh("level_glow"), &mat)
        }
        if let ps = psDecal, list.decals.count > 0 {
            enc.setRenderPipelineState(ps)
            enc.setDepthBias(-4, slopeScale: -2, clamp: 0)
            enc.setVertexBuffer(arena, offset: list.decals.offset, index: BufferIndex.instances)
            enc.setFragmentTexture(store.texture("decals"), index: TextureIndex.main)
            drawQuads(enc, list.decals.count)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if let ps = psSprite {
            enc.setRenderPipelineState(ps)
            sprites(enc, arena, list.glowSprites, "glow")
            sprites(enc, arena, list.ringSprites, "ring")
            sprites(enc, arena, list.fillSprites, "fill")
            sprites(enc, arena, list.laneSprites, "lane")
            sprites(enc, arena, list.indicators, "glow")
        }
        // swarm glints: one soft additive dot per speckle of every visible bug (instance = bug × speckle)
        if let ps = psGlint {
            enc.setRenderPipelineState(ps)
            for t in 0..<4 where list.bugs[t].count > 0 && !bugMeshes[t].glints.isEmpty {
                let g = bugMeshes[t].glints
                var n = UInt32(g.count / 2)
                enc.setVertexBuffer(arena, offset: list.bugs[t].offset, index: BufferIndex.instances)
                g.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: BufferIndex.material) }
                enc.setVertexBytes(&n, length: 4, index: 4)
                drawQuads(enc, list.bugs[t].count * Int(n))
            }
        }
        let noise = store.noise
        if let ps = psParticleAlpha, list.pn.count > 0 {
            enc.setRenderPipelineState(ps)
            enc.setVertexBuffer(arena, offset: list.pn.offset, index: BufferIndex.instances)
            enc.setFragmentTexture(noise, index: TextureIndex.noise)
            drawQuads(enc, list.pn.count)
        }
        if let ps = psParticleAdd, list.pa.count > 0 {
            enc.setRenderPipelineState(ps)
            enc.setVertexBuffer(arena, offset: list.pa.offset, index: BufferIndex.instances)
            enc.setFragmentTexture(noise, index: TextureIndex.noise)
            drawQuads(enc, list.pa.count)
        }
        if let ps = psRibbon, list.ribbons.count > 0 {
            enc.setRenderPipelineState(ps)
            enc.setVertexBuffer(arena, offset: list.ribbons.offset, index: BufferIndex.instances)
            enc.setFragmentTexture(store.texture("dash"), index: 0)
            enc.setFragmentTexture(store.texture("streak"), index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: list.ribbons.count)
            drawCalls += 1
            triangles += list.ribbons.count / 3
        }
        // weather: snowfall + mist (alpha), motes rising from the abyss (additive)
        if let ps = psWeatherAlpha, list.snow + list.mist > 0 {
            enc.setRenderPipelineState(ps)
            if list.snow > 0 { weather(enc, kind: 0, count: list.snow) }
            if list.mist > 0 { weather(enc, kind: 2, count: list.mist) }
        }
        if let ps = psWeatherAdd, list.motes > 0 {
            enc.setRenderPipelineState(ps)
            weather(enc, kind: 1, count: list.motes)
        }
    }

    private func sprites(_ enc: MTLRenderCommandEncoder, _ arena: MTLBuffer, _ r: Region, _ tex: String) {
        if r.count == 0 { return }
        enc.setVertexBuffer(arena, offset: r.offset, index: BufferIndex.instances)
        enc.setFragmentTexture(store.texture(tex), index: TextureIndex.main)
        drawQuads(enc, r.count)
    }

    private func drawStatic(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, _ mat: inout MaterialUniforms) {
        enc.setVertexBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        drawCalls += 1
        triangles += mesh.indexCount / 3
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, instances: Int) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices,
                                  indexBufferOffset: 0, instanceCount: instances)
        drawCalls += 1
        instanceCount += instances
        triangles += mesh.indexCount / 3 * instances
    }

    private func drawQuads(_ enc: MTLRenderCommandEncoder, _ n: Int) {
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
        drawCalls += 1
        instanceCount += n
        triangles += 2 * n
    }

    private func weather(_ enc: MTLRenderCommandEncoder, kind: Float, count: Int) {
        var w = (F4(list.weather.x, list.weather.y, list.weather.z, kind), F4(Float(count), 0, 0, 0))
        enc.setVertexBytes(&w, length: MemoryLayout<F4>.stride * 2, index: BufferIndex.instances)
        drawQuads(enc, count)
    }
}
